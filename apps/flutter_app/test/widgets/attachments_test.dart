import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:voice_assistant/app.dart';
import 'package:voice_assistant/core/network/api_exception.dart';
import 'package:voice_assistant/data/mappers/json_mappers.dart';
import 'package:voice_assistant/domain/entities/ai_provider.dart';
import 'package:voice_assistant/domain/entities/attachment.dart';

import '../support/fakes.dart';

/// A catalog whose default model reads images and PDFs, plus a text-only one.
final visionCatalog = ProviderCatalog(
  defaultProviderId: 'acme',
  providers: const [
    AIProviderInfo(
      id: 'acme',
      displayName: 'Acme AI',
      isDefault: true,
      models: [
        AIModelInfo(
          id: 'acme-vision',
          displayName: 'Acme Vision',
          isDefault: true,
          capabilities: ModelCapabilities(textStreaming: true, imageInput: true, pdfInput: true),
        ),
        AIModelInfo(
          id: 'acme-images',
          displayName: 'Acme Images',
          capabilities: ModelCapabilities(textStreaming: true, imageInput: true),
        ),
        AIModelInfo(id: 'acme-text', displayName: 'Acme Text', capabilities: ModelCapabilities(textStreaming: true)),
      ],
    ),
  ],
);

class Setup {
  Setup() {
    scriptServer(stream, repo, reply: 'Nice picture', attachments: attachments);
  }

  final repo = FakeConversationRepository();
  final stream = FakeChatStream();
  final attachments = FakeAttachmentRepository();
  final picker = FakeAttachmentPicker();

  Future<void> pump(WidgetTester tester, {ProviderCatalog? catalog}) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final overrides = await fakeOverrides(
      conversations: repo,
      chatStream: stream,
      catalog: FakeCatalogRepository(catalog ?? visionCatalog),
      attachments: attachments,
      picker: picker,
    );
    await tester.pumpWidget(
      ProviderScope(overrides: overrides, retry: (_, _) => null, child: const VoiceAssistantApp()),
    );
    await tester.pumpAndSettle();
  }
}

Finder get attachButton => find.byTooltip('Attach images or PDFs');

Future<void> choose(WidgetTester tester, String item) async {
  await tester.tap(attachButton);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

void main() {
  group('attachment basics', () {
    test('file types are recognised from their bytes', () {
      expect(attachmentKindOf(tinyPng), AttachmentKind.image);
      expect(attachmentKindOf(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), AttachmentKind.image);
      expect(attachmentKindOf(Uint8List.fromList(utf8.encode('RIFF\x00\x00\x00\x00WEBPVP8 '))), AttachmentKind.image);
      expect(attachmentKindOf(tinyPdf), AttachmentKind.pdf);
      expect(attachmentKindOf(Uint8List.fromList(utf8.encode('GIF89a'))), isNull);
      expect(attachmentKindOf(Uint8List(0)), isNull);
      expect(formatFileSize(900), '900 B');
      expect(formatFileSize(2048), '2 KB');
      expect(formatFileSize(3 * 1024 * 1024 + 512 * 1024), '3.5 MB');
    });

    test('messages carry their attachments', () {
      final message = messageFromJson({
        'id': 'm1',
        'conversation_id': 'c1',
        'seq': 1,
        'role': 'user',
        'content': '',
        'status': 'complete',
        'provider': null,
        'model': null,
        'usage': null,
        'audio_metadata': null,
        'metadata': null,
        'attachments': [
          {
            'id': 'a1',
            'kind': 'pdf',
            'filename': 'report.pdf',
            'content_type': 'application/pdf',
            'size_bytes': 2048,
            'conversation_id': 'c1',
            'message_id': 'm1',
            'created_at': '2026-11-21T10:00:00+00:00',
          },
        ],
        'created_at': '2026-11-21T10:00:00+00:00',
        'updated_at': '2026-11-21T10:00:00+00:00',
        'edited_at': null,
      });
      final [attachment] = message.attachments;
      expect(
        (attachment.kind, attachment.filename, attachment.sizeBytes, attachment.messageId),
        (AttachmentKind.pdf, 'report.pdf', 2048, 'm1'),
      );
    });
  });

  testWidgets('attach an image and a PDF, see them upload, and send them with the message', (tester) async {
    final setup = Setup();
    setup.picker
      ..images = [PickedFile(name: 'cat.png', bytes: tinyPng)]
      ..pdfs = [PickedFile(name: 'menu.pdf', bytes: tinyPdf)];
    final gate = setup.attachments.gate = Completer<void>();
    await setup.pump(tester);

    await choose(tester, 'Images');
    expect(find.bySemanticsLabel(RegExp('Image cat.png, uploading')), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'What is in these?');
    await tester.pump();
    final send = find.byTooltip('Wait for the uploads to finish');
    expect(send, findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(of: find.byIcon(Icons.arrow_upward_rounded), matching: find.byType(IconButton)),
          )
          .onPressed,
      isNull,
    );

    gate.complete();
    await tester.pumpAndSettle();
    await choose(tester, 'PDF documents');
    expect(find.text('menu.pdf'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final command = setup.stream.commands.single;
    expect(command['content'], 'What is in these?');
    expect(command['attachment_ids'], ['att-1', 'att-2']);
    final [conversation] = (await setup.repo.list()).items;
    final [user, _] = setup.repo.messagesSync(conversation.id);
    expect(user.attachments.map((a) => a.filename), ['cat.png', 'menu.pdf']);

    // The sent message shows the image thumbnail and the PDF chip; the composer is empty again.
    expect(find.bySemanticsLabel(RegExp('Image cat.png. Open')), findsOneWidget);
    expect(find.text('PDF · 68 B'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(', uploading')), findsNothing);
    expect(find.text('Nice picture'), findsOneWidget);

    // Tapping the thumbnail opens the full-screen viewer.
    await tester.tap(find.bySemanticsLabel(RegExp('Image cat.png. Open')));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets('an image alone can be sent; removing a chip deletes the upload', (tester) async {
    final setup = Setup();
    setup.picker.images = [PickedFile(name: 'a.png', bytes: tinyPng), PickedFile(name: 'b.png', bytes: tinyPng)];
    await setup.pump(tester);

    await choose(tester, 'Images');
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pumpAndSettle();
    expect(setup.attachments.deleted, ['att-1']);

    await tester.tap(find.byTooltip('Send (Enter)'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(setup.stream.commands.single['content'], '');
    expect(setup.stream.commands.single['attachment_ids'], ['att-2']);
  });

  testWidgets('only what the model reads is offered; other files are explained', (tester) async {
    final setup = Setup();
    setup.picker.images = [
      PickedFile(name: 'notes.txt', bytes: Uint8List.fromList(utf8.encode('hello'))),
      PickedFile(name: 'huge.png', bytes: Uint8List.fromList([...tinyPng, ...Uint8List(AttachmentLimits.maxBytes)])),
    ];
    await setup.pump(
      tester,
      catalog: ProviderCatalog(
        defaultProviderId: 'acme',
        providers: [
          AIProviderInfo(
            id: 'acme',
            displayName: 'Acme AI',
            models: [visionCatalog.providers.single.models[1]], // images only
          ),
        ],
      ),
    );

    await tester.tap(attachButton);
    await tester.pumpAndSettle();
    expect(find.text('Images'), findsOneWidget);
    expect(find.text('PDF documents'), findsNothing);
    await tester.tap(find.text('Images'));
    await tester.pumpAndSettle();
    expect(find.textContaining('notes.txt is not a PNG, JPEG or WEBP image or a PDF.'), findsOneWidget);
    expect(find.textContaining('huge.png is larger than 10.0 MB.'), findsOneWidget);
    expect(setup.attachments.uploaded, isEmpty);
  });

  testWidgets('a text-only model disables attaching', (tester) async {
    final setup = Setup();
    await setup.pump(tester, catalog: sampleCatalog); // Acme Text: no image or PDF input
    expect(attachButton, findsNothing);
    expect(find.byTooltip("Acme Text doesn't accept images or PDFs"), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add_rounded)).onPressed, isNull);
  });

  testWidgets('a failed upload is shown and blocks sending until removed', (tester) async {
    final setup = Setup();
    setup.picker.images = [PickedFile(name: 'cat.png', bytes: tinyPng)];
    setup.attachments.uploadError = const ApiException(
      code: 'attachment_too_large',
      message: 'Files can be at most 10 MB.',
    );
    await setup.pump(tester);

    await choose(tester, 'Images');
    expect(find.byTooltip('Files can be at most 10 MB.'), findsOneWidget);
    expect(find.byTooltip('Remove the files that could not be uploaded'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Send (Enter)'), findsOneWidget);
  });
}
