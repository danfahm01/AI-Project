import '../../domain/entities/ai_provider.dart';
import '../../domain/entities/attachment.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/user.dart';
import '../../domain/entities/user_preferences.dart';

typedef Json = Map<String, dynamic>;

DateTime _date(Object? value) => DateTime.parse(value as String).toUtc();
DateTime? _dateOrNull(Object? value) => value == null ? null : _date(value);
double? _doubleOrNull(Object? value) => (value as num?)?.toDouble();

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) =>
    values.where((v) => v.name == name).firstOrNull ?? fallback;

User userFromJson(Json json) => User(
  id: json['id'] as String,
  email: json['email'] as String,
  displayName: json['display_name'] as String,
  createdAt: _date(json['created_at']),
);

Conversation conversationFromJson(Json json) => Conversation(
  id: json['id'] as String,
  title: json['title'] as String,
  provider: json['provider'] as String?,
  model: json['model'] as String?,
  createdAt: _date(json['created_at']),
  updatedAt: _date(json['updated_at']),
  lastMessageAt: _dateOrNull(json['last_message_at']),
);

ConversationPage conversationPageFromJson(Json json) => ConversationPage(
  items: [for (final item in json['items'] as List) conversationFromJson(item as Json)],
  nextCursor: json['next_cursor'] as String?,
);

ChatMessage messageFromJson(Json json) {
  final usage = json['usage'] as Json?;
  final error = (json['metadata'] as Json?)?['error'] as Json?;
  return ChatMessage(
    id: json['id'] as String,
    conversationId: json['conversation_id'] as String,
    seq: json['seq'] as int,
    role: _enumByName(MessageRole.values, json['role'], MessageRole.assistant),
    content: json['content'] as String,
    status: _enumByName(MessageStatus.values, json['status'], MessageStatus.complete),
    provider: json['provider'] as String?,
    model: json['model'] as String?,
    usage: usage == null
        ? null
        : TokenUsage(
            inputTokens: usage['input_tokens'] as int?,
            outputTokens: usage['output_tokens'] as int?,
            totalTokens: usage['total_tokens'] as int?,
          ),
    createdAt: _date(json['created_at']),
    editedAt: _dateOrNull(json['edited_at']),
    errorMessage: error?['message'] as String?,
    attachments: [for (final item in (json['attachments'] as List? ?? const [])) attachmentFromJson(item as Json)],
  );
}

Attachment attachmentFromJson(Json json) => Attachment(
  id: json['id'] as String,
  kind: json['kind'] == 'pdf' ? AttachmentKind.pdf : AttachmentKind.image,
  filename: json['filename'] as String,
  contentType: json['content_type'] as String,
  sizeBytes: (json['size_bytes'] as num).toInt(),
  messageId: json['message_id'] as String?,
);

MessageEditResult messageEditResultFromJson(Json json) => MessageEditResult(
  message: messageFromJson(json['message'] as Json),
  removedMessageIds: [for (final id in json['removed_message_ids'] as List) id as String],
);

UserPreferences preferencesFromJson(Json json) {
  final audio = (json['audio_settings'] as Json?) ?? const {};
  return UserPreferences(
    theme: _enumByName(ThemePreference.values, json['theme'], ThemePreference.system),
    language: json['language'] as String?,
    defaultProvider: json['default_provider'] as String?,
    defaultModel: json['default_model'] as String?,
    voiceProvider: json['voice_provider'] as String?,
    voiceModel: json['voice_model'] as String?,
    voiceName: json['voice_name'] as String?,
    speakingRate: _doubleOrNull(json['speaking_rate']),
    autoSpeechDetection: json['auto_speech_detection'] as bool? ?? true,
    voiceMode: VoiceMode.fromWire(json['voice_mode'] as String? ?? VoiceMode.handsFree.wireName),
    audioSettings: AudioSettings(
      echoCancellation: audio['echo_cancellation'] as bool? ?? true,
      noiseSuppression: audio['noise_suppression'] as bool? ?? true,
      autoGainControl: audio['auto_gain_control'] as bool? ?? true,
    ),
  );
}

ModelCapabilities _capabilitiesFromJson(Json json) {
  final rate = json['speaking_rate'] as Json?;
  return ModelCapabilities(
    textStreaming: json['text_streaming'] as bool? ?? false,
    realtimeVoice: json['realtime_voice'] as bool? ?? false,
    serverVad: json['server_vad'] as bool? ?? false,
    interruption: json['interruption'] as bool? ?? false,
    imageInput: json['image_input'] as bool? ?? false,
    pdfInput: json['pdf_input'] as bool? ?? false,
    voices: [
      for (final voice in (json['voices'] as List? ?? const []))
        VoiceOption(id: (voice as Json)['id'] as String, displayName: voice['display_name'] as String),
    ],
    languages: [for (final language in (json['languages'] as List? ?? const [])) language as String],
    speakingRate: rate == null
        ? null
        : NumericRange(
            min: (rate['min'] as num).toDouble(),
            max: (rate['max'] as num).toDouble(),
            defaultValue: (rate['default'] as num).toDouble(),
          ),
  );
}

ProviderCatalog providerCatalogFromJson(Json json) => ProviderCatalog(
  defaultProviderId: json['default_provider'] as String?,
  providers: [
    for (final provider in json['items'] as List)
      AIProviderInfo(
        id: (provider as Json)['id'] as String,
        displayName: provider['display_name'] as String,
        isDefault: provider['is_default'] as bool? ?? false,
        models: [
          for (final model in provider['models'] as List)
            AIModelInfo(
              id: (model as Json)['id'] as String,
              displayName: model['display_name'] as String,
              isDefault: model['is_default'] as bool? ?? false,
              capabilities: _capabilitiesFromJson(model['capabilities'] as Json),
            ),
        ],
      ),
  ],
);
