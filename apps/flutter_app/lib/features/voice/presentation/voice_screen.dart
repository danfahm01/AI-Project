import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/widgets/common_widgets.dart';
import '../../../domain/entities/ai_provider.dart';
import '../../../domain/voice/voice_session_state.dart';
import '../../../providers/preferences_controller.dart';
import '../../chat/application/chat_controller.dart';
import '../../chat/application/conversation_list_controller.dart';
import '../application/voice_session_controller.dart';
import 'widgets/voice_orb.dart';
import 'widgets/voice_settings_section.dart';

/// Full-screen voice conversation.
class VoiceScreen extends ConsumerWidget {
  const VoiceScreen({super.key, this.conversationId});

  final String? conversationId;

  /// Ends the session and returns to the conversation, reloaded so the saved
  /// voice turns appear. A session started from "new chat" opens its new conversation.
  Future<void> _close(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(voiceSessionControllerProvider.notifier);
    final sessionConversation = ref.read(voiceSessionControllerProvider).conversationId;
    await controller.end();
    final target = sessionConversation ?? conversationId;
    if (target != null) {
      ref.invalidate(chatControllerProvider(target));
      unawaited(ref.read(conversationListControllerProvider.notifier).refreshOne(target).catchError((Object _) {}));
    }
    if (!context.mounted) return;
    if (context.canPop() && (target == null || target == conversationId)) {
      context.pop();
    } else {
      context.go(target == null ? '/chat' : '/chat/$target');
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, WidgetRef ref) {
    final session = ref.read(voiceSessionControllerProvider);
    if (!session.pushToTalk || event.logicalKey != LogicalKeyboardKey.space) return KeyEventResult.ignored;
    final controller = ref.read(voiceSessionControllerProvider.notifier);
    if (event is KeyDownEvent) controller.startTalking();
    if (event is KeyUpEvent) controller.stopTalking();
    return KeyEventResult.handled;
  }

  /// Provider of the open conversation: voice continues with it unless the user
  /// chose a voice model.
  String? _conversationProvider(WidgetRef ref) =>
      conversationId == null ? null : ref.watch(conversationProvider(conversationId!)).value?.provider;

  ModelSelection? _voiceModel(WidgetRef ref) => selectVoiceModel(
    ref.watch(providerCatalogProvider).value,
    ref.watch(preferencesControllerProvider).value,
    fallbackProviderId: _conversationProvider(ref),
  );

  void _openSettings(BuildContext context, String? fallbackProviderId) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final preferences = ref.watch(preferencesControllerProvider);
          final catalog = ref.watch(providerCatalogProvider).value ?? ProviderCatalog.empty;
          return SafeArea(
            child: SingleChildScrollView(
              child: preferences.when(
                data: (prefs) => prefs == null
                    ? const SizedBox.shrink()
                    : VoiceSettingsSection(
                        preferences: prefs,
                        catalog: catalog,
                        fallbackProviderId: fallbackProviderId,
                      ),
                loading: () => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                ),
                error: (error, _) => ErrorView(error: error, compact: true),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(voiceSessionControllerProvider);
    final controller = ref.read(voiceSessionControllerProvider.notifier);
    final catalogLoading = ref.watch(providerCatalogProvider).isLoading;
    final voiceModel = _voiceModel(ref);
    final phase = session.phase;

    final (title, subtitle) = _describe(session, voiceModel, catalogLoading);

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) => _onKey(node, event, ref),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close voice mode',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => _close(context, ref),
          ),
          title: Text(voiceModel == null ? 'Voice' : 'Voice · ${voiceModel.model.displayName}'),
          actions: [
            IconButton(
              tooltip: 'Voice settings',
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => _openSettings(context, _conversationProvider(ref)),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final orbSize = (constraints.biggest.shortestSide * 0.6).clamp(160.0, 300.0);
              return Column(
                children: [
                  Expanded(
                    flex: 5,
                    child: Center(
                      child: VoiceOrb(phase: phase, level: session.level, size: orbSize),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      children: [
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          subtitle,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: phase == VoicePhase.error
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(flex: 3, child: _Transcript(entries: session.transcript)),
                  _Controls(
                    session: session,
                    controller: controller,
                    onStart: voiceModel == null
                        ? null
                        : () => controller.start(
                            providerId: voiceModel.provider.id,
                            modelId: voiceModel.model.id,
                            conversationId: conversationId,
                          ),
                  ),
                  const SizedBox(height: 24),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  (String, String) _describe(VoiceSessionState session, ModelSelection? voiceModel, bool catalogLoading) {
    return switch (session.phase) {
      VoicePhase.disconnected when catalogLoading => ('Disconnected', 'Checking available voice models…'),
      VoicePhase.disconnected when voiceModel == null => (
        'Disconnected',
        session.errorMessage ?? 'Voice needs a realtime-capable AI provider configured on the server.',
      ),
      VoicePhase.disconnected => ('Disconnected', session.errorMessage ?? 'Tap the call button to start talking.'),
      VoicePhase.connecting => ('Connecting…', 'Setting up a secure voice session.'),
      VoicePhase.idle when session.pushToTalk => ('Ready', 'Hold the talk button (or Space) while you speak.'),
      VoicePhase.idle => ('Ready', session.isMuted ? 'Your microphone is muted.' : 'Start speaking whenever you like.'),
      VoicePhase.listening when session.pushToTalk => ('Listening…', 'Release to send.'),
      VoicePhase.listening => ('Listening…', 'Pause when you are done speaking.'),
      VoicePhase.processing => ('Thinking…', 'Working on a response.'),
      VoicePhase.speaking => ('Speaking', 'Start talking to interrupt.'),
      VoicePhase.interrupted => ('Interrupted', 'Go ahead, I am listening.'),
      VoicePhase.reconnecting => ('Reconnecting…', 'Connection lost (attempt ${session.reconnectAttempt}).'),
      VoicePhase.error => ('Error', session.errorMessage ?? 'The voice session failed.'),
    };
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript({required this.entries});

  final List<TranscriptEntry> entries;

  @override
  Widget build(BuildContext context) {
    // Empty entries are slots reserved for transcripts still being produced.
    final entries = this.entries.where((e) => e.text.trim().isNotEmpty).toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[entries.length - 1 - index];
        final isUser = entry.role == TranscriptRole.user;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            entry.text,
            textAlign: isUser ? TextAlign.right : TextAlign.left,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: entry.isFinal ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
              fontStyle: entry.isFinal ? FontStyle.normal : FontStyle.italic,
            ),
          ),
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.session, required this.controller, required this.onStart});

  final VoiceSessionState session;
  final VoiceSessionController controller;

  /// `null` when no realtime voice model is available.
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phase = session.phase;
    final active = phase.isActive;
    final startable = phase == VoicePhase.disconnected || phase == VoicePhase.error;

    final talking = phase == VoicePhase.listening;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (session.pushToTalk && phase.isConnected)
          // Hold to talk: pointer down starts the turn, release sends it.
          Listener(
            onPointerDown: (_) => controller.startTalking(),
            onPointerUp: (_) => controller.stopTalking(),
            onPointerCancel: (_) => controller.stopTalking(),
            child: Tooltip(
              message: 'Hold to talk (Space)',
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: talking ? scheme.primary : scheme.secondaryContainer,
                ),
                child: Icon(
                  Icons.mic_rounded,
                  size: 28,
                  color: talking ? scheme.onPrimary : scheme.onSecondaryContainer,
                ),
              ),
            ),
          )
        else
          IconButton.filledTonal(
            tooltip: session.isMuted ? 'Unmute microphone' : 'Mute microphone',
            iconSize: 28,
            padding: const EdgeInsets.all(16),
            icon: Icon(session.isMuted ? Icons.mic_off_rounded : Icons.mic_none_rounded),
            onPressed: phase.isConnected ? controller.toggleMute : null,
          ),
        const SizedBox(width: 24),
        if (active)
          IconButton.filled(
            tooltip: 'End voice session',
            iconSize: 32,
            padding: const EdgeInsets.all(20),
            style: IconButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
            icon: const Icon(Icons.call_end_rounded),
            onPressed: controller.end,
          )
        else
          IconButton.filled(
            tooltip: onStart != null ? 'Start voice session' : 'No realtime voice model available',
            iconSize: 32,
            padding: const EdgeInsets.all(20),
            icon: const Icon(Icons.call_rounded),
            onPressed: startable ? onStart : null,
          ),
        const SizedBox(width: 24),
        IconButton.filledTonal(
          tooltip: 'Stop the assistant speaking',
          iconSize: 28,
          padding: const EdgeInsets.all(16),
          icon: const Icon(Icons.stop_rounded),
          onPressed: phase == VoicePhase.speaking ? controller.interrupt : null,
        ),
      ],
    );
  }
}
