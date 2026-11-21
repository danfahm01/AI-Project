/// Pure state machine for a realtime voice session.
///
/// The voice UI renders exclusively from [VoiceSessionState]; transports
/// (phase 3) translate provider events into [VoiceEvent]s. Events that are not
/// valid in the current phase are ignored, so out-of-order provider events can
/// never put the UI into an impossible state.
library;

enum VoicePhase {
  disconnected,
  connecting,
  idle,
  listening,
  processing,
  speaking,
  interrupted,
  reconnecting,
  error;

  bool get isConnected => switch (this) {
    idle || listening || processing || speaking || interrupted => true,
    _ => false,
  };

  bool get isActive => isConnected || this == connecting || this == reconnecting;

  /// Phases whose visuals react to live audio levels.
  bool get usesAudioLevel => this == listening || this == speaking || this == interrupted;
}

enum TranscriptRole { user, assistant }

class TranscriptEntry {
  const TranscriptEntry({required this.role, required this.text, required this.isFinal, this.itemId});

  final TranscriptRole role;
  final String text;
  final bool isFinal;

  /// Provider item id; updates for the same item replace it in place, so a
  /// user transcript that finishes after the reply started keeps its position.
  final String? itemId;
}

class VoiceSessionState {
  const VoiceSessionState({
    required this.phase,
    this.isMuted = false,
    this.level = 0,
    this.errorMessage,
    this.reconnectAttempt = 0,
    this.transcript = const [],
    this.pushToTalk = false,
    this.conversationId,
  });

  const VoiceSessionState.initial() : this(phase: VoicePhase.disconnected);

  final VoicePhase phase;
  final bool isMuted;

  /// Current audio level in [0, 1]: microphone while listening, playback while speaking.
  final double level;
  final String? errorMessage;
  final int reconnectAttempt;
  final List<TranscriptEntry> transcript;

  /// Turn-taking mode of the connected session (from the user's settings).
  final bool pushToTalk;

  /// Conversation the transcript is saved to (may be created by the session).
  final String? conversationId;

  VoiceSessionState copyWith({
    VoicePhase? phase,
    bool? isMuted,
    double? level,
    String? errorMessage,
    bool clearError = false,
    int? reconnectAttempt,
    List<TranscriptEntry>? transcript,
    bool? pushToTalk,
    String? conversationId,
  }) {
    final nextPhase = phase ?? this.phase;
    return VoiceSessionState(
      phase: nextPhase,
      isMuted: isMuted ?? this.isMuted,
      level: nextPhase.usesAudioLevel ? (level ?? this.level).clamp(0.0, 1.0) : 0,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      transcript: transcript ?? this.transcript,
      pushToTalk: pushToTalk ?? this.pushToTalk,
      conversationId: conversationId ?? this.conversationId,
    );
  }
}

sealed class VoiceEvent {
  const VoiceEvent();
}

class VoiceConnectRequested extends VoiceEvent {
  const VoiceConnectRequested();
}

class VoiceConnected extends VoiceEvent {
  const VoiceConnected();
}

class VoiceUserSpeechStarted extends VoiceEvent {
  const VoiceUserSpeechStarted();
}

class VoiceUserSpeechStopped extends VoiceEvent {
  const VoiceUserSpeechStopped();
}

class VoiceAssistantAudioStarted extends VoiceEvent {
  const VoiceAssistantAudioStarted();
}

class VoiceAssistantAudioFinished extends VoiceEvent {
  const VoiceAssistantAudioFinished();
}

class VoiceConnectionLost extends VoiceEvent {
  const VoiceConnectionLost();
}

class VoiceReconnectGaveUp extends VoiceEvent {
  const VoiceReconnectGaveUp();
}

class VoiceFailed extends VoiceEvent {
  const VoiceFailed(this.message);

  final String message;
}

class VoiceDisconnectRequested extends VoiceEvent {
  const VoiceDisconnectRequested();
}

class VoiceReset extends VoiceEvent {
  const VoiceReset();
}

class VoiceMuteChanged extends VoiceEvent {
  const VoiceMuteChanged({required this.muted});

  final bool muted;
}

class VoiceLevelChanged extends VoiceEvent {
  const VoiceLevelChanged(this.level);

  final double level;
}

class VoiceTranscriptUpdated extends VoiceEvent {
  const VoiceTranscriptUpdated({required this.role, required this.text, required this.isFinal, this.itemId});

  final TranscriptRole role;
  final String text;
  final bool isFinal;
  final String? itemId;
}

/// A reply finished without (more) audio, e.g. it was cancelled before speaking.
class VoiceResponseFinished extends VoiceEvent {
  const VoiceResponseFinished();
}

/// Session details known once connected.
class VoiceSessionConfigured extends VoiceEvent {
  const VoiceSessionConfigured({required this.pushToTalk, required this.conversationId});

  final bool pushToTalk;
  final String? conversationId;
}

VoiceSessionState reduceVoiceState(VoiceSessionState state, VoiceEvent event) {
  final phase = state.phase;
  VoiceSessionState to(VoicePhase next) => state.copyWith(phase: next);

  return switch (event) {
    VoiceConnectRequested() when phase == VoicePhase.disconnected || phase == VoicePhase.error => state.copyWith(
      phase: VoicePhase.connecting,
      clearError: true,
      reconnectAttempt: 0,
      isMuted: false,
    ),
    VoiceConnected() when phase == VoicePhase.connecting || phase == VoicePhase.reconnecting => state.copyWith(
      phase: VoicePhase.idle,
      reconnectAttempt: 0,
    ),

    VoiceUserSpeechStarted() => switch (phase) {
      VoicePhase.idle || VoicePhase.processing || VoicePhase.interrupted => to(VoicePhase.listening),
      VoicePhase.speaking => to(VoicePhase.interrupted), // barge-in
      _ => state,
    },
    VoiceUserSpeechStopped() => switch (phase) {
      VoicePhase.listening || VoicePhase.interrupted => to(VoicePhase.processing),
      _ => state,
    },
    VoiceAssistantAudioStarted() => switch (phase) {
      VoicePhase.idle || VoicePhase.processing || VoicePhase.listening => to(VoicePhase.speaking),
      _ => state,
    },
    VoiceAssistantAudioFinished() => switch (phase) {
      VoicePhase.speaking => to(VoicePhase.idle),
      VoicePhase.interrupted => to(VoicePhase.listening),
      _ => state,
    },
    VoiceResponseFinished() when phase == VoicePhase.processing => to(VoicePhase.idle),
    VoiceSessionConfigured(:final pushToTalk, :final conversationId) => state.copyWith(
      pushToTalk: pushToTalk,
      conversationId: conversationId,
    ),

    VoiceConnectionLost() when phase.isConnected || phase == VoicePhase.reconnecting => state.copyWith(
      phase: VoicePhase.reconnecting,
      reconnectAttempt: state.reconnectAttempt + 1,
    ),
    VoiceReconnectGaveUp() when phase == VoicePhase.reconnecting => state.copyWith(
      phase: VoicePhase.disconnected,
      errorMessage: 'Connection lost. Start a new voice session to continue.',
      reconnectAttempt: 0,
    ),

    VoiceFailed(:final message) => state.copyWith(phase: VoicePhase.error, errorMessage: message, isMuted: false),
    VoiceDisconnectRequested() => const VoiceSessionState.initial().copyWith(
      transcript: state.transcript,
      conversationId: state.conversationId,
    ),
    VoiceReset() when phase == VoicePhase.error => state.copyWith(phase: VoicePhase.disconnected, clearError: true),

    VoiceMuteChanged(:final muted) when phase.isConnected => state.copyWith(isMuted: muted),
    VoiceLevelChanged(:final level) when phase.usesAudioLevel => state.copyWith(level: level),
    VoiceTranscriptUpdated() when phase.isActive => state.copyWith(
      transcript: _applyTranscript(state.transcript, event),
    ),

    _ => state,
  };
}

List<TranscriptEntry> _applyTranscript(List<TranscriptEntry> current, VoiceTranscriptUpdated update) {
  final entry = TranscriptEntry(role: update.role, text: update.text, isFinal: update.isFinal, itemId: update.itemId);
  // Updates for a known provider item replace it where it is.
  if (update.itemId != null) {
    final index = current.indexWhere((e) => e.itemId == update.itemId);
    if (index >= 0) return [...current]..[index] = entry;
    return [...current, entry];
  }
  // A partial transcript for the same speaker replaces the previous partial.
  if (current.isNotEmpty && !current.last.isFinal && current.last.role == update.role) {
    return [...current.sublist(0, current.length - 1), entry];
  }
  return [...current, entry];
}
