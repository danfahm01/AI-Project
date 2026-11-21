import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/network/api_exception.dart';
import '../../../domain/chat/chat_stream.dart';
import '../../../domain/entities/attachment.dart';
import '../../../domain/entities/chat_message.dart';
import '../../../domain/repositories/repositories.dart';
import '../../../providers/dependencies.dart';

class ChatState {
  const ChatState({required this.messages, this.activeRequestId, this.failure});

  final List<ChatMessage> messages;

  /// The generation in progress (send or regenerate), if any.
  final String? activeRequestId;

  /// A reply that could not start and has no message to show the error on
  /// (e.g. no AI provider configured). Retried with [ChatController.regenerate].
  final ChatError? failure;

  bool get isGenerating => activeRequestId != null;

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  ChatState copyWith({
    List<ChatMessage>? messages,
    String? activeRequestId,
    bool clearActive = false,
    ChatError? failure,
    bool clearFailure = false,
  }) => ChatState(
    messages: messages ?? this.messages,
    activeRequestId: clearActive ? null : (activeRequestId ?? this.activeRequestId),
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}

/// Messages of one conversation plus its live generation, driven by
/// [ChatStream] events.
class ChatController extends AsyncNotifier<ChatState> {
  ChatController(this.conversationId);

  final String conversationId;

  static const _uuid = Uuid();
  static const _deltaFlushInterval = Duration(milliseconds: 40);
  static const _resyncInterval = Duration(seconds: 3);
  static const _maxResyncs = 40;

  final _pendingDeltas = <String, StringBuffer>{};
  Timer? _flushTimer;
  Timer? _resyncTimer;
  int _resyncs = 0;
  bool _lostDuringGeneration = false;

  ConversationRepository get _repository => ref.read(conversationRepositoryProvider);
  ChatStream get _stream => ref.read(chatStreamProvider);

  @override
  Future<ChatState> build() async {
    final stream = ref.watch(chatStreamProvider);
    final events = stream.events.listen(_onEvent);
    final status = stream.statusChanges.listen(_onStatus);
    ref.onDispose(() {
      events.cancel();
      status.cancel();
      _flushTimer?.cancel();
      _resyncTimer?.cancel();
    });
    // Connect early so sending is instant; failures surface when sending.
    unawaited(stream.ensureConnected().catchError((Object _) {}));

    final messages = await _repository.messages(conversationId);
    _scheduleResyncIfStreaming(messages);

    final firstMessage = ref.read(pendingFirstMessagesProvider.notifier).take(conversationId);
    if (firstMessage != null) {
      Future.microtask(() => send(firstMessage.content, attachments: firstMessage.attachments));
    }
    return ChatState(messages: messages);
  }

  ChatState? get _current => state.value;

  void _emit(ChatState next) {
    if (ref.mounted) state = AsyncData(next);
  }

  // ---------------------------------------------------------------- commands

  /// Sends [content] with already uploaded [attachments] (either may be empty).
  Future<void> send(String content, {List<Attachment> attachments = const []}) async {
    final current = _current;
    if (current == null || current.isGenerating) return;
    final requestId = _uuid.v4();
    final nextSeq = current.messages.fold(0, (max, m) => m.seq > max ? m.seq : max) + 1;
    final pending = ChatMessage.pending(
      requestId: requestId,
      conversationId: conversationId,
      content: content,
      seq: nextSeq,
      attachments: attachments,
    );
    _emit(current.copyWith(messages: [...current.messages, pending], activeRequestId: requestId, clearFailure: true));
    try {
      await _stream.sendMessage(
        requestId: requestId,
        conversationId: conversationId,
        content: content,
        attachmentIds: [for (final attachment in attachments) attachment.id],
      );
    } on ApiException catch (error) {
      _failActive(ChatError(code: error.code, message: error.userMessage));
    }
  }

  /// Re-answers the latest user message (replacing the last reply, if any).
  Future<void> regenerate() async {
    final current = _current;
    if (current == null || current.isGenerating) return;
    final requestId = _uuid.v4();
    _emit(current.copyWith(activeRequestId: requestId, clearFailure: true));
    try {
      await _stream.regenerate(requestId: requestId, conversationId: conversationId);
    } on ApiException catch (error) {
      _failActive(ChatError(code: error.code, message: error.userMessage));
    }
  }

  /// Stops the reply in progress; the partial text is kept.
  Future<void> stop() async {
    final requestId = _current?.activeRequestId;
    if (requestId == null) return;
    try {
      await _stream.cancel(requestId);
    } on ApiException {
      // Disconnected: the server finishes the reply; we resync on reconnect.
    }
  }

  Future<void> retry(String localId) async {
    final current = _current;
    final failed = current?.messages.where((m) => m.id == localId && m.status == MessageStatus.failed).firstOrNull;
    if (current == null || failed == null) return;
    _emit(current.copyWith(messages: current.messages.where((m) => m.id != localId).toList()));
    // A rejected message was not stored, so its uploads are still pending and can be resent.
    await send(failed.content, attachments: failed.attachments);
  }

  void discard(String localId) {
    final current = _current;
    if (current != null) _emit(current.copyWith(messages: current.messages.where((m) => m.id != localId).toList()));
  }

  /// Edits a user message (the server drops the turns after it), then asks
  /// for a new reply to the edited text.
  Future<void> edit(String messageId, String content) async {
    final result = await _repository.editMessage(messageId, content);
    final current = _current;
    if (current == null) return;
    final removed = result.removedMessageIds.toSet();
    _emit(
      current.copyWith(
        messages: [
          for (final message in current.messages)
            if (message.id == messageId) result.message else if (!removed.contains(message.id)) message,
        ],
        clearFailure: true,
      ),
    );
    await regenerate();
  }

  Future<void> delete(String messageId) async {
    await _repository.deleteMessage(messageId);
    final current = _current;
    if (current != null) _emit(current.copyWith(messages: current.messages.where((m) => m.id != messageId).toList()));
  }

  // ---------------------------------------------------------------- events

  void _onEvent(ChatEvent event) {
    final current = _current;
    if (current == null) return;
    if (event is CommandRejectedEvent) {
      if (event.requestId != null && event.requestId == current.activeRequestId) _failActive(event.error);
      return;
    }
    if (event.conversationId != conversationId) return;

    switch (event) {
      case MessageCreatedEvent(:final requestId, :final message):
        final localId = requestId == null ? null : ChatMessage.localIdFor(requestId);
        _emit(current.copyWith(messages: _upsert(current.messages, message, replacing: localId)));
      case MessageDeletedEvent(:final messageId):
        _emit(current.copyWith(messages: current.messages.where((m) => m.id != messageId).toList()));
      case ResponseStartedEvent(:final message):
        _emit(current.copyWith(messages: _upsert(current.messages, message)));
      case ResponseDeltaEvent(:final messageId, :final delta):
        (_pendingDeltas[messageId] ??= StringBuffer()).write(delta);
        _flushTimer ??= Timer(_deltaFlushInterval, _flushDeltas);
      case ResponseCompletedEvent(:final requestId, :final message):
        _finish(requestId, message: message);
      case ResponseCancelledEvent(:final requestId, :final message):
        _finish(requestId, message: message);
      case ResponseFailedEvent(:final requestId, :final message, :final error):
        _finish(requestId, message: message, error: message == null ? error : null);
      case ConversationUpdatedEvent() || CommandRejectedEvent():
        break; // the conversation list handles title/recency updates
    }
  }

  void _flushDeltas() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final current = _current;
    if (current == null || _pendingDeltas.isEmpty) return;
    final messages = [
      for (final message in current.messages)
        if (_pendingDeltas[message.id] case final buffer?)
          message.copyWith(content: message.content + buffer.toString())
        else
          message,
    ];
    _pendingDeltas.clear();
    _emit(current.copyWith(messages: messages));
  }

  void _finish(String? requestId, {ChatMessage? message, ChatError? error}) {
    _flushDeltas();
    final current = _current;
    if (current == null) return;
    var messages = message == null ? current.messages : _upsert(current.messages, message);
    ChatError? failure;
    if (error != null) {
      // Still-pending user message (never stored): show the error on it so it
      // can be retried; otherwise show it as a conversation-level failure.
      final localId = requestId == null ? null : ChatMessage.localIdFor(requestId);
      if (localId != null && messages.any((m) => m.id == localId)) {
        messages = _markFailed(messages, localId, error.message);
      } else {
        failure = error;
      }
    }
    final finishedActive = requestId != null && requestId == current.activeRequestId;
    _emit(
      ChatState(
        messages: messages,
        activeRequestId: finishedActive ? null : current.activeRequestId,
        failure: failure ?? (finishedActive ? null : current.failure),
      ),
    );
  }

  void _failActive(ChatError error) {
    final current = _current;
    final requestId = current?.activeRequestId;
    if (current == null || requestId == null) return;
    final localId = ChatMessage.localIdFor(requestId);
    final hasPending = current.messages.any((m) => m.id == localId);
    _emit(
      current.copyWith(
        messages: hasPending ? _markFailed(current.messages, localId, error.message) : null,
        clearActive: true,
        failure: hasPending ? null : error,
      ),
    );
  }

  // ---------------------------------------------------------------- resync

  void _onStatus(ChatConnectionStatus status) {
    final current = _current;
    if (status == ChatConnectionStatus.reconnecting && (current?.isGenerating ?? false)) {
      _lostDuringGeneration = true;
    } else if (status == ChatConnectionStatus.connected && _lostDuringGeneration) {
      _lostDuringGeneration = false;
      unawaited(_reload());
    }
  }

  /// Reloads from the server; the reply may have finished while we were offline.
  Future<void> _reload() async {
    try {
      final messages = await _repository.messages(conversationId);
      final current = _current;
      if (current == null) return;
      final localPending = current.messages.where((m) => m.isLocal && m.status == MessageStatus.failed);
      _emit(ChatState(messages: [...messages, ...localPending]));
      _scheduleResyncIfStreaming(messages);
    } on ApiException {
      // Keep what we have; the next reconnect retries.
    }
  }

  void _scheduleResyncIfStreaming(List<ChatMessage> messages) {
    _resyncTimer?.cancel();
    if (!messages.any((m) => m.status == MessageStatus.streaming) || _resyncs >= _maxResyncs) return;
    _resyncs++;
    _resyncTimer = Timer(_resyncInterval, () {
      if (!(_current?.isGenerating ?? false)) unawaited(_reload());
    });
  }

  // ---------------------------------------------------------------- helpers

  static List<ChatMessage> _upsert(List<ChatMessage> messages, ChatMessage message, {String? replacing}) {
    final index = messages.indexWhere((m) => m.id == message.id || (replacing != null && m.id == replacing));
    if (index < 0) return [...messages, message]..sort((a, b) => a.seq.compareTo(b.seq));
    return [...messages]..[index] = message;
  }

  static List<ChatMessage> _markFailed(List<ChatMessage> messages, String id, String reason) => [
    for (final m in messages) m.id == id ? m.copyWith(status: MessageStatus.failed, errorMessage: reason) : m,
  ];
}

final chatControllerProvider = AsyncNotifierProvider.autoDispose.family<ChatController, ChatState, String>(
  ChatController.new,
);

typedef FirstMessage = ({String content, List<Attachment> attachments});

/// First message of a new chat: stored while the app navigates to the new
/// conversation, then sent by its [ChatController].
class PendingFirstMessages extends Notifier<Map<String, FirstMessage>> {
  @override
  Map<String, FirstMessage> build() => const {};

  void put(String conversationId, String content, {List<Attachment> attachments = const []}) =>
      state = {...state, conversationId: (content: content, attachments: attachments)};

  FirstMessage? take(String conversationId) {
    final message = state[conversationId];
    if (message != null) state = {...state}..remove(conversationId);
    return message;
  }
}

final pendingFirstMessagesProvider = NotifierProvider<PendingFirstMessages, Map<String, FirstMessage>>(
  PendingFirstMessages.new,
);
