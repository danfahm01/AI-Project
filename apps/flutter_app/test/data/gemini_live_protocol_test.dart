import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/data/voice/gemini_live_protocol.dart';
import 'package:voice_assistant/data/voice/pcm_audio.dart';
import 'package:voice_assistant/domain/voice/voice_session_state.dart';

Map<String, dynamic> content(Map<String, dynamic> serverContent) => {'serverContent': serverContent};

Map<String, dynamic> audioPart(List<int> bytes) => content({
  'modelTurn': {
    'parts': [
      {
        'inlineData': {'mimeType': 'audio/pcm;rate=24000', 'data': base64Encode(bytes)},
      },
    ],
  },
});

Map<String, dynamic> userSaid(String text) => content({
  'inputTranscription': {'text': text},
});

Map<String, dynamic> modelSaid(String text) => content({
  'outputTranscription': {'text': text},
});

final turnComplete = content({'turnComplete': true});
final interrupted = content({'interrupted': true});

List<Type> types(Iterable<VoiceEvent> events) => [for (final e in events) e.runtimeType];

void main() {
  test('client messages follow the documented shapes', () {
    expect(GeminiLiveProtocol.setup('gemini-3.8-live'), {
      'setup': {
        'model': 'models/gemini-3.8-live',
        'generationConfig': {
          'responseModalities': ['AUDIO'],
        },
        'sessionResumption': <String, Object?>{},
      },
    });
    expect((GeminiLiveProtocol.setup('models/x', resumeHandle: 'h1')['setup']! as Map)['sessionResumption'], {
      'handle': 'h1',
    });
    final audio = GeminiLiveProtocol.audio(Uint8List.fromList([1, 2, 3, 4]), 'audio/pcm;rate=16000');
    expect(audio, {
      'realtimeInput': {
        'audio': {'data': 'AQIDBA==', 'mimeType': 'audio/pcm;rate=16000'},
      },
    });
    expect(jsonEncode(GeminiLiveProtocol.activityStart), '{"realtimeInput":{"activityStart":{}}}');
    expect(jsonEncode(GeminiLiveProtocol.activityEnd), '{"realtimeInput":{"activityEnd":{}}}');
    expect(jsonEncode(GeminiLiveProtocol.audioStreamEnd), '{"realtimeInput":{"audioStreamEnd":true}}');
  });

  test('decodes text and binary frames; ignores garbage', () {
    expect(GeminiLiveProtocol.decode('{"setupComplete":{}}'), {'setupComplete': <String, dynamic>{}});
    expect(GeminiLiveProtocol.decode(utf8.encode('{"a":1}')), {'a': 1});
    expect(GeminiLiveProtocol.decode('not json'), isNull);
    expect(GeminiLiveProtocol.decode('[1]'), isNull);
    expect(GeminiLiveProtocol.decode(null), isNull);
  });

  test('setup, resumption handles and goAway', () {
    final protocol = GeminiLiveProtocol();
    expect(protocol.handle({'setupComplete': <String, dynamic>{}}).setupComplete, isTrue);
    expect(
      protocol.handle({
        'sessionResumptionUpdate': {'newHandle': 'h2', 'resumable': true},
      }).resumeHandle,
      'h2',
    );
    // Not resumable (e.g. mid-generation): no handle to use.
    expect(
      protocol.handle({
        'sessionResumptionUpdate': {'newHandle': '', 'resumable': false},
      }).resumeHandle,
      isNull,
    );
    expect(
      protocol.handle({
        'goAway': {'timeLeft': '9.5s'},
      }).goAway,
      const Duration(milliseconds: 9500),
    );
    expect(GeminiLiveProtocol.parseDuration('12s'), const Duration(seconds: 12));
    expect(GeminiLiveProtocol.parseDuration(12), isNull);
  });

  test('hands-free exchange: speech, reply audio, transcripts saved in order', () {
    final protocol = GeminiLiveProtocol();

    final heard = protocol.handle(userSaid('Hello '));
    expect(types(heard.events), [VoiceUserSpeechStarted, VoiceTranscriptUpdated]);
    expect((heard.events.last as VoiceTranscriptUpdated).itemId, 'u0');
    protocol.handle(userSaid(' there'));

    final reply = protocol.handle(audioPart([1, 0, 2, 0]));
    expect(types(reply.events), [VoiceUserSpeechStopped]);
    expect(reply.audio.single, [1, 0, 2, 0]);
    expect(protocol.responding, isTrue);

    final words = protocol.handle(modelSaid('Hi! '));
    expect((words.events.single as VoiceTranscriptUpdated).text, 'Hi!');
    // A late user fragment still belongs to this exchange and does not barge in.
    final late = protocol.handle(userSaid(' friend'));
    expect(types(late.events), [VoiceTranscriptUpdated]);
    protocol.handle(modelSaid('How can I help?'));
    expect(protocol.takeReadyTurns(), isEmpty);

    final done = protocol.handle(turnComplete);
    expect(done.turnComplete, isTrue);
    final finals = done.events.whereType<VoiceTranscriptUpdated>().toList();
    expect(
      [for (final f in finals) (f.itemId, f.text, f.isFinal)],
      [('u0', 'Hello there friend', true), ('a0', 'Hi! How can I help?', true)],
    );
    expect(done.events.whereType<VoiceResponseFinished>(), isEmpty); // the reply had audio
    final turns = protocol.takeReadyTurns();
    expect(
      [for (final t in turns) (t.itemId, t.role, t.text)],
      [('u0', TranscriptRole.user, 'Hello there friend'), ('a0', TranscriptRole.assistant, 'Hi! How can I help?')],
    );
    expect(protocol.responding, isFalse);

    // The next exchange gets new item ids.
    expect((protocol.handle(userSaid('Again')).events.last as VoiceTranscriptUpdated).itemId, 'u1');
  });

  test('barge-in ends the reply at what was received; the new speech is a new exchange', () {
    final protocol = GeminiLiveProtocol();
    protocol.handle(userSaid('Tell me a story'));
    protocol.handle(audioPart([0, 0]));
    protocol.handle(modelSaid('Once upon a time'));

    final cut = protocol.handle(interrupted);
    expect(cut.interrupted, isTrue);
    expect(types(cut.events), [VoiceTranscriptUpdated, VoiceTranscriptUpdated, VoiceUserSpeechStarted]);
    expect(protocol.takeReadyTurns().map((t) => t.text), ['Tell me a story', 'Once upon a time']);

    // Output still in flight for the cancelled reply is dropped.
    expect(protocol.handle(audioPart([9, 9])).audio, isEmpty);
    expect(protocol.handle(modelSaid(' there was')).events, isEmpty);
    protocol.handle(userSaid('Actually, a joke'));
    // The cancelled reply's turnComplete does not end the new exchange.
    expect(protocol.handle(turnComplete).events, isEmpty);
    expect(protocol.takeReadyTurns(), isEmpty);

    protocol.handle(modelSaid('Why did the chicken…'));
    protocol.handle(turnComplete);
    expect(
      [for (final t in protocol.takeReadyTurns()) (t.itemId, t.text)],
      [('u1', 'Actually, a joke'), ('a1', 'Why did the chicken…')],
    );
  });

  test('manual stop drops the rest of the reply and keeps what was heard', () {
    final protocol = GeminiLiveProtocol();
    protocol.handle(userSaid('Explain tides'));
    protocol.handle(modelSaid('The moon pulls'));
    protocol.suppressCurrentOutput();
    expect(protocol.responding, isFalse);
    expect(protocol.handle(audioPart([1, 1])).audio, isEmpty);
    expect(protocol.handle(modelSaid(' the oceans')).events, isEmpty);
    final done = protocol.handle(turnComplete);
    expect(done.events.whereType<VoiceResponseFinished>(), hasLength(1));
    expect(protocol.takeReadyTurns().last.text, 'The moon pulls');
  });

  test('push-to-talk: the button marks speech, transcripts do not', () {
    final protocol = GeminiLiveProtocol(pushToTalk: true);
    expect(types(protocol.handle(userSaid('Hi')).events), [VoiceTranscriptUpdated]);
    expect(
      protocol.handle({
        'voiceActivity': {'voiceActivityType': 'ACTIVITY_START'},
      }).events,
      isEmpty,
    );
    expect(types(protocol.handle(interrupted).events), isEmpty);
  });

  test('voice activity signals and replies without audio', () {
    final protocol = GeminiLiveProtocol();
    expect(
      types(
        protocol.handle({
          'voiceActivity': {'voiceActivityType': 'ACTIVITY_START'},
        }).events,
      ),
      [VoiceUserSpeechStarted],
    );
    expect(
      types(
        protocol.handle({
          'voiceActivity': {'voiceActivityType': 'ACTIVITY_END'},
        }).events,
      ),
      [VoiceUserSpeechStopped],
    );
    // A turn that ends without any reply audio tells the UI to stop "thinking".
    expect(protocol.handle(turnComplete).events.whereType<VoiceResponseFinished>(), hasLength(1));
  });

  test('flush returns the exchange in progress', () {
    final protocol = GeminiLiveProtocol();
    protocol.handle(userSaid('Half a'));
    protocol.handle(modelSaid('Partial'));
    expect(protocol.takeReadyTurns(), isEmpty);
    expect(protocol.takeReadyTurns(flush: true).map((t) => t.text), ['Half a', 'Partial']);
    expect(protocol.takeReadyTurns(flush: true), isEmpty);
  });

  test('PCM helpers', () {
    expect(pcm16Level(Uint8List(0)), 0);
    // Full-scale square wave: RMS 1.0.
    final loud = ByteData(4)
      ..setInt16(0, 32767, Endian.little)
      ..setInt16(2, -32768, Endian.little);
    expect(pcm16Level(loud.buffer.asUint8List()), closeTo(1.0, 0.001));
    expect(pcm16Duration(48000, 24000), const Duration(seconds: 1));
    expect(sampleRateOf('audio/pcm;rate=16000'), 16000);
    expect(sampleRateOf('audio/pcm'), isNull);
  });
}
