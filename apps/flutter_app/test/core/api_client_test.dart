import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/core/network/api_client.dart';
import 'package:voice_assistant/core/network/api_exception.dart';
import 'package:voice_assistant/core/storage/token_storage.dart';

typedef Handler = Future<ResponseBody> Function(RequestOptions request);

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final Handler handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody errorEnvelope(int status, String code) => json(status, {
  'error': {'code': code, 'message': 'msg for $code', 'details': null, 'request_id': 'req-123'},
});

({ApiClient client, FakeAdapter adapter, MemoryTokenStorage tokens, List<String> expired}) build(
  Handler handler, {
  AuthTokens? tokens,
}) {
  final adapter = FakeAdapter(handler);
  final storage = MemoryTokenStorage(tokens);
  final expired = <String>[];
  Dio dio() => Dio(BaseOptions(baseUrl: 'http://api.test/api/v1'))..httpClientAdapter = adapter;
  final client = ApiClient(
    baseUrl: 'http://api.test/api/v1',
    tokenStorage: storage,
    dio: dio(),
    refreshDio: dio(),
    onSessionExpired: () => expired.add('expired'),
  );
  return (client: client, adapter: adapter, tokens: storage, expired: expired);
}

String? bearer(RequestOptions request) => request.headers['Authorization'] as String?;

void main() {
  const oldTokens = AuthTokens(accessToken: 'old-access', refreshToken: 'old-refresh');

  test('attaches the bearer token, but not to skipAuth requests', () async {
    final setup = build((_) async => json(200, {'ok': true}), tokens: oldTokens);
    await setup.client.getJson('/users/me');
    await setup.client.postJson('/auth/login', body: {}, skipAuth: true);
    expect(bearer(setup.adapter.requests[0]), 'Bearer old-access');
    expect(bearer(setup.adapter.requests[1]), isNull);
  });

  test('maps the error envelope into ApiException', () async {
    final setup = build((_) async => errorEnvelope(409, 'email_taken'));
    await expectLater(
      setup.client.postJson('/auth/register', body: {}, skipAuth: true),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'status', 409)
            .having((e) => e.code, 'code', 'email_taken')
            .having((e) => e.requestId, 'requestId', 'req-123'),
      ),
    );
  });

  test('network failures become network_error', () async {
    final setup = build(
      (request) async => throw DioException.connectionError(requestOptions: request, reason: 'refused'),
    );
    await expectLater(
      setup.client.getJson('/conversations'),
      throwsA(isA<ApiException>().having((e) => e.isNetworkError, 'isNetworkError', isTrue)),
    );
  });

  test('validation errors produce a readable message', () {
    const error = ApiException(
      code: 'validation_error',
      message: 'Request validation failed',
      statusCode: 422,
      details: [
        {
          'loc': ['body', 'password'],
          'msg': 'String should have at least 8 characters',
          'type': 'string_too_short',
        },
      ],
    );
    expect(error.userMessage, 'password: String should have at least 8 characters');
  });

  test('concurrent 401s trigger exactly one refresh, then requests are retried', () async {
    var refreshCalls = 0;
    final refreshGate = Completer<void>();
    final setup = build((request) async {
      if (request.path == '/auth/refresh') {
        refreshCalls++;
        await refreshGate.future;
        expect(request.data, {'refresh_token': 'old-refresh'});
        return json(200, {
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'token_type': 'bearer',
          'expires_in': 900,
        });
      }
      return bearer(request) == 'Bearer new-access'
          ? json(200, {'path': request.path})
          : errorEnvelope(401, 'token_expired');
    }, tokens: oldTokens);

    final first = setup.client.getJson('/a');
    final second = setup.client.getJson('/b');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    refreshGate.complete();

    expect((await first)['path'], '/a');
    expect((await second)['path'], '/b');
    expect(refreshCalls, 1);
    expect((await setup.tokens.read())?.refreshToken, 'new-refresh');
  });

  test('a rejected refresh clears the session and reports expiry', () async {
    final setup = build((request) async {
      if (request.path == '/auth/refresh') return errorEnvelope(401, 'refresh_token_revoked');
      return errorEnvelope(401, 'token_expired');
    }, tokens: oldTokens);

    await expectLater(
      setup.client.getJson('/users/me'),
      throwsA(isA<ApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)),
    );
    expect(await setup.tokens.read(), isNull);
    expect(setup.expired, ['expired']);
  });

  test('a refresh that fails on the network keeps the session', () async {
    final setup = build((request) async {
      if (request.path == '/auth/refresh') {
        throw DioException.connectionError(requestOptions: request, reason: 'offline');
      }
      return errorEnvelope(401, 'token_expired');
    }, tokens: oldTokens);

    await expectLater(setup.client.getJson('/users/me'), throwsA(isA<ApiException>()));
    expect(await setup.tokens.read(), isNotNull);
    expect(setup.expired, isEmpty);
  });

  test('a request is retried at most once', () async {
    final setup = build((request) async {
      if (request.path == '/auth/refresh') {
        return json(200, {'access_token': 'new-access', 'refresh_token': 'new-refresh'});
      }
      return errorEnvelope(401, 'invalid_token'); // even the new token is rejected
    }, tokens: oldTokens);

    await expectLater(setup.client.getJson('/users/me'), throwsA(isA<ApiException>()));
    expect(setup.adapter.requests.where((r) => r.path == '/users/me'), hasLength(2));
  });
}
