import 'dart:typed_data';

import 'package:dio/dio.dart' show FormData, MultipartFile;

import '../../core/config/app_config.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/storage/token_storage.dart';
import '../../domain/entities/ai_provider.dart';
import '../../domain/entities/attachment.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/conversation.dart';
import '../../domain/entities/user.dart';
import '../../domain/entities/user_preferences.dart';
import '../../domain/repositories/repositories.dart';
import '../mappers/json_mappers.dart';

class ApiAuthRepository implements AuthRepository {
  ApiAuthRepository(this._api, this._tokens);

  final ApiClient _api;
  final TokenStorage _tokens;

  @override
  Future<User> login({required String email, required String password}) async {
    final json = await _api.postJson('/auth/login', body: {'email': email, 'password': password}, skipAuth: true);
    return _storeSession(json);
  }

  @override
  Future<User> register({required String email, required String password, required String displayName}) async {
    final json = await _api.postJson(
      '/auth/register',
      body: {'email': email, 'password': password, 'display_name': displayName},
      skipAuth: true,
    );
    return _storeSession(json);
  }

  Future<User> _storeSession(Json json) async {
    await _tokens.write(AuthTokens.fromJson(json['tokens'] as Json));
    return userFromJson(json['user'] as Json);
  }

  @override
  Future<User?> currentUser() async {
    if (await _tokens.read() == null) return null;
    try {
      return userFromJson(await _api.getJson('/users/me'));
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await _tokens.clear();
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<User> updateProfile({required String displayName}) async =>
      userFromJson(await _api.patchJson('/users/me', body: {'display_name': displayName}));

  @override
  Future<void> logout() async {
    final tokens = await _tokens.read();
    await _tokens.clear();
    if (tokens == null) return;
    try {
      await _api.postNoContent('/auth/logout', body: {'refresh_token': tokens.refreshToken}, skipAuth: true);
    } on ApiException {
      // Best effort: the local session is already gone; the refresh token expires on its own.
    }
  }
}

class ApiConversationRepository implements ConversationRepository {
  ApiConversationRepository(this._api);

  final ApiClient _api;

  @override
  Future<ConversationPage> list({String? query, String? cursor, int limit = 30}) async {
    final json = await _api.getJson(
      '/conversations',
      query: {'limit': limit, if (query != null && query.isNotEmpty) 'q': query, 'cursor': ?cursor},
    );
    return conversationPageFromJson(json);
  }

  @override
  Future<Conversation> get(String id) async => conversationFromJson(await _api.getJson('/conversations/$id'));

  @override
  Future<Conversation> create({String? title, String? provider, String? model}) async {
    final json = await _api.postJson('/conversations', body: {'title': ?title, 'provider': ?provider, 'model': ?model});
    return conversationFromJson(json);
  }

  @override
  Future<Conversation> rename(String id, String title) async =>
      conversationFromJson(await _api.patchJson('/conversations/$id', body: {'title': title}));

  @override
  Future<Conversation> setModel(String id, {required String provider, required String model}) async =>
      conversationFromJson(await _api.patchJson('/conversations/$id', body: {'provider': provider, 'model': model}));

  @override
  Future<void> delete(String id) => _api.delete('/conversations/$id');

  @override
  Future<List<ChatMessage>> messages(String conversationId) async {
    final json = await _api.getJson('/conversations/$conversationId/messages');
    return [for (final item in json['items'] as List) messageFromJson(item as Json)];
  }

  @override
  Future<ChatMessage> sendUserMessage(String conversationId, String content) async =>
      messageFromJson(await _api.postJson('/conversations/$conversationId/messages', body: {'content': content}));

  @override
  Future<MessageEditResult> editMessage(String messageId, String content) async =>
      messageEditResultFromJson(await _api.patchJson('/messages/$messageId', body: {'content': content}));

  @override
  Future<void> deleteMessage(String messageId) => _api.delete('/messages/$messageId');
}

class ApiPreferencesRepository implements PreferencesRepository {
  ApiPreferencesRepository(this._api);

  final ApiClient _api;

  @override
  Future<UserPreferences> get() async => preferencesFromJson(await _api.getJson('/users/me/preferences'));

  @override
  Future<UserPreferences> update(Map<String, Object?> fields) async =>
      preferencesFromJson(await _api.patchJson('/users/me/preferences', body: fields));
}

class ApiProviderCatalogRepository implements ProviderCatalogRepository {
  ApiProviderCatalogRepository(this._api);

  final ApiClient _api;

  @override
  Future<ProviderCatalog> fetch() async => providerCatalogFromJson(await _api.getJson('/providers'));
}

class ApiAttachmentRepository implements AttachmentRepository {
  ApiAttachmentRepository(this._api, this._config);

  final ApiClient _api;
  final AppConfig _config;

  @override
  Future<Attachment> upload(PickedFile file, {void Function(double progress)? onProgress}) async {
    final json = await _api.postMultipart(
      '/attachments',
      form: () => FormData.fromMap({'file': MultipartFile.fromBytes(file.bytes, filename: file.name)}),
      onProgress: onProgress,
    );
    return attachmentFromJson(json);
  }

  @override
  Future<void> delete(String attachmentId) => _api.delete('/attachments/$attachmentId');

  @override
  Future<Uint8List> content(String attachmentId) async =>
      Uint8List.fromList(await _api.getBytes('/attachments/$attachmentId/content'));

  @override
  Future<Uri> link(String attachmentId) async {
    final json = await _api.postJson('/attachments/$attachmentId/link');
    // The path is relative to the API base URL.
    return Uri.parse('${_config.apiV1Url}${json['path'] as String}');
  }
}

class ApiVoiceSessionRepository implements VoiceSessionRepository {
  ApiVoiceSessionRepository(this._api);

  final ApiClient _api;

  @override
  Future<VoiceSessionGrant> start({String? conversationId, String? providerId, String? modelId}) async {
    final json = await _api.postJson(
      '/voice/sessions',
      body: {'conversation_id': ?conversationId, 'provider': ?providerId, 'model': ?modelId},
    );
    return VoiceSessionGrant(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      provider: json['provider'] as String,
      model: json['model'] as String,
      transport: json['transport'] as String,
      endpoint: json['endpoint'] as String,
      clientSecret: json['client_secret'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String).toUtc(),
      pushToTalk: json['push_to_talk'] as bool? ?? false,
      voice: json['voice'] as String?,
      dataChannel: json['data_channel'] as String?,
      inputAudioFormat: json['input_audio_format'] as String?,
      outputSampleRate: (json['output_sample_rate'] as num?)?.toInt(),
      sessionExpiresAt: switch (json['session_expires_at']) {
        final String value => DateTime.parse(value).toUtc(),
        _ => null,
      },
    );
  }

  @override
  Future<void> saveTranscript(String sessionId, {required String role, required String content, String? itemId}) => _api
      .postJson('/voice/sessions/$sessionId/transcripts', body: {'role': role, 'content': content, 'item_id': ?itemId});

  @override
  Future<void> end(String sessionId) => _api.postNoContent('/voice/sessions/$sessionId/end');
}

class ApiServerStatusRepository implements ServerStatusRepository {
  ApiServerStatusRepository(this._api, this._config);

  final ApiClient _api;
  final AppConfig _config;

  @override
  Future<ServerStatus> check() async {
    final json = await _api.getAbsolute(_config.readinessUrl);
    final checks = (json['checks'] as Json?) ?? const {};
    return ServerStatus(
      healthy: json['status'] == 'ok',
      version: json['version'] as String?,
      checks: {for (final entry in checks.entries) entry.key: entry.value == true},
    );
  }
}
