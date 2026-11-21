/// OpenAI Realtime API (GA) event protocol over the WebRTC data channel.
///
/// Event names verified on 2026-11-20 against the realtime-conversations,
/// realtime-vad and realtime-webrtc guides and the official SDK's generated types:
///   input_audio_buffer.speech_started / speech_stopped,
///   output_audio_buffer.started / stopped / cleared (WebRTC only),
///   conversation.item.added, conversation.item.input_audio_transcription.delta /
///   completed / failed, response.output_audio_transcript.delta / done,
///   response.created / done, error.
/// Client commands: response.cancel + output_audio_buffer.clear (interrupt);
/// push-to-talk with turn_detection null: input_audio_buffer.clear on press,
/// input_audio_buffer.commit + response.create on release.
library;

import '../../domain/voice/voice_session_state.dart';

/// A finished turn to store in the conversation.
class CompletedTurn {
  const CompletedTurn({required this.itemId, required this.role, required this.text});

  final String itemId;
  final TranscriptRole role;
  final String text;
}

class _Item {
  _Item(this.id, this.role, this.addedAt);

  final String id;
  final TranscriptRole role;
  final DateTime addedAt;
  final text = StringBuffer();
  bool isFinal = false;
  bool skip = false;
  bool saved = false;
}

class OpenAIRealtimeProtocol {
  OpenAIRealtimeProtocol({DateTime Function()? clock, this.staleAfter = const Duration(seconds: 15)})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// A user turn whose transcription never arrives stops blocking later turns
  /// after this long.
  final Duration staleAfter;

  final _items = <String, _Item>{};
  final _order = <String>[];
  String? _activeResponseId;
  bool _assistantAudioPlaying = false;

  bool get assistantAudioPlaying => _assistantAudioPlaying;
  bool get responseInProgress => _activeResponseId != null;

  // ------------------------------------------------------------------ commands

  static const List<Map<String, Object?>> interruptCommands = [
    {'type': 'response.cancel'},
    {'type': 'output_audio_buffer.clear'},
  ];

  List<Map<String, Object?>> pushToTalkStartCommands() => [
    {'type': 'input_audio_buffer.clear'},
    if (responseInProgress) {'type': 'response.cancel'},
    if (_assistantAudioPlaying) {'type': 'output_audio_buffer.clear'},
  ];

  static const List<Map<String, Object?>> pushToTalkEndCommands = [
    {'type': 'input_audio_buffer.commit'},
    {'type': 'response.create'},
  ];

  // ------------------------------------------------------------------ events

  /// Translates one server event into state-machine events.
  List<VoiceEvent> handle(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'input_audio_buffer.speech_started':
        return const [VoiceUserSpeechStarted()];
      case 'input_audio_buffer.speech_stopped':
        return const [VoiceUserSpeechStopped()];
      case 'output_audio_buffer.started':
        _assistantAudioPlaying = true;
        return const [VoiceAssistantAudioStarted()];
      case 'output_audio_buffer.stopped' || 'output_audio_buffer.cleared':
        _assistantAudioPlaying = false;
        return const [VoiceAssistantAudioFinished()];
      case 'response.created':
        _activeResponseId = (event['response'] as Map?)?['id'] as String? ?? 'active';
        return const [];
      case 'response.done':
        _activeResponseId = null;
        // Cancelled/interrupted replies never get a transcript "done": keep what was said.
        for (final item in _items.values) {
          if (item.role == TranscriptRole.assistant && !item.isFinal) {
            item.isFinal = true;
            item.skip = item.text.isEmpty;
          }
        }
        return [..._finalAssistantUpdates(), const VoiceResponseFinished()];
      case 'conversation.item.added':
        final item = event['item'] as Map?;
        final id = item?['id'] as String?;
        final role = switch (item?['role']) {
          'user' => TranscriptRole.user,
          'assistant' => TranscriptRole.assistant,
          _ => null,
        };
        if (id == null || role == null || item?['type'] != 'message' || _items.containsKey(id)) return const [];
        _items[id] = _Item(id, role, _clock());
        _order.add(id);
        // Reserve the transcript slot so turns stay in conversation order.
        return [VoiceTranscriptUpdated(role: role, text: '', isFinal: false, itemId: id)];
      case 'conversation.item.input_audio_transcription.delta':
        return _append(event['item_id'] as String?, TranscriptRole.user, event['delta'] as String? ?? '');
      case 'conversation.item.input_audio_transcription.completed':
        return _complete(event['item_id'] as String?, TranscriptRole.user, event['transcript'] as String? ?? '');
      case 'conversation.item.input_audio_transcription.failed':
        final item = _items[event['item_id']];
        if (item != null) {
          item
            ..isFinal = true
            ..skip = true;
        }
        return const [];
      case 'response.output_audio_transcript.delta':
        return _append(event['item_id'] as String?, TranscriptRole.assistant, event['delta'] as String? ?? '');
      case 'response.output_audio_transcript.done':
        return _complete(event['item_id'] as String?, TranscriptRole.assistant, event['transcript'] as String? ?? '');
      default:
        return const []; // session.*, rate_limits.updated, non-fatal error, ...
    }
  }

  /// The `error` event's message, when the server reports one.
  static String? errorMessage(Map<String, dynamic> event) {
    if (event['type'] != 'error') return null;
    return ((event['error'] as Map?)?['message'] as String?) ?? 'The voice service reported an error.';
  }

  _Item _ensure(String id, TranscriptRole role) => _items.putIfAbsent(id, () {
    _order.add(id);
    return _Item(id, role, _clock());
  });

  List<VoiceEvent> _append(String? id, TranscriptRole role, String delta) {
    if (id == null) return const [];
    final item = _ensure(id, role)..text.write(delta);
    if (item.isFinal) return const [];
    return [VoiceTranscriptUpdated(role: role, text: item.text.toString(), isFinal: false, itemId: id)];
  }

  List<VoiceEvent> _complete(String? id, TranscriptRole role, String transcript) {
    if (id == null) return const [];
    final item = _ensure(id, role);
    item
      ..text.clear()
      ..text.write(transcript.trim())
      ..isFinal = true
      ..skip = transcript.trim().isEmpty;
    return [VoiceTranscriptUpdated(role: role, text: item.text.toString(), isFinal: true, itemId: id)];
  }

  List<VoiceEvent> _finalAssistantUpdates() => [
    for (final item in _items.values)
      if (item.role == TranscriptRole.assistant && item.isFinal && !item.skip && !item.saved)
        VoiceTranscriptUpdated(role: item.role, text: item.text.toString(), isFinal: true, itemId: item.id),
  ];

  /// Finished turns ready to store, strictly in conversation order. A pending
  /// turn blocks later ones until it finishes, fails, or goes stale.
  /// Pass [flush] when the session ends to release everything that finished.
  List<CompletedTurn> takeReadyTurns({bool flush = false}) {
    final now = _clock();
    final ready = <CompletedTurn>[];
    for (final id in _order) {
      final item = _items[id]!;
      if (item.saved) continue;
      if (!item.isFinal) {
        final laterFinished = _order.skipWhile((other) => other != id).skip(1).any((other) => _items[other]!.isFinal);
        final stale = laterFinished && now.difference(item.addedAt) > staleAfter;
        if (flush || stale) {
          item
            ..saved = true
            ..skip = true;
          continue;
        }
        break;
      }
      item.saved = true;
      if (!item.skip) ready.add(CompletedTurn(itemId: id, role: item.role, text: item.text.toString()));
    }
    return ready;
  }
}
