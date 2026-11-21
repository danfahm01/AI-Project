import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/network/api_exception.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/markdown_view.dart';
import '../../../../domain/entities/chat_message.dart';
import '../../application/chat_controller.dart';
import 'message_attachments.dart';

class MessageBubble extends ConsumerStatefulWidget {
  const MessageBubble({super.key, required this.message, required this.isLast});

  final ChatMessage message;

  /// Whether this is the newest message (editing it removes nothing after it).
  final bool isLast;

  @override
  ConsumerState<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends ConsumerState<MessageBubble> {
  bool _hovered = false;
  bool _editing = false;

  ChatMessage get _message => widget.message;
  ChatController get _controller => ref.read(chatControllerProvider(_message.conversationId).notifier);

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _message.content));
    if (mounted) showInfoSnackBar(context, 'Copied to clipboard');
  }

  Future<void> _delete() async {
    final confirmed = await confirmDialog(
      context,
      title: 'Delete message?',
      message: 'This message will be permanently removed from the conversation.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed && mounted) await runGuarded(context, () => _controller.delete(_message.id));
  }

  Future<void> _saveEdit(String content) async {
    if (content.trim().isEmpty || content == _message.content) {
      setState(() => _editing = false);
      return;
    }
    try {
      await _controller.edit(_message.id, content);
      if (mounted) setState(() => _editing = false);
    } on ApiException catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = _message.isUser;
    final isTouch = switch (theme.platform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
      _ => false,
    };

    if (_editing) {
      return _EditBox(
        initialText: _message.content,
        warnTruncation: !widget.isLast,
        onCancel: () => setState(() => _editing = false),
        onSave: _saveEdit,
      );
    }

    final generating = ref.watch(
      chatControllerProvider(_message.conversationId).select((s) => s.value?.isGenerating ?? false),
    );
    final thinking = _message.status == MessageStatus.streaming && _message.content.isEmpty;
    final Widget content = isUser
        ? SelectableText(_message.content, style: theme.textTheme.bodyLarge?.copyWith(height: 1.5))
        : thinking
        ? const _StatusLine(icon: null, text: 'Thinking…')
        : SelectionArea(child: MarkdownView(data: _message.content));
    final canRegenerate = _message.isAssistant && widget.isLast && !generating;

    final body = isUser
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_message.attachments.isNotEmpty) MessageAttachments(attachments: _message.attachments),
              if (_message.content.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxWidth: 600),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: content,
                ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: AppMark(size: 26)),
              const SizedBox(width: 12),
              Expanded(child: content),
            ],
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            body,
            switch (_message.status) {
              MessageStatus.sending => const _StatusLine(icon: null, text: 'Sending…'),
              MessageStatus.failed => _FailedLine(
                message: _message.errorMessage ?? 'Not sent',
                onRetry: generating ? null : () => _controller.retry(_message.id),
                onDiscard: () => _controller.discard(_message.id),
              ),
              MessageStatus.streaming => const SizedBox.shrink(),
              _ => Column(
                crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (_message.status == MessageStatus.error)
                    _Note(
                      icon: Icons.error_outline_rounded,
                      text: _message.errorMessage ?? 'The response could not be completed.',
                      isError: true,
                    ),
                  if (_message.status == MessageStatus.cancelled)
                    const _Note(icon: Icons.stop_circle_outlined, text: 'Stopped', isError: false),
                  _Actions(
                    visible: _hovered || isTouch || (canRegenerate && _message.status != MessageStatus.complete),
                    alignEnd: isUser,
                    onCopy: _message.content.isEmpty ? null : _copy,
                    onEdit: isUser && !generating ? () => setState(() => _editing = true) : null,
                    onRegenerate: canRegenerate ? () => _controller.regenerate() : null,
                    onDelete: generating ? null : _delete,
                    edited: _message.editedAt != null,
                  ),
                ],
              ),
            },
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.visible,
    required this.alignEnd,
    required this.onCopy,
    required this.onDelete,
    required this.edited,
    this.onEdit,
    this.onRegenerate,
  });

  final bool visible;
  final bool alignEnd;
  final bool edited;
  final VoidCallback? onCopy;
  final VoidCallback? onEdit;
  final VoidCallback? onRegenerate;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const iconSize = 18.0;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: IgnorePointer(
        ignoring: !visible,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (edited)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Edited',
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            IconButton(
              tooltip: 'Copy',
              iconSize: iconSize,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.content_copy_rounded),
              onPressed: onCopy,
            ),
            if (onEdit != null)
              IconButton(
                tooltip: 'Edit',
                iconSize: iconSize,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_outlined),
                onPressed: onEdit,
              ),
            if (onRegenerate != null)
              IconButton(
                tooltip: 'Regenerate response',
                iconSize: iconSize,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: onRegenerate,
              ),
            IconButton(
              tooltip: 'Delete',
              iconSize: iconSize,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.icon, required this.text});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon == null)
            const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
          else
            Icon(icon, size: 14),
          const SizedBox(width: 6),
          Text(text, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, required this.isError});

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.error : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 38),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

class _FailedLine extends StatelessWidget {
  const _FailedLine({required this.message, required this.onRetry, required this.onDiscard});

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.end,
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: scheme.error),
          const SizedBox(width: 6),
          Text(message, style: style?.copyWith(color: scheme.error)),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
          TextButton(onPressed: onDiscard, child: const Text('Discard')),
        ],
      ),
    );
  }
}

class _EditBox extends StatefulWidget {
  const _EditBox({
    required this.initialText,
    required this.warnTruncation,
    required this.onCancel,
    required this.onSave,
  });

  final String initialText;
  final bool warnTruncation;
  final VoidCallback onCancel;
  final Future<void> Function(String content) onSave;

  @override
  State<_EditBox> createState() => _EditBoxState();
}

class _EditBoxState extends State<_EditBox> {
  late final _controller = TextEditingController(text: widget.initialText);
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.onSave(_controller.text);
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 10,
            decoration: const InputDecoration(filled: false, border: InputBorder.none, enabledBorder: InputBorder.none),
          ),
          if (widget.warnTruncation)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Saving removes the messages after this one.',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _saving ? null : widget.onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}
