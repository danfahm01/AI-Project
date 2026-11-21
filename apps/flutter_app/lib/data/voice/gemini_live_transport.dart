import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/network/api_exception.dart';
import '../../domain/repositories/repositories.dart';
import '../../domain/voice/voice_session_state.dart';
import '../../domain/voice/voice_transport.dart';
import 'gemini_live_protocol.dart';
import 'pcm_audio.dart';
import 'realtime_link.dart';

/// Gemini Live API speech-to-speech over a WebSocket.
///
/// 1. The backend mints a single-use ephemeral token whose configuration
///    (model, instructions, voice, transcription, turn detection) is locked
///    server-side (`POST /api/v1/voice/sessions`).
/// 2. The app connects straight to Google
///    (`<endpoint>?access_token=<token>`), sends `setup` and waits for
///    `setupComplete`.
/// 3. Microphone audio is streamed as 16 kHz PCM; the reply arrives as 24 kHz PCM
///    and is played as it comes. Transcripts drive [VoiceSessionState] and are
///    stored in the conversation, in order.
/// 4. Connections last about 10 minutes: on `goAway` (or a drop) the app
///    reconnects with the latest session-resumption handle and the same token,
///    keeping the conversation context. If that fails, it starts one fresh session.
class GeminiLiveTransport implements VoiceTransport {
  GeminiLiveTransport({
    required this.sessions,
    required this.options,
    required this.connector,
    required this.captureFactory,
    required this.playbackFactory,
    DateTime Function()? clock,
    this.levelInterval = const Duration(milliseconds: 80),
    this.setupTimeout = const Duration(seconds: 15),
    this.maxReconnects = 1,
  }) : _clock = clock ?? DateTime.now,
       _playEnd = (clock ?? DateTime.now)();

  final VoiceSessionRepository sessions;
  final VoiceSessionOptions options;
  final LiveSocketConnector connector;
  final PcmCapture Function() captureFactory;
  final PcmPlayback Function() playbackFactory;
  final Duration levelInterval;
  final Duration setupTimeout;

  /// Fresh sessions started after a drop that could not be resumed.
  final int maxReconnects;
  final DateTime Function() _clock;

  final _protocol = GeminiLiveProtocol();
  final _events = StreamController<VoiceEvent>.broadcast();
  final _socketSubscriptions = <LiveSocket, StreamSubscription<Object?>>{};

  VoiceSessionGrant? _grant;
  PcmCapture? _capture;
  StreamSubscription<Uint8List>? _microphone;
  PcmPlayback? _playback;
  LiveSocket? _socket;
  String? _resumeHandle;
  Timer? _levelTimer;
  Future<void> _saving = Future.value();

  String _inputMimeType = 'audio/pcm;rate=16000';
  int _inputRate = 16000;
  int _outputRate = 24000;

  bool _muted = false;
  bool _talking = false;
  bool _closed = false;
  bool _recovering = false;
  bool _swapPending = false;
  bool _swapping = false;
  bool _streamEnded = false;
  int _reconnects = 0;

  // Playback timeline (what is audible now), for levels and speaking state.
  double _micLevel = 0;
  DateTime _playEnd;
  final _segments = <({DateTime start, DateTime end, double level})>[];
  bool _assistantPlaying = false;
  bool _replyDone = true;

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
    _configure(grant);
    await _startMicrophone();
    try {
      final playback = _playback = playbackFactory();
      await playback.open(sampleRate: _outputRate);
    } catch (error) {
      debugPrint('Audio playback unavailable: $error');
      await _stopMedia();
      throw const VoiceConnectError('Audio playback is not available on this device.');
    }
    try {
      await _openSocket(grant, activate: true);
    } catch (_) {
      await _stopMedia();
      rethrow;
    }
    _levelTimer = Timer.periodic(levelInterval, (_) => _tick());
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

  void _configure(VoiceSessionGrant grant) {
    _protocol.pushToTalk = grant.pushToTalk;
    _inputMimeType = grant.inputAudioFormat ?? 'audio/pcm;rate=16000';
    _inputRate = sampleRateOf(_inputMimeType) ?? 16000;
    _outputRate = grant.outputSampleRate ?? 24000;
  }

  Future<void> _startMicrophone() async {
    final capture = _capture = captureFactory();
    try {
      final stream = await capture.start(sampleRate: _inputRate, audio: options.audio);
      _microphone = stream.listen(_onMicrophone, onError: (Object error) => debugPrint('Microphone error: $error'));
    } on MicrophoneUnavailable catch (error) {
      _capture = null;
      unawaited(capture.stop().catchError((Object _) {}));
      throw VoiceConnectError(
        error.denied
            ? 'Microphone access was denied. Allow microphone access in your browser or system settings, then try again.'
            : 'No microphone was found. Connect a microphone and try again.',
      );
    }
  }

  /// Connects, sends `setup` and waits for `setupComplete`. With [activate] the
  /// socket becomes the live one immediately; otherwise (a seamless swap after
  /// `goAway`) only once its setup is complete.
  Future<LiveSocket> _openSocket(VoiceSessionGrant grant, {required bool activate, String? resumeHandle}) async {
    final uri = Uri.parse(grant.endpoint).replace(queryParameters: {'access_token': grant.clientSecret});
    final LiveSocket socket;
    try {
      socket = await connector(uri).timeout(setupTimeout);
    } catch (error) {
      debugPrint('Voice connection failed: $error');
      throw const VoiceConnectError('Could not reach the voice service. Check your connection and try again.');
    }
    final setup = Completer<void>();
    _socketSubscriptions[socket] = socket.messages.listen(
      (frame) => _onFrame(socket, frame, setup),
      onError: (Object error) => debugPrint('Voice socket error: $error'),
      onDone: () => _onSocketDone(socket, setup),
    );
    if (activate) _socket = socket;
    socket.send(jsonEncode(GeminiLiveProtocol.setup(grant.model, resumeHandle: resumeHandle)));
    try {
      await setup.future.timeout(setupTimeout);
    } catch (error) {
      if (identical(_socket, socket)) _socket = null;
      await _closeSocket(socket);
      if (error is VoiceConnectError) rethrow;
      throw const VoiceConnectError('The voice service did not respond. Try again.');
    }
    return socket;
  }

  Future<void> _closeSocket(LiveSocket socket) async {
    unawaited(_socketSubscriptions.remove(socket)?.cancel());
    try {
      await socket.close();
    } catch (_) {
      // Already closed.
    }
  }

  // ---------------------------------------------------------------- incoming

  void _onFrame(LiveSocket source, Object? frame, Completer<void> setup) {
    final message = GeminiLiveProtocol.decode(frame);
    if (message == null) return;
    if (message.containsKey('setupComplete') && !setup.isCompleted) setup.complete();
    if (!identical(source, _socket)) return; // a socket still being set up, or replaced
    final update = _protocol.handle(message);

    if (update.resumeHandle != null) _resumeHandle = update.resumeHandle;
    for (final event in update.events) {
      _emit(event);
    }
    if (update.interrupted) _stopPlayback();
    if (update.audio.isNotEmpty) _replyDone = false;
    for (final chunk in update.audio) {
      _enqueue(chunk);
    }
    if (update.turnComplete) {
      _replyDone = true;
      unawaited(_maybeSwap());
    }
    if (update.goAway != null) {
      debugPrint('Voice server closes this connection in ${update.goAway}; reconnecting.');
      _swapPending = true;
      unawaited(_maybeSwap());
    }
    _saveReadyTurns();
  }

  void _onSocketDone(LiveSocket source, Completer<void> setup) {
    _socketSubscriptions.remove(source);
    if (!setup.isCompleted) {
      // _openSocket() reports this; nothing to recover yet.
      debugPrint('Voice socket closed during setup: ${source.closeCode} ${source.closeReason}');
      setup.completeError(
        VoiceConnectError(switch (source.closeCode) {
          1008 => 'The voice session expired before it connected. Try again.',
          _ => 'Could not connect to the voice service. Try again in a moment.',
        }),
      );
      return;
    }
    if (!identical(source, _socket) || _closed) return;
    debugPrint('Voice socket closed: ${source.closeCode} ${source.closeReason}');
    _socket = null;
    unawaited(_recover());
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

  // ---------------------------------------------------------------- audio

  void _onMicrophone(Uint8List chunk) {
    final sending = !_muted && (!_protocol.pushToTalk || _talking);
    _micLevel = sending ? pcm16Level(chunk) : 0;
    final socket = _socket;
    if (!sending || socket == null || _recovering) return;
    socket.send(jsonEncode(GeminiLiveProtocol.audio(chunk, _inputMimeType)));
    _streamEnded = false;
  }

  void _enqueue(Uint8List pcm) {
    _playback?.add(pcm);
    final now = _clock();
    final start = _playEnd.isAfter(now) ? _playEnd : now;
    final end = start.add(pcm16Duration(pcm.length, _outputRate));
    _segments.add((start: start, end: end, level: pcm16Level(pcm)));
    _playEnd = end;
    if (!_assistantPlaying) {
      _assistantPlaying = true;
      _emit(const VoiceAssistantAudioStarted());
    }
  }

  void _stopPlayback() {
    _segments.clear();
    _playEnd = _clock();
    unawaited(_playback?.clear());
    if (_assistantPlaying) {
      _assistantPlaying = false;
      _emit(const VoiceAssistantAudioFinished());
    }
  }

  void _tick() {
    if (_closed) return;
    final now = _clock();
    _segments.removeWhere((s) => !s.end.isAfter(now));
    // A short gap mid-reply (audio arriving slower than real time) is not the end.
    final drained = !_playEnd.isAfter(now);
    if (_assistantPlaying && drained && (_replyDone || now.difference(_playEnd) > const Duration(seconds: 1))) {
      _assistantPlaying = false;
      _emit(const VoiceAssistantAudioFinished());
    }
    final raw = _assistantPlaying
        ? (_segments.where((s) => !s.start.isAfter(now)).firstOrNull?.level ?? 0.0)
        : (_muted ? 0.0 : _micLevel);
    // RMS is small for speech (mostly 0.01-0.3); a square-root curve reads better.
    _emit(VoiceLevelChanged(math.min(1.0, math.sqrt(raw) * 1.4)));
  }

  // ---------------------------------------------------------------- reconnecting

  /// After `goAway`: once no reply is playing, reconnect with the resumption
  /// handle on a new socket, then drop the old one (no visible interruption).
  Future<void> _maybeSwap() async {
    final grant = _grant;
    final handle = _resumeHandle;
    if (!_swapPending || _swapping || _recovering || _closed || grant == null || handle == null) return;
    if (_protocol.responding || _talking) return;
    _swapping = true;
    try {
      final next = await _openSocket(grant, activate: false, resumeHandle: handle);
      final previous = _socket;
      _socket = next;
      _swapPending = false;
      // A handle is used once; the resumed connection sends fresh ones.
      if (_resumeHandle == handle) _resumeHandle = null;
      if (previous != null) await _closeSocket(previous);
      if (_closed) await _closeSocket(next);
    } catch (error) {
      // The old connection closes on its own; _recover() takes over then.
      debugPrint('Voice resume before goAway failed: $error');
    } finally {
      _swapping = false;
    }
  }

  Future<void> _recover() async {
    if (_recovering || _closed) return;
    _recovering = true;
    _emit(const VoiceConnectionLost());
    _stopPlayback();
    _talking = false;
    _saveReadyTurns(flush: true);
    try {
      final grant = _grant!;
      final handle = _resumeHandle;
      final sessionOpen = grant.sessionExpiresAt?.isAfter(_clock().add(const Duration(seconds: 5))) ?? false;
      if (handle != null && sessionOpen) {
        // Used once, so a connection that keeps dropping cannot loop forever.
        _resumeHandle = null;
        try {
          await _openSocket(grant, activate: true, resumeHandle: handle);
          _swapPending = false;
          _emit(const VoiceConnected());
          return;
        } catch (error) {
          debugPrint('Voice resume failed: $error');
        }
      }
      if (_reconnects >= maxReconnects || _closed) {
        _emit(const VoiceReconnectGaveUp());
        return;
      }
      _reconnects++;
      // A fresh session in the same conversation (its earlier turns are context).
      final fresh = _grant = await _startSession(conversationId);
      _configure(fresh);
      _resumeHandle = null;
      _swapPending = false;
      await _openSocket(fresh, activate: true);
      _emit(const VoiceConnected());
    } catch (error) {
      debugPrint('Voice reconnect failed: $error');
      _emit(const VoiceReconnectGaveUp());
    } finally {
      _recovering = false;
    }
  }

  // ---------------------------------------------------------------- controls

  void _send(Map<String, Object?> message) => _socket?.send(jsonEncode(message));

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    // A paused microphone: let automatic detection end the user's turn.
    if (muted && !pushToTalk && !_streamEnded) {
      _send(GeminiLiveProtocol.audioStreamEnd);
      _streamEnded = true;
    }
  }

  @override
  Future<void> interrupt() async {
    // The Live API has no "cancel reply" message: the rest of this reply is
    // discarded here and the transcript keeps what was heard.
    _protocol.suppressCurrentOutput();
    _replyDone = true;
    _stopPlayback();
  }

  @override
  Future<void> startTalking() async {
    if (!pushToTalk || _socket == null || _talking) return;
    if (_protocol.responding) {
      _protocol.suppressCurrentOutput();
      _stopPlayback();
    }
    _talking = true;
    // Starting a new activity also interrupts a reply still being generated.
    _send(GeminiLiveProtocol.activityStart);
    _emit(const VoiceUserSpeechStarted());
  }

  @override
  Future<void> stopTalking() async {
    if (!pushToTalk || !_talking) return;
    _talking = false;
    _send(GeminiLiveProtocol.activityEnd);
    _emit(const VoiceUserSpeechStopped());
  }

  // ---------------------------------------------------------------- teardown

  Future<void> _stopMedia() async {
    unawaited(_microphone?.cancel());
    _microphone = null;
    final capture = _capture;
    _capture = null;
    try {
      await capture?.stop();
    } catch (error) {
      debugPrint('Could not stop the microphone: $error');
    }
    final playback = _playback;
    _playback = null;
    try {
      await playback?.close();
    } catch (error) {
      debugPrint('Could not stop playback: $error');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _levelTimer?.cancel();
    _levelTimer = null;
    final socket = _socket;
    _socket = null;
    for (final open in {?socket, ..._socketSubscriptions.keys}.toList()) {
      await _closeSocket(open);
    }
    await _stopMedia();
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
