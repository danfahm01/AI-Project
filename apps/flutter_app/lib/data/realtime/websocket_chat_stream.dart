import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/storage/token_storage.dart';
import '../../domain/chat/chat_stream.dart';
import 'chat_event_parser.dart';

typedef WebSocketConnector = WebSocketChannel Function(Uri url);

/// [ChatStream] over the backend's `/api/v1/chat/ws` endpoint.
///
/// * The first frame authenticates with the access token (browsers cannot set
///   WebSocket headers, and tokens in URLs leak into logs). An expired token
///   is refreshed once through [ApiClient.refreshTokens].
/// * Dropped connections are re-established with exponential backoff.
/// * A ping every 25 s keeps idle connections alive through proxies.
class WebSocketChatStream implements ChatStream {
  WebSocketChatStream({
    required this.url,
    required this.tokens,
    required this.api,
    WebSocketConnector? connector,
    this.authTimeout = const Duration(seconds: 10),
    this.pingInterval = const Duration(seconds: 25),
  }) : _connector = connector ?? WebSocketChannel.connect;

  /// Derives `ws(s)://host/api/v1/chat/ws` from the REST base URL.
  static Uri urlFromApiBase(String apiV1Url) {
    final base = Uri.parse(apiV1Url);
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '${base.path}/chat/ws');
  }

  final Uri url;
  final Duration authTimeout;
  final Duration pingInterval;
  final TokenStorage tokens;
  final ApiClient api;
  final WebSocketConnector _connector;

  final _events = StreamController<ChatEvent>.broadcast();
  final _status = StreamController<ChatConnectionStatus>.broadcast();
  ChatConnectionStatus _current = ChatConnectionStatus.disconnected;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _connecting;
  Completer<Map<String, dynamic>>? _authReply;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _closed = false;

  @override
  Stream<ChatEvent> get events => _events.stream;

  @override
  ChatConnectionStatus get status => _current;

  @override
  Stream<ChatConnectionStatus> get statusChanges => _status.stream;

  void _setStatus(ChatConnectionStatus value) {
    if (_current == value) return;
    _current = value;
    if (!_status.isClosed) _status.add(value);
  }

  @override
  Future<void> ensureConnected() {
    if (_closed) return Future.error(StateError('Chat stream is closed'));
    if (_current == ChatConnectionStatus.connected) return Future.value();
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    _reconnectTimer?.cancel();
    if (_current != ChatConnectionStatus.reconnecting) _setStatus(ChatConnectionStatus.connecting);
    try {
      for (var attempt = 0; ; attempt++) {
        final reply = await _openAndAuthenticate();
        if (reply['type'] == 'auth.ok') break;

        final code = (reply['error'] as Map?)?['code']?.toString() ?? 'unauthorized';
        final canRefresh = attempt == 0 && (code == 'token_expired' || code == 'invalid_token');
        if (canRefresh && await api.refreshTokens() != null) continue;
        throw ApiException(code: code, message: 'Your session has expired. Please sign in again.', statusCode: 401);
      }
    } catch (error) {
      await _dropChannel();
      _setStatus(ChatConnectionStatus.disconnected);
      if (error is ApiException) rethrow;
      throw const ApiException(
        code: ApiException.networkErrorCode,
        message: "Can't reach the chat server. Check your connection and try again.",
      );
    }
    _reconnectAttempt = 0;
    _setStatus(ChatConnectionStatus.connected);
    _pingTimer = Timer.periodic(pingInterval, (_) => _send({'type': 'ping'}));
  }

  Future<Map<String, dynamic>> _openAndAuthenticate() async {
    await _dropChannel();
    final stored = await tokens.read();
    if (stored == null) {
      throw const ApiException(code: 'unauthorized', message: 'Please sign in again.', statusCode: 401);
    }
    final channel = _connector(url);
    _channel = channel;
    await channel.ready;

    final authReply = _authReply = Completer<Map<String, dynamic>>();
    _subscription = channel.stream.listen(
      _onFrame,
      onError: (Object _) => _onClosed(channel),
      onDone: () => _onClosed(channel),
      cancelOnError: true,
    );
    channel.sink.add(jsonEncode({'type': 'auth', 'token': stored.accessToken}));
    return authReply.future.timeout(authTimeout);
  }

  void _onFrame(dynamic raw) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return; // ignore malformed frames
    }
    final pendingAuth = _authReply;
    if (pendingAuth != null && !pendingAuth.isCompleted) {
      if (json['type'] == 'auth.ok' || json['type'] == 'auth.failed') pendingAuth.complete(json);
      return;
    }
    final event = parseChatEvent(json);
    if (event != null && !_events.isClosed) _events.add(event);
  }

  void _onClosed(WebSocketChannel channel) {
    if (!identical(channel, _channel)) return; // a channel we already replaced
    final pendingAuth = _authReply;
    if (pendingAuth != null && !pendingAuth.isCompleted) {
      pendingAuth.completeError(StateError('closed during authentication'));
    }
    _pingTimer?.cancel();
    _channel = null;
    if (_closed || _current != ChatConnectionStatus.connected) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _setStatus(ChatConnectionStatus.reconnecting);
    final seconds = math.min(30, 1 << math.min(_reconnectAttempt, 5));
    _reconnectAttempt++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: seconds), () async {
      if (_closed) return;
      try {
        await ensureConnected();
      } on ApiException catch (error) {
        if (error.isUnauthorized) return; // needs a new sign-in; stay disconnected
        if (!_closed) _scheduleReconnect();
      }
    });
  }

  Future<void> _dropChannel() async {
    _pingTimer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
  }

  void _send(Map<String, Object?> command) {
    final channel = _channel;
    if (channel == null) throw StateError('not connected');
    channel.sink.add(jsonEncode(command));
  }

  Future<void> _sendCommand(Map<String, Object?> command) async {
    await ensureConnected();
    try {
      _send(command);
    } on StateError {
      throw const ApiException(code: ApiException.networkErrorCode, message: 'The connection was lost. Try again.');
    }
  }

  @override
  Future<void> sendMessage({
    required String requestId,
    required String conversationId,
    required String content,
    List<String> attachmentIds = const [],
  }) => _sendCommand({
    'type': 'message.send',
    'request_id': requestId,
    'conversation_id': conversationId,
    'content': content,
    if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
  });

  @override
  Future<void> regenerate({required String requestId, required String conversationId}) =>
      _sendCommand({'type': 'response.regenerate', 'request_id': requestId, 'conversation_id': conversationId});

  @override
  Future<void> cancel(String requestId) => _sendCommand({'type': 'response.cancel', 'request_id': requestId});

  @override
  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    await _dropChannel();
    _setStatus(ChatConnectionStatus.disconnected);
    await _events.close();
    await _status.close();
  }
}
