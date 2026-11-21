/// Real-time chat channel: commands go up, generation events come down.
/// Implemented over WebSocket in `lib/data/realtime/`; faked in tests.
library;

import '../entities/chat_message.dart';
import '../entities/conversation.dart';

enum ChatConnectionStatus {
  disconnected,
  connecting,
  connected,

  /// The connection dropped and is being re-established automatically.
  reconnecting,
}

class ChatError {
  const ChatError({required this.code, required this.message});

  final String code;
  final String message;
}

sealed class ChatEvent {
  const ChatEvent({required this.requestId, required this.conversationId});

  final String? requestId;
  final String? conversationId;
}

/// The user message was stored.
class MessageCreatedEvent extends ChatEvent {
  const MessageCreatedEvent({required super.requestId, required super.conversationId, required this.message});

  final ChatMessage message;
}

/// A message was removed (the previous reply, when regenerating).
class MessageDeletedEvent extends ChatEvent {
  const MessageDeletedEvent({required super.requestId, required super.conversationId, required this.messageId});

  final String messageId;
}

class ConversationUpdatedEvent extends ChatEvent {
  const ConversationUpdatedEvent({
    required super.requestId,
    required super.conversationId,
    required this.conversation,
    required this.titleChanged,
  });

  final Conversation conversation;
  final bool titleChanged;
}

/// The assistant message exists (empty, status streaming).
class ResponseStartedEvent extends ChatEvent {
  const ResponseStartedEvent({required super.requestId, required super.conversationId, required this.message});

  final ChatMessage message;
}

class ResponseDeltaEvent extends ChatEvent {
  const ResponseDeltaEvent({
    required super.requestId,
    required super.conversationId,
    required this.messageId,
    required this.delta,
  });

  final String messageId;
  final String delta;
}

class ResponseCompletedEvent extends ChatEvent {
  const ResponseCompletedEvent({required super.requestId, required super.conversationId, required this.message});

  final ChatMessage message;
}

/// Stopped by the user; [message] holds the partial reply.
class ResponseCancelledEvent extends ChatEvent {
  const ResponseCancelledEvent({required super.requestId, required super.conversationId, required this.message});

  final ChatMessage? message;
}

/// [message] is null when the failure happened before a reply was created
/// (e.g. no AI provider configured).
class ResponseFailedEvent extends ChatEvent {
  const ResponseFailedEvent({
    required super.requestId,
    required super.conversationId,
    required this.message,
    required this.error,
  });

  final ChatMessage? message;
  final ChatError error;
}

/// A command was rejected (busy, rate limited, invalid).
class CommandRejectedEvent extends ChatEvent {
  const CommandRejectedEvent({required super.requestId, required this.error}) : super(conversationId: null);

  final ChatError error;
}

abstract interface class ChatStream {
  Stream<ChatEvent> get events;

  ChatConnectionStatus get status;
  Stream<ChatConnectionStatus> get statusChanges;

  /// Connects and authenticates if needed. Throws `ApiException` on failure.
  Future<void> ensureConnected();

  /// [attachmentIds] are uploads (see `AttachmentRepository`) sent with the message.
  Future<void> sendMessage({
    required String requestId,
    required String conversationId,
    required String content,
    List<String> attachmentIds = const [],
  });

  Future<void> regenerate({required String requestId, required String conversationId});

  Future<void> cancel(String requestId);

  Future<void> close();
}
