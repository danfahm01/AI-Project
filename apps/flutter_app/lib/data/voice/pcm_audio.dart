import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../domain/entities/user_preferences.dart';

/// Microphone capture as raw 16-bit little-endian mono PCM (implemented with
/// `package:record` in `record_pcm_capture.dart`).
abstract interface class PcmCapture {
  /// Asks for microphone access and starts capturing.
  /// Throws `MicrophoneUnavailable` (see `realtime_link.dart`).
  Future<Stream<Uint8List>> start({required int sampleRate, required AudioSettings audio});

  Future<void> stop();
}

/// Plays raw 16-bit little-endian mono PCM as it arrives (implemented with
/// `package:flutter_soloud` in `soloud_pcm_playback.dart`).
abstract interface class PcmPlayback {
  Future<void> open({required int sampleRate});

  void add(Uint8List pcm);

  /// Drops everything queued (the user interrupted).
  Future<void> clear();

  Future<void> close();
}

/// A bidirectional message socket (JSON text out; text or binary frames in).
abstract interface class LiveSocket {
  /// Incoming frames: `String` or `List<int>`. Completes when the socket closes.
  Stream<Object?> get messages;

  int? get closeCode;
  String? get closeReason;

  void send(String text);

  Future<void> close();
}

typedef LiveSocketConnector = Future<LiveSocket> Function(Uri uri);

/// [LiveSocket] over `package:web_socket_channel` (all platforms, including web).
class WebSocketLiveSocket implements LiveSocket {
  WebSocketLiveSocket._(this._channel);

  final WebSocketChannel _channel;

  static Future<LiveSocket> connect(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;
    return WebSocketLiveSocket._(channel);
  }

  @override
  Stream<Object?> get messages => _channel.stream;

  @override
  int? get closeCode => _channel.closeCode;

  @override
  String? get closeReason => _channel.closeReason;

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close() async => _channel.sink.close();
}

/// Root-mean-square level of 16-bit little-endian PCM, in [0, 1].
double pcm16Level(Uint8List pcm) {
  final samples = pcm.length ~/ 2;
  if (samples == 0) return 0;
  final data = ByteData.sublistView(pcm);
  var sum = 0.0;
  for (var i = 0; i < samples; i++) {
    final value = data.getInt16(i * 2, Endian.little) / 32768.0;
    sum += value * value;
  }
  return math.sqrt(sum / samples).clamp(0.0, 1.0);
}

/// Playing time of [bytes] of 16-bit mono PCM at [sampleRate].
Duration pcm16Duration(int bytes, int sampleRate) =>
    Duration(microseconds: (bytes ~/ 2) * Duration.microsecondsPerSecond ~/ sampleRate);

/// Sample rate from a mime type such as `audio/pcm;rate=16000`.
int? sampleRateOf(String? mimeType) {
  final match = RegExp(r'rate=(\d+)').firstMatch(mimeType ?? '');
  return match == null ? null : int.tryParse(match.group(1)!);
}
