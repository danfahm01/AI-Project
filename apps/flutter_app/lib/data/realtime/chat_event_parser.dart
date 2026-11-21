import '../../domain/chat/chat_stream.dart';
import '../mappers/json_mappers.dart';

ChatError _error(Object? raw) {
  final json = raw is Map ? raw : const {};
  return ChatError(
    code: json['code']?.toString() ?? 'unknown_error',
    message: json['message']?.toString() ?? 'Something went wrong.',
  );
}

/// Parses a server frame; returns null for frames that are not chat events
/// (pong, auth acknowledgements) or unknown future event types.
ChatEvent? parseChatEvent(Json json) {
  final requestId = json['request_id'] as String?;
  final conversationId = json['conversation_id'] as String?;
  Json? message() => json['message'] as Json?;

  return switch (json['type']) {
    'message.created' => MessageCreatedEvent(
      requestId: requestId,
      conversationId: conversationId,
      message: messageFromJson(message()!),
    ),
    'message.deleted' => MessageDeletedEvent(
      requestId: requestId,
      conversationId: conversationId,
      messageId: json['message_id'] as String,
    ),
    'conversation.updated' => ConversationUpdatedEvent(
      requestId: requestId,
      conversationId: conversationId,
      conversation: conversationFromJson(json['conversation'] as Json),
      titleChanged: json['title_changed'] as bool? ?? false,
    ),
    'response.started' => ResponseStartedEvent(
      requestId: requestId,
      conversationId: conversationId,
      message: messageFromJson(message()!),
    ),
    'response.delta' => ResponseDeltaEvent(
      requestId: requestId,
      conversationId: conversationId,
      messageId: json['message_id'] as String,
      delta: json['delta'] as String,
    ),
    'response.completed' => ResponseCompletedEvent(
      requestId: requestId,
      conversationId: conversationId,
      message: messageFromJson(message()!),
    ),
    'response.cancelled' => ResponseCancelledEvent(
      requestId: requestId,
      conversationId: conversationId,
      message: message() == null ? null : messageFromJson(message()!),
    ),
    'response.failed' => ResponseFailedEvent(
      requestId: requestId,
      conversationId: conversationId,
      message: message() == null ? null : messageFromJson(message()!),
      error: _error(json['error']),
    ),
    'error' => CommandRejectedEvent(requestId: requestId, error: _error(json['error'])),
    _ => null,
  };
}
