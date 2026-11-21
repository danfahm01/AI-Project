import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/chat/chat_stream.dart';
import '../../../domain/entities/ai_provider.dart';
import '../../../domain/entities/conversation.dart';
import '../../../domain/repositories/repositories.dart';
import '../../../providers/auth_controller.dart';
import '../../../providers/dependencies.dart';

class ConversationListState {
  const ConversationListState({
    required this.items,
    this.nextCursor,
    this.query = '',
    this.isSearching = false,
    this.isLoadingMore = false,
  });

  final List<Conversation> items;
  final String? nextCursor;
  final String query;
  final bool isSearching;
  final bool isLoadingMore;

  bool get hasMore => nextCursor != null;

  ConversationListState copyWith({
    List<Conversation>? items,
    String? nextCursor,
    bool clearCursor = false,
    String? query,
    bool? isSearching,
    bool? isLoadingMore,
  }) => ConversationListState(
    items: items ?? this.items,
    nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
    query: query ?? this.query,
    isSearching: isSearching ?? this.isSearching,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );
}

class ConversationListController extends AsyncNotifier<ConversationListState> {
  static const pageSize = 30;

  ConversationRepository get _repository => ref.read(conversationRepositoryProvider);

  @override
  Future<ConversationListState> build() async {
    if (ref.watch(currentUserIdProvider) == null) return const ConversationListState(items: []);
    // Titles and recency change while chatting; the chat stream reports them.
    final updates = ref.watch(chatStreamProvider).events.listen((event) {
      if (event is ConversationUpdatedEvent && state.hasValue) upsert(event.conversation);
    });
    ref.onDispose(updates.cancel);
    final page = await _repository.list(limit: pageSize);
    return ConversationListState(items: page.items, nextCursor: page.nextCursor);
  }

  ConversationListState get _current => state.value ?? const ConversationListState(items: []);

  Future<void> search(String query) async {
    final trimmed = query.trim();
    if (trimmed == _current.query && state.hasValue) return;
    state = AsyncData(_current.copyWith(query: trimmed, isSearching: true));
    try {
      final page = await _repository.list(query: trimmed, limit: pageSize);
      if (_current.query != trimmed) return; // a newer search superseded this one
      state = AsyncData(ConversationListState(items: page.items, nextCursor: page.nextCursor, query: trimmed));
    } catch (error, stack) {
      if (_current.query == trimmed) state = AsyncError(error, stack);
    }
  }

  Future<void> loadMore() async {
    final current = _current;
    if (!current.hasMore || current.isLoadingMore || current.isSearching) return;
    state = AsyncData(current.copyWith(isLoadingMore: true));
    try {
      final page = await _repository.list(query: current.query, cursor: current.nextCursor, limit: pageSize);
      final known = {for (final c in current.items) c.id};
      state = AsyncData(
        current.copyWith(
          items: [...current.items, ...page.items.where((c) => !known.contains(c.id))],
          nextCursor: page.nextCursor,
          clearCursor: page.nextCursor == null,
          isLoadingMore: false,
        ),
      );
    } catch (_) {
      state = AsyncData(current.copyWith(isLoadingMore: false));
      rethrow;
    }
  }

  Future<Conversation> create({ModelSelection? model}) async {
    final conversation = await _repository.create(provider: model?.provider.id, model: model?.model.id);
    upsert(conversation);
    return conversation;
  }

  Future<void> rename(String id, String title) async => upsert(await _repository.rename(id, title), moveToTop: false);

  Future<void> setModel(String id, ModelSelection selection) async => upsert(
    await _repository.setModel(id, provider: selection.provider.id, model: selection.model.id),
    moveToTop: false,
  );

  Future<void> delete(String id) async {
    await _repository.delete(id);
    final current = _current;
    state = AsyncData(current.copyWith(items: current.items.where((c) => c.id != id).toList()));
  }

  /// Re-fetches one conversation (e.g. after a message changed its title and
  /// activity time) and moves it to the top.
  Future<void> refreshOne(String id) async => upsert(await _repository.get(id));

  void upsert(Conversation conversation, {bool moveToTop = true}) {
    final current = _current;
    final items = [...current.items];
    final index = items.indexWhere((c) => c.id == conversation.id);
    if (index >= 0 && !moveToTop) {
      items[index] = conversation;
    } else {
      if (index >= 0) items.removeAt(index);
      items.insert(0, conversation);
    }
    state = AsyncData(current.copyWith(items: items));
  }
}

final conversationListControllerProvider = AsyncNotifierProvider<ConversationListController, ConversationListState>(
  ConversationListController.new,
);

/// A conversation by id: from the loaded list when available, otherwise fetched.
final conversationProvider = FutureProvider.autoDispose.family<Conversation, String>((ref, id) async {
  final fromList = ref.watch(conversationListControllerProvider).value?.items.where((c) => c.id == id).firstOrNull;
  if (fromList != null) return fromList;
  return ref.read(conversationRepositoryProvider).get(id);
});

enum DateBucket { today, yesterday, previous7Days, previous30Days, older }

/// Groups conversations (already sorted newest first) by last activity, in local time.
List<(DateBucket, List<Conversation>)> groupByRecency(List<Conversation> items, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  DateBucket bucketFor(Conversation c) {
    final local = c.updatedAt.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final daysAgo = today.difference(day).inDays;
    if (daysAgo <= 0) return DateBucket.today;
    if (daysAgo == 1) return DateBucket.yesterday;
    if (daysAgo <= 7) return DateBucket.previous7Days;
    if (daysAgo <= 30) return DateBucket.previous30Days;
    return DateBucket.older;
  }

  final groups = <(DateBucket, List<Conversation>)>[];
  for (final conversation in items) {
    final bucket = bucketFor(conversation);
    if (groups.isNotEmpty && groups.last.$1 == bucket) {
      groups.last.$2.add(conversation);
    } else {
      groups.add((bucket, [conversation]));
    }
  }
  return groups;
}
