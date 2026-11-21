import '../entities/ai_provider.dart';
import '../entities/user_preferences.dart';
import 'voice_session_state.dart';

/// Provider-agnostic realtime voice connection.
///
/// The UI and [VoiceSessionState] never see provider-specific events; each
/// implementation translates its provider's protocol into [VoiceEvent]s.
abstract interface class VoiceTransport {
  /// Provider events already translated into state-machine events, including
  /// [VoiceLevelChanged] for microphone/playback levels.
  Stream<VoiceEvent> get events;

  /// Requests microphone access, obtains a short-lived session from the
  /// backend and opens the realtime connection. Throws [VoiceConnectError].
  Future<void> connect();

  /// Conversation the transcript is stored in (known after [connect]).
  String? get conversationId;

  /// Whether the session uses push-to-talk instead of automatic turn detection.
  bool get pushToTalk;

  Future<void> setMuted(bool muted);

  /// Push-to-talk: start capturing a turn (also stops the assistant speaking).
  Future<void> startTalking();

  /// Push-to-talk: finish the turn and ask for a reply.
  Future<void> stopTalking();

  /// Stops assistant playback immediately (manual interruption).
  Future<void> interrupt();

  Future<void> close();
}

/// Why connecting failed, in words the user can act on.
class VoiceConnectError implements Exception {
  const VoiceConnectError(this.message);

  final String message;

  @override
  String toString() => message;
}

class VoiceSessionOptions {
  const VoiceSessionOptions({required this.selection, this.conversationId, this.audio = const AudioSettings()});

  final ModelSelection selection;
  final String? conversationId;

  /// Microphone processing (echo cancellation, noise suppression, gain control).
  final AudioSettings audio;
}

/// Creates the transport for a provider, or returns `null` when this app build
/// has no transport for it.
typedef VoiceTransportFactory = VoiceTransport? Function(VoiceSessionOptions options);
