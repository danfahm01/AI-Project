import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/data/voice/gemini_live_transport.dart';
import 'package:voice_assistant/data/voice/pcm_audio.dart';
import 'package:voice_assistant/data/voice/realtime_link.dart';
import 'package:voice_assistant/domain/entities/ai_provider.dart';
import 'package:voice_assistant/domain/entities/user_preferences.dart';
import 'package:voice_assistant/domain/repositories/repositories.dart';
import 'package:voice_assistant/domain/voice/voice_session_state.dart';
import 'package:voice_assistant/domain/voice/voice_transport.dart';

class FakeSocket implements LiveSocket {
  FakeSocket({this.autoSetup = true});

  final bool autoSetup;
  final _incoming = StreamController<Object?>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void send(String text) {
    final message = jsonDecode(text) as Map<String, dynamic>;
    sent.add(message);
    if (autoSetup && message.containsKey('setup')) {
      scheduleMicrotask(() => serverSends({'setupComplete': <String, dynamic>{}}));
    }
  }

  /// The real service sends JSON in binary frames.
  void serverSends(Map<String, dynamic> message) {
    if (!_incoming.isClosed) _incoming.add(utf8.encode(jsonEncode(message)));
  }

  void serverCloses([int code = 1011, String reason = 'internal']) {
    closeCode = code;
    closeReason = reason;
    _incoming.close();
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }

  Map<String, dynamic> get setup => sent.firstWhere((m) => m.containsKey('setup'))['setup'] as Map<String, dynamic>;

  List<Map<String, dynamic>> get realtimeInputs => [
    for (final m in sent)
      if (m['realtimeInput'] case final Map<String, dynamic> input) input,
  ];
}

class FakeCapture implements PcmCapture {
  FakeCapture({this.error});

  final MicrophoneUnavailable? error;
  final chunks = StreamController<Uint8List>.broadcast();
  int? sampleRate;
  AudioSettings? audio;
  bool stopped = false;

  @override
  Future<Stream<Uint8List>> start({required int sampleRate, required AudioSettings audio}) async {
    if (error case final error?) throw error;
    this.sampleRate = sampleRate;
    this.audio = audio;
    return chunks.stream;
  }

  @override
  Future<void> stop() async => stopped = true;
}

class FakePlayback implements PcmPlayback {
  int? sampleRate;
  final played = <List<int>>[];
  int clears = 0;
  bool closed = false;

  @override
  Future<void> open({required int sampleRate}) async => this.sampleRate = sampleRate;

  @override
  void add(Uint8List pcm) => played.add(pcm);

  @override
  Future<void> clear() async => clears++;

  @override
  Future<void> close() async => closed = true;
}

class FakeSessions implements VoiceSessionRepository {
  FakeSessions({this.pushToTalk = false, required this.now});

  final bool pushToTalk;
  final DateTime Function() now;
  int started = 0;
  final saved = <(String, String, String, String?)>[];
  final ended = <String>[];

  @override
  Future<VoiceSessionGrant> start({String? conversationId, String? providerId, String? modelId}) async {
    started++;
    return VoiceSessionGrant(
      id: 'vs-$started',
      conversationId: conversationId ?? 'conv-1',
      provider: providerId!,
      model: modelId!,
      transport: 'websocket',
      endpoint: 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained',
      clientSecret: 'auth_tokens/t-$started',
      expiresAt: now().add(const Duration(minutes: 1)),
      pushToTalk: pushToTalk,
      voice: 'Kore',
      inputAudioFormat: 'audio/pcm;rate=16000',
      outputSampleRate: 24000,
      sessionExpiresAt: now().add(const Duration(minutes: 30)),
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

const _live = AIModelInfo(
  id: 'gemini-3.8-live',
  displayName: 'Gemini 3.8 Live',
  capabilities: ModelCapabilities(realtimeVoice: true, serverVad: true, interruption: true),
);
const _gemini = AIProviderInfo(id: 'gemini', displayName: 'Google Gemini', models: [_live]);

class Harness {
  Harness({bool pushToTalk = false, this.connectError, MicrophoneUnavailable? micError, this.autoSetup = true}) {
    sessions = FakeSessions(pushToTalk: pushToTalk, now: () => now);
    capture = FakeCapture(error: micError);
    transport = GeminiLiveTransport(
      sessions: sessions,
      options: const VoiceSessionOptions(
        selection: (provider: _gemini, model: _live),
        audio: AudioSettings(noiseSuppression: false),
      ),
      connector: (uri) async {
        uris.add(uri);
        if (connectError != null) throw connectError!;
        final socket = FakeSocket(autoSetup: autoSetup);
        sockets.add(socket);
        return socket;
      },
      captureFactory: () => capture,
      playbackFactory: () => playback,
      clock: () => now,
      levelInterval: const Duration(milliseconds: 5),
      setupTimeout: const Duration(milliseconds: 200),
    );
    transport.events.listen(events.add);
  }

  final Object? connectError;
  final bool autoSetup;
  DateTime now = DateTime.utc(2026, 11, 21, 10);
  late final FakeSessions sessions;
  late final FakeCapture capture;
  final playback = FakePlayback();
  late final GeminiLiveTransport transport;
  final uris = <Uri>[];
  final sockets = <FakeSocket>[];
  final events = <VoiceEvent>[];

  FakeSocket get socket => sockets.last;

  VoiceSessionState get state =>
      events.fold(reduceVoiceState(const VoiceSessionState.initial(), const VoiceConnectRequested()), reduceVoiceState);

  void mic(List<int> bytes) => capture.chunks.add(Uint8List.fromList(bytes));

  Future<void> server(Map<String, dynamic> message) async {
    socket.serverSends(message);
    await pumpEventQueue();
  }

  Future<void> wait(Duration duration) => Future<void>.delayed(duration);
}

Map<String, dynamic> serverContent(Map<String, dynamic> content) => {'serverContent': content};

Map<String, dynamic> audio(int milliseconds) => serverContent({
  'modelTurn': {
    'parts': [
      {
        'inlineData': {
          'mimeType': 'audio/pcm;rate=24000',
          'data': base64Encode(Uint8List.fromList(List.filled(48 * milliseconds, 40))),
        },
      },
    ],
  },
});

void main() {
  test('connects with the ephemeral token and streams microphone audio', () async {
    final h = Harness();
    await h.transport.connect();
    await pumpEventQueue();

    final uri = h.uris.single;
    expect(uri.host, 'generativelanguage.googleapis.com');
    expect(uri.path, endsWith('GenerativeService.BidiGenerateContentConstrained'));
    expect(uri.queryParameters['access_token'], 'auth_tokens/t-1');
    expect(h.socket.sent.first.keys, ['setup']);
    expect(h.socket.setup['model'], 'models/gemini-3.8-live');
    expect(h.socket.setup['sessionResumption'], <String, dynamic>{});
    expect(h.capture.sampleRate, 16000);
    expect(h.capture.audio?.noiseSuppression, isFalse);
    expect(h.playback.sampleRate, 24000);
    expect(h.events.take(2).map((e) => e.runtimeType), [VoiceSessionConfigured, VoiceConnected]);
    expect(h.transport.conversationId, 'conv-1');

    h.mic([1, 2, 3, 4]);
    await pumpEventQueue();
    final audioIn = h.socket.realtimeInputs.single['audio'] as Map<String, dynamic>;
    expect(audioIn, {
      'data': base64Encode([1, 2, 3, 4]),
      'mimeType': 'audio/pcm;rate=16000',
    });
    await h.transport.close();
  });

  test('a hands-free exchange: playback, speaking state, levels and saved transcripts', () async {
    final h = Harness();
    await h.transport.connect();

    await h.server(
      serverContent({
        'inputTranscription': {'text': 'What time is it?'},
      }),
    );
    expect(h.state.phase, VoicePhase.listening);

    await h.server(audio(500));
    await h.server(
      serverContent({
        'outputTranscription': {'text': 'It is ten.'},
      }),
    );
    expect(h.playback.played, hasLength(1));
    expect(h.state.phase, VoicePhase.speaking);
    await h.wait(const Duration(milliseconds: 20));
    expect(h.events.whereType<VoiceLevelChanged>().last.level, greaterThan(0));

    await h.server(serverContent({'turnComplete': true}));
    expect(h.state.phase, VoicePhase.speaking); // still playing the buffered half second
    h.now = h.now.add(const Duration(milliseconds: 600));
    await h.wait(const Duration(milliseconds: 20));
    expect(h.state.phase, VoicePhase.idle);

    await pumpEventQueue();
    expect(h.sessions.saved, [('vs-1', 'user', 'What time is it?', 'u0'), ('vs-1', 'assistant', 'It is ten.', 'a0')]);
    expect(h.state.transcript.map((t) => (t.text, t.isFinal)), [('What time is it?', true), ('It is ten.', true)]);
    await h.transport.close();
  });

  test('barge-in and the stop button clear queued audio', () async {
    final h = Harness();
    await h.transport.connect();
    await h.server(
      serverContent({
        'inputTranscription': {'text': 'Tell me a story'},
      }),
    );
    await h.server(audio(2000));
    expect(h.state.phase, VoicePhase.speaking);

    await h.server(serverContent({'interrupted': true}));
    expect(h.playback.clears, 1);
    expect(h.state.phase, VoicePhase.listening);
    await h.server(serverContent({'turnComplete': true}));

    await h.server(audio(2000));
    expect(h.state.phase, VoicePhase.speaking);
    await h.transport.interrupt();
    expect(h.playback.clears, 2);
    expect(h.state.phase, VoicePhase.idle);
    await h.server(audio(100)); // the rest of the stopped reply is not played
    expect(h.playback.played, hasLength(2));
    await h.transport.close();
  });

  test('push-to-talk: audio and activity markers only while talking', () async {
    final h = Harness(pushToTalk: true);
    await h.transport.connect();
    expect(h.transport.pushToTalk, isTrue);

    h.mic([1, 1]);
    await pumpEventQueue();
    expect(h.socket.realtimeInputs, isEmpty);

    await h.transport.startTalking();
    h.mic([2, 2]);
    await pumpEventQueue();
    await h.transport.stopTalking();
    expect(h.socket.realtimeInputs.map((m) => m.keys.single), ['activityStart', 'audio', 'activityEnd']);
    expect(h.state.phase, VoicePhase.processing);

    // Transcripts do not move the state in push-to-talk sessions.
    await h.server(
      serverContent({
        'inputTranscription': {'text': 'Hi'},
      }),
    );
    expect(h.state.phase, VoicePhase.processing);
    await h.server(serverContent({'turnComplete': true}));
    expect(h.state.phase, VoicePhase.idle); // no reply audio
    await h.transport.close();
  });

  test('muting stops audio and tells the server the stream paused', () async {
    final h = Harness();
    await h.transport.connect();
    await h.transport.setMuted(true);
    await h.transport.setMuted(true);
    h.mic([5, 5]);
    await pumpEventQueue();
    expect(h.socket.realtimeInputs, [
      {'audioStreamEnd': true},
    ]);
    await h.transport.setMuted(false);
    h.mic([6, 6]);
    await pumpEventQueue();
    expect(h.socket.realtimeInputs.last.keys, ['audio']);
    await h.transport.close();
  });

  test('goAway: reconnects with the resumption handle without interrupting', () async {
    final h = Harness();
    await h.transport.connect();
    final first = h.socket;
    await h.server({
      'sessionResumptionUpdate': {'newHandle': 'handle-7', 'resumable': true},
    });
    await h.server({
      'goAway': {'timeLeft': '30s'},
    });
    await pumpEventQueue();

    expect(h.sockets, hasLength(2));
    expect(h.uris.last.queryParameters['access_token'], 'auth_tokens/t-1'); // same token
    expect(h.socket.setup['sessionResumption'], {'handle': 'handle-7'});
    expect(first.closed, isTrue);
    expect(h.events.whereType<VoiceConnectionLost>(), isEmpty);
    expect(h.sessions.started, 1);

    h.mic([7, 7]);
    await pumpEventQueue();
    expect(h.socket.realtimeInputs.single.keys, ['audio']); // the new socket is live
    await h.transport.close();
  });

  test('a dropped connection resumes, then falls back to one fresh session, then gives up', () async {
    final h = Harness();
    await h.transport.connect();
    await h.server({
      'sessionResumptionUpdate': {'newHandle': 'handle-1', 'resumable': true},
    });
    await h.server(
      serverContent({
        'inputTranscription': {'text': 'Half a sentence'},
      }),
    );

    h.socket.serverCloses();
    await pumpEventQueue();
    expect(h.sockets, hasLength(2));
    expect(h.socket.setup['sessionResumption'], {'handle': 'handle-1'});
    expect(h.events.whereType<VoiceConnectionLost>(), hasLength(1));
    expect(h.state.phase, VoicePhase.idle);
    expect(h.sessions.saved.single.$3, 'Half a sentence'); // flushed on the drop

    // No new handle on this connection: the next drop needs a fresh session.
    h.sessions.saved.clear();
    h.socket.serverCloses();
    await pumpEventQueue();
    expect(h.sessions.started, 2);
    expect(h.uris.last.queryParameters['access_token'], 'auth_tokens/t-2');
    expect(h.state.phase, VoicePhase.idle);

    h.socket.serverCloses();
    await pumpEventQueue();
    expect(h.state.phase, VoicePhase.disconnected);
    expect(h.state.errorMessage, contains('Connection lost'));
    await h.transport.close();
  });

  group('connection errors are explained', () {
    test('microphone denied', () async {
      final h = Harness(micError: const MicrophoneUnavailable(denied: true));
      await expectLater(
        h.transport.connect(),
        throwsA(isA<VoiceConnectError>().having((e) => e.message, 'message', contains('Microphone access was denied'))),
      );
      expect(h.uris, isEmpty);
    });

    test('service unreachable', () async {
      final h = Harness(connectError: Exception('refused'));
      await expectLater(
        h.transport.connect(),
        throwsA(isA<VoiceConnectError>().having((e) => e.message, 'message', contains('Could not reach'))),
      );
      expect(h.capture.stopped, isTrue);
      expect(h.playback.closed, isTrue);
    });

    test('token rejected during setup', () async {
      final h = Harness(autoSetup: false);
      final connecting = h.transport.connect();
      await pumpEventQueue();
      h.socket.serverCloses(1008, 'Invalid token');
      await expectLater(
        connecting,
        throwsA(isA<VoiceConnectError>().having((e) => e.message, 'message', contains('expired'))),
      );
    });

    test('no setupComplete', () async {
      final h = Harness(autoSetup: false);
      await expectLater(
        h.transport.connect(),
        throwsA(isA<VoiceConnectError>().having((e) => e.message, 'message', contains('did not respond'))),
      );
      expect(h.socket.closed, isTrue);
    });
  });

  test('close flushes the exchange in progress and ends the session', () async {
    final h = Harness();
    await h.transport.connect();
    await h.server(
      serverContent({
        'inputTranscription': {'text': 'Goodbye'},
      }),
    );
    await h.transport.close();
    expect(h.sessions.saved.single.$3, 'Goodbye');
    expect(h.sessions.ended, ['vs-1']);
    expect(h.capture.stopped, isTrue);
    expect(h.playback.closed, isTrue);
    expect(h.socket.closed, isTrue);
  });
}
