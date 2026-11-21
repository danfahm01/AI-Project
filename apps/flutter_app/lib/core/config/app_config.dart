import 'package:flutter/foundation.dart';

/// Runtime configuration. Override the backend at build/run time:
///
///     flutter run --dart-define=API_BASE_URL=https://api.example.com
///
/// On the web, a path such as `/` means "the server that serves this page"
/// (the production web image serves the app and proxies the API on one origin).
class AppConfig {
  const AppConfig({required this.apiBaseUrl});

  factory AppConfig.fromEnvironment() {
    const fromDefine = String.fromEnvironment('API_BASE_URL');
    return AppConfig(
      apiBaseUrl: resolveApiBaseUrl(fromDefine, isWeb: kIsWeb, platform: defaultTargetPlatform, pageUri: Uri.base),
    );
  }

  /// Server origin, e.g. `http://localhost:8000`.
  final String apiBaseUrl;

  String get apiV1Url => '$apiBaseUrl/api/v1';
  String get readinessUrl => '$apiBaseUrl/health/ready';

  /// The API base URL for a build-time [define] (empty when not given).
  @visibleForTesting
  static String resolveApiBaseUrl(
    String define, {
    required bool isWeb,
    required TargetPlatform platform,
    required Uri pageUri,
  }) {
    final value = define.trim();
    if (value.startsWith('/')) {
      if (!isWeb) {
        throw ArgumentError.value(define, 'API_BASE_URL', 'A path is only valid for web builds; use a full URL');
      }
      return _withoutTrailingSlash(pageUri.resolve(value).toString());
    }
    if (value.isNotEmpty) return _withoutTrailingSlash(value);
    // The Android emulator reaches the host machine through 10.0.2.2.
    if (!isWeb && platform == TargetPlatform.android) return 'http://10.0.2.2:8000';
    return 'http://localhost:8000';
  }

  static String _withoutTrailingSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}
