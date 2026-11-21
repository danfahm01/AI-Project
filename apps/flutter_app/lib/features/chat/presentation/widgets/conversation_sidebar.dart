import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/widgets/common_widgets.dart';
import '../../../../domain/entities/conversation.dart';
import '../../../../domain/entities/user.dart';
import '../../../../providers/auth_controller.dart';
import '../../../shell/chat_shell.dart';
import '../../application/conversation_list_controller.dart';

class ConversationSidebar extends ConsumerStatefulWidget {
  const ConversationSidebar({
    super.key,
    required this.selectedConversationId,
    required this.searchFocusNode,
    required this.onNavigate,
  });

  final String? selectedConversationId;
  final FocusNode searchFocusNode;

  /// Called after navigating, so the drawer can close on phones.
  final VoidCallback onNavigate;

  @override
  ConsumerState<ConversationSidebar> createState() => _ConversationSidebarState();
}

class _ConversationSidebarState extends ConsumerState<ConversationSidebar> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (_scrollController.position.extentAfter < 400) {
      ref.read(conversationListControllerProvider.notifier).loadMore().catchError((Object _) {});
    }
  }

  void _onSearchChanged(String value) {
    setState(() {}); // toggles the clear button
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(conversationListControllerProvider.notifier).search(value);
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _onSearchChanged('');
  }

  void _open(String path) {
    context.go(path);
    widget.onNavigate();
  }

  Future<void> _rename(Conversation conversation) async {
    final title = await textInputDialog(
      context,
      title: 'Rename conversation',
      initialValue: conversation.title,
      confirmLabel: 'Rename',
    );
    if (title == null || title == conversation.title || !mounted) return;
    await runGuarded(
      context,
      () => ref.read(conversationListControllerProvider.notifier).rename(conversation.id, title),
    );
  }

  Future<void> _delete(Conversation conversation) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Delete conversation?',
      message: '"${conversation.title}" and all of its messages will be permanently deleted.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await runGuarded(context, () async {
      await ref.read(conversationListControllerProvider.notifier).delete(conversation.id);
      if (mounted && widget.selectedConversationId == conversation.id) context.go('/chat');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final listState = ref.watch(conversationListControllerProvider);
    final user = ref.watch(currentUserProvider);
    final shell = ShellScope.maybeOf(context);

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  const AppMark(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text('Assistant', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  if (shell?.isWide ?? false)
                    IconButton(
                      tooltip: 'Hide sidebar (Ctrl+B)',
                      icon: const Icon(Icons.view_sidebar_outlined),
                      onPressed: shell!.toggleSidebar,
                    ),
                  IconButton(
                    tooltip: 'New chat (Ctrl+N)',
                    icon: const Icon(Icons.edit_square),
                    onPressed: () => _open('/chat'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _searchController,
                focusNode: widget.searchFocusNode,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search chats (Ctrl+K)',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: _clearSearch,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: listState.when(
                skipLoadingOnReload: true,
                data: _buildList,
                loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                error: (error, _) => ErrorView(
                  error: error,
                  compact: true,
                  onRetry: () => ref.invalidate(conversationListControllerProvider),
                ),
              ),
            ),
            const Divider(),
            if (user != null) _ProfileButton(user: user, onOpenSettings: () => _open('/settings')),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ConversationListState state) {
    final theme = Theme.of(context);
    if (state.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: state.isSearching
              ? const CircularProgressIndicator(strokeWidth: 2)
              : Text(
                  state.query.isEmpty ? 'No conversations yet' : 'No chats match "${state.query}"',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
        ),
      );
    }

    final entries = <Object>[
      for (final (bucket, conversations) in groupByRecency(state.items, DateTime.now())) ...[bucket, ...conversations],
      if (state.hasMore) const _LoadingMore(),
    ];

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: entries.length,
      itemBuilder: (context, index) => switch (entries[index]) {
        final DateBucket bucket => _BucketHeader(bucket: bucket),
        final Conversation conversation => _ConversationTile(
          conversation: conversation,
          selected: conversation.id == widget.selectedConversationId,
          onTap: () => _open('/chat/${conversation.id}'),
          onRename: () => _rename(conversation),
          onDelete: () => _delete(conversation),
        ),
        _ => const Padding(
          padding: EdgeInsets.all(12),
          child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      },
    );
  }
}

class _LoadingMore {
  const _LoadingMore();
}

class _BucketHeader extends StatelessWidget {
  const _BucketHeader({required this.bucket});

  final DateBucket bucket;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (bucket) {
      DateBucket.today => 'Today',
      DateBucket.yesterday => 'Yesterday',
      DateBucket.previous7Days => 'Previous 7 days',
      DateBucket.previous30Days => 'Previous 30 days',
      DateBucket.older => 'Older',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 6),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

enum _TileAction { rename, delete }

class _ConversationTile extends StatefulWidget {
  const _ConversationTile({
    required this.conversation,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  State<_ConversationTile> createState() => _ConversationTileState();
}

class _ConversationTileState extends State<_ConversationTile> {
  bool _hovered = false;

  /// The pointer leaves the tile when it moves onto the open menu. The menu
  /// button must stay mounted meanwhile, or PopupMenuButton drops the selection.
  bool _menuOpen = false;
  final _menuKey = GlobalKey<PopupMenuButtonState<_TileAction>>();

  /// Long-press opens the menu: touchscreens on desktop platforms never hover.
  void _openMenuFromLongPress() {
    setState(() => _menuOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _menuKey.currentState?.showButtonMenu());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isTouch = switch (theme.platform) {
      TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
      _ => false,
    };
    final showMenu = widget.selected || _hovered || _menuOpen || isTouch;
    final background = widget.selected
        ? scheme.secondaryContainer
        : (_hovered ? scheme.surfaceContainerHighest : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onTap,
            onLongPress: _openMenuFromLongPress,
            child: SizedBox(
              height: 42,
              child: Padding(
                padding: const EdgeInsets.only(left: 12, right: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.conversation.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: widget.selected ? scheme.onSecondaryContainer : scheme.onSurface,
                          fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (showMenu)
                      PopupMenuButton<_TileAction>(
                        key: _menuKey,
                        tooltip: 'Conversation options',
                        icon: const Icon(Icons.more_horiz_rounded, size: 18),
                        onOpened: () => setState(() => _menuOpen = true),
                        onCanceled: () => setState(() => _menuOpen = false),
                        onSelected: (action) {
                          setState(() => _menuOpen = false);
                          switch (action) {
                            case _TileAction.rename:
                              widget.onRename();
                            case _TileAction.delete:
                              widget.onDelete();
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: _TileAction.rename,
                            child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Rename')),
                          ),
                          PopupMenuItem(
                            value: _TileAction.delete,
                            child: ListTile(
                              leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
                              title: Text('Delete', style: TextStyle(color: scheme.error)),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ProfileAction { settings, logout }

class _ProfileButton extends ConsumerWidget {
  const _ProfileButton({required this.user, required this.onOpenSettings});

  final User user;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: PopupMenuButton<_ProfileAction>(
        tooltip: 'Account',
        position: PopupMenuPosition.over,
        onSelected: (action) async {
          switch (action) {
            case _ProfileAction.settings:
              onOpenSettings();
            case _ProfileAction.logout:
              await ref.read(authControllerProvider.notifier).logout();
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: _ProfileAction.settings,
            child: ListTile(leading: Icon(Icons.settings_outlined), title: Text('Settings')),
          ),
          PopupMenuItem(
            value: _ProfileAction.logout,
            child: ListTile(leading: Icon(Icons.logout_rounded), title: Text('Log out')),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  user.initials,
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      user.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.unfold_more_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
