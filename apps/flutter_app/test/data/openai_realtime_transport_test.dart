import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/core/network/api_exception.dart';
import 'package:voice_assistant/data/voice/openai_realtime_transport.dart';
import 'package:voice_assistant/data/voice/realtime_link.dart';
import 'package:voice_assistant/domain/entities/user_preferences.dart';
import 'package:voice_assistant/domain/repositories/repositories.dart';
import 'package:voice_assistant/domain/voice/voice_session_state.dart';
import 'package:voice_assistant/domain/voice/voice_transport.dart';

import '../support/fakes.dart';

class FakeLink implements RealtimeLink {
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _states = StreamController<RealtimeLinkState>.broadcast();
  final sent = <Map<String, Object?>>[];
  final micStates = <bool>[];
  String? offerAnswer;
  String? dataChannelLabel;
  AudioSettings? audio;
  Object? connectError;
  bool closed = false;
  ({double input, double output}) currentLevels = (input: 0.0, output: 0.0);

  void serverSends(Map<String, dynamic> event) => _messages.add(event);
  void fail() => _states.add(RealtimeLinkState.failed);

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Stream<RealtimeLinkState> get states => _states.stream;

  @override
  Future<void> connect({
    required Future<String> Function(String offerSdp) exchangeSdp,
    required String dataChannelLabel,
    required AudioSettings audio,
  }) async {
    if (connectError != null) throw connectError!;
    this.dataChannelLabel = dataChannelLabel;
    this.audio = audio;
    offerAnswer = await exchangeSdp('v=0 offer');
  }

  @override
  void send(Map<String, Object?> event) => sent.add(event);

  @override
  void setMicrophoneEnabled(bool enabled) => micStates.add(enabled);

  @override
  Future<({double input, double output})> levels() async => currentLevels;

  @override
  Future<void> close() async => closed = true;
}

class FakeSessions implements VoiceSessionRepository {
  FakeSessions({this.pushToTalk = false});

  final bool pushToTalk;
  final started = <String?>[];
  final saved = <(String, String, String, String?)>[];
  final ended = <String>[];
  ApiException? startError;

  @override
  Future<VoiceSessionGrant> start({String? conversationId, String? providerId, String? modelId}) async {
    if (startError != null) throw startError!;
    started.add(conversationId);
    return VoiceSessionGrant(
      id: 'vs-${started.length}',
      conversationId: conversationId ?? 'new-conversation',
      provider: providerId ?? 'openai',
      model: modelId ?? 'gpt-realtime-2.1',
      transport: 'webrtc',
      endpoint: 'https://api.openai.com/v1/realtime/calls',
      clientSecret: 'ek_ephemeral_${started.length}',
      expiresAt: DateTime.utc(2030),
      pushToTalk: pushToTalk,
      dataChannel: 'oai-events',
    );
  }

  @override
  Future<void> saveTranscript(
    String sessionId, {
    required String role,
    required String content,
    String? itemId,
  }) async => saved.add((sessionId, role, content, itemId));

  @override
  Future<void> end(String sessionId) async => ended.add(sessionId);
}

class SdpAdapter implements HttpClientAdapter {
  SdpAdapter({this.status = 201});

  final int status;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(status < 300 ? 'v=0 answer' : 'error', status);
  }

  @override
  void close({bool force = false}) {}
}

final _selection = (provider: sampleCatalog.providers.single, model: sampleCatalog.providers.single.models.last);

({
  OpenAIRealtimeTransport transport,
  FakeSessions sessions,
  List<FakeLink> links,
  SdpAdapter sdp,
  List<VoiceEvent> events,
})
build({bool pushToTalk = false, int sdpStatus = 201, String? conversationId}) {
  final sessions = FakeSessions(pushToTalk: pushToTalk);
  final links = <FakeLink>[];
  final sdp = SdpAdapter(status: sdpStatus);
  final transport = OpenAIRealtimeTransport(
    sessions: sessions,
    options: VoiceSessionOptions(
      selection: _selection,
      conversationId: conversationId,
      audio: const AudioSettings(noiseSuppression: false),
    ),
    linkFactory: () {
      final link = FakeLink();
      links.add(link);
      return link;
    },
    sdpClient: Dio()..httpClientAdapter = sdp,
    levelInterval: const Duration(milliseconds: 10),
  );
  final events = <VoiceEvent>[];
  transport.events.listen(events.add);
  return (transport: transport, sessions: sessions, links: links, sdp: sdp, events: events);
}

Map<String, dynamic> itemAdded(String id, String role) => {
  'type': 'conversation.item.added',
  'item': {'id': id, 'type': 'message', 'role': role},
};

void main() {
  test('connect: backend mints the session, SDP goes to OpenAI with the ephemeral secret', () async {
    final setup = build(conversationId: 'c1');
    await setup.transport.connect();
    await pumpEventQueue();

    expect(setup.sessions.started, ['c1']);
    final [request] = setup.sdp.requests;
    expect(request.uri.toString(), 'https://api.openai.com/v1/realtime/calls');
    expect(request.method, 'POST');
    expect(request.headers['Authorization'], 'Bearer ek_ephemeral_1');
    expect(request.contentType, 'application/sdp');
    expect(request.data, 'v=0 offer');
    expect(setup.links.single.offerAnswer, 'v=0 answer');
    expect(setup.links.single.dataChannelLabel, 'oai-events');
    expect(setup.links.single.audio?.noiseSuppression, isFalse);
    expect(setup.links.single.micStates, [true]); // hands-free: microphone live
    expect(setup.transport.conversationId, 'c1');
    expect(setup.events.whereType<VoiceSessionConfigured>().single.pushToTalk, isFalse);
    expect(setup.events.last, isA<VoiceConnected>());
    await setup.transport.close();
  });

  test('provider events become voice events and transcripts are saved in order', () async {
    final setup = build();
    await setup.transport.connect();
    final link = setup.links.single;

    link.serverSends({'type': 'input_audio_buffer.speech_started'});
    link.serverSends(itemAdded('u1', 'user'));
    link.serverSends({'type': 'input_audio_buffer.speech_stopped'});
    link.serverSends(itemAdded('a1', 'assistant'));
    link.serverSends({'type': 'output_audio_buffer.started', 'response_id': 'r'});
    link.serverSends({'type': 'response.output_audio_transcript.done', 'item_id': 'a1', 'transcript': 'Hi there!'});
    link.serverSends({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'u1',
      'transcript': 'Hello',
    });
    link.serverSends({'type': 'output_audio_buffer.stopped', 'response_id': 'r'});
    await pumpEventQueue();

    // The controller requests the connection before the transport reports events.
    final connecting = reduceVoiceState(const VoiceSessionState.initial(), const VoiceConnectRequested());
    final state = setup.events.fold(connecting, reduceVoiceState);
    expect(state.phase, VoicePhase.idle);
    expect(state.transcript.map((e) => e.text), ['Hello', 'Hi there!']);
    expect(setup.sessions.saved, [('vs-1', 'user', 'Hello', 'u1'), ('vs-1', 'assistant', 'Hi there!', 'a1')]);
    await setup.transport.close();
  });

  test('audio levels follow the speaker: microphone, or playback while the assistant talks', () async {
    final setup = build();
    await setup.transport.connect();
    final link = setup.links.single..currentLevels = (input: 0.25, output: 0.0);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final micLevel = setup.events.whereType<VoiceLevelChanged>().last.level;
    expect(micLevel, closeTo(0.7, 0.01)); // sqrt(0.25) * 1.4

    link
      ..serverSends({'type': 'output_audio_buffer.started', 'response_id': 'r'})
      ..currentLevels = (input: 0.0, output: 0.04);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(setup.events.whereType<VoiceLevelChanged>().last.level, closeTo(0.28, 0.01));
    await setup.transport.close();
  });

  test('push-to-talk: mic only while held; release commits and asks for a reply', () async {
    final setup = build(pushToTalk: true);
    await setup.transport.connect();
    final link = setup.links.single;
    expect(setup.transport.pushToTalk, isTrue);
    expect(link.micStates, [false]);

    await setup.transport.startTalking();
    expect(link.micStates.last, isTrue);
    expect(link.sent.map((c) => c['type']), ['input_audio_buffer.clear']);
    await setup.transport.stopTalking();
    expect(link.micStates.last, isFalse);
    expect(link.sent.map((c) => c['type']), [
      'input_audio_buffer.clear',
      'input_audio_buffer.commit',
      'response.create',
    ]);
    await pumpEventQueue(); // broadcast events are delivered asynchronously
    expect(setup.events.whereType<VoiceUserSpeechStarted>(), hasLength(1));
    expect(setup.events.whereType<VoiceUserSpeechStopped>(), hasLength(1));
    await setup.transport.close();
  });

  test('mute toggles the microphone; interrupt cancels and clears playback', () async {
    final setup = build();
    await setup.transport.connect();
    final link = setup.links.single;
    await setup.transport.setMuted(true);
    expect(link.micStates.last, isFalse);
    await setup.transport.setMuted(false);
    expect(link.micStates.last, isTrue);
    await setup.transport.interrupt();
    expect(link.sent.map((c) => c['type']), ['response.cancel', 'output_audio_buffer.clear']);
    await setup.transport.close();
  });

  test('a dropped connection reconnects once with a fresh session in the same conversation', () async {
    final setup = build();
    await setup.transport.connect();
    setup.links.single.fail();
    await pumpEventQueue();
    await pumpEventQueue();

    expect(setup.sessions.started, [null, 'new-conversation']);
    expect(setup.links, hasLength(2));
    expect(setup.links.first.closed, isTrue);
    expect(setup.sdp.requests.last.headers['Authorization'], 'Bearer ek_ephemeral_2');
    final types = setup.events.map((e) => e.runtimeType).toList();
    expect(types.where((t) => t == VoiceConnected), hasLength(2));
    expect(types, contains(VoiceConnectionLost));

    setup.links.last.fail(); // second drop: no more retries
    await pumpEventQueue();
    await pumpEventQueue();
    expect(setup.events.last, isA<VoiceReconnectGaveUp>());
    await setup.transport.close();
  });

  test('microphone denial and backend errors become actionable messages', () async {
    final denied = build();
    final link = FakeLink()..connectError = const MicrophoneUnavailable(denied: true);
    final transport = OpenAIRealtimeTransport(
      sessions: denied.sessions,
      options: VoiceSessionOptions(selection: _selection),
      linkFactory: () => link,
      sdpClient: Dio()..httpClientAdapter = denied.sdp,
    );
    await expectLater(
      transport.connect(),
      throwsA(isA<VoiceConnectError>().having((e) => e.message, 'message', contains('Microphone access was denied'))),
    );
    expect(link.closed, isTrue);

    final noProvider = build();
    noProvider.sessions.startError = const ApiException(
      code: 'provider_not_available',
      message: 'No realtime voice model is configured on this server',
      statusCode: 404,
    );
    await expectLater(
      noProvider.transport.connect(),
      throwsA(isA<VoiceConnectError>().having((e) => e.message, 'message', contains('No realtime voice model'))),
    );

    final expired = build(sdpStatus: 401);
    await expectLater(
      expired.transport.connect(),
      throwsA(isA<VoiceConnectError>().having((e) => e.message, 'message', contains('expired'))),
    );
  });

  test('close flushes finished transcripts and ends the backend session', () async {
    final setup = build();
    await setup.transport.connect();
    final link = setup.links.single;
    link.serverSends(itemAdded('u1', 'user')); // never transcribed
    link.serverSends(itemAdded('a1', 'assistant'));
    link.serverSends({'type': 'response.output_audio_transcript.done', 'item_id': 'a1', 'transcript': 'Goodbye'});
    await pumpEventQueue();
    expect(setup.sessions.saved, isEmpty); // waiting for u1

    await setup.transport.close();
    expect(setup.sessions.saved.single.$3, 'Goodbye');
    expect(setup.sessions.ended, ['vs-1']);
    expect(link.closed, isTrue);
  });
}
