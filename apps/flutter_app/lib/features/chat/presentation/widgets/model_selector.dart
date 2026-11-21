import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/widgets/common_widgets.dart';
import '../../../../domain/entities/ai_provider.dart';
import '../../../../domain/entities/conversation.dart';
import '../../../../providers/preferences_controller.dart';
import '../../application/conversation_list_controller.dart';

/// Model picker. For a conversation it changes that conversation's model;
/// on the new-chat screen it changes the account default.
class ModelSelector extends ConsumerWidget {
  const ModelSelector({super.key, this.conversation});

  final Conversation? conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(providerCatalogProvider);
    final preferences = ref.watch(preferencesControllerProvider).value;
    // On phones the label would crowd out the conversation title.
    final compact = MediaQuery.sizeOf(context).width < 600;

    return catalog.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (error, _) => IconButton(
        tooltip: "Couldn't load models. Tap to retry.",
        icon: const Icon(Icons.error_outline_rounded),
        onPressed: () => ref.invalidate(providerCatalogProvider),
      ),
      data: (catalog) {
        if (catalog.isEmpty) {
          return Tooltip(
            message: 'No AI provider is configured on the server',
            child: _SelectorLabel(label: 'No model available', enabled: false, compact: compact),
          );
        }
        final current = catalog.resolve(
          providerId: conversation?.provider ?? preferences?.defaultProvider,
          modelId: conversation?.model ?? preferences?.defaultModel,
        );
        return PopupMenuButton<ModelSelection>(
          tooltip: compact ? 'Model: ${current?.model.displayName ?? 'choose'}' : 'Choose model',
          position: PopupMenuPosition.under,
          onSelected: (selection) => runGuarded(context, () async {
            final target = conversation;
            if (target != null) {
              await ref.read(conversationListControllerProvider.notifier).setModel(target.id, selection);
            } else {
              await ref.read(preferencesControllerProvider.notifier).setDefaultModel(selection);
            }
          }),
          itemBuilder: (context) => [
            // Only text-capable models: realtime voice models are used by voice mode.
            for (final provider in catalog.providers.where(
              (p) => p.models.any((m) => m.capabilities.textStreaming),
            )) ...[
              PopupMenuItem<ModelSelection>(
                enabled: false,
                height: 32,
                child: Text(provider.displayName, style: Theme.of(context).textTheme.labelSmall),
              ),
              for (final model in provider.models.where((m) => m.capabilities.textStreaming))
                CheckedPopupMenuItem<ModelSelection>(
                  value: (provider: provider, model: model),
                  checked: current?.provider.id == provider.id && current?.model.id == model.id,
                  child: Text(model.displayName),
                ),
            ],
          ],
          child: _SelectorLabel(label: current?.model.displayName ?? 'Choose model', enabled: true, compact: compact),
        );
      },
    );
  }
}

class _SelectorLabel extends StatelessWidget {
  const _SelectorLabel({required this.label, required this.enabled, this.compact = false});

  final String label;
  final bool enabled;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = enabled ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant;
    if (compact) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Semantics(
          label: label,
          child: Icon(Icons.auto_awesome_outlined, size: 22, color: color),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_outlined, size: 16, color: color),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(color: color),
            ),
          ),
          if (enabled) Icon(Icons.expand_more_rounded, size: 18, color: color),
        ],
      ),
    );
  }
}
