import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/auth/presentation/auth_screens.dart';
import '../../features/chat/presentation/chat_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/shell/chat_shell.dart';
import '../../features/voice/presentation/voice_screen.dart';
import '../../providers/auth_controller.dart';

const _publicRoutes = {'/login', '/register'};
const _home = '/chat';

/// Pure redirect rule, unit-tested separately.
///
/// The page the user asked for (a deep link, or the conversation open when the
/// web page reloads) travels through `/splash` and `/login` as `?from=` and is
/// restored once signed in.
String? authRedirect(AsyncValue<AuthState> auth, Uri uri) {
  final location = uri.path;
  final isPublic = _publicRoutes.contains(location);
  final isSplash = location == '/splash';
  // Where to go after authentication: carried along, or the current page.
  final target = (isPublic || isSplash) ? _safeTarget(uri.queryParameters['from']) : _safeTarget(uri.toString());

  final resolved = auth.hasValue || auth.hasError;
  if (!resolved) return isSplash ? null : _withFrom('/splash', target);

  final signedIn = auth.value is Authenticated;
  if (!signedIn) return isPublic ? null : _withFrom('/login', target);
  if (isPublic || isSplash) return target ?? _home;
  return null;
}

String _withFrom(String path, String? target) =>
    target == null || target == _home ? path : '$path?from=${Uri.encodeQueryComponent(target)}';

/// Only in-app paths are accepted, so `from` can never redirect to another site.
String? _safeTarget(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.hasScheme || uri.hasAuthority || !uri.path.startsWith('/') || raw.startsWith('//')) {
    return null;
  }
  if (_publicRoutes.contains(uri.path) || uri.path == '/splash') return null;
  return raw;
}

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ValueNotifier<AsyncValue<AuthState>>(ref.read(authControllerProvider));
  ref.listen(authControllerProvider, (_, next) => authState.value = next);

  final router = GoRouter(
    initialLocation: '/chat',
    refreshListenable: authState,
    redirect: (context, state) => authRedirect(authState.value, state.uri),
    routes: [
      GoRoute(path: '/splash', builder: (context, state) => const SplashScreen()),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) => const NoTransitionPage(child: LoginScreen()),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (context, state) => const NoTransitionPage(child: RegisterScreen()),
      ),
      ShellRoute(
        builder: (context, state, child) => ChatShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/chat',
            pageBuilder: (context, state) => const NoTransitionPage(child: ChatScreen()),
          ),
          GoRoute(
            path: '/chat/:id',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: ChatScreen(key: ValueKey(state.pathParameters['id']), conversationId: state.pathParameters['id']),
            ),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => const NoTransitionPage(child: SettingsScreen()),
          ),
        ],
      ),
      GoRoute(
        path: '/voice',
        pageBuilder: (context, state) => MaterialPage(
          fullscreenDialog: true,
          child: VoiceScreen(conversationId: state.uri.queryParameters['conversation']),
        ),
      ),
    ],
  );

  ref.onDispose(() {
    router.dispose();
    authState.dispose();
  });
  return router;
});
