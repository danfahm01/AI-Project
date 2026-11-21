import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/domain/voice/voice_session_state.dart';

VoiceSessionState run(List<VoiceEvent> events, [VoiceSessionState? from]) =>
    events.fold(from ?? const VoiceSessionState.initial(), reduceVoiceState);

void main() {
  const connected = [VoiceConnectRequested(), VoiceConnected()];

  test('connects from disconnected to idle', () {
    expect(run([const VoiceConnectRequested()]).phase, VoicePhase.connecting);
    expect(run(connected).phase, VoicePhase.idle);
  });

  test('a full turn: listening -> processing -> speaking -> idle', () {
    final phases = <VoicePhase>[];
    var state = run(connected);
    for (final event in const [
      VoiceUserSpeechStarted(),
      VoiceUserSpeechStopped(),
      VoiceAssistantAudioStarted(),
      VoiceAssistantAudioFinished(),
    ]) {
      state = reduceVoiceState(state, event);
      phases.add(state.phase);
    }
    expect(phases, [VoicePhase.listening, VoicePhase.processing, VoicePhase.speaking, VoicePhase.idle]);
  });

  test('user speech while the assistant speaks is a barge-in', () {
    final speaking = run([...connected, const VoiceAssistantAudioStarted()]);
    final interrupted = reduceVoiceState(speaking, const VoiceUserSpeechStarted());
    expect(interrupted.phase, VoicePhase.interrupted);
    // Playback stops while the user keeps talking -> listening.
    expect(reduceVoiceState(interrupted, const VoiceAssistantAudioFinished()).phase, VoicePhase.listening);
    // Or the user finishes first -> processing.
    expect(reduceVoiceState(interrupted, const VoiceUserSpeechStopped()).phase, VoicePhase.processing);
  });

  test('events that are invalid for the current phase are ignored', () {
    const initial = VoiceSessionState.initial();
    expect(reduceVoiceState(initial, const VoiceUserSpeechStarted()), same(initial));
    expect(reduceVoiceState(initial, const VoiceAssistantAudioStarted()), same(initial));
    expect(reduceVoiceState(initial, const VoiceMuteChanged(muted: true)).isMuted, isFalse);
    final idle = run(connected);
    expect(reduceVoiceState(idle, const VoiceConnected()), same(idle));
  });

  test('connection loss reconnects and counts attempts, then gives up', () {
    final listening = run([...connected, const VoiceUserSpeechStarted()]);
    final lost = reduceVoiceState(listening, const VoiceConnectionLost());
    expect(lost.phase, VoicePhase.reconnecting);
    expect(lost.reconnectAttempt, 1);
    final lostAgain = reduceVoiceState(lost, const VoiceConnectionLost());
    expect(lostAgain.reconnectAttempt, 2);

    expect(reduceVoiceState(lostAgain, const VoiceConnected()).phase, VoicePhase.idle);
    final gaveUp = reduceVoiceState(lostAgain, const VoiceReconnectGaveUp());
    expect(gaveUp.phase, VoicePhase.disconnected);
    expect(gaveUp.errorMessage, isNotNull);
  });

  test('failures move to error from any phase; reset and reconnect clear it', () {
    final failed = run([...connected, const VoiceFailed('boom')]);
    expect(failed.phase, VoicePhase.error);
    expect(failed.errorMessage, 'boom');
    expect(reduceVoiceState(failed, const VoiceReset()).errorMessage, isNull);
    final retried = reduceVoiceState(failed, const VoiceConnectRequested());
    expect(retried.phase, VoicePhase.connecting);
    expect(retried.errorMessage, isNull);
  });

  test('audio level is tracked only while audio is flowing and is clamped', () {
    final idle = run(connected);
    expect(reduceVoiceState(idle, const VoiceLevelChanged(0.8)).level, 0);
    final listening = reduceVoiceState(idle, const VoiceUserSpeechStarted());
    expect(reduceVoiceState(listening, const VoiceLevelChanged(0.8)).level, 0.8);
    expect(reduceVoiceState(listening, const VoiceLevelChanged(3)).level, 1);
    final loud = reduceVoiceState(listening, const VoiceLevelChanged(0.9));
    // Leaving an audio phase resets the level so the orb settles.
    expect(reduceVoiceState(loud, const VoiceUserSpeechStopped()).level, 0);
  });

  test('mute applies only while connected and resets on disconnect', () {
    final muted = run([...connected, const VoiceMuteChanged(muted: true)]);
    expect(muted.isMuted, isTrue);
    expect(reduceVoiceState(muted, const VoiceDisconnectRequested()).isMuted, isFalse);
  });

  test('partial transcripts are replaced, final ones appended; kept after disconnect', () {
    var state = run(connected);
    state = reduceVoiceState(
      state,
      const VoiceTranscriptUpdated(role: TranscriptRole.user, text: 'Hel', isFinal: false),
    );
    state = reduceVoiceState(
      state,
      const VoiceTranscriptUpdated(role: TranscriptRole.user, text: 'Hello', isFinal: true),
    );
    state = reduceVoiceState(
      state,
      const VoiceTranscriptUpdated(role: TranscriptRole.assistant, text: 'Hi!', isFinal: true),
    );
    expect(state.transcript.map((e) => e.text), ['Hello', 'Hi!']);
    expect(reduceVoiceState(state, const VoiceDisconnectRequested()).transcript, hasLength(2));
  });

  test('transcripts with a provider item id are updated in place, keeping turn order', () {
    final state = run([
      ...connected,
      const VoiceTranscriptUpdated(role: TranscriptRole.user, text: '', isFinal: false, itemId: 'u1'),
      const VoiceTranscriptUpdated(role: TranscriptRole.assistant, text: 'Sure', isFinal: false, itemId: 'a1'),
      const VoiceTranscriptUpdated(role: TranscriptRole.user, text: 'Can you help?', isFinal: true, itemId: 'u1'),
      const VoiceTranscriptUpdated(role: TranscriptRole.assistant, text: 'Sure thing!', isFinal: true, itemId: 'a1'),
    ]);
    expect(state.transcript.map((e) => (e.itemId, e.text, e.isFinal)), [
      ('u1', 'Can you help?', true),
      ('a1', 'Sure thing!', true),
    ]);
  });

  test('session configuration and push-to-talk replies', () {
    final configured = run([...connected, const VoiceSessionConfigured(pushToTalk: true, conversationId: 'c1')]);
    expect(configured.pushToTalk, isTrue);
    expect(configured.conversationId, 'c1');

    // A reply that produced no audio (or was cancelled) returns to idle.
    final processing = run(const [VoiceUserSpeechStarted(), VoiceUserSpeechStopped()], configured);
    expect(processing.phase, VoicePhase.processing);
    expect(reduceVoiceState(processing, const VoiceResponseFinished()).phase, VoicePhase.idle);
    final speaking = reduceVoiceState(processing, const VoiceAssistantAudioStarted());
    expect(reduceVoiceState(speaking, const VoiceResponseFinished()), same(speaking));

    // Ending the session keeps the conversation so the app can open it.
    final ended = reduceVoiceState(configured, const VoiceDisconnectRequested());
    expect(ended.conversationId, 'c1');
    expect(ended.pushToTalk, isFalse);
  });
}
