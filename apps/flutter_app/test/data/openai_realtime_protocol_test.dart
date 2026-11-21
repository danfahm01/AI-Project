import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/data/voice/openai_realtime_protocol.dart';
import 'package:voice_assistant/domain/voice/voice_session_state.dart';

Map<String, dynamic> itemAdded(String id, String role) => {
  'type': 'conversation.item.added',
  'event_id': 'e',
  'item': {'id': id, 'type': 'message', 'role': role},
};

void main() {
  late DateTime now;
  late OpenAIRealtimeProtocol protocol;

  setUp(() {
    now = DateTime(2026, 11, 20, 12);
    protocol = OpenAIRealtimeProtocol(clock: () => now);
  });

  test('turn-taking and playback events map onto the voice state machine', () {
    expect(protocol.handle({'type': 'input_audio_buffer.speech_started'}), [isA<VoiceUserSpeechStarted>()]);
    expect(protocol.handle({'type': 'input_audio_buffer.speech_stopped'}), [isA<VoiceUserSpeechStopped>()]);
    expect(protocol.handle({'type': 'output_audio_buffer.started', 'response_id': 'r1'}), [
      isA<VoiceAssistantAudioStarted>(),
    ]);
    expect(protocol.assistantAudioPlaying, isTrue);
    expect(protocol.handle({'type': 'output_audio_buffer.cleared', 'response_id': 'r1'}), [
      isA<VoiceAssistantAudioFinished>(),
    ]);
    expect(protocol.assistantAudioPlaying, isFalse);
    expect(protocol.handle({'type': 'session.updated'}), isEmpty);
    expect(protocol.handle({'type': 'rate_limits.updated'}), isEmpty);
  });

  test('a full turn produces live transcripts and two ordered turns to store', () {
    final updates = <VoiceEvent>[
      ...protocol.handle(itemAdded('u1', 'user')),
      ...protocol.handle({
        'type': 'conversation.item.input_audio_transcription.delta',
        'item_id': 'u1',
        'delta': 'What ',
      }),
      ...protocol.handle({
        'type': 'conversation.item.input_audio_transcription.delta',
        'item_id': 'u1',
        'delta': 'time',
      }),
      ...protocol.handle({
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'u1',
        'transcript': 'What time is it?',
      }),
      ...protocol.handle({
        'type': 'response.created',
        'response': {'id': 'resp_1'},
      }),
      ...protocol.handle(itemAdded('a1', 'assistant')),
      ...protocol.handle({'type': 'response.output_audio_transcript.delta', 'item_id': 'a1', 'delta': "It's noon."}),
      ...protocol.handle({
        'type': 'response.output_audio_transcript.done',
        'item_id': 'a1',
        'transcript': "It's noon.",
      }),
    ];
    final transcripts = updates.whereType<VoiceTranscriptUpdated>().toList();
    expect(transcripts.first.text, ''); // slot reserved for the user turn
    expect(
      transcripts.map((t) => (t.itemId, t.text, t.isFinal)),
      containsAllInOrder([
        ('u1', 'What ', false),
        ('u1', 'What time', false),
        ('u1', 'What time is it?', true),
        ('a1', "It's noon.", true),
      ]),
    );
    expect(protocol.responseInProgress, isTrue);

    final turns = protocol.takeReadyTurns();
    expect(turns.map((t) => (t.itemId, t.role, t.text)), [
      ('u1', TranscriptRole.user, 'What time is it?'),
      ('a1', TranscriptRole.assistant, "It's noon."),
    ]);
    expect(protocol.takeReadyTurns(), isEmpty); // each turn is handed out once
  });

  test('a late user transcript is still stored before the reply that followed it', () {
    protocol.handle(itemAdded('u1', 'user'));
    protocol.handle(itemAdded('a1', 'assistant'));
    protocol.handle({'type': 'response.output_audio_transcript.done', 'item_id': 'a1', 'transcript': 'Sure!'});
    expect(protocol.takeReadyTurns(), isEmpty); // waiting for u1

    protocol.handle({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'u1',
      'transcript': 'Can you help?',
    });
    expect(protocol.takeReadyTurns().map((t) => t.itemId), ['u1', 'a1']);
  });

  test('failed or stale user transcriptions stop blocking later turns', () {
    protocol.handle(itemAdded('u1', 'user'));
    protocol.handle(itemAdded('a1', 'assistant'));
    protocol.handle({'type': 'response.output_audio_transcript.done', 'item_id': 'a1', 'transcript': 'Answer one'});
    protocol.handle({'type': 'conversation.item.input_audio_transcription.failed', 'item_id': 'u1'});
    expect(protocol.takeReadyTurns().map((t) => t.itemId), ['a1']);

    protocol.handle(itemAdded('u2', 'user'));
    protocol.handle(itemAdded('a2', 'assistant'));
    protocol.handle({'type': 'response.output_audio_transcript.done', 'item_id': 'a2', 'transcript': 'Answer two'});
    expect(protocol.takeReadyTurns(), isEmpty);
    now = now.add(const Duration(seconds: 20)); // u2 never got a transcript
    expect(protocol.takeReadyTurns().map((t) => t.itemId), ['a2']);
  });

  test('an interrupted reply keeps what was said; empty items are dropped', () {
    protocol.handle(itemAdded('u1', 'user'));
    protocol.handle({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'u1',
      'transcript': 'Tell me a story',
    });
    protocol.handle({
      'type': 'response.created',
      'response': {'id': 'r'},
    });
    protocol.handle(itemAdded('a1', 'assistant'));
    protocol.handle({'type': 'response.output_audio_transcript.delta', 'item_id': 'a1', 'delta': 'Once upon'});
    final done = protocol.handle({
      'type': 'response.done',
      'response': {'id': 'r', 'status': 'cancelled'},
    });
    expect(done.last, isA<VoiceResponseFinished>());
    expect(protocol.responseInProgress, isFalse);
    expect(protocol.takeReadyTurns().map((t) => t.text), ['Tell me a story', 'Once upon']);

    protocol.handle(itemAdded('u2', 'user'));
    protocol.handle({
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': 'u2',
      'transcript': '   ',
    });
    expect(protocol.takeReadyTurns(), isEmpty);
  });

  test('flush at session end releases finished turns and drops unfinished ones', () {
    protocol.handle(itemAdded('u1', 'user'));
    protocol.handle(itemAdded('a1', 'assistant'));
    protocol.handle({'type': 'response.output_audio_transcript.done', 'item_id': 'a1', 'transcript': 'Bye'});
    expect(protocol.takeReadyTurns(flush: true).map((t) => t.itemId), ['a1']);
  });

  test('client commands follow the documented interruption and push-to-talk flow', () {
    expect(OpenAIRealtimeProtocol.interruptCommands.map((c) => c['type']), [
      'response.cancel',
      'output_audio_buffer.clear',
    ]);
    expect(protocol.pushToTalkStartCommands().map((c) => c['type']), ['input_audio_buffer.clear']);

    protocol.handle({
      'type': 'response.created',
      'response': {'id': 'r'},
    });
    protocol.handle({'type': 'output_audio_buffer.started', 'response_id': 'r'});
    expect(protocol.pushToTalkStartCommands().map((c) => c['type']), [
      'input_audio_buffer.clear',
      'response.cancel',
      'output_audio_buffer.clear',
    ]);
    expect(OpenAIRealtimeProtocol.pushToTalkEndCommands.map((c) => c['type']), [
      'input_audio_buffer.commit',
      'response.create',
    ]);
  });

  test('error events expose their message', () {
    expect(
      OpenAIRealtimeProtocol.errorMessage({
        'type': 'error',
        'error': {'message': 'Bad session'},
      }),
      'Bad session',
    );
    expect(OpenAIRealtimeProtocol.errorMessage({'type': 'session.updated'}), isNull);
  });
}
