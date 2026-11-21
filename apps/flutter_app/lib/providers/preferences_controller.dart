import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;

import '../domain/entities/ai_provider.dart';
import '../domain/entities/user_preferences.dart';
import '../domain/repositories/repositories.dart';
import 'auth_controller.dart';
import 'dependencies.dart';

/// Account preferences stored on the server. `null` while signed out.
class PreferencesController extends AsyncNotifier<UserPreferences?> {
  @override
  Future<UserPreferences?> build() async {
    final userId = ref.watch(currentUserIdProvider);
    if (userId == null) return null;
    return ref.read(preferencesRepositoryProvider).get();
  }

  /// Partial update with API field names; throws `ApiException` on failure.
  Future<void> updateFields(Map<String, Object?> fields) async {
    final updated = await ref.read(preferencesRepositoryProvider).update(fields);
    state = AsyncData(updated);
  }

  Future<void> setVoiceMode(VoiceMode mode) => updateFields({'voice_mode': mode.wireName});

  Future<void> setAutoSpeechDetection(bool enabled) => updateFields({'auto_speech_detection': enabled});

  Future<void> setAudioSettings(AudioSettings settings) => updateFields({'audio_settings': settings.toJson()});

  Future<void> setVoice(String? voiceId) => updateFields({'voice_name': voiceId});

  Future<void> setSpeakingRate(double? rate) => updateFields({'speaking_rate': rate});

  Future<void> setLanguage(String? language) => updateFields({'language': language});

  Future<void> setDefaultModel(ModelSelection selection) =>
      updateFields({'default_provider': selection.provider.id, 'default_model': selection.model.id});

  /// Realtime model for voice mode. Voice IDs differ per provider, so a voice the
  /// new model does not offer is reset to that model's default.
  Future<void> setVoiceModel(ModelSelection selection) {
    final voice = state.value?.voiceName;
    final keepsVoice = selection.model.capabilities.voices.any((v) => v.id == voice);
    return updateFields({
      'voice_provider': selection.provider.id,
      'voice_model': selection.model.id,
      if (!keepsVoice) 'voice_name': null,
    });
  }
}

/// The realtime model voice mode will use: the user's choice, else a realtime
/// model of [fallbackProviderId] (e.g. the open conversation's provider), else
/// the server default. `null` while loading or when no realtime model exists.
ModelSelection? selectVoiceModel(ProviderCatalog? catalog, UserPreferences? preferences, {String? fallbackProviderId}) {
  if (catalog == null) return null;
  final choice = catalog.realtimeModels
      .where((c) => c.provider.id == preferences?.voiceProvider && c.model.id == preferences?.voiceModel)
      .firstOrNull;
  return choice ??
      catalog.realtimeVoice(
        providerId: preferences?.voiceProvider ?? fallbackProviderId ?? preferences?.defaultProvider,
      );
}

final preferencesControllerProvider = AsyncNotifierProvider<PreferencesController, UserPreferences?>(
  PreferencesController.new,
);

/// Theme is kept on the device (so the sign-in screen is themed too) and
/// synced to the account so it follows the user to other devices.
class ThemeController extends Notifier<ThemeMode> {
  static const _storageKey = 'appearance.theme';

  @override
  ThemeMode build() {
    ref.listen(preferencesControllerProvider, (previous, next) {
      final fromServer = next.value?.theme;
      if (fromServer != null && fromServer != previous?.value?.theme) {
        _apply(fromServer);
      }
    });
    final stored = ref.read(sharedPreferencesProvider).getString(_storageKey);
    return _toThemeMode(ThemePreference.values.where((t) => t.name == stored).firstOrNull ?? ThemePreference.system);
  }

  ThemePreference get preference => switch (state) {
    ThemeMode.light => ThemePreference.light,
    ThemeMode.dark => ThemePreference.dark,
    ThemeMode.system => ThemePreference.system,
  };

  Future<void> setPreference(ThemePreference preference) async {
    _apply(preference);
    if (ref.read(currentUserIdProvider) != null) {
      await ref.read(preferencesControllerProvider.notifier).updateFields({'theme': preference.name});
    }
  }

  void _apply(ThemePreference preference) {
    state = _toThemeMode(preference);
    ref.read(sharedPreferencesProvider).setString(_storageKey, preference.name);
  }

  static ThemeMode _toThemeMode(ThemePreference preference) => switch (preference) {
    ThemePreference.light => ThemeMode.light,
    ThemePreference.dark => ThemeMode.dark,
    ThemePreference.system => ThemeMode.system,
  };
}

final themeControllerProvider = NotifierProvider<ThemeController, ThemeMode>(ThemeController.new);

final providerCatalogProvider = FutureProvider<ProviderCatalog>((ref) async {
  if (ref.watch(currentUserIdProvider) == null) return ProviderCatalog.empty;
  return ref.read(providerCatalogRepositoryProvider).fetch();
});

final serverStatusProvider = FutureProvider.autoDispose<ServerStatus>(
  (ref) => ref.read(serverStatusRepositoryProvider).check(),
);
