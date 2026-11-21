import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../../domain/entities/user_preferences.dart';
import 'pcm_audio.dart';
import 'realtime_link.dart';

/// Microphone capture with `package:record` (v7.2): `startStream` with
/// `AudioEncoder.pcm16bits` streams raw PCM on Android, iOS, macOS, Windows,
/// Linux (needs `parecord`) and the web.
class RecordPcmCapture implements PcmCapture {
  AudioRecorder? _recorder;

  @override
  Future<Stream<Uint8List>> start({required int sampleRate, required AudioSettings audio}) async {
    final recorder = _recorder = AudioRecorder();
    final bool granted;
    try {
      granted = await recorder.hasPermission();
    } catch (error) {
      throw MicrophoneUnavailable(denied: true, detail: '$error');
    }
    if (!granted) throw const MicrophoneUnavailable(denied: true);

    try {
      return await recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          echoCancel: audio.echoCancellation,
          noiseSuppress: audio.noiseSuppression,
          autoGain: audio.autoGainControl,
          // The voice-communication source applies the platform's echo canceller.
          androidConfig: AndroidRecordConfig(
            audioSource: audio.echoCancellation ? AndroidAudioSource.voiceCommunication : AndroidAudioSource.mic,
          ),
        ),
      );
    } catch (error) {
      debugPrint('Microphone capture failed: $error');
      final text = '$error';
      final denied = text.contains('NotAllowed') || text.toLowerCase().contains('permission');
      throw MicrophoneUnavailable(denied: denied, detail: text);
    }
  }

  @override
  Future<void> stop() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder == null) return;
    try {
      await recorder.stop();
    } finally {
      await recorder.dispose();
    }
  }
}
