import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:voice_assistant/app.dart';
import 'package:voice_assistant/core/router/app_router.dart';
import 'package:voice_assistant/domain/chat/chat_stream.dart';
import 'package:voice_assistant/domain/entities/chat_message.dart';
import 'package:voice_assistant/domain/voice/voice_session_state.dart';
import 'package:voice_assistant/providers/auth_controller.dart';

import '../support/fakes.dart';

Future<void> pumpApp(
  WidgetTester tester, {
  required Size size,
  FakeAuthRepository? auth,
  FakeConversationRepository? conversations,
  FakeChatStream? chatStream,
  FakeCatalogRepository? catalog,
  FakeVoiceTransport? voice,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final overrides = await fakeOverrides(
    auth: auth,
    conversations: conversations,
    chatStream: chatStream,
    catalog: catalog,
    voiceTransports: voice == null ? null : (options) => voice..options = options,
  );
  await tester.pumpWidget(ProviderScope(overrides: overrides, retry: (_, _) => null, child: const VoiceAssistantApp()));
  await tester.pumpAndSettle();
}

void main() {
  group('auth redirect rule', () {
    const loading = AsyncLoading<AuthState>();
    const signedOut = AsyncData<AuthState>(Unauthenticated());
    final signedIn = AsyncData<AuthState>(Authenticated(testUser));
    String? redirect(AsyncValue<AuthState> auth, String location) => authRedirect(auth, Uri.parse(location));

    test('loading goes to splash', () {
      expect(redirect(loading, '/chat'), '/splash');
      expect(redirect(loading, '/splash'), isNull);
    });
    test('signed out users only see public routes', () {
      expect(redirect(signedOut, '/chat'), '/login');
      expect(redirect(signedOut, '/register'), isNull);
    });
    test('signed in users skip auth screens', () {
      expect(redirect(signedIn, '/login'), '/chat');
      expect(redirect(signedIn, '/splash'), '/chat');
      expect(redirect(signedIn, '/chat/abc'), isNull);
    });
    test('a failed session restore is treated as signed out', () {
      expect(redirect(AsyncError<AuthState>(Exception('boom'), StackTrace.empty), '/chat'), '/login');
    });
    test('a deep link survives the splash screen (page reload on a conversation)', () {
      final toSplash = redirect(loading, '/chat/abc')!;
      expect(toSplash, '/splash?from=%2Fchat%2Fabc');
      expect(redirect(signedIn, toSplash), '/chat/abc');
    });
    test('a deep link survives signing in', () {
      final toLogin = redirect(signedOut, '/settings')!;
      expect(toLogin, '/login?from=%2Fsettings');
      expect(redirect(signedIn, toLogin), '/settings');
      // Through splash and then login.
      final viaSplash = redirect(signedOut, redirect(loading, '/chat/xyz')!)!;
      expect(redirect(signedIn, viaSplash), '/chat/xyz');
    });
    test('from= cannot redirect to another site or loop through auth pages', () {
      for (final hostile in [
        'https://evil.example',
        '//evil.example/chat',
        'javascript:alert(1)',
        '/login',
        '/splash',
      ]) {
        final location = '/login?from=${Uri.encodeQueryComponent(hostile)}';
        expect(redirect(signedIn, location), '/chat', reason: hostile);
      }
    });
  });

  testWidgets('signed-out users land on the login form, which validates input', (tester) async {
    await pumpApp(tester, size: const Size(1280, 800), auth: FakeAuthRepository());
    expect(find.text('Welcome back'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'ana@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'secret-password');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('How can I help you today?'), findsOneWidget);
  });

  testWidgets('wide layout shows a permanent sidebar with conversations', (tester) async {
    final repo = FakeConversationRepository()
      ..seed('Trip to Bali')
      ..seed('Rendang recipe');
    await pumpApp(tester, size: const Size(1280, 800), conversations: repo);

    expect(find.text('Trip to Bali'), findsOneWidget);
    expect(find.text('Rendang recipe'), findsOneWidget);
    expect(find.byTooltip('Open menu'), findsNothing);
    expect(find.text('No model available'), findsOneWidget); // no provider configured
    expect(find.textContaining('No AI provider is connected'), findsOneWidget);
  });

  testWidgets('narrow layout moves the sidebar into a drawer', (tester) async {
    final repo = FakeConversationRepository()..seed('Trip to Bali');
    await pumpApp(tester, size: const Size(400, 800), conversations: repo);

    expect(find.text('Trip to Bali'), findsNothing);
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pumpAndSettle();
    expect(find.text('Trip to Bali'), findsOneWidget);

    await tester.tap(find.text('Trip to Bali'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets('Enter sends the first message, opens the conversation and streams the reply', (tester) async {
    final repo = FakeConversationRepository();
    final stream = FakeChatStream();
    scriptServer(stream, repo, reply: 'Day one: **Braga** street, then *Lembang*.');
    await pumpApp(
      tester,
      size: const Size(1280, 800),
      conversations: repo,
      chatStream: stream,
      catalog: FakeCatalogRepository(sampleCatalog),
    );

    await tester.enterText(find.byType(TextField).last, 'Plan a weekend in Bandung');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100)); // delta batching
    await tester.pumpAndSettle();

    final [conversation] = (await repo.list()).items;
    expect(stream.commands.single, {
      'type': 'message.send',
      'request_id': stream.commands.single['request_id'],
      'conversation_id': conversation.id,
      'content': 'Plan a weekend in Bandung',
    });
    final messages = repo.messagesSync(conversation.id);
    expect(messages.map((m) => m.role), [MessageRole.user, MessageRole.assistant]);

    // Both turns are on screen; the reply is rendered as Markdown (no literal asterisks).
    expect(find.text('Plan a weekend in Bandung'), findsWidgets);
    final rendered = tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).join('\n');
    expect(rendered, contains('Day one: Braga street, then Lembang.'));
    expect(rendered, isNot(contains('**Braga**')));
  });

  testWidgets('while streaming, the send button becomes Stop and stopping keeps the partial reply', (tester) async {
    final repo = FakeConversationRepository();
    final conversation = repo.seed('Existing chat');
    final stream = FakeChatStream();
    scriptServer(stream, repo, reply: 'Partial answer continues', hold: true);
    await pumpApp(
      tester,
      size: const Size(1280, 800),
      conversations: repo,
      chatStream: stream,
      catalog: FakeCatalogRepository(sampleCatalog),
    );

    await tester.tap(find.text('Existing chat'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Tell me something');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byTooltip('Stop generating'), findsOneWidget);
    expect(find.byTooltip('Send (Enter)'), findsNothing);
    await tester.tap(find.byTooltip('Stop generating'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(stream.commands.last['type'], 'response.cancel');
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.byTooltip('Send (Enter)'), findsOneWidget);
    expect(repo.messagesSync(conversation.id).last.status, MessageStatus.cancelled);
  });

  testWidgets('a reply that cannot start shows a banner with Try again', (tester) async {
    final repo = FakeConversationRepository();
    repo.seed('Chat');
    final stream = FakeChatStream();
    scriptServer(
      stream,
      repo,
      failBeforeReply: const ChatError(
        code: 'provider_not_available',
        message: 'No AI provider is configured on this server',
      ),
    );
    await pumpApp(
      tester,
      size: const Size(1280, 800),
      conversations: repo,
      chatStream: stream,
      catalog: FakeCatalogRepository(sampleCatalog),
    );
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Hello?');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('No AI provider is configured on this server'), findsOneWidget);
    scriptServer(stream, repo, reply: 'Back online');
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.text('No AI provider is configured on this server'), findsNothing);
    expect(stream.commands.last['type'], 'response.regenerate');
  });

  testWidgets('voice screen explains when no realtime model is available', (tester) async {
    await pumpApp(tester, size: const Size(1280, 800));
    await tester.tap(find.byTooltip('Voice mode').first);
    await tester.pumpAndSettle();

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.textContaining('realtime-capable AI provider'), findsOneWidget);
    final start = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.call_rounded));
    expect(start.onPressed, isNull);
  });

  testWidgets('push-to-talk voice session: hold to talk, live transcript, close opens the conversation', (
    tester,
  ) async {
    final repo = FakeConversationRepository();
    final conversation = repo.seed('Voice chat');
    repo.seedMessage(conversation.id, MessageRole.user, 'Saved voice question');
    final voice = FakeVoiceTransport(pushToTalk: true, conversationId: conversation.id);
    await pumpApp(
      tester,
      size: const Size(1280, 800),
      conversations: repo,
      catalog: FakeCatalogRepository(sampleCatalog),
      voice: voice,
    );

    await tester.tap(find.byTooltip('Voice mode').first);
    await tester.pumpAndSettle();
    expect(find.text('Voice · Acme Voice'), findsOneWidget);
    await tester.tap(find.byTooltip('Start voice session'));
    await tester.pumpAndSettle();
    expect(find.text('Hold the talk button (or Space) while you speak.'), findsOneWidget);

    // Holding the button is the user's turn; releasing sends it.
    final hold = await tester.startGesture(tester.getCenter(find.byIcon(Icons.mic_rounded)));
    await tester.pump();
    expect(find.text('Release to send.'), findsOneWidget);
    await hold.up();
    await tester.pump();
    expect(find.text('Thinking…'), findsOneWidget);
    expect((voice.talkStarts, voice.talkStops), (1, 1));

    // Space works as a push-to-talk key on desktop and web.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(voice.talkStarts, 2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(voice.talkStops, 2);

    voice.emit(
      const VoiceTranscriptUpdated(role: TranscriptRole.user, text: 'What is the weather?', isFinal: true, itemId: 'u'),
    );
    await tester.pump();
    expect(find.text('What is the weather?'), findsOneWidget);

    await tester.tap(find.byTooltip('Close voice mode'));
    await tester.pumpAndSettle();
    expect(voice.closed, isTrue);
    expect(find.text('Saved voice question'), findsOneWidget); // the voice conversation is open
  });
}
