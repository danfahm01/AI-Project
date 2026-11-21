import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/data/mappers/json_mappers.dart';
import 'package:voice_assistant/domain/entities/ai_provider.dart';
import 'package:voice_assistant/domain/entities/chat_message.dart';
import 'package:voice_assistant/domain/entities/user.dart';
import 'package:voice_assistant/domain/entities/user_preferences.dart';
import 'package:voice_assistant/providers/preferences_controller.dart';

import '../support/fakes.dart';

void main() {
  group('ProviderCatalog', () {
    test('resolves an explicit choice, else the server default', () {
      expect(sampleCatalog.resolve(providerId: 'acme', modelId: 'acme-voice')?.model.id, 'acme-voice');
      expect(sampleCatalog.resolve()?.model.id, 'acme-text');
      expect(sampleCatalog.resolve(providerId: 'gone', modelId: 'x')?.model.id, 'acme-text');
      expect(ProviderCatalog.empty.resolve(), isNull);
    });

    test('finds a realtime voice model even when the default is text-only', () {
      expect(sampleCatalog.realtimeVoice()?.model.id, 'acme-voice');
      expect(ProviderCatalog.empty.realtimeVoice(), isNull);
    });

    test('voice model: the chosen one, else the preferred provider, else the server default', () {
      final catalog = twoVoiceProviders;
      expect(catalog.realtimeModels.map((c) => c.model.id), ['acme-voice', 'zeta-live']);
      expect(catalog.realtimeVoice(providerId: 'zeta', modelId: 'zeta-live')?.model.id, 'zeta-live');
      // A text model of the provider still leads to that provider's realtime model.
      expect(catalog.realtimeVoice(providerId: 'zeta', modelId: 'zeta-text')?.model.id, 'zeta-live');
      expect(catalog.realtimeVoice(providerId: 'gone')?.model.id, 'acme-voice');

      expect(selectVoiceModel(catalog, null)?.model.id, 'acme-voice');
      expect(selectVoiceModel(catalog, const UserPreferences(defaultProvider: 'zeta'))?.model.id, 'zeta-live');
      // The open conversation's provider wins over the account's text default...
      expect(
        selectVoiceModel(
          catalog,
          const UserPreferences(defaultProvider: 'zeta'),
          fallbackProviderId: 'acme',
        )?.provider.id,
        'acme',
      );
      // ...and an explicit voice model choice wins over both.
      expect(
        selectVoiceModel(
          catalog,
          const UserPreferences(voiceProvider: 'zeta', voiceModel: 'zeta-live'),
          fallbackProviderId: 'acme',
        )?.model.id,
        'zeta-live',
      );
      expect(selectVoiceModel(null, null), isNull);
    });
  });

  test('user initials and first name', () {
    expect(testUser.initials, 'AM');
    expect(testUser.firstName, 'Ana');
    final noName = User(id: '1', email: 'zed@example.com', displayName: ' ', createdAt: DateTime.utc(2026));
    expect(noName.initials, 'Z');
  });

  group('JSON mappers', () {
    test('message with usage and unknown enum values', () {
      final message = messageFromJson({
        'id': 'm1',
        'conversation_id': 'c1',
        'seq': 2,
        'role': 'assistant',
        'content': 'Hi',
        'status': 'some_future_status',
        'provider': 'acme',
        'model': 'acme-text',
        'usage': {'input_tokens': 3, 'output_tokens': 5, 'total_tokens': 8},
        'audio_metadata': null,
        'metadata': null,
        'created_at': '2026-11-19T10:00:00+00:00',
        'updated_at': '2026-11-19T10:00:00+00:00',
        'edited_at': null,
      });
      expect(message.role, MessageRole.assistant);
      expect(message.status, MessageStatus.complete); // unknown -> safe default
      expect(message.usage?.totalTokens, 8);
      expect(message.createdAt.isUtc, isTrue);
    });

    test('preferences with defaults for missing audio settings', () {
      final prefs = preferencesFromJson({
        'theme': 'dark',
        'voice_mode': 'push_to_talk',
        'auto_speech_detection': false,
        'speaking_rate': 1,
        'audio_settings': null,
        'voice_provider': 'gemini',
        'voice_model': 'gemini-3.8-live',
      });
      expect((prefs.voiceProvider, prefs.voiceModel), ('gemini', 'gemini-3.8-live'));
      expect(prefs.theme, ThemePreference.dark);
      expect(prefs.voiceMode, VoiceMode.pushToTalk);
      expect(prefs.speakingRate, 1.0);
      expect(prefs.audioSettings.noiseSuppression, isTrue);
    });

    test('provider catalog with capability ranges', () {
      final catalog = providerCatalogFromJson({
        'default_provider': 'acme',
        'items': [
          {
            'id': 'acme',
            'display_name': 'Acme',
            'is_default': true,
            'models': [
              {
                'id': 'v',
                'display_name': 'Voice',
                'is_default': true,
                'capabilities': {
                  'realtime_voice': true,
                  'voices': [
                    {'id': 'alpha', 'display_name': 'Alpha', 'language_hints': <String>[]},
                  ],
                  'speaking_rate': {'min': 0.5, 'max': 2, 'default': 1},
                },
              },
            ],
          },
        ],
      });
      final model = catalog.providers.single.models.single;
      expect(model.capabilities.realtimeVoice, isTrue);
      expect(model.capabilities.voices.single.displayName, 'Alpha');
      expect(model.capabilities.speakingRate?.max, 2.0);
      expect(model.capabilities.imageInput, isFalse);
    });
  });
}
