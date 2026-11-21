import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/layout/breakpoints.dart';
import '../chat/presentation/widgets/conversation_sidebar.dart';

/// Lets screens inside the shell reach the navigation (drawer or sidebar).
class ShellScope extends InheritedWidget {
  const ShellScope({
    super.key,
    required this.isWide,
    required this.isSidebarVisible,
    required this.openNavigation,
    required this.toggleSidebar,
    required super.child,
  });

  final bool isWide;
  final bool isSidebarVisible;
  final VoidCallback openNavigation;
  final VoidCallback toggleSidebar;

  static ShellScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShellScope>();

  @override
  bool updateShouldNotify(ShellScope oldWidget) =>
      isWide != oldWidget.isWide || isSidebarVisible != oldWidget.isSidebarVisible;
}

/// App-bar leading button: opens the drawer on narrow layouts, or re-shows a
/// hidden sidebar on wide ones. `null` when no button is needed.
Widget? shellNavigationButton(BuildContext context) {
  final scope = ShellScope.maybeOf(context);
  if (scope == null) return null;
  if (!scope.isWide) {
    return IconButton(tooltip: 'Open menu', icon: const Icon(Icons.menu_rounded), onPressed: scope.openNavigation);
  }
  if (!scope.isSidebarVisible) {
    return IconButton(
      tooltip: 'Show sidebar (Ctrl+B)',
      icon: const Icon(Icons.view_sidebar_outlined),
      onPressed: scope.toggleSidebar,
    );
  }
  return null;
}

/// Responsive frame around chat and settings: a permanent sidebar on wide
/// windows, a drawer on phones, and desktop keyboard shortcuts.
class ChatShell extends ConsumerStatefulWidget {
  const ChatShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  ConsumerState<ChatShell> createState() => _ChatShellState();
}

class _ChatShellState extends ConsumerState<ChatShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _searchFocus = FocusNode(debugLabel: 'conversation-search');
  bool _sidebarVisible = true;

  String? get _selectedConversationId {
    final segments = Uri.parse(widget.location).pathSegments;
    return segments.length == 2 && segments.first == 'chat' ? segments[1] : null;
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  void _toggleSidebar() => setState(() => _sidebarVisible = !_sidebarVisible);

  void _focusSearch(bool isWide) {
    if (!isWide) {
      _scaffoldKey.currentState?.openDrawer();
    } else if (!_sidebarVisible) {
      setState(() => _sidebarVisible = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
  }

  Map<ShortcutActivator, VoidCallback> _shortcuts(bool isWide) {
    void newChat() => context.go('/chat');
    void search() => _focusSearch(isWide);
    void sidebar() => isWide ? _toggleSidebar() : _scaffoldKey.currentState?.openDrawer();
    return {
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): newChat,
      const SingleActivator(LogicalKeyboardKey.keyN, meta: true): newChat,
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): search,
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true): search,
      const SingleActivator(LogicalKeyboardKey.keyB, control: true): sidebar,
      const SingleActivator(LogicalKeyboardKey.keyB, meta: true): sidebar,
    };
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= Breakpoints.sidebar;
    final sidebar = ConversationSidebar(
      selectedConversationId: _selectedConversationId,
      searchFocusNode: _searchFocus,
      onNavigate: () {
        if (!isWide) _scaffoldKey.currentState?.closeDrawer();
      },
    );

    return CallbackShortcuts(
      bindings: _shortcuts(isWide),
      child: Focus(
        autofocus: true,
        child: ShellScope(
          isWide: isWide,
          isSidebarVisible: _sidebarVisible,
          openNavigation: () => _scaffoldKey.currentState?.openDrawer(),
          toggleSidebar: _toggleSidebar,
          child: Scaffold(
            key: _scaffoldKey,
            drawer: isWide ? null : Drawer(width: Breakpoints.sidebarWidth + 16, child: sidebar),
            body: isWide
                ? Row(
                    children: [
                      if (_sidebarVisible) ...[
                        SizedBox(width: Breakpoints.sidebarWidth, child: sidebar),
                        const VerticalDivider(width: 1),
                      ],
                      Expanded(child: widget.child),
                    ],
                  )
                : widget.child,
          ),
        ),
      ),
    );
  }
}
