import 'dart:convert';
import 'dart:typed_data';

import '../../domain/voice/voice_session_state.dart';
import 'openai_realtime_protocol.dart' show CompletedTurn;

/// What one Live API server message means for the transport.
class LiveServerUpdate {
  const LiveServerUpdate({
    this.events = const [],
    this.audio = const [],
    this.setupComplete = false,
    this.interrupted = false,
    this.turnComplete = false,
    this.resumeHandle,
    this.goAway,
  });

  /// State-machine events (speech start/stop, transcripts, reply finished).
  final List<VoiceEvent> events;

  /// Model audio to play: raw 16-bit little-endian PCM.
  final List<Uint8List> audio;
  final bool setupComplete;

  /// The user interrupted the model: stop playback and drop queued audio.
  final bool interrupted;
  final bool turnComplete;

  /// New session-resumption handle (only when the server says it is resumable).
  final String? resumeHandle;

  /// The server will close the connection after this much time.
  final Duration? goAway;
}

/// Gemini Live API messages (pure Dart, no I/O), as documented in the Live API
/// guides and the official SDK's types (verified 2026-11-21):
///
/// * client: `setup` (first message), `realtimeInput.audio` (base64 PCM with a
///   `mimeType`), `realtimeInput.activityStart` / `activityEnd` (push-to-talk) and
///   `realtimeInput.audioStreamEnd` (microphone paused);
/// * server: `setupComplete`, `serverContent` (`modelTurn.parts[].inlineData`,
///   `inputTranscription`, `outputTranscription`, `interrupted`, `turnComplete`),
///   `sessionResumptionUpdate` (`newHandle`, `resumable`), `goAway` (`timeLeft`) and
///   `voiceActivity` (`ACTIVITY_START` / `ACTIVITY_END`).
///
/// Transcripts arrive as fragments. One exchange (user turn + reply) ends with
/// `turnComplete`; both transcripts are then saved, user first. When the user
/// interrupts a reply (`interrupted`, always followed by `turnComplete`), the
/// exchange ends right away with the part of the reply received so far, and the
/// interrupting speech starts the next exchange.
class GeminiLiveProtocol {
  GeminiLiveProtocol({this.pushToTalk = false});

  /// In push-to-talk sessions the button, not the transcript, marks speech.
  bool pushToTalk;

  int _exchange = 0;
  final _user = StringBuffer();
  final _assistant = StringBuffer();
  bool _userSpeaking = false;
  bool _modelOutput = false;
  bool _suppressed = false;

  /// After `interrupted`: output still in flight for the cancelled reply is
  /// dropped, and its `turnComplete` does not end the new exchange.
  bool _discardCancelledReply = false;
  final _ready = <CompletedTurn>[];

  /// True while the model is producing a reply the user can hear.
  bool get responding => _modelOutput && !_suppressed;

  String get _userItem => 'u$_exchange';
  String get _assistantItem => 'a$_exchange';

  // ------------------------------------------------------------------ client messages

  /// The first message. The ephemeral token locks the model's configuration
  /// (instructions, voice, transcription, turn detection) on the server; the
  /// client repeats the documented minimum and asks for resumption handles.
  static Map<String, Object?> setup(String model, {String? resumeHandle}) => {
    'setup': {
      'model': model.startsWith('models/') ? model : 'models/$model',
      'generationConfig': {
        'responseModalities': ['AUDIO'],
      },
      'sessionResumption': resumeHandle == null ? <String, Object?>{} : {'handle': resumeHandle},
    },
  };

  static Map<String, Object?> audio(Uint8List pcm, String mimeType) => {
    'realtimeInput': {
      'audio': {'data': base64Encode(pcm), 'mimeType': mimeType},
    },
  };

  static const Map<String, Object?> activityStart = {
    'realtimeInput': {'activityStart': <String, Object?>{}},
  };

  static const Map<String, Object?> activityEnd = {
    'realtimeInput': {'activityEnd': <String, Object?>{}},
  };

  /// Sent when the microphone pauses (mute), so automatic detection ends the turn.
  static const Map<String, Object?> audioStreamEnd = {
    'realtimeInput': {'audioStreamEnd': true},
  };

  // ------------------------------------------------------------------ server messages

  LiveServerUpdate handle(Map<String, dynamic> message) {
    final events = <VoiceEvent>[];
    final audio = <Uint8List>[];
    var interrupted = false;
    var turnComplete = false;
    String? handle;
    Duration? goAway;

    final resumption = message['sessionResumptionUpdate'];
    if (resumption is Map && resumption['resumable'] == true) {
      final newHandle = resumption['newHandle'];
      if (newHandle is String && newHandle.isNotEmpty) handle = newHandle;
    }
    if (message['goAway'] case final Map<dynamic, dynamic> away) {
      goAway = parseDuration(away['timeLeft']) ?? Duration.zero;
    }
    if (message['voiceActivity'] case {'voiceActivityType': final String type} when !pushToTalk) {
      if (type == 'ACTIVITY_START') _startUserSpeech(events);
      if (type == 'ACTIVITY_END' && _userSpeaking) {
        _userSpeaking = false;
        events.add(const VoiceUserSpeechStopped());
      }
    }

    final content = message['serverContent'];
    if (content is Map) {
      if (content['interrupted'] == true) {
        interrupted = true;
        if (!_discardCancelledReply) {
          // Save what was said so far; the interrupting speech is a new exchange.
          if (_modelOutput) _finishExchange(events, replyFinished: false);
          _discardCancelledReply = true;
        }
        if (!pushToTalk) _startUserSpeech(events); // barge-in
      }

      final input = (content['inputTranscription'] as Map?)?['text'];
      if (input is String && input.isNotEmpty) {
        // A late fragment after the reply started still belongs to this user turn.
        if (!pushToTalk && !_modelOutput) _startUserSpeech(events);
        _user.write(input);
        events.add(
          VoiceTranscriptUpdated(role: TranscriptRole.user, text: _clean(_user), isFinal: false, itemId: _userItem),
        );
      }

      final parts = (content['modelTurn'] as Map?)?['parts'];
      if (parts is List && !_discardCancelledReply) {
        for (final part in parts) {
          final data = (part is Map ? part['inlineData'] : null) as Map?;
          final encoded = data?['data'];
          if (encoded is! String || encoded.isEmpty) continue;
          _beginModelOutput(events);
          if (!_suppressed) audio.add(base64Decode(encoded));
        }
      }

      final output = (content['outputTranscription'] as Map?)?['text'];
      if (output is String && output.isNotEmpty && !_discardCancelledReply) {
        _beginModelOutput(events);
        if (!_suppressed) {
          _assistant.write(output);
          events.add(
            VoiceTranscriptUpdated(
              role: TranscriptRole.assistant,
              text: _clean(_assistant),
              isFinal: false,
              itemId: _assistantItem,
            ),
          );
        }
      }

      if (content['turnComplete'] == true) {
        turnComplete = true;
        if (_discardCancelledReply) {
          _discardCancelledReply = false; // end of the cancelled reply
        } else {
          _finishExchange(events);
        }
      }
    }

    return LiveServerUpdate(
      events: events,
      audio: audio,
      setupComplete: message.containsKey('setupComplete'),
      interrupted: interrupted,
      turnComplete: turnComplete,
      resumeHandle: handle,
      goAway: goAway,
    );
  }

  /// Manual stop: the rest of the current reply is neither played nor saved.
  void suppressCurrentOutput() {
    if (_modelOutput) _suppressed = true;
  }

  /// Finished turns in conversation order. [flush] also returns the exchange in
  /// progress (used when the session ends or the connection drops).
  List<CompletedTurn> takeReadyTurns({bool flush = false}) {
    if (flush) _finishExchange(null);
    final ready = List<CompletedTurn>.of(_ready);
    _ready.clear();
    return ready;
  }

  void _startUserSpeech(List<VoiceEvent> events) {
    if (_userSpeaking) return;
    _userSpeaking = true;
    events.add(const VoiceUserSpeechStarted());
  }

  void _beginModelOutput(List<VoiceEvent> events) {
    if (_modelOutput) return;
    _modelOutput = true;
    if (_userSpeaking) {
      _userSpeaking = false;
      events.add(const VoiceUserSpeechStopped());
    }
  }

  /// [updates] receives the final transcripts and state events (null when flushing).
  void _finishExchange(List<VoiceEvent>? updates, {bool replyFinished = true}) {
    final user = _clean(_user);
    final assistant = _clean(_assistant);
    if (user.isNotEmpty) {
      _ready.add(CompletedTurn(itemId: _userItem, role: TranscriptRole.user, text: user));
      updates?.add(VoiceTranscriptUpdated(role: TranscriptRole.user, text: user, isFinal: true, itemId: _userItem));
    }
    if (assistant.isNotEmpty) {
      _ready.add(CompletedTurn(itemId: _assistantItem, role: TranscriptRole.assistant, text: assistant));
      updates?.add(
        VoiceTranscriptUpdated(role: TranscriptRole.assistant, text: assistant, isFinal: true, itemId: _assistantItem),
      );
    }
    // A turn that produced no audio (or whose audio was dropped) ends here.
    if (replyFinished && (!_modelOutput || _suppressed)) updates?.add(const VoiceResponseFinished());
    if (user.isNotEmpty || assistant.isNotEmpty || _modelOutput) _exchange++;
    _user.clear();
    _assistant.clear();
    _modelOutput = false;
    _suppressed = false;
    _userSpeaking = false;
  }

  static String _clean(StringBuffer buffer) => buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Protobuf JSON durations look like `"12s"` or `"0.5s"`.
  static Duration? parseDuration(Object? value) {
    if (value is! String || !value.endsWith('s')) return null;
    final seconds = double.tryParse(value.substring(0, value.length - 1));
    return seconds == null ? null : Duration(microseconds: (seconds * 1e6).round());
  }

  /// Decodes a server frame: JSON in a text or (as the service sends) binary frame.
  static Map<String, dynamic>? decode(Object? frame) {
    final text = switch (frame) {
      final String value => value,
      final List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    if (text == null || text.isEmpty) return null;
    try {
      final json = jsonDecode(text);
      return json is Map<String, dynamic> ? json : null;
    } on FormatException {
      return null;
    }
  }
}
