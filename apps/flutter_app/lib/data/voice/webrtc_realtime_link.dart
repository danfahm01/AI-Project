import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../domain/entities/user_preferences.dart';
import 'realtime_link.dart';

/// [RealtimeLink] over WebRTC (`flutter_webrtc`): Android, iOS, macOS, Windows,
/// Linux and the web.
///
/// * The microphone track is sent to the peer; the peer's audio track plays
///   back automatically on native platforms. On the web an `RTCVideoRenderer`
///   attaches it to an (invisible) autoplay `<audio>` element.
/// * Events travel as JSON text on a data channel.
/// * Levels come from WebRTC statistics (`media-source` / `inbound-rtp` `audioLevel`).
class WebRtcRealtimeLink implements RealtimeLink {
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _states = StreamController<RealtimeLinkState>.broadcast();

  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  MediaStream? _microphone;
  RTCVideoRenderer? _webAudio;
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Stream<RealtimeLinkState> get states => _states.stream;

  void _emitState(RealtimeLinkState state) {
    if (!_states.isClosed) _states.add(state);
  }

  @override
  Future<void> connect({
    required Future<String> Function(String offerSdp) exchangeSdp,
    required String dataChannelLabel,
    required AudioSettings audio,
  }) async {
    _emitState(RealtimeLinkState.connecting);
    _microphone = await _openMicrophone(audio);

    final peer = _peer = await createPeerConnection({'sdpSemantics': 'unified-plan'});
    peer.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        if (!_closed) _emitState(RealtimeLinkState.failed);
      }
    };
    peer.onTrack = (event) async {
      if (!kIsWeb || event.streams.isEmpty) return;
      final renderer = _webAudio ??= RTCVideoRenderer();
      await renderer.initialize();
      renderer.srcObject = event.streams.first;
    };
    for (final track in _microphone!.getAudioTracks()) {
      await peer.addTrack(track, _microphone!);
    }

    final channel = _channel = await peer.createDataChannel(dataChannelLabel, RTCDataChannelInit());
    final opened = Completer<void>();
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen && !opened.isCompleted) {
        opened.complete();
        _emitState(RealtimeLinkState.open);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed && !_closed) {
        _emitState(RealtimeLinkState.failed);
      }
    };
    channel.onMessage = (message) {
      if (message.isBinary) return;
      try {
        final decoded = jsonDecode(message.text);
        if (decoded is Map<String, dynamic> && !_messages.isClosed) _messages.add(decoded);
      } on FormatException {
        // ignore malformed frames
      }
    };

    final offer = await peer.createOffer({});
    await peer.setLocalDescription(offer);
    final answer = await exchangeSdp(offer.sdp!);
    await peer.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
    await opened.future.timeout(const Duration(seconds: 15));

    // Phones: play through the loudspeaker rather than the earpiece.
    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {
        // Not critical: audio still plays through the default route.
      }
    }
  }

  static Future<MediaStream> _openMicrophone(AudioSettings audio) async {
    try {
      return await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': audio.echoCancellation,
          'noiseSuppression': audio.noiseSuppression,
          'autoGainControl': audio.autoGainControl,
        },
        'video': false,
      });
    } catch (error) {
      final text = error.toString().toLowerCase();
      final denied =
          text.contains('notallowed') ||
          text.contains('permission') ||
          text.contains('denied') ||
          text.contains('security');
      throw MicrophoneUnavailable(denied: denied, detail: error.toString());
    }
  }

  @override
  void send(Map<String, Object?> event) {
    final channel = _channel;
    if (channel == null || channel.state != RTCDataChannelState.RTCDataChannelOpen) return;
    channel.send(RTCDataChannelMessage(jsonEncode(event)));
  }

  @override
  void setMicrophoneEnabled(bool enabled) {
    for (final track in _microphone?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Future<({double input, double output})> levels() async {
    final peer = _peer;
    if (peer == null) return (input: 0.0, output: 0.0);
    var input = 0.0;
    var output = 0.0;
    for (final report in await peer.getStats()) {
      final values = report.values;
      final isAudio = values['kind'] == 'audio' || values['mediaType'] == 'audio';
      final level = values['audioLevel'];
      if (!isAudio || level is! num) continue;
      if (report.type == 'media-source') input = math.max(input, level.toDouble());
      if (report.type == 'inbound-rtp') output = math.max(output, level.toDouble());
    }
    return (input: input, output: output);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel?.close();
    } catch (_) {}
    for (final track in _microphone?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _microphone?.dispose();
    await _peer?.close();
    final renderer = _webAudio;
    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    _emitState(RealtimeLinkState.closed);
    await _messages.close();
    await _states.close();
  }
}
