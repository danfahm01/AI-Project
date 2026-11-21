import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/api_exception.dart';
import '../domain/entities/user.dart';
import 'dependencies.dart';

sealed class AuthState {
  const AuthState();
}

class Authenticated extends AuthState {
  const Authenticated(this.user);

  final User user;
}

enum SignedOutReason { loggedOut, sessionExpired, serverUnreachable }

class Unauthenticated extends AuthState {
  const Unauthenticated({this.reason});

  final SignedOutReason? reason;
}

class AuthController extends AsyncNotifier<AuthState> {
  @override
  Future<AuthState> build() async {
    try {
      final user = await ref.read(authRepositoryProvider).currentUser();
      return user == null ? const Unauthenticated() : Authenticated(user);
    } on ApiException catch (error) {
      // Keep stored tokens: the session may still be valid once the server is reachable.
      if (error.isNetworkError) return const Unauthenticated(reason: SignedOutReason.serverUnreachable);
      rethrow;
    }
  }

  /// Throws [ApiException] on failure so the form can show the message.
  Future<void> login({required String email, required String password}) async {
    final user = await ref.read(authRepositoryProvider).login(email: email, password: password);
    state = AsyncData(Authenticated(user));
  }

  Future<void> register({required String email, required String password, required String displayName}) async {
    final user = await ref
        .read(authRepositoryProvider)
        .register(email: email, password: password, displayName: displayName);
    state = AsyncData(Authenticated(user));
  }

  Future<void> updateDisplayName(String displayName) async {
    final user = await ref.read(authRepositoryProvider).updateProfile(displayName: displayName);
    state = AsyncData(Authenticated(user));
  }

  Future<void> logout() async {
    await ref.read(authRepositoryProvider).logout();
    state = const AsyncData(Unauthenticated(reason: SignedOutReason.loggedOut));
  }

  /// Called by the API client when the refresh token is rejected.
  void handleSessionExpired() {
    if (state.value is Authenticated) {
      state = const AsyncData(Unauthenticated(reason: SignedOutReason.sessionExpired));
    }
  }
}

final authControllerProvider = AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

final currentUserProvider = Provider<User?>((ref) {
  return switch (ref.watch(authControllerProvider).value) {
    Authenticated(:final user) => user,
    _ => null,
  };
});

/// Rebuilds dependants only when the signed-in account changes.
final currentUserIdProvider = Provider<String?>((ref) => ref.watch(currentUserProvider)?.id);
