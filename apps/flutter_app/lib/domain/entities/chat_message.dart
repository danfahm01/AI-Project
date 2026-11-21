import 'attachment.dart';

enum MessageRole { user, assistant, system, tool }

enum MessageStatus {
  complete,
  streaming,
  error,
  cancelled,

  /// Client-only: being sent to the server.
  sending,

  /// Client-only: the server did not accept the message.
  failed,
}

class TokenUsage {
  const TokenUsage({this.inputTokens, this.outputTokens, this.totalTokens});

  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.seq,
    required this.role,
    required this.content,
    required this.status,
    required this.createdAt,
    this.provider,
    this.model,
    this.usage,
    this.editedAt,
    this.errorMessage,
    this.attachments = const [],
  });

  /// An optimistic message shown while the request is in flight. Its id is
  /// derived from the request id so the server's echo can replace it.
  factory ChatMessage.pending({
    required String requestId,
    required String conversationId,
    required String content,
    required int seq,
    List<Attachment> attachments = const [],
  }) => ChatMessage(
    id: localIdFor(requestId),
    conversationId: conversationId,
    seq: seq,
    role: MessageRole.user,
    content: content,
    status: MessageStatus.sending,
    createdAt: DateTime.now().toUtc(),
    attachments: attachments,
  );

  final String id;
  final String conversationId;
  final int seq;
  final MessageRole role;
  final String content;
  final MessageStatus status;
  final String? provider;
  final String? model;
  final TokenUsage? usage;
  final DateTime createdAt;
  final DateTime? editedAt;
  final String? errorMessage;

  /// Images and PDFs sent with a user message.
  final List<Attachment> attachments;

  static String localIdFor(String requestId) => 'local-$requestId';

  bool get isLocal => id.startsWith('local-');
  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;

  ChatMessage copyWith({String? content, MessageStatus? status, String? errorMessage, DateTime? editedAt}) =>
      ChatMessage(
        id: id,
        conversationId: conversationId,
        seq: seq,
        role: role,
        content: content ?? this.content,
        status: status ?? this.status,
        provider: provider,
        model: model,
        usage: usage,
        createdAt: createdAt,
        editedAt: editedAt ?? this.editedAt,
        errorMessage: errorMessage,
        attachments: attachments,
      );
}

class MessageEditResult {
  const MessageEditResult({required this.message, required this.removedMessageIds});

  final ChatMessage message;
  final List<String> removedMessageIds;
}
