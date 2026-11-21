import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_assistant/core/network/api_exception.dart';
import 'package:voice_assistant/data/attachments/attachment_picker.dart';
import 'package:voice_assistant/domain/chat/chat_stream.dart';
import 'package:voice_assistant/domain/entities/ai_provider.dart';
import 'package:voice_assistant/domain/entities/attachment.dart';
import 'package:voice_assistant/domain/entities/chat_message.dart';
import 'package:voice_assistant/domain/entities/conversation.dart';
import 'package:voice_assistant/domain/entities/user.dart';
import 'package:voice_assistant/domain/entities/user_preferences.dart';
import 'package:voice_assistant/domain/repositories/repositories.dart';
import 'package:voice_assistant/domain/voice/voice_session_state.dart';
import 'package:voice_assistant/domain/voice/voice_transport.dart';
import 'package:voice_assistant/providers/dependencies.dart';

final testUser = User(
  id: 'user-1',
  email: 'ana@example.com',
  displayName: 'Ana Maria',
  createdAt: DateTime.utc(2026, 1, 1),
);

const networkError = ApiException(code: ApiException.networkErrorCode, message: "Can't reach the server.");

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this.signedInUser, this.currentUserError});

  User? signedInUser;
  ApiException? currentUserError;
  ApiException? loginError;
  int logoutCalls = 0;

  @override
  Future<User?> currentUser() async {
    if (currentUserError != null) throw currentUserError!;
    return signedInUser;
  }

  @override
  Future<User> login({required String email, required String password}) async {
    if (loginError != null) throw loginError!;
    return signedInUser = testUser;
  }

  @override
  Future<User> register({required String email, required String password, required String displayName}) async =>
      signedInUser = User(id: 'user-2', email: email, displayName: displayName, createdAt: DateTime.utc(2026));

  @override
  Future<User> updateProfile({required String displayName}) async =>
      signedInUser = signedInUser!.copyWith(displayName: displayName);

  @override
  Future<void> logout() async {
    logoutCalls++;
    signedInUser = null;
  }
}

/// In-memory backend with the same semantics as the API (ordering, paging,
/// search, edit truncation).
class FakeConversationRepository implements ConversationRepository {
  final _conversations = <Conversation>[];
  final _messages = <String, List<ChatMessage>>{};
  var _clock = DateTime.utc(2026, 11, 19, 9);
  var _ids = 0;

  ApiException? failNextSend;
  int listCalls = 0;

  DateTime _tick() => _clock = _clock.add(const Duration(minutes: 1));

  Conversation seed(String title, {DateTime? updatedAt}) {
    final now = updatedAt ?? _tick();
    final conversation = Conversation(id: 'c${++_ids}', title: title, createdAt: now, updatedAt: now);
    _conversations.add(conversation);
    _messages[conversation.id] = [];
    return conversation;
  }

  ChatMessage seedMessage(
    String conversationId,
    MessageRole role,
    String content, {
    String? id,
    MessageStatus status = MessageStatus.complete,
    List<Attachment> attachments = const [],
  }) {
    final list = _messages[conversationId]!;
    final message = ChatMessage(
      id: id ?? 'm${++_ids}',
      conversationId: conversationId,
      seq: list.isEmpty ? 1 : list.last.seq + 1,
      role: role,
      content: content,
      status: status,
      createdAt: _tick(),
      attachments: attachments,
    );
    list.add(message);
    return message;
  }

  void replaceMessage(ChatMessage message) {
    final list = _messages[message.conversationId]!;
    list[list.indexWhere((m) => m.id == message.id)] = message;
  }

  void removeMessage(String conversationId, String messageId) =>
      _messages[conversationId]!.removeWhere((m) => m.id == messageId);

  Conversation conversation(String id) => _find(id);

  List<ChatMessage> messagesSync(String conversationId) => [..._messages[conversationId]!];

  List<Conversation> get _sorted => [..._conversations]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<ConversationPage> list({String? query, String? cursor, int limit = 30}) async {
    listCalls++;
    final q = (query ?? '').toLowerCase();
    final matches = _sorted
        .where(
          (c) =>
              q.isEmpty ||
              c.title.toLowerCase().contains(q) ||
              _messages[c.id]!.any((m) => m.content.toLowerCase().contains(q)),
        )
        .toList();
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + limit).clamp(0, matches.length);
    return ConversationPage(items: matches.sublist(start, end), nextCursor: end < matches.length ? '$end' : null);
  }

  Conversation _find(String id) => _conversations.firstWhere(
    (c) => c.id == id,
    orElse: () => throw const ApiException(code: 'conversation_not_found', message: 'Not found', statusCode: 404),
  );

  void _replace(Conversation updated) {
    _conversations[_conversations.indexWhere((c) => c.id == updated.id)] = updated;
  }

  @override
  Future<Conversation> get(String id) async => _find(id);

  @override
  Future<Conversation> create({String? title, String? provider, String? model}) async {
    final now = _tick();
    final conversation = Conversation(
      id: 'c${++_ids}',
      title: title ?? 'New conversation',
      provider: provider,
      model: model,
      createdAt: now,
      updatedAt: now,
    );
    _conversations.add(conversation);
    _messages[conversation.id] = [];
    return conversation;
  }

  @override
  Future<Conversation> rename(String id, String title) async {
    final updated = _find(id).copyWith(title: title, updatedAt: _tick());
    _replace(updated);
    return updated;
  }

  @override
  Future<Conversation> setModel(String id, {required String provider, required String model}) async {
    final updated = _find(id).copyWith(provider: provider, model: model, updatedAt: _tick());
    _replace(updated);
    return updated;
  }

  @override
  Future<void> delete(String id) async {
    _find(id);
    _conversations.removeWhere((c) => c.id == id);
    _messages.remove(id);
  }

  @override
  Future<List<ChatMessage>> messages(String conversationId) async {
    _find(conversationId);
    return [..._messages[conversationId]!];
  }

  @override
  Future<ChatMessage> sendUserMessage(String conversationId, String content) async {
    final failure = failNextSend;
    if (failure != null) {
      failNextSend = null;
      throw failure;
    }
    final conversation = _find(conversationId);
    final message = seedMessage(conversationId, MessageRole.user, content);
    _replace(
      conversation.copyWith(
        title: message.seq == 1 && conversation.title == 'New conversation' ? content : null,
        updatedAt: _tick(),
      ),
    );
    return message;
  }

  @override
  Future<MessageEditResult> editMessage(String messageId, String content) async {
    for (final list in _messages.values) {
      final index = list.indexWhere((m) => m.id == messageId);
      if (index < 0) continue;
      final removed = list.sublist(index + 1).map((m) => m.id).toList();
      final edited = list[index].copyWith(content: content, editedAt: _tick());
      list
        ..removeRange(index, list.length)
        ..add(edited);
      return MessageEditResult(message: edited, removedMessageIds: removed);
    }
    throw const ApiException(code: 'message_not_found', message: 'Not found', statusCode: 404);
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    for (final list in _messages.values) {
      list.removeWhere((m) => m.id == messageId);
    }
  }
}

class FakePreferencesRepository implements PreferencesRepository {
  UserPreferences preferences = const UserPreferences();
  final updates = <Map<String, Object?>>[];

  @override
  Future<UserPreferences> get() async => preferences;

  @override
  Future<UserPreferences> update(Map<String, Object?> fields) async {
    updates.add(fields);
    final audio = fields['audio_settings'] as Map<String, Object?>?;
    preferences = UserPreferences(
      theme: fields.containsKey('theme')
          ? ThemePreference.values.byName(fields['theme']! as String)
          : preferences.theme,
      voiceMode: fields.containsKey('voice_mode')
          ? VoiceMode.fromWire(fields['voice_mode']! as String)
          : preferences.voiceMode,
      autoSpeechDetection: fields['auto_speech_detection'] as bool? ?? preferences.autoSpeechDetection,
      defaultProvider: fields.containsKey('default_provider')
          ? fields['default_provider'] as String?
          : preferences.defaultProvider,
      defaultModel: fields.containsKey('default_model') ? fields['default_model'] as String? : preferences.defaultModel,
      voiceProvider: fields.containsKey('voice_provider')
          ? fields['voice_provider'] as String?
          : preferences.voiceProvider,
      voiceModel: fields.containsKey('voice_model') ? fields['voice_model'] as String? : preferences.voiceModel,
      voiceName: fields.containsKey('voice_name') ? fields['voice_name'] as String? : preferences.voiceName,
      speakingRate: fields.containsKey('speaking_rate') ? fields['speaking_rate'] as double? : preferences.speakingRate,
      language: fields.containsKey('language') ? fields['language'] as String? : preferences.language,
      audioSettings: audio == null
          ? preferences.audioSettings
          : AudioSettings(
              echoCancellation: audio['echo_cancellation']! as bool,
              noiseSuppression: audio['noise_suppression']! as bool,
              autoGainControl: audio['auto_gain_control']! as bool,
            ),
    );
    return preferences;
  }
}

class FakeCatalogRepository implements ProviderCatalogRepository {
  FakeCatalogRepository([this.catalog = ProviderCatalog.empty]);

  ProviderCatalog catalog;

  @override
  Future<ProviderCatalog> fetch() async => catalog;
}

const voiceCapable = ModelCapabilities(
  textStreaming: true,
  realtimeVoice: true,
  serverVad: true,
  interruption: true,
  voices: [VoiceOption(id: 'alpha', displayName: 'Alpha')],
  languages: ['en', 'id'],
  speakingRate: NumericRange(min: 0.5, max: 2, defaultValue: 1),
);

final sampleCatalog = ProviderCatalog(
  defaultProviderId: 'acme',
  providers: [
    AIProviderInfo(
      id: 'acme',
      displayName: 'Acme AI',
      isDefault: true,
      models: [
        const AIModelInfo(
          id: 'acme-text',
          displayName: 'Acme Text',
          isDefault: true,
          capabilities: ModelCapabilities(textStreaming: true),
        ),
        const AIModelInfo(id: 'acme-voice', displayName: 'Acme Voice', capabilities: voiceCapable),
      ],
    ),
  ],
);

/// Two providers with realtime models (e.g. OpenAI and Gemini), with different voices.
final twoVoiceProviders = ProviderCatalog(
  defaultProviderId: 'acme',
  providers: [
    sampleCatalog.providers.single,
    const AIProviderInfo(
      id: 'zeta',
      displayName: 'Zeta AI',
      models: [
        AIModelInfo(
          id: 'zeta-text',
          displayName: 'Zeta Text',
          isDefault: true,
          capabilities: ModelCapabilities(textStreaming: true),
        ),
        AIModelInfo(
          id: 'zeta-live',
          displayName: 'Zeta Live',
          capabilities: ModelCapabilities(
            realtimeVoice: true,
            serverVad: true,
            interruption: true,
            voices: [VoiceOption(id: 'Kore', displayName: 'Kore (Firm)')],
          ),
        ),
      ],
    ),
  ],
);

class FakeVoiceTransport implements VoiceTransport {
  FakeVoiceTransport({this.pushToTalk = false, this.conversationId = 'voice-conversation'});

  final _events = StreamController<VoiceEvent>.broadcast();
  bool connected = false;
  bool closed = false;
  bool? muted;
  int interrupts = 0;
  int talkStarts = 0;
  int talkStops = 0;
  Object? connectError;

  /// The options the app asked the transport factory for.
  VoiceSessionOptions? options;

  @override
  final bool pushToTalk;

  @override
  final String? conversationId;

  void emit(VoiceEvent event) => _events.add(event);

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (connectError != null) throw connectError!;
    connected = true;
    emit(VoiceSessionConfigured(pushToTalk: pushToTalk, conversationId: conversationId));
    emit(const VoiceConnected());
  }

  @override
  Future<void> startTalking() async {
    talkStarts++;
    emit(const VoiceUserSpeechStarted());
  }

  @override
  Future<void> stopTalking() async {
    talkStops++;
    emit(const VoiceUserSpeechStopped());
  }

  @override
  Future<void> setMuted(bool value) async => muted = value;

  @override
  Future<void> interrupt() async => interrupts++;

  @override
  Future<void> close() async {
    closed = true;
    await _events.close();
  }
}

/// In-memory [ChatStream]. Tests script the server through [onCommand] (see
/// [scriptServer]) or emit events directly with [emit].
class FakeChatStream implements ChatStream {
  final _events = StreamController<ChatEvent>.broadcast();
  final _statusChanges = StreamController<ChatConnectionStatus>.broadcast();
  ChatConnectionStatus _status = ChatConnectionStatus.connected;

  final commands = <Map<String, Object?>>[];
  ApiException? failNextCommand;
  void Function(Map<String, Object?> command)? onCommand;

  void emit(ChatEvent event) => _events.add(event);

  void setStatus(ChatConnectionStatus status) {
    _status = status;
    _statusChanges.add(status);
  }

  Future<void> _record(Map<String, Object?> command) async {
    final failure = failNextCommand;
    if (failure != null) {
      failNextCommand = null;
      throw failure;
    }
    commands.add(command);
    onCommand?.call(command);
  }

  @override
  Stream<ChatEvent> get events => _events.stream;

  @override
  ChatConnectionStatus get status => _status;

  @override
  Stream<ChatConnectionStatus> get statusChanges => _statusChanges.stream;

  @override
  Future<void> ensureConnected() async {}

  @override
  Future<void> sendMessage({
    required String requestId,
    required String conversationId,
    required String content,
    List<String> attachmentIds = const [],
  }) => _record({
    'type': 'message.send',
    'request_id': requestId,
    'conversation_id': conversationId,
    'content': content,
    if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
  });

  @override
  Future<void> regenerate({required String requestId, required String conversationId}) =>
      _record({'type': 'response.regenerate', 'request_id': requestId, 'conversation_id': conversationId});

  @override
  Future<void> cancel(String requestId) => _record({'type': 'response.cancel', 'request_id': requestId});

  @override
  Future<void> close() async {
    await _events.close();
    await _statusChanges.close();
  }
}

/// Makes [stream] behave like the backend: stores the user message, streams
/// [reply] word by word and completes. With [hold], the reply stops after the
/// first delta and waits for `response.cancel`.
void scriptServer(
  FakeChatStream stream,
  FakeConversationRepository repo, {
  String reply = 'Hello there!',
  bool hold = false,
  ChatError? failBeforeReply,
  FakeAttachmentRepository? attachments,
}) {
  ChatMessage? streaming;
  String? streamingRequest;
  stream.onCommand = (command) {
    final requestId = command['request_id'] as String?;
    final conversationId = command['conversation_id'] as String?;
    switch (command['type']) {
      case 'response.cancel':
        final partial = streaming;
        if (partial == null || requestId != streamingRequest) return;
        final cancelled = partial.copyWith(status: MessageStatus.cancelled);
        repo.replaceMessage(cancelled);
        streaming = null;
        stream.emit(
          ResponseCancelledEvent(requestId: requestId, conversationId: partial.conversationId, message: cancelled),
        );
        return;
      case 'message.send':
        final ids = (command['attachment_ids'] as List<String>?) ?? const [];
        final user = repo.seedMessage(
          conversationId!,
          MessageRole.user,
          command['content']! as String,
          attachments: [for (final id in ids) attachments?.uploaded[id] ?? fakeAttachment(id)],
        );
        stream.emit(MessageCreatedEvent(requestId: requestId, conversationId: conversationId, message: user));
      case 'response.regenerate':
        final last = repo._messages[conversationId]!.lastOrNull;
        if (last != null && last.role == MessageRole.assistant) {
          repo.removeMessage(conversationId!, last.id);
          stream.emit(MessageDeletedEvent(requestId: requestId, conversationId: conversationId, messageId: last.id));
        }
    }
    if (failBeforeReply != null) {
      stream.emit(
        ResponseFailedEvent(
          requestId: requestId,
          conversationId: conversationId,
          message: null,
          error: failBeforeReply,
        ),
      );
      return;
    }
    final started = repo.seedMessage(
      conversationId!,
      MessageRole.assistant,
      '',
      id: 'reply-$requestId',
      status: MessageStatus.streaming,
    );
    stream.emit(ResponseStartedEvent(requestId: requestId, conversationId: conversationId, message: started));
    final words = reply.split(' ');
    var text = '';
    for (final (index, word) in words.indexed) {
      final delta = index == 0 ? word : ' $word';
      text += delta;
      stream.emit(
        ResponseDeltaEvent(requestId: requestId, conversationId: conversationId, messageId: started.id, delta: delta),
      );
      if (hold) {
        streaming = started.copyWith(content: text);
        streamingRequest = requestId;
        repo.replaceMessage(streaming!);
        return;
      }
    }
    final done = started.copyWith(content: text, status: MessageStatus.complete);
    repo.replaceMessage(done);
    stream.emit(ResponseCompletedEvent(requestId: requestId, conversationId: conversationId, message: done));
  };
}

/// Overrides that replace every network-backed dependency with fakes.
Future<List<Override>> fakeOverrides({
  FakeAuthRepository? auth,
  FakeConversationRepository? conversations,
  FakePreferencesRepository? preferences,
  FakeCatalogRepository? catalog,
  VoiceTransportFactory? voiceTransports,
  FakeChatStream? chatStream,
  FakeAttachmentRepository? attachments,
  FakeAttachmentPicker? picker,
}) async {
  SharedPreferences.setMockInitialValues({});
  final sharedPreferences = await SharedPreferences.getInstance();
  return [
    sharedPreferencesProvider.overrideWithValue(sharedPreferences),
    authRepositoryProvider.overrideWithValue(auth ?? FakeAuthRepository(signedInUser: testUser)),
    conversationRepositoryProvider.overrideWithValue(conversations ?? FakeConversationRepository()),
    preferencesRepositoryProvider.overrideWithValue(preferences ?? FakePreferencesRepository()),
    providerCatalogRepositoryProvider.overrideWithValue(catalog ?? FakeCatalogRepository()),
    chatStreamProvider.overrideWithValue(chatStream ?? FakeChatStream()),
    attachmentRepositoryProvider.overrideWithValue(attachments ?? FakeAttachmentRepository()),
    attachmentPickerProvider.overrideWithValue(picker ?? FakeAttachmentPicker()),
    if (voiceTransports != null) voiceTransportFactoryProvider.overrideWithValue(voiceTransports),
  ];
}

// --------------------------------------------------------------------------- attachments

/// A 1x1 transparent PNG (valid, so `Image.memory` can decode it).
final tinyPng = Uint8List.fromList(
  base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='),
);
final tinyPdf = Uint8List.fromList(utf8.encode('%PDF-1.7\n%%EOF\n'));

Attachment fakeAttachment(String id, {AttachmentKind kind = AttachmentKind.image, String? filename}) => Attachment(
  id: id,
  kind: kind,
  filename: filename ?? (kind == AttachmentKind.image ? '$id.png' : '$id.pdf'),
  contentType: kind == AttachmentKind.image ? 'image/png' : 'application/pdf',
  sizeBytes: 68,
);

class FakeAttachmentRepository implements AttachmentRepository {
  final uploaded = <String, Attachment>{};
  final deleted = <String>[];
  final linked = <String>[];
  ApiException? uploadError;

  /// When set, uploads wait for it (to observe the "uploading" state).
  Completer<void>? gate;
  int _ids = 0;

  @override
  Future<Attachment> upload(PickedFile file, {void Function(double progress)? onProgress}) async {
    onProgress?.call(0.5);
    await gate?.future;
    if (uploadError != null) throw uploadError!;
    final attachment = fakeAttachment('att-${++_ids}', kind: file.kind!, filename: file.name);
    uploaded[attachment.id] = attachment;
    onProgress?.call(1);
    return attachment;
  }

  @override
  Future<void> delete(String attachmentId) async => deleted.add(attachmentId);

  @override
  Future<Uint8List> content(String attachmentId) async =>
      uploaded[attachmentId]?.kind == AttachmentKind.pdf ? tinyPdf : tinyPng;

  @override
  Future<Uri> link(String attachmentId) async {
    linked.add(attachmentId);
    return Uri.parse('http://localhost/api/v1/attachments/$attachmentId/download?expires=1&signature=x');
  }
}

class FakeAttachmentPicker implements AttachmentPicker {
  List<PickedFile> images = [];
  List<PickedFile> pdfs = [];
  PickedFile? photo;

  @override
  bool get canTakePhoto => photo != null;

  @override
  Future<List<PickedFile>> pickImages() async => images;

  @override
  Future<List<PickedFile>> pickPdfs() async => pdfs;

  @override
  Future<PickedFile?> takePhoto() async => photo;
}
