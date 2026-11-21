import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';

import 'pcm_audio.dart';

/// Streaming PCM playback with `package:mp_audio_stream` (v0.3): miniaudio on
/// Android, iOS, macOS, Windows and Linux; Web Audio (AudioWorklet) on the web.
///
/// The stream plays float32 samples from a fixed-size buffer and drops input
/// when that buffer is full, while replies arrive faster than real time. Chunks
/// are therefore queued here and fed at most [lead] ahead of playback.
/// Clearing re-creates the stream, which drops everything queued.
class StreamPcmPlayback implements PcmPlayback {
  StreamPcmPlayback({
    this.lead = const Duration(seconds: 2),
    this.bufferLength = const Duration(seconds: 5),
    this.feedInterval = const Duration(milliseconds: 100),
  });

  /// How far ahead of playback audio is handed to the device buffer.
  final Duration lead;
  final Duration bufferLength;
  final Duration feedInterval;

  /// One per app: the native side is a single global stream, and on the web
  /// each instance would load the worklet script again.
  static final AudioStream _stream = getAudioStream();

  final _queue = Queue<Float32List>();
  Timer? _feeder;
  DateTime _bufferedUntil = DateTime.now();
  int _sampleRate = 24000;
  bool _open = false;

  @override
  Future<void> open({required int sampleRate}) async {
    _sampleRate = sampleRate;
    _start();
    _open = true;
    _feeder = Timer.periodic(feedInterval, (_) => _feed());
  }

  void _start() {
    final result = _stream.init(
      bufferMilliSec: bufferLength.inMilliseconds,
      waitingBufferMilliSec: 60,
      channels: 1,
      sampleRate: _sampleRate,
      fadeOnExhaust: true, // no click when a reply pauses or ends
    );
    if (result != 0) throw StateError('Audio output could not start (code $result)');
    // Web: allowed because the session was started by a tap.
    _stream.resume();
    _bufferedUntil = DateTime.now();
  }

  @override
  void add(Uint8List pcm) {
    if (!_open || pcm.length < 2) return;
    _queue.add(pcm16ToFloat32(pcm));
    _feed();
  }

  void _feed() {
    final now = DateTime.now();
    if (_bufferedUntil.isBefore(now)) _bufferedUntil = now;
    while (_queue.isNotEmpty && _bufferedUntil.difference(now) < lead) {
      final samples = _queue.removeFirst();
      try {
        _stream.push(samples);
      } catch (error) {
        debugPrint('Audio playback failed: $error');
      }
      _bufferedUntil = _bufferedUntil.add(
        Duration(microseconds: samples.length * Duration.microsecondsPerSecond ~/ _sampleRate),
      );
    }
  }

  @override
  Future<void> clear() async {
    _queue.clear();
    if (!_open) return;
    try {
      _start();
    } catch (error) {
      debugPrint('Could not reset playback: $error');
    }
  }

  @override
  Future<void> close() async {
    _feeder?.cancel();
    _feeder = null;
    _queue.clear();
    if (!_open) return;
    _open = false;
    try {
      _stream.uninit();
    } catch (error) {
      debugPrint('Could not stop playback: $error');
    }
  }
}

/// 16-bit little-endian PCM to float samples in [-1, 1].
Float32List pcm16ToFloat32(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  final samples = Float32List(pcm.length ~/ 2);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}
