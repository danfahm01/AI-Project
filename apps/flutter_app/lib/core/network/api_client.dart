import 'package:dio/dio.dart';

import '../storage/token_storage.dart';
import 'api_exception.dart';

/// HTTP client for the backend's `/api/v1` API.
///
/// * Attaches the access token to every request (unless `skipAuth`).
/// * On a 401, refreshes the token pair once and retries the request.
/// * Refreshes are single-flight: the backend treats reuse of a rotated refresh
///   token as theft and revokes the session, so concurrent 401s must share one refresh.
/// * Converts every failure into an [ApiException].
class ApiClient {
  ApiClient({
    required String baseUrl,
    required TokenStorage tokenStorage,
    Dio? dio,
    Dio? refreshDio,
    this.onSessionExpired,
  }) : _tokens = tokenStorage,
       dio = dio ?? Dio(_defaultOptions(baseUrl)),
       _refreshDio = refreshDio ?? Dio(_defaultOptions(baseUrl)) {
    this.dio.interceptors.add(InterceptorsWrapper(onRequest: _onRequest, onError: _onError));
  }

  static BaseOptions _defaultOptions(String baseUrl) => BaseOptions(
    baseUrl: baseUrl,
    connectTimeout: const Duration(seconds: 10),
    sendTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
    contentType: Headers.jsonContentType,
    responseType: ResponseType.json,
  );

  static const _skipAuthKey = 'skipAuth';
  static const _retriedKey = 'retriedAfterRefresh';

  final Dio dio;
  final Dio _refreshDio;
  final TokenStorage _tokens;

  /// Called when the refresh token is rejected and the user must sign in again.
  void Function()? onSessionExpired;

  Future<AuthTokens?>? _refreshInFlight;

  // ---------------------------------------------------------------------------
  // JSON helpers
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getJson(String path, {Map<String, dynamic>? query}) => _guard(() async {
    final response = await dio.get<Map<String, dynamic>>(path, queryParameters: query);
    return response.data ?? const {};
  });

  Future<Map<String, dynamic>> postJson(String path, {Object? body, bool skipAuth = false}) => _guard(() async {
    final response = await dio.post<Map<String, dynamic>>(
      path,
      data: body ?? const <String, dynamic>{},
      options: Options(extra: {_skipAuthKey: skipAuth}),
    );
    return response.data ?? const {};
  });

  Future<Map<String, dynamic>> patchJson(String path, {required Object body}) => _guard(() async {
    final response = await dio.patch<Map<String, dynamic>>(path, data: body);
    return response.data ?? const {};
  });

  Future<void> postNoContent(String path, {Object? body, bool skipAuth = false}) => _guard(() async {
    await dio.post<void>(
      path,
      data: body,
      options: Options(extra: {_skipAuthKey: skipAuth}),
    );
  });

  Future<void> delete(String path) => _guard(() async {
    await dio.delete<void>(path);
  });

  /// Multipart upload. [onProgress] receives the fraction sent (0..1).
  Future<Map<String, dynamic>> postMultipart(
    String path, {
    required FormData Function() form,
    void Function(double progress)? onProgress,
    CancelToken? cancelToken,
  }) => _guard(() async {
    final response = await dio.post<Map<String, dynamic>>(
      path,
      // A FormData can be sent once; a builder lets a retry after a token refresh resend it.
      data: form(),
      cancelToken: cancelToken,
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: const Duration(minutes: 5),
        extra: {_formKey: form},
      ),
      onSendProgress: onProgress == null ? null : (sent, total) => onProgress(total > 0 ? sent / total : 0),
    );
    return response.data ?? const {};
  });

  /// Raw bytes (e.g. an attachment for a thumbnail).
  Future<List<int>> getBytes(String path) => _guard(() async {
    final response = await dio.get<List<int>>(path, options: Options(responseType: ResponseType.bytes));
    return response.data ?? const [];
  });

  static const _formKey = 'formBuilder';

  /// GET an absolute URL outside `/api/v1` (e.g. health checks) without auth.
  Future<Map<String, dynamic>> getAbsolute(String url) => _guard(() async {
    final response = await dio.get<Map<String, dynamic>>(
      url,
      options: Options(extra: {_skipAuthKey: true}, validateStatus: (status) => status != null && status < 600),
    );
    return response.data ?? const {};
  });

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }

  // ---------------------------------------------------------------------------
  // Auth handling
  // ---------------------------------------------------------------------------

  Future<void> _onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (options.extra[_skipAuthKey] != true) {
      final tokens = await _tokens.read();
      if (tokens != null) {
        options.headers['Authorization'] = 'Bearer ${tokens.accessToken}';
      }
    }
    handler.next(options);
  }

  Future<void> _onError(DioException error, ErrorInterceptorHandler handler) async {
    final request = error.requestOptions;
    final canRefresh =
        error.response?.statusCode == 401 && request.extra[_skipAuthKey] != true && request.extra[_retriedKey] != true;
    if (!canRefresh) {
      handler.next(error);
      return;
    }

    final refreshed = await refreshTokens();
    if (refreshed == null) {
      handler.next(error);
      return;
    }

    request.extra[_retriedKey] = true;
    // A multipart body is consumed by the first attempt: build a fresh one.
    if (request.extra[_formKey] case final FormData Function() form) request.data = form();
    try {
      handler.resolve(await dio.fetch<dynamic>(request));
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  /// Exchanges the stored refresh token for a new pair. Returns `null` if
  /// there is no session or the refresh failed.
  Future<AuthTokens?> refreshTokens() => _refreshInFlight ??= _refresh().whenComplete(() => _refreshInFlight = null);

  Future<AuthTokens?> _refresh() async {
    final current = await _tokens.read();
    if (current == null) return null;
    try {
      final response = await _refreshDio.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refresh_token': current.refreshToken},
      );
      final tokens = AuthTokens.fromJson(response.data!);
      await _tokens.write(tokens);
      return tokens;
    } on DioException catch (error) {
      if (error.response?.statusCode == 401) {
        await _tokens.clear();
        onSessionExpired?.call();
      }
      // Network failures keep the session: the original request fails and can be retried.
      return null;
    }
  }
}
