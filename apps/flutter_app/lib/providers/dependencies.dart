import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config/app_config.dart';
import '../core/network/api_client.dart';
import '../core/storage/token_storage.dart';
import '../data/attachments/attachment_picker.dart';
import '../data/realtime/websocket_chat_stream.dart';
import '../data/repositories/api_repositories.dart';
import '../data/voice/gemini_live_transport.dart';
import '../data/voice/openai_realtime_transport.dart';
import '../data/voice/pcm_audio.dart';
import '../data/voice/record_pcm_capture.dart';
import '../data/voice/stream_pcm_playback.dart';
import '../data/voice/webrtc_realtime_link.dart';
import '../domain/chat/chat_stream.dart';
import '../domain/repositories/repositories.dart';
import '../domain/voice/voice_transport.dart';
import 'auth_controller.dart';

/// Dependency graph. Tests override the repository providers with fakes.

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.fromEnvironment());

final tokenStorageProvider = Provider<TokenStorage>((ref) => SecureTokenStorage());

/// Device-local settings (theme). Overridden in `main()` with the loaded instance.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw StateError('sharedPreferencesProvider must be overridden at startup'),
);

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    baseUrl: ref.watch(appConfigProvider).apiV1Url,
    tokenStorage: ref.watch(tokenStorageProvider),
    onSessionExpired: () => ref.read(authControllerProvider.notifier).handleSessionExpired(),
  );
});

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => ApiAuthRepository(ref.watch(apiClientProvider), ref.watch(tokenStorageProvider)),
);

final conversationRepositoryProvider = Provider<ConversationRepository>(
  (ref) => ApiConversationRepository(ref.watch(apiClientProvider)),
);

final preferencesRepositoryProvider = Provider<PreferencesRepository>(
  (ref) => ApiPreferencesRepository(ref.watch(apiClientProvider)),
);

final providerCatalogRepositoryProvider = Provider<ProviderCatalogRepository>(
  (ref) => ApiProviderCatalogRepository(ref.watch(apiClientProvider)),
);

final serverStatusRepositoryProvider = Provider<ServerStatusRepository>(
  (ref) => ApiServerStatusRepository(ref.watch(apiClientProvider), ref.watch(appConfigProvider)),
);

final attachmentRepositoryProvider = Provider<AttachmentRepository>(
  (ref) => ApiAttachmentRepository(ref.watch(apiClientProvider), ref.watch(appConfigProvider)),
);

final attachmentPickerProvider = Provider<AttachmentPicker>((ref) => DeviceAttachmentPicker());

final voiceSessionRepositoryProvider = Provider<VoiceSessionRepository>(
  (ref) => ApiVoiceSessionRepository(ref.watch(apiClientProvider)),
);

/// Realtime voice transport per provider. Providers without a transport in this
/// app version return `null` and the voice screen says so.
final voiceTransportFactoryProvider = Provider<VoiceTransportFactory>((ref) {
  final sessions = ref.watch(voiceSessionRepositoryProvider);
  return (options) => switch (options.selection.provider.id) {
    'openai' => OpenAIRealtimeTransport(sessions: sessions, options: options, linkFactory: WebRtcRealtimeLink.new),
    'gemini' => GeminiLiveTransport(
      sessions: sessions,
      options: options,
      connector: WebSocketLiveSocket.connect,
      captureFactory: RecordPcmCapture.new,
      playbackFactory: StreamPcmPlayback.new,
    ),
    _ => null,
  };
});

/// Streaming chat channel. One instance per signed-in account: signing out
/// (or switching account) disposes it, closing the authenticated socket.
final chatStreamProvider = Provider<ChatStream>((ref) {
  ref.watch(currentUserIdProvider);
  final stream = WebSocketChatStream(
    url: WebSocketChatStream.urlFromApiBase(ref.watch(appConfigProvider).apiV1Url),
    tokens: ref.watch(tokenStorageProvider),
    api: ref.watch(apiClientProvider),
  );
  ref.onDispose(stream.close);
  return stream;
});

final chatConnectionStatusProvider = StreamProvider<ChatConnectionStatus>((ref) async* {
  final stream = ref.watch(chatStreamProvider);
  yield stream.status;
  yield* stream.statusChanges;
});
