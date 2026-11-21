import 'package:dio/dio.dart';

/// Every failed backend call surfaces as an [ApiException] carrying the
/// backend's error envelope: `{"error": {"code", "message", "details", "request_id"}}`.
class ApiException implements Exception {
  const ApiException({required this.code, required this.message, this.statusCode, this.requestId, this.details});

  factory ApiException.fromDio(DioException error) {
    final response = error.response;
    if (response == null) {
      return ApiException(
        code: networkErrorCode,
        message: switch (error.type) {
          DioExceptionType.connectionTimeout ||
          DioExceptionType.sendTimeout ||
          DioExceptionType.receiveTimeout => 'The server took too long to respond.',
          DioExceptionType.cancel => 'The request was cancelled.',
          _ => "Can't reach the server. Check your connection and try again.",
        },
      );
    }

    final data = response.data;
    if (data is Map && data['error'] is Map) {
      final envelope = data['error'] as Map;
      return ApiException(
        statusCode: response.statusCode,
        code: envelope['code']?.toString() ?? 'http_error',
        message: envelope['message']?.toString() ?? 'Request failed.',
        requestId: envelope['request_id']?.toString(),
        details: envelope['details'],
      );
    }
    return ApiException(
      statusCode: response.statusCode,
      code: 'http_error',
      message: 'Request failed (HTTP ${response.statusCode}).',
    );
  }

  static const networkErrorCode = 'network_error';

  final String code;
  final String message;
  final int? statusCode;
  final String? requestId;
  final Object? details;

  bool get isNetworkError => code == networkErrorCode;
  bool get isUnauthorized => statusCode == 401;
  bool get isNotFound => statusCode == 404;

  /// A message suitable for showing to the user. Validation errors are
  /// rewritten from the first field error, e.g. "password: String should have at least 8 characters".
  String get userMessage {
    final fieldErrors = details;
    if (code == 'validation_error' && fieldErrors is List && fieldErrors.isNotEmpty) {
      final first = fieldErrors.first;
      if (first is Map) {
        final loc = (first['loc'] as List?)?.where((part) => part != 'body').join('.');
        final msg = first['msg']?.toString() ?? message;
        return (loc == null || loc.isEmpty) ? msg : '$loc: $msg';
      }
    }
    return message;
  }

  @override
  String toString() => 'ApiException(${statusCode ?? '-'}, $code): $message';
}
