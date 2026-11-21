import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:voice_assistant/domain/entities/user_preferences.dart';
import 'package:voice_assistant/features/voice/presentation/widgets/voice_settings_section.dart';
import 'package:voice_assistant/providers/preferences_controller.dart';

import '../support/fakes.dart';

/// Capability handling: the voice options follow the selected realtime model.
void main() {
  testWidgets('the voice model picker lists every realtime model and the options follow the choice', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final preferences = FakePreferencesRepository()..preferences = const UserPreferences(voiceName: 'alpha');
    final overrides = await fakeOverrides(preferences: preferences, catalog: FakeCatalogRepository(twoVoiceProviders));
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        retry: (_, _) => null,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final prefs = ref.watch(preferencesControllerProvider).value;
                if (prefs == null) return const SizedBox.shrink();
                return SingleChildScrollView(
                  child: VoiceSettingsSection(preferences: prefs, catalog: twoVoiceProviders),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Server default (Acme): its voices, languages and speed range are offered.
    expect(find.text('Acme Voice · Acme AI'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.textContaining('Speaking speed'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice-model-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zeta Live · Zeta AI').last);
    await tester.pumpAndSettle();

    expect(preferences.updates.last, {'voice_provider': 'zeta', 'voice_model': 'zeta-live', 'voice_name': null});
    expect(find.text('Zeta Live · Zeta AI'), findsOneWidget);
    // Zeta Live has no speed or language setting, and its own voices.
    expect(find.textContaining('Speaking speed'), findsNothing);
    expect(find.text('Language'), findsNothing);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Default'), findsOneWidget); // the voice was reset to the model default

    await tester.tap(find.text('Default'));
    await tester.pumpAndSettle();
    expect(find.text('Kore (Firm)'), findsWidgets);
  });
}
