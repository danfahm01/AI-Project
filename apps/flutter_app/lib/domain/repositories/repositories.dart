import 'dart:typed_data';

import '../entities/ai_provider.dart';
import '../entities/attachment.dart';
import '../entities/chat_message.dart';
import '../entities/conversation.dart';
import '../entities/user.dart';
import '../entities/user_preferences.dart';

/// Repository contracts. Implementations live in `lib/data/`; tests use fakes.
/// All methods throw `ApiException` on failure.

abstract interface class AuthRepository {
  Future<User> login({required String email, required String password});

  Future<User> register({required String email, required String password, required String displayName});

  /// The signed-in user, or `null` when no session is stored or it is no longer valid.
  Future<User?> currentUser();

  Future<User> updateProfile({required String displayName});

  /// Revokes the session on the server (best effort) and forgets local tokens.
  Future<void> logout();
}

abstract interface class ConversationRepository {
  Future<ConversationPage> list({String? query, String? cursor, int limit = 30});

  Future<Conversation> get(String id);

  Future<Conversation> create({String? title, String? provider, String? model});

  Future<Conversation> rename(String id, String title);

  Future<Conversation> setModel(String id, {required String provider, required String model});

  Future<void> delete(String id);

  Future<List<ChatMessage>> messages(String conversationId);

  Future<ChatMessage> sendUserMessage(String conversationId, String content);

  Future<MessageEditResult> editMessage(String messageId, String content);

  Future<void> deleteMessage(String messageId);
}

abstract interface class PreferencesRepository {
  Future<UserPreferences> get();

  /// Partial update using the API's field names. A `null` value clears the field.
  Future<UserPreferences> update(Map<String, Object?> fields);
}

abstract interface class ProviderCatalogRepository {
  Future<ProviderCatalog> fetch();
}

/// Images and PDFs sent with messages. Uploads are pending until a message
/// with their ids is sent.
abstract interface class AttachmentRepository {
  /// Uploads [file]; [onProgress] receives the fraction sent (0..1).
  Future<Attachment> upload(PickedFile file, {void Function(double progress)? onProgress});

  /// Removes an upload that has not been sent.
  Future<void> delete(String attachmentId);

  /// The file's bytes (for thumbnails and previews).
  Future<Uint8List> content(String attachmentId);

  /// A short-lived link that opens the file without signing in (e.g. a PDF in
  /// the system viewer or a browser tab).
  Future<Uri> link(String attachmentId);
}

/// A realtime voice session minted by the backend. [clientSecret] is a
/// short-lived credential for this session only.
class VoiceSessionGrant {
  const VoiceSessionGrant({
    required this.id,
    required this.conversationId,
    required this.provider,
    required this.model,
    required this.transport,
    required this.endpoint,
    required this.clientSecret,
    required this.expiresAt,
    required this.pushToTalk,
    this.voice,
    this.dataChannel,
    this.inputAudioFormat,
    this.outputSampleRate,
    this.sessionExpiresAt,
  });

  final String id;
  final String conversationId;
  final String provider;
  final String model;

  /// `webrtc` (OpenAI) or `websocket` (Gemini Live).
  final String transport;
  final String endpoint;
  final String clientSecret;

  /// Connect before this time.
  final DateTime expiresAt;
  final bool pushToTalk;
  final String? voice;

  /// WebRTC: data channel for provider events.
  final String? dataChannel;

  /// WebSocket: microphone format to send (e.g. `audio/pcm;rate=16000`),
  /// playback sample rate, and when the session (including reconnects) ends.
  final String? inputAudioFormat;
  final int? outputSampleRate;
  final DateTime? sessionExpiresAt;
}

abstract interface class VoiceSessionRepository {
  Future<VoiceSessionGrant> start({String? conversationId, String? providerId, String? modelId});

  /// Stores a finished turn; [itemId] makes retries idempotent.
  Future<void> saveTranscript(String sessionId, {required String role, required String content, String? itemId});

  Future<void> end(String sessionId);
}

abstract interface class ServerStatusRepository {
  /// Returns the readiness report from `/health/ready`.
  Future<ServerStatus> check();
}

class ServerStatus {
  const ServerStatus({required this.healthy, required this.version, required this.checks});

  final bool healthy;
  final String? version;
  final Map<String, bool> checks;
}
