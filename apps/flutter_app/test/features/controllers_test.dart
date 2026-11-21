import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_assistant/core/network/api_exception.dart';
import 'package:voice_assistant/domain/chat/chat_stream.dart';
import 'package:voice_assistant/domain/entities/chat_message.dart';
import 'package:voice_assistant/domain/entities/conversation.dart';
import 'package:voice_assistant/domain/entities/user_preferences.dart';
import 'package:voice_assistant/domain/voice/voice_session_state.dart';
import 'package:voice_assistant/domain/voice/voice_transport.dart';
import 'package:voice_assistant/features/chat/application/chat_controller.dart';
import 'package:voice_assistant/features/chat/application/conversation_list_controller.dart';
import 'package:voice_assistant/features/voice/application/voice_session_controller.dart';
import 'package:voice_assistant/providers/auth_controller.dart';
import 'package:voice_assistant/providers/preferences_controller.dart';

import '../support/fakes.dart';

Future<ProviderContainer> makeContainer({
  FakeAuthRepository? auth,
  FakeConversationRepository? conversations,
  FakeCatalogRepository? catalog,
  FakeVoiceTransport? transport,
  FakeChatStream? chatStream,
}) async {
  final container = ProviderContainer.test(
    retry: (_, _) => null,
    overrides: await fakeOverrides(
      auth: auth,
      conversations: conversations,
      catalog: catalog,
      voiceTransports: transport == null ? null : (options) => transport..options = options,
      chatStream: chatStream,
    ),
  );
  await container.read(authControllerProvider.future);
  return container;
}

void main() {
  group('AuthController', () {
    test('restores a stored session', () async {
      final container = await makeContainer();
      expect(container.read(currentUserProvider)?.email, testUser.email);
    });

    test('server unreachable on startup is reported, not treated as a crash', () async {
      final container = await makeContainer(auth: FakeAuthRepository(currentUserError: networkError));
      final state = container.read(authControllerProvider).value;
      expect(state, isA<Unauthenticated>().having((s) => s.reason, 'reason', SignedOutReason.serverUnreachable));
    });

    test('session expiry signs the user out with a reason', () async {
      final container = await makeContainer();
      container.read(authControllerProvider.notifier).handleSessionExpired();
      final state = container.read(authControllerProvider).value;
      expect(state, isA<Unauthenticated>().having((s) => s.reason, 'reason', SignedOutReason.sessionExpired));
    });
  });

  group('ConversationListController', () {
    test('loads, paginates and de-duplicates', () async {
      final repo = FakeConversationRepository();
      for (var i = 0; i < 35; i++) {
        repo.seed('Chat $i');
      }
      final container = await makeContainer(conversations: repo);
      final controller = container.read(conversationListControllerProvider.notifier);

      final first = await container.read(conversationListControllerProvider.future);
      expect(first.items, hasLength(30));
      expect(first.items.first.title, 'Chat 34');
      expect(first.hasMore, isTrue);

      await controller.loadMore();
      final all = container.read(conversationListControllerProvider).value!;
      expect(all.items, hasLength(35));
      expect(all.hasMore, isFalse);
      expect(all.items.map((c) => c.id).toSet(), hasLength(35));
    });

    test('search filters by title and message text', () async {
      final repo = FakeConversationRepository();
      repo.seed('Bali trip');
      final misc = repo.seed('Misc');
      repo.seedMessage(misc.id, MessageRole.user, 'rendang recipe');
      final container = await makeContainer(conversations: repo);
      await container.read(conversationListControllerProvider.future);
      final controller = container.read(conversationListControllerProvider.notifier);

      await controller.search('RENDANG');
      expect(container.read(conversationListControllerProvider).value!.items.single.id, misc.id);
      await controller.search('');
      expect(container.read(conversationListControllerProvider).value!.items, hasLength(2));
    });

    test('create, rename and delete keep the list in sync', () async {
      final repo = FakeConversationRepository()..seed('Old');
      final container = await makeContainer(conversations: repo);
      await container.read(conversationListControllerProvider.future);
      final controller = container.read(conversationListControllerProvider.notifier);

      final created = await controller.create();
      List<Conversation> items() => container.read(conversationListControllerProvider).value!.items;
      expect(items().first.id, created.id);

      await controller.rename(created.id, 'Renamed');
      expect(items().first.title, 'Renamed');

      await controller.delete(created.id);
      expect(items().map((c) => c.title), ['Old']);
    });

    test('groupByRecency buckets by local calendar day', () {
      final now = DateTime(2026, 11, 19, 15);
      Conversation at(DateTime local) =>
          Conversation(id: '$local', title: 't', createdAt: local.toUtc(), updatedAt: local.toUtc());
      final groups = groupByRecency([
        at(DateTime(2026, 11, 19, 8)),
        at(DateTime(2026, 11, 18, 23)),
        at(DateTime(2026, 11, 14)),
        at(DateTime(2026, 11, 1)),
        at(DateTime(2026, 9, 1)),
      ], now);
      expect(groups.map((g) => g.$1), [
        DateBucket.today,
        DateBucket.yesterday,
        DateBucket.previous7Days,
        DateBucket.previous30Days,
        DateBucket.older,
      ]);
    });
  });

  group('ChatController', () {
    late FakeConversationRepository repo;
    late Conversation conversation;

    setUp(() {
      repo = FakeConversationRepository();
      conversation = repo.seed('New conversation');
    });

    late FakeChatStream stream;

    Future<(ProviderContainer, ChatController)> open() async {
      stream = FakeChatStream();
      final container = await makeContainer(conversations: repo, chatStream: stream);
      container.listen(chatControllerProvider(conversation.id), (_, _) {}); // keep alive
      await container.read(chatControllerProvider(conversation.id).future);
      return (container, container.read(chatControllerProvider(conversation.id).notifier));
    }

    ChatState read(ProviderContainer container) => container.read(chatControllerProvider(conversation.id)).value!;

    /// Lets broadcast events and the 40 ms delta batching run.
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 80));

    test('send shows the message at once, then streams and completes the reply', () async {
      final (container, controller) = await open();
      scriptServer(stream, repo, reply: 'Hi! How can I help?', hold: true);

      final sending = controller.send('Hello there');
      // Optimistic: visible before the server answers.
      expect(read(container).messages.single.status, MessageStatus.sending);
      expect(read(container).isGenerating, isTrue);
      await sending;
      await settle();

      var state = read(container);
      expect(state.messages.map((m) => (m.role, m.isLocal)), [
        (MessageRole.user, false),
        (MessageRole.assistant, false),
      ]);
      expect(state.messages.last.status, MessageStatus.streaming);
      expect(state.messages.last.content, 'Hi!'); // first delta applied
      expect(stream.commands.single, containsPair('content', 'Hello there'));

      // Finish the reply.
      final requestId = stream.commands.single['request_id'] as String?;
      final done = state.messages.last.copyWith(content: 'Hi! How can I help?', status: MessageStatus.complete);
      stream.emit(ResponseCompletedEvent(requestId: requestId, conversationId: conversation.id, message: done));
      await settle();
      state = read(container);
      expect(state.isGenerating, isFalse);
      expect(state.messages.last.content, 'Hi! How can I help?');
    });

    test('many deltas are batched and applied in order', () async {
      final (container, controller) = await open();
      scriptServer(stream, repo, reply: List.generate(50, (i) => 'w$i').join(' '));
      await controller.send('Count');
      await settle();
      final reply = read(container).messages.last;
      expect(reply.content.split(' '), hasLength(50));
      expect(reply.content, startsWith('w0 w1 w2'));
      expect(reply.status, MessageStatus.complete);
    });

    test('stop cancels the active request and keeps the partial reply', () async {
      final (container, controller) = await open();
      scriptServer(stream, repo, reply: 'one two three', hold: true);
      await controller.send('Go');
      await settle();
      await controller.stop();
      await settle();

      expect(stream.commands.last['type'], 'response.cancel');
      expect(stream.commands.last['request_id'], stream.commands.first['request_id']);
      final state = read(container);
      expect(state.isGenerating, isFalse);
      expect(state.messages.last.status, MessageStatus.cancelled);
      expect(state.messages.last.content, 'one');
    });

    test('a send that cannot reach the server is marked failed and can be retried', () async {
      final (container, controller) = await open();
      scriptServer(stream, repo);
      stream.failNextCommand = networkError;
      await controller.send('Hi');

      var state = read(container);
      expect(state.isGenerating, isFalse);
      expect(state.messages.single.status, MessageStatus.failed);
      expect(state.messages.single.errorMessage, networkError.message);

      await controller.retry(state.messages.single.id);
      await settle();
      state = read(container);
      expect(state.messages.map((m) => m.status), [MessageStatus.complete, MessageStatus.complete]);
    });

    test('attachments rejected by the model keep the message retryable with its files', () async {
      final (container, controller) = await open();
      final image = fakeAttachment('att-9');
      // Like the server for `attachments_not_supported`: nothing is stored.
      stream.onCommand = (command) => stream.emit(
        ResponseFailedEvent(
          requestId: command['request_id'] as String?,
          conversationId: command['conversation_id'] as String?,
          message: null,
          error: const ChatError(code: 'attachments_not_supported', message: 'Acme Text cannot read images.'),
        ),
      );
      await controller.send('Look', attachments: [image]);
      await settle();

      expect(stream.commands.single['attachment_ids'], ['att-9']);
      final failed = read(container).messages.single;
      expect(failed.status, MessageStatus.failed);
      expect(failed.errorMessage, 'Acme Text cannot read images.');
      expect(failed.attachments.single.id, 'att-9');

      scriptServer(stream, repo);
      await controller.retry(failed.id);
      await settle();
      expect(stream.commands.last['attachment_ids'], ['att-9']);
      expect(read(container).messages.first.attachments.single.id, 'att-9');
    });

    test('a reply that cannot start (no provider) becomes a retryable failure', () async {
      final (container, controller) = await open();
      const noProvider = ChatError(code: 'provider_not_available', message: 'No AI provider is configured');
      scriptServer(stream, repo, failBeforeReply: noProvider);
      await controller.send('Anyone?');
      await settle();

      var state = read(container);
      expect(state.messages.single.role, MessageRole.user); // the question is saved
      expect(state.failure?.code, 'provider_not_available');
      expect(state.isGenerating, isFalse);

      scriptServer(stream, repo, reply: 'Now I can answer');
      await controller.regenerate();
      await settle();
      state = read(container);
      expect(state.failure, isNull);
      expect(state.messages.last.content, 'Now I can answer');
    });

    test('server rejection of the active command (rate limit) marks it failed', () async {
      final (container, controller) = await open();
      stream.onCommand = (command) => stream.emit(
        CommandRejectedEvent(
          requestId: command['request_id'] as String?,
          error: const ChatError(code: 'rate_limited', message: 'Too many messages'),
        ),
      );
      await controller.send('Spam');
      await settle();
      final state = read(container);
      expect(state.isGenerating, isFalse);
      expect(state.messages.single.status, MessageStatus.failed);
      expect(state.messages.single.errorMessage, 'Too many messages');
    });

    test('regenerate replaces the last reply', () async {
      repo.seedMessage(conversation.id, MessageRole.user, 'Q');
      repo.seedMessage(conversation.id, MessageRole.assistant, 'old answer');
      final (container, controller) = await open();
      scriptServer(stream, repo, reply: 'new answer');
      await controller.regenerate();
      await settle();
      expect(read(container).messages.map((m) => m.content), ['Q', 'new answer']);
    });

    test('editing a user message drops later turns and asks for a new reply', () async {
      final first = repo.seedMessage(conversation.id, MessageRole.user, 'Q1');
      repo.seedMessage(conversation.id, MessageRole.assistant, 'A1');
      repo.seedMessage(conversation.id, MessageRole.user, 'Q2');
      final (container, controller) = await open();
      scriptServer(stream, repo, reply: 'A1 again');

      await controller.edit(first.id, 'Q1 (edited)');
      await settle();
      final state = read(container);
      expect(state.messages.map((m) => m.content), ['Q1 (edited)', 'A1 again']);
      expect(state.messages.first.editedAt, isNotNull);
      expect(stream.commands.single['type'], 'response.regenerate');
    });

    test('events for other conversations are ignored', () async {
      final (container, _) = await open();
      final other = repo.seed('Other');
      final message = repo.seedMessage(other.id, MessageRole.user, 'elsewhere');
      stream.emit(MessageCreatedEvent(requestId: 'x', conversationId: other.id, message: message));
      await settle();
      expect(read(container).messages, isEmpty);
    });

    test('losing the connection mid-reply reloads the conversation on reconnect', () async {
      final (container, controller) = await open();
      scriptServer(stream, repo, reply: 'partial reply', hold: true);
      await controller.send('Question');
      await settle();

      stream.setStatus(ChatConnectionStatus.reconnecting);
      await settle();
      // Meanwhile the server finished the reply.
      final reply = repo.messagesSync(conversation.id).last;
      repo.replaceMessage(reply.copyWith(content: 'partial reply, finished offline', status: MessageStatus.complete));
      stream.setStatus(ChatConnectionStatus.connected);
      await settle();

      final state = read(container);
      expect(state.isGenerating, isFalse);
      expect(state.messages.last.content, 'partial reply, finished offline');
    });

    test('delete removes a message', () async {
      final message = repo.seedMessage(conversation.id, MessageRole.user, 'oops');
      final (container, controller) = await open();
      await controller.delete(message.id);
      expect(read(container).messages, isEmpty);
    });

    test('the sidebar follows conversation.updated events', () async {
      final (container, _) = await open();
      await container.read(conversationListControllerProvider.future);
      stream.emit(
        ConversationUpdatedEvent(
          requestId: 'r',
          conversationId: conversation.id,
          conversation: conversation.copyWith(title: 'Streamed title', updatedAt: DateTime.utc(2027)),
          titleChanged: true,
        ),
      );
      await settle();
      expect(container.read(conversationListControllerProvider).value!.items.first.title, 'Streamed title');
    });
  });

  test('choosing a voice model keeps the voice only if the new model offers it', () async {
    final preferences = FakePreferencesRepository()
      ..preferences = const UserPreferences(voiceName: 'alpha', speakingRate: 1.2);
    final container = ProviderContainer.test(
      retry: (_, _) => null,
      overrides: await fakeOverrides(preferences: preferences, catalog: FakeCatalogRepository(twoVoiceProviders)),
    );
    await container.read(authControllerProvider.future);
    await container.read(preferencesControllerProvider.future);
    final controller = container.read(preferencesControllerProvider.notifier);
    final [acme, zeta] = twoVoiceProviders.realtimeModels;

    await controller.setVoiceModel(acme);
    expect(preferences.updates.last, {'voice_provider': 'acme', 'voice_model': 'acme-voice'});
    expect(container.read(preferencesControllerProvider).value?.voiceName, 'alpha');

    await controller.setVoiceModel(zeta); // Zeta has no "alpha" voice
    expect(preferences.updates.last, {'voice_provider': 'zeta', 'voice_model': 'zeta-live', 'voice_name': null});
    final updated = container.read(preferencesControllerProvider).value!;
    expect((updated.voiceProvider, updated.voiceModel, updated.voiceName), ('zeta', 'zeta-live', null));
    expect(updated.speakingRate, 1.2);
  });

  test('voice sessions use the chosen voice model', () async {
    final transport = FakeVoiceTransport();
    final preferences = FakePreferencesRepository()
      ..preferences = const UserPreferences(voiceProvider: 'zeta', voiceModel: 'zeta-live');
    final container = ProviderContainer.test(
      retry: (_, _) => null,
      overrides: await fakeOverrides(
        preferences: preferences,
        catalog: FakeCatalogRepository(twoVoiceProviders),
        voiceTransports: (options) => transport..options = options,
      ),
    );
    await container.read(authControllerProvider.future);
    final prefs = await container.read(preferencesControllerProvider.future);
    container.listen(voiceSessionControllerProvider, (_, _) {});
    final selection = selectVoiceModel(twoVoiceProviders, prefs)!;
    await container
        .read(voiceSessionControllerProvider.notifier)
        .start(providerId: selection.provider.id, modelId: selection.model.id);
    await pumpEventQueue();
    expect(transport.options?.selection.model.id, 'zeta-live');
    expect(container.read(voiceSessionControllerProvider).phase, VoicePhase.idle);
  });

  group('VoiceSessionController', () {
    Future<ProviderContainer> voiceContainer({FakeCatalogRepository? catalog, FakeVoiceTransport? transport}) async {
      final container = await makeContainer(catalog: catalog, transport: transport);
      container.listen(voiceSessionControllerProvider, (_, _) {}); // keep alive
      return container;
    }

    test('without a realtime model the session fails with an explanation', () async {
      final container = await voiceContainer();
      await container.read(voiceSessionControllerProvider.notifier).start();
      final state = container.read(voiceSessionControllerProvider);
      expect(state.phase, VoicePhase.error);
      expect(state.errorMessage, contains('No realtime voice model'));
    });

    test('with a model but no transport for it, the session fails clearly', () async {
      final container = await voiceContainer(catalog: FakeCatalogRepository(sampleCatalog));
      await container.read(voiceSessionControllerProvider.notifier).start();
      expect(container.read(voiceSessionControllerProvider).errorMessage, contains('Acme AI'));
    });

    test('transport events drive the state; mute and end reach the transport', () async {
      final transport = FakeVoiceTransport();
      final container = await voiceContainer(catalog: FakeCatalogRepository(sampleCatalog), transport: transport);
      final controller = container.read(voiceSessionControllerProvider.notifier);
      VoicePhase phase() => container.read(voiceSessionControllerProvider).phase;

      await controller.start();
      await pumpEventQueue();
      expect(transport.connected, isTrue);
      expect(phase(), VoicePhase.idle);

      transport.emit(const VoiceUserSpeechStarted());
      transport.emit(const VoiceLevelChanged(0.6));
      await pumpEventQueue();
      expect(phase(), VoicePhase.listening);
      expect(container.read(voiceSessionControllerProvider).level, 0.6);

      await controller.toggleMute();
      expect(transport.muted, isTrue);
      expect(container.read(voiceSessionControllerProvider).isMuted, isTrue);

      await controller.end();
      expect(transport.closed, isTrue);
      expect(phase(), VoicePhase.disconnected);
    });

    test('a connection error surfaces the API message and closes the transport', () async {
      final transport = FakeVoiceTransport()
        ..connectError = const ApiException(code: 'rate_limited', message: 'Too many requests', statusCode: 429);
      final container = await voiceContainer(catalog: FakeCatalogRepository(sampleCatalog), transport: transport);
      await container.read(voiceSessionControllerProvider.notifier).start();
      final state = container.read(voiceSessionControllerProvider);
      expect(state.phase, VoicePhase.error);
      expect(state.errorMessage, 'Too many requests');
      expect(transport.closed, isTrue);
    });

    test('voice-specific connection errors (e.g. microphone denied) are shown as is', () async {
      final transport = FakeVoiceTransport()..connectError = const VoiceConnectError('Microphone access was denied.');
      final container = await voiceContainer(catalog: FakeCatalogRepository(sampleCatalog), transport: transport);
      await container.read(voiceSessionControllerProvider.notifier).start();
      expect(container.read(voiceSessionControllerProvider).errorMessage, 'Microphone access was denied.');
    });

    test('push-to-talk: talking reaches the transport only in push-to-talk sessions', () async {
      final transport = FakeVoiceTransport(pushToTalk: true, conversationId: 'c-42');
      final container = await voiceContainer(catalog: FakeCatalogRepository(sampleCatalog), transport: transport);
      final controller = container.read(voiceSessionControllerProvider.notifier);

      await controller.start(conversationId: 'c-42');
      await pumpEventQueue();
      expect(transport.options?.conversationId, 'c-42');
      expect(transport.options?.selection.model.id, 'acme-voice');
      final state = container.read(voiceSessionControllerProvider);
      expect(state.pushToTalk, isTrue);
      expect(state.conversationId, 'c-42');

      await controller.startTalking();
      await pumpEventQueue();
      expect(container.read(voiceSessionControllerProvider).phase, VoicePhase.listening);
      await controller.stopTalking();
      await pumpEventQueue();
      expect(container.read(voiceSessionControllerProvider).phase, VoicePhase.processing);
      expect((transport.talkStarts, transport.talkStops), (1, 1));

      final handsFree = FakeVoiceTransport();
      final other = await voiceContainer(catalog: FakeCatalogRepository(sampleCatalog), transport: handsFree);
      final otherController = other.read(voiceSessionControllerProvider.notifier);
      await otherController.start();
      await pumpEventQueue();
      await otherController.startTalking();
      expect(handsFree.talkStarts, 0);
    });
  });
}
