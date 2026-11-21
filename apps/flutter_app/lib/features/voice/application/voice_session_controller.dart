import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../domain/entities/ai_provider.dart';
import '../../../domain/entities/user_preferences.dart';
import '../../../domain/voice/voice_session_state.dart';
import '../../../domain/voice/voice_transport.dart';
import '../../../providers/dependencies.dart';
import '../../../providers/preferences_controller.dart';

/// Drives one voice session: picks a realtime-capable model, opens the
/// provider transport and feeds its events through [reduceVoiceState].
class VoiceSessionController extends Notifier<VoiceSessionState> {
  VoiceTransport? _transport;
  StreamSubscription<VoiceEvent>? _events;

  @override
  VoiceSessionState build() {
    ref.onDispose(() => unawaited(_closeTransport()));
    return const VoiceSessionState.initial();
  }

  void _dispatch(VoiceEvent event) {
    if (ref.mounted) state = reduceVoiceState(state, event);
  }

  /// Starts a session saved to [conversationId] (or a new conversation).
  Future<void> start({String? providerId, String? modelId, String? conversationId}) async {
    if (state.phase != VoicePhase.disconnected && state.phase != VoicePhase.error) return;
    _dispatch(const VoiceConnectRequested());

    final ModelSelection? selection;
    try {
      final catalog = await ref.read(providerCatalogProvider.future);
      selection = catalog.realtimeVoice(providerId: providerId, modelId: modelId);
    } on ApiException catch (error) {
      _dispatch(VoiceFailed(error.userMessage));
      return;
    }
    if (!ref.mounted) return;
    if (selection == null) {
      _dispatch(const VoiceFailed('No realtime voice model is configured on the server.'));
      return;
    }

    final preferences = ref.read(preferencesControllerProvider).value;
    final transport = ref.read(voiceTransportFactoryProvider)(
      VoiceSessionOptions(
        selection: selection,
        conversationId: conversationId ?? state.conversationId,
        audio: preferences?.audioSettings ?? const AudioSettings(),
      ),
    );
    if (transport == null) {
      _dispatch(
        VoiceFailed('Realtime voice for ${selection.provider.displayName} is not available in this app version.'),
      );
      return;
    }

    _transport = transport;
    _events = transport.events.listen(
      _dispatch,
      onError: (Object error) => _dispatch(VoiceFailed('Voice connection error: $error')),
    );
    try {
      await transport.connect();
    } catch (error) {
      _dispatch(
        VoiceFailed(switch (error) {
          VoiceConnectError(:final message) => message,
          ApiException() => error.userMessage,
          _ => 'Could not start the voice session.',
        }),
      );
      await _closeTransport();
    }
  }

  /// Push-to-talk: called when the talk button is pressed / released.
  Future<void> startTalking() async {
    if (state.pushToTalk && state.phase.isConnected) await _transport?.startTalking();
  }

  Future<void> stopTalking() async {
    if (state.pushToTalk) await _transport?.stopTalking();
  }

  Future<void> toggleMute() async {
    final transport = _transport;
    if (transport == null || !state.phase.isConnected) return;
    final muted = !state.isMuted;
    await transport.setMuted(muted);
    _dispatch(VoiceMuteChanged(muted: muted));
  }

  Future<void> interrupt() async {
    if (state.phase == VoicePhase.speaking) await _transport?.interrupt();
  }

  Future<void> end() async {
    await _closeTransport();
    _dispatch(const VoiceDisconnectRequested());
  }

  void dismissError() => _dispatch(const VoiceReset());

  Future<void> _closeTransport() async {
    final transport = _transport;
    final events = _events;
    _transport = null;
    _events = null;
    // Cancelling stops delivery immediately; awaiting it is not needed (and the
    // returned future can belong to another zone, e.g. under fake-async tests).
    if (events != null) unawaited(events.cancel());
    await transport?.close();
  }
}

final voiceSessionControllerProvider = NotifierProvider.autoDispose<VoiceSessionController, VoiceSessionState>(
  VoiceSessionController.new,
);
