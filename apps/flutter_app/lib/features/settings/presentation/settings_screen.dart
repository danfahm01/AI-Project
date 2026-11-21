import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/widgets/common_widgets.dart';
import '../../../domain/entities/ai_provider.dart';
import '../../../domain/entities/user_preferences.dart';
import '../../../providers/auth_controller.dart';
import '../../../providers/dependencies.dart';
import '../../../providers/preferences_controller.dart';
import '../../shell/chat_shell.dart';
import '../../voice/presentation/widgets/voice_settings_section.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeController = ref.read(themeControllerProvider.notifier);
    ref.watch(themeControllerProvider);
    final preferences = ref.watch(preferencesControllerProvider);
    final catalog = ref.watch(providerCatalogProvider).value ?? ProviderCatalog.empty;
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: shellNavigationButton(context),
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Section(
                    title: 'Appearance',
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: SegmentedButton<ThemePreference>(
                          segments: const [
                            ButtonSegment(
                              value: ThemePreference.system,
                              icon: Icon(Icons.brightness_auto_outlined),
                              label: Text('System'),
                            ),
                            ButtonSegment(
                              value: ThemePreference.light,
                              icon: Icon(Icons.light_mode_outlined),
                              label: Text('Light'),
                            ),
                            ButtonSegment(
                              value: ThemePreference.dark,
                              icon: Icon(Icons.dark_mode_outlined),
                              label: Text('Dark'),
                            ),
                          ],
                          selected: {themeController.preference},
                          onSelectionChanged: (selection) =>
                              runGuarded(context, () => themeController.setPreference(selection.first)),
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Voice',
                    children: [
                      preferences.when(
                        data: (prefs) => prefs == null
                            ? const SizedBox.shrink()
                            : VoiceSettingsSection(preferences: prefs, catalog: catalog),
                        loading: () => const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                        error: (error, _) => ErrorView(
                          error: error,
                          compact: true,
                          onRetry: () => ref.invalidate(preferencesControllerProvider),
                        ),
                      ),
                    ],
                  ),
                  if (user != null)
                    _Section(
                      title: 'Account',
                      children: [
                        ListTile(
                          leading: CircleAvatar(child: Text(user.initials)),
                          title: Text(user.displayName),
                          subtitle: Text(user.email),
                          trailing: IconButton(
                            tooltip: 'Edit name',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () async {
                              final name = await textInputDialog(
                                context,
                                title: 'Display name',
                                initialValue: user.displayName,
                                confirmLabel: 'Save',
                                maxLength: 100,
                              );
                              if (name == null || !context.mounted) return;
                              await runGuarded(
                                context,
                                () => ref.read(authControllerProvider.notifier).updateDisplayName(name),
                              );
                            },
                          ),
                        ),
                        ListTile(
                          leading: const Icon(Icons.logout_rounded),
                          title: const Text('Log out'),
                          onTap: () => ref.read(authControllerProvider.notifier).logout(),
                        ),
                      ],
                    ),
                  const _Section(title: 'Server', children: [_ServerStatusTile()]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ],
      ),
    );
  }
}

class _ServerStatusTile extends ConsumerWidget {
  const _ServerStatusTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final config = ref.watch(appConfigProvider);
    final status = ref.watch(serverStatusProvider);

    final (icon, color, text) = status.when(
      data: (s) => s.healthy
          ? (Icons.check_circle_rounded, Colors.green.shade600, 'Connected · API ${s.version ?? ''}'.trim())
          : (
              Icons.warning_amber_rounded,
              theme.colorScheme.tertiary,
              'Degraded: ${s.checks.entries.where((e) => !e.value).map((e) => e.key).join(', ')} unavailable',
            ),
      loading: () => (Icons.sync_rounded, theme.colorScheme.onSurfaceVariant, 'Checking…'),
      error: (error, _) => (Icons.error_outline_rounded, theme.colorScheme.error, describeError(error)),
    );

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(config.apiBaseUrl),
      subtitle: Text(text),
      trailing: IconButton(
        tooltip: 'Check again',
        icon: const Icon(Icons.refresh_rounded),
        onPressed: () => ref.invalidate(serverStatusProvider),
      ),
    );
  }
}
