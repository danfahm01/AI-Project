import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import '../../domain/repositories/repositories.dart';
import '../../domain/voice/voice_session_state.dart';
import '../../domain/voice/voice_transport.dart';
import 'openai_realtime_protocol.dart';
import 'realtime_link.dart';

/// OpenAI Realtime speech-to-speech over WebRTC.
///
/// 1. The backend mints a short-lived client secret (`POST /api/v1/voice/sessions`).
/// 2. The SDP offer goes straight to OpenAI (`POST <endpoint>` with
///    `Authorization: Bearer <client secret>`, `Content-Type: application/sdp`) using
///    a separate HTTP client, so the app's own session tokens never leave our backend.
/// 3. Events on the `oai-events` data channel drive [VoiceSessionState]; finished
///    turns are stored in the conversation, in order.
class OpenAIRealtimeTransport implements VoiceTransport {
  OpenAIRealtimeTransport({
    required this.sessions,
    required this.options,
    required this.linkFactory,
    Dio? sdpClient,
    OpenAIRealtimeProtocol? protocol,
    this.levelInterval = const Duration(milliseconds: 80),
    this.maxReconnects = 1,
  }) : _sdp = sdpClient ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15))),
       _protocol = protocol ?? OpenAIRealtimeProtocol();

  final VoiceSessionRepository sessions;
  final VoiceSessionOptions options;
  final Duration levelInterval;
  final int maxReconnects;
  final RealtimeLink Function() linkFactory;
  final Dio _sdp;
  final OpenAIRealtimeProtocol _protocol;

  final _events = StreamController<VoiceEvent>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  VoiceSessionGrant? _grant;
  RealtimeLink? _link;
  Timer? _levelTimer;
  Future<void> _saving = Future.value();
  bool _muted = false;
  bool _talking = false;
  bool _closed = false;
  int _reconnects = 0;

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  String? get conversationId => _grant?.conversationId ?? options.conversationId;

  @override
  bool get pushToTalk => _grant?.pushToTalk ?? false;

  void _emit(VoiceEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  // ---------------------------------------------------------------- connect

  @override
  Future<void> connect() async {
    final grant = _grant = await _startSession(options.conversationId);
    await _open(grant);
    _emit(VoiceSessionConfigured(pushToTalk: grant.pushToTalk, conversationId: grant.conversationId));
    _emit(const VoiceConnected());
  }

  Future<VoiceSessionGrant> _startSession(String? conversationId) async {
    try {
      return await sessions.start(
        conversationId: conversationId,
        providerId: options.selection.provider.id,
        modelId: options.selection.model.id,
      );
    } on ApiException catch (error) {
      throw VoiceConnectError(error.userMessage);
    }
  }

  Future<void> _open(VoiceSessionGrant grant) async {
    final link = _link = linkFactory();
    _subscriptions
      ..add(link.messages.listen(_onMessage))
      ..add(link.states.listen(_onLinkState));
    try {
      await link.connect(
        exchangeSdp: (offer) => _exchangeSdp(grant, offer),
        dataChannelLabel: grant.dataChannel ?? 'oai-events',
        audio: options.audio,
      );
    } on MicrophoneUnavailable catch (error) {
      await _dropLink();
      throw VoiceConnectError(
        error.denied
            ? 'Microphone access was denied. Allow microphone access in your browser or system settings, then try again.'
            : 'No microphone was found. Connect a microphone and try again.',
      );
    } on VoiceConnectError {
      await _dropLink();
      rethrow;
    } catch (error) {
      await _dropLink();
      debugPrint('Voice connection failed: $error');
      throw const VoiceConnectError('Could not connect to the voice service. Check your connection and try again.');
    }
    // Push-to-talk: the microphone is live only while the button is held.
    link.setMicrophoneEnabled(!grant.pushToTalk && !_muted);
    _levelTimer?.cancel();
    _levelTimer = Timer.periodic(levelInterval, (_) => _pollLevels());
  }

  Future<String> _exchangeSdp(VoiceSessionGrant grant, String offer) async {
    try {
      final response = await _sdp.post<String>(
        grant.endpoint,
        data: offer,
        options: Options(
          headers: {'Authorization': 'Bearer ${grant.clientSecret}'},
          contentType: 'application/sdp',
          responseType: ResponseType.plain,
        ),
      );
      final answer = response.data;
      if (answer == null || answer.isEmpty) throw const VoiceConnectError('The voice service sent an empty answer.');
      return answer;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw VoiceConnectError(switch (status) {
        401 || 403 => 'The voice session expired before it connected. Try again.',
        429 => 'The voice service is busy. Try again in a moment.',
        _ => 'Could not reach the voice service. Check your connection and try again.',
      });
    }
  }

  // ---------------------------------------------------------------- events

  void _onMessage(Map<String, dynamic> event) {
    final error = OpenAIRealtimeProtocol.errorMessage(event);
    if (error != null) debugPrint('Realtime error event: $error');
    for (final voiceEvent in _protocol.handle(event)) {
      _emit(voiceEvent);
    }
    _saveReadyTurns();
  }

  void _saveReadyTurns({bool flush = false}) {
    final grant = _grant;
    if (grant == null) return;
    final turns = _protocol.takeReadyTurns(flush: flush);
    if (turns.isEmpty) return;
    // Sequential, so stored order matches conversation order.
    _saving = _saving.then((_) async {
      for (final turn in turns) {
        try {
          await sessions.saveTranscript(
            grant.id,
            role: turn.role == TranscriptRole.user ? 'user' : 'assistant',
            content: turn.text,
            itemId: turn.itemId,
          );
        } on ApiException catch (error) {
          debugPrint('Could not save voice transcript: ${error.message}');
        }
      }
    });
  }

  Future<void> _pollLevels() async {
    final link = _link;
    if (link == null || _closed) return;
    try {
      final levels = await link.levels();
      final raw = _protocol.assistantAudioPlaying ? levels.output : (_muted ? 0.0 : levels.input);
      // audioLevel is linear (speech is mostly 0.01-0.3); a square-root curve reads better.
      _emit(VoiceLevelChanged(math.min(1.0, math.sqrt(raw) * 1.4)));
    } catch (_) {
      // Stats are best effort.
    }
  }

  Future<void> _onLinkState(RealtimeLinkState state) async {
    if (state != RealtimeLinkState.failed || _closed) return;
    _emit(const VoiceConnectionLost());
    await _dropLink();
    _saveReadyTurns(flush: true);
    if (_reconnects >= maxReconnects) {
      _emit(const VoiceReconnectGaveUp());
      return;
    }
    _reconnects++;
    try {
      // A realtime call cannot be resumed: start a fresh session in the same conversation.
      final grant = _grant = await _startSession(conversationId);
      await _open(grant);
      _emit(const VoiceConnected());
    } catch (error) {
      debugPrint('Voice reconnect failed: $error');
      _emit(const VoiceReconnectGaveUp());
    }
  }

  // ---------------------------------------------------------------- controls

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    if (!pushToTalk) _link?.setMicrophoneEnabled(!muted);
  }

  @override
  Future<void> interrupt() async {
    for (final command in OpenAIRealtimeProtocol.interruptCommands) {
      _link?.send(command);
    }
  }

  @override
  Future<void> startTalking() async {
    final link = _link;
    if (!pushToTalk || link == null || _talking) return;
    _talking = true;
    for (final command in _protocol.pushToTalkStartCommands()) {
      link.send(command);
    }
    link.setMicrophoneEnabled(true);
    _emit(const VoiceUserSpeechStarted());
  }

  @override
  Future<void> stopTalking() async {
    final link = _link;
    if (!pushToTalk || link == null || !_talking) return;
    _talking = false;
    link.setMicrophoneEnabled(false);
    for (final command in OpenAIRealtimeProtocol.pushToTalkEndCommands) {
      link.send(command);
    }
    _emit(const VoiceUserSpeechStopped());
  }

  // ---------------------------------------------------------------- teardown

  Future<void> _dropLink() async {
    _levelTimer?.cancel();
    _levelTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final link = _link;
    _link = null;
    await link?.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _dropLink();
    _saveReadyTurns(flush: true);
    await _saving;
    final grant = _grant;
    if (grant != null) {
      try {
        await sessions.end(grant.id);
      } on ApiException {
        // The session also expires on its own.
      }
    }
    await _events.close();
  }
}
