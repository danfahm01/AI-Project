import '../../domain/entities/user_preferences.dart';

enum RealtimeLinkState { connecting, open, failed, closed }

/// Audio + event channel to a realtime voice service (implemented with WebRTC
/// in `webrtc_realtime_link.dart`). Kept minimal so protocol logic is testable
/// without a WebRTC stack.
abstract interface class RealtimeLink {
  /// JSON events received on the data channel.
  Stream<Map<String, dynamic>> get messages;

  Stream<RealtimeLinkState> get states;

  /// Captures the microphone, creates the connection and completes once the
  /// event channel is open. [exchangeSdp] posts the offer and returns the answer.
  Future<void> connect({
    required Future<String> Function(String offerSdp) exchangeSdp,
    required String dataChannelLabel,
    required AudioSettings audio,
  });

  void send(Map<String, Object?> event);

  void setMicrophoneEnabled(bool enabled);

  /// Current microphone (input) and playback (output) levels in [0, 1].
  Future<({double input, double output})> levels();

  Future<void> close();
}

/// Raised when the microphone cannot be used.
class MicrophoneUnavailable implements Exception {
  const MicrophoneUnavailable({required this.denied, this.detail});

  /// True when the user or the OS refused access (vs. no device found).
  final bool denied;
  final String? detail;
}
