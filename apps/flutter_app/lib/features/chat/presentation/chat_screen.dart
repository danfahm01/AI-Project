import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../domain/chat/chat_stream.dart';
import '../../../domain/entities/attachment.dart';
import '../../../providers/auth_controller.dart';
import '../../../providers/dependencies.dart';
import '../../../providers/preferences_controller.dart';
import '../../shell/chat_shell.dart';
import '../application/chat_controller.dart';
import '../application/conversation_list_controller.dart';
import 'widgets/composer.dart';
import 'widgets/message_bubble.dart';
import 'widgets/model_selector.dart';

/// A conversation, or the new-chat screen when [conversationId] is null.
class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, this.conversationId});

  final String? conversationId;

  Future<void> _send(BuildContext context, WidgetRef ref, String text, List<Attachment> attachments) async {
    final id = conversationId;
    if (id != null) {
      await ref.read(chatControllerProvider(id).notifier).send(text, attachments: attachments);
      return;
    }
    // New chat: create the conversation with the default model, then open it;
    // its controller sends the first message once the screen is up.
    final preferences = ref.read(preferencesControllerProvider).value;
    final catalog = ref.read(providerCatalogProvider).value;
    final model = catalog?.resolve(providerId: preferences?.defaultProvider, modelId: preferences?.defaultModel);
    final conversation = await ref.read(conversationListControllerProvider.notifier).create(model: model);
    ref.read(pendingFirstMessagesProvider.notifier).put(conversation.id, text, attachments: attachments);
    if (context.mounted) context.go('/chat/${conversation.id}');
  }

  void _openVoice(BuildContext context) {
    final id = conversationId;
    context.push(id == null ? '/voice' : '/voice?conversation=$id');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = conversationId;
    final conversation = id == null ? null : ref.watch(conversationProvider(id));
    final catalog = ref.watch(providerCatalogProvider).value;

    final notFound = conversation?.error is ApiException && (conversation!.error! as ApiException).isNotFound;
    if (notFound) return const _ConversationNotFound();

    final title = id == null ? 'New chat' : (conversation?.value?.title ?? '');
    // The model the next message goes to decides which attachments are offered.
    final preferences = ref.watch(preferencesControllerProvider).value;
    final model = catalog?.resolve(
      providerId: conversation?.value?.provider ?? preferences?.defaultProvider,
      modelId: conversation?.value?.model ?? preferences?.defaultModel,
    );
    final capabilities = model?.model.capabilities;
    final chat = id == null ? null : ref.watch(chatControllerProvider(id)).value;
    final chatController = id == null ? null : ref.read(chatControllerProvider(id).notifier);
    final reconnecting = ref.watch(chatConnectionStatusProvider).value == ChatConnectionStatus.reconnecting;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: shellNavigationButton(context),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          ModelSelector(conversation: conversation?.value),
          IconButton(
            tooltip: 'Voice mode',
            icon: const Icon(Icons.graphic_eq_rounded),
            onPressed: () => _openVoice(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: id == null ? const _EmptyChat() : _MessageList(conversationId: id)),
          if (reconnecting)
            const _Banner(icon: Icons.wifi_off_rounded, text: 'Connection lost. Reconnecting…')
          else if (chat?.failure case final failure?)
            _Banner(
              icon: Icons.error_outline_rounded,
              text: failure.message,
              isError: true,
              actionLabel: 'Try again',
              onAction: chatController?.regenerate,
            )
          else if (catalog != null && catalog.isEmpty)
            const _Banner(
              icon: Icons.info_outline_rounded,
              text:
                  'No AI provider is connected to the server yet. Your messages are saved, '
                  'and replies will appear once a provider is configured.',
            ),
          Composer(
            key: ValueKey(id),
            onSend: (text, attachments) => _send(context, ref, text, attachments),
            onOpenVoice: () => _openVoice(context),
            isGenerating: chat?.isGenerating ?? false,
            onStop: chatController?.stop,
            acceptImages: capabilities?.imageInput ?? false,
            acceptPdfs: capabilities?.pdfInput ?? false,
            modelName: model?.model.displayName,
          ),
        ],
      ),
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatControllerProvider(conversationId));
    return chat.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, _) =>
          ErrorView(error: error, onRetry: () => ref.invalidate(chatControllerProvider(conversationId))),
      data: (state) {
        final items = state.messages;
        if (items.isEmpty) {
          final theme = Theme.of(context);
          return Center(
            child: Text(
              'No messages yet. Say hello!',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          );
        }
        // Reversed so the list stays anchored to the newest message.
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 16),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final message = items[items.length - 1 - index];
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: Breakpoints.contentMaxWidth),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: MessageBubble(key: ValueKey(message.id), message: message, isLast: index == 0),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _EmptyChat extends ConsumerWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider);
    final hour = DateTime.now().hour;
    final greeting = hour < 12 ? 'Good morning' : (hour < 18 ? 'Good afternoon' : 'Good evening');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppMark(size: 56),
            const SizedBox(height: 20),
            Text(
              user == null ? greeting : '$greeting, ${user.firstName}',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'How can I help you today?',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.isError = false, this.actionLabel, this.onAction});

  final IconData icon;
  final String text;
  final bool isError;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = isError ? theme.colorScheme.errorContainer : theme.colorScheme.secondaryContainer;
    final foreground = isError ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSecondaryContainer;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Breakpoints.contentMaxWidth),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          padding: EdgeInsets.fromLTRB(14, actionLabel == null ? 10 : 4, 6, actionLabel == null ? 10 : 4),
          decoration: BoxDecoration(color: background.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(14)),
          child: Row(
            children: [
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: foreground)),
              ),
              if (actionLabel != null) TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationNotFound extends StatelessWidget {
  const _ConversationNotFound();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, leading: shellNavigationButton(context)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('Conversation not found', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'It may have been deleted.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: () => context.go('/chat'), child: const Text('Start a new chat')),
          ],
        ),
      ),
    );
  }
}
