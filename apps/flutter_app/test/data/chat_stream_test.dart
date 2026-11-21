import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/core/network/api_client.dart';
import 'package:voice_assistant/core/network/api_exception.dart';
import 'package:voice_assistant/core/storage/token_storage.dart';
import 'package:voice_assistant/data/realtime/chat_event_parser.dart';
import 'package:voice_assistant/data/realtime/websocket_chat_stream.dart';
import 'package:voice_assistant/domain/chat/chat_stream.dart';
import 'package:voice_assistant/domain/entities/chat_message.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Map<String, dynamic> messageJson({String id = 'm1', String role = 'assistant', String status = 'streaming'}) => {
  'id': id,
  'conversation_id': 'c1',
  'seq': 2,
  'role': role,
  'content': '',
  'status': status,
  'provider': 'openai',
  'model': 'gpt-6-luna',
  'usage': null,
  'audio_metadata': null,
  'metadata': null,
  'created_at': '2026-11-20T10:00:00Z',
  'updated_at': '2026-11-20T10:00:00Z',
  'edited_at': null,
};

/// Minimal in-memory WebSocket: frames sent by the client are recorded and
/// answered by [server]; [push] simulates server frames; [drop] closes it.
class FakeSocket implements WebSocketChannel {
  FakeSocket(this.server);

  final void Function(FakeSocket socket, Map<String, dynamic> frame) server;
  final _incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];

  void push(Map<String, dynamic> frame) => _incoming.add(jsonEncode(frame));

  Future<void> drop() => _incoming.close();

  @override
  Future<void> get ready => Future.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  late final WebSocketSink sink = _FakeSink(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this.socket);

  final FakeSocket socket;

  @override
  void add(dynamic data) {
    final frame = jsonDecode(data as String) as Map<String, dynamic>;
    socket.sent.add(frame);
    socket.server(socket, frame);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeApiClient extends ApiClient {
  FakeApiClient(TokenStorage storage, {this.refreshed})
    : _storage = storage,
      super(baseUrl: 'http://api.test', tokenStorage: storage);

  final TokenStorage _storage;
  final AuthTokens? refreshed;
  int refreshCalls = 0;

  @override
  Future<AuthTokens?> refreshTokens() async {
    refreshCalls++;
    if (refreshed != null) await _storage.write(refreshed!);
    return refreshed;
  }
}

void main() {
  group('chat event parser', () {
    test('parses the streaming lifecycle', () {
      final started = parseChatEvent({
        'type': 'response.started',
        'request_id': 'r1',
        'conversation_id': 'c1',
        'message': messageJson(),
      });
      expect(started, isA<ResponseStartedEvent>().having((e) => e.message.status, 'status', MessageStatus.streaming));

      final delta = parseChatEvent({
        'type': 'response.delta',
        'request_id': 'r1',
        'conversation_id': 'c1',
        'message_id': 'm1',
        'delta': 'Hel',
      });
      expect(delta, isA<ResponseDeltaEvent>().having((e) => e.delta, 'delta', 'Hel'));

      final failed = parseChatEvent({
        'type': 'response.failed',
        'request_id': 'r1',
        'conversation_id': 'c1',
        'message': {
          ...messageJson(status: 'error'),
          'metadata': {
            'error': {'code': 'provider_rate_limited', 'message': 'Busy'},
          },
        },
        'error': {'code': 'provider_rate_limited', 'message': 'Busy'},
      });
      expect(
        failed,
        isA<ResponseFailedEvent>()
            .having((e) => e.error.code, 'code', 'provider_rate_limited')
            .having((e) => e.message?.errorMessage, 'errorMessage', 'Busy'),
      );
    });

    test('protocol errors and unknown frames', () {
      expect(
        parseChatEvent({
          'type': 'error',
          'request_id': 'r2',
          'error': {'code': 'busy', 'message': 'Wait'},
        }),
        isA<CommandRejectedEvent>().having((e) => e.requestId, 'requestId', 'r2'),
      );
      expect(parseChatEvent({'type': 'pong'}), isNull);
      expect(parseChatEvent({'type': 'some.future.event'}), isNull);
    });
  });

  group('WebSocketChatStream', () {
    test('derives the socket URL from the API base', () {
      expect(
        WebSocketChatStream.urlFromApiBase('http://localhost:8000/api/v1').toString(),
        'ws://localhost:8000/api/v1/chat/ws',
      );
      expect(
        WebSocketChatStream.urlFromApiBase('https://api.example.com/api/v1').toString(),
        'wss://api.example.com/api/v1/chat/ws',
      );
    });

    test('authenticates with the first frame, then sends commands and emits events', () async {
      final storage = MemoryTokenStorage(const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'));
      late FakeSocket socket;
      final stream = WebSocketChatStream(
        url: Uri.parse('ws://test/api/v1/chat/ws'),
        tokens: storage,
        api: FakeApiClient(storage),
        connector: (_) => socket = FakeSocket((s, frame) {
          if (frame['type'] == 'auth') s.push({'type': 'auth.ok', 'user_id': 'u1'});
        }),
      );
      addTearDown(stream.close);

      final events = <ChatEvent>[];
      stream.events.listen(events.add);
      await stream.ensureConnected();
      expect(stream.status, ChatConnectionStatus.connected);
      expect(socket.sent.first, {'type': 'auth', 'token': 'access-1'});

      await stream.sendMessage(requestId: 'r0', conversationId: 'c1', content: '', attachmentIds: ['a1', 'a2']);
      expect(socket.sent.last, {
        'type': 'message.send',
        'request_id': 'r0',
        'conversation_id': 'c1',
        'content': '',
        'attachment_ids': ['a1', 'a2'],
      });
      await stream.sendMessage(requestId: 'r1', conversationId: 'c1', content: 'Hi');
      expect(socket.sent.last, {'type': 'message.send', 'request_id': 'r1', 'conversation_id': 'c1', 'content': 'Hi'});

      socket.push({
        'type': 'response.delta',
        'request_id': 'r1',
        'conversation_id': 'c1',
        'message_id': 'm1',
        'delta': 'Yo',
      });
      await pumpEventQueue();
      expect(events.single, isA<ResponseDeltaEvent>());
    });

    test('an expired token is refreshed once before giving up', () async {
      final storage = MemoryTokenStorage(const AuthTokens(accessToken: 'old', refreshToken: 'r'));
      final api = FakeApiClient(
        storage,
        refreshed: const AuthTokens(accessToken: 'new', refreshToken: 'r2'),
      );
      final sockets = <FakeSocket>[];
      final stream = WebSocketChatStream(
        url: Uri.parse('ws://test'),
        tokens: storage,
        api: api,
        connector: (_) {
          final socket = FakeSocket((s, frame) {
            if (frame['type'] != 'auth') return;
            s.push(
              frame['token'] == 'new'
                  ? {'type': 'auth.ok'}
                  : {
                      'type': 'auth.failed',
                      'error': {'code': 'token_expired', 'message': 'expired'},
                    },
            );
          });
          sockets.add(socket);
          return socket;
        },
      );
      addTearDown(stream.close);

      await stream.ensureConnected();
      expect(api.refreshCalls, 1);
      expect(sockets.map((s) => s.sent.first['token']), ['old', 'new']);
      expect(stream.status, ChatConnectionStatus.connected);
    });

    test('a rejected session surfaces as unauthorized', () async {
      final storage = MemoryTokenStorage(const AuthTokens(accessToken: 'bad', refreshToken: 'r'));
      final stream = WebSocketChatStream(
        url: Uri.parse('ws://test'),
        tokens: storage,
        api: FakeApiClient(storage), // refresh fails
        connector: (_) => FakeSocket((s, frame) {
          s.push({
            'type': 'auth.failed',
            'error': {'code': 'invalid_token', 'message': 'nope'},
          });
        }),
      );
      addTearDown(stream.close);

      await expectLater(
        stream.ensureConnected(),
        throwsA(isA<ApiException>().having((e) => e.isUnauthorized, 'unauthorized', isTrue)),
      );
      expect(stream.status, ChatConnectionStatus.disconnected);
    });

    test('a dropped connection reconnects automatically', () async {
      final storage = MemoryTokenStorage(const AuthTokens(accessToken: 'a', refreshToken: 'r'));
      final sockets = <FakeSocket>[];
      final stream = WebSocketChatStream(
        url: Uri.parse('ws://test'),
        tokens: storage,
        api: FakeApiClient(storage),
        connector: (_) {
          final socket = FakeSocket((s, frame) {
            if (frame['type'] == 'auth') s.push({'type': 'auth.ok'});
          });
          sockets.add(socket);
          return socket;
        },
      );
      addTearDown(stream.close);
      final statuses = <ChatConnectionStatus>[];
      stream.statusChanges.listen(statuses.add);

      await stream.ensureConnected();
      await sockets.single.drop();
      await pumpEventQueue();
      expect(stream.status, ChatConnectionStatus.reconnecting);

      await Future<void>.delayed(const Duration(milliseconds: 1200)); // first backoff is 1 s
      expect(stream.status, ChatConnectionStatus.connected);
      expect(sockets, hasLength(2));
      expect(statuses, [
        ChatConnectionStatus.connecting,
        ChatConnectionStatus.connected,
        ChatConnectionStatus.reconnecting,
        ChatConnectionStatus.connected,
      ]);
    });
  });
}
