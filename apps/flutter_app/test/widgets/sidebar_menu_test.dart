import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:voice_assistant/app.dart';

import '../support/fakes.dart';

/// Regression: on desktop the "more" button appears on hover. Moving the mouse
/// onto the opened menu un-hovers the tile; the button must stay mounted or
/// the chosen action is silently dropped.
void main() {
  testWidgets('rename via the hover menu works with a mouse', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final repo = FakeConversationRepository()..seed('Old title');
    final overrides = await fakeOverrides(conversations: repo);
    await tester.pumpWidget(
      ProviderScope(overrides: overrides, retry: (_, _) => null, child: const VoiceAssistantApp()),
    );
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // Hover the tile: the menu button appears only now.
    expect(find.byTooltip('Conversation options'), findsNothing);
    await mouse.moveTo(tester.getCenter(find.text('Old title')));
    await tester.pumpAndSettle();
    final moreButton = find.byTooltip('Conversation options');
    expect(moreButton, findsOneWidget);

    // Open the menu with the mouse, then move onto the menu item (leaving the tile).
    await mouse.moveTo(tester.getCenter(moreButton));
    await mouse.down(tester.getCenter(moreButton));
    await mouse.up();
    await tester.pumpAndSettle();
    final renameItem = find.text('Rename');
    await mouse.moveTo(tester.getCenter(renameItem));
    await tester.pumpAndSettle();
    await mouse.down(tester.getCenter(renameItem));
    await mouse.up();
    await tester.pumpAndSettle();

    expect(find.text('Rename conversation'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'New title');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(find.text('New title'), findsOneWidget);
    expect((await repo.list()).items.single.title, 'New title');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('long-press opens the menu on desktop touchscreens (no hover) and delete works', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final repo = FakeConversationRepository()..seed('Touch me');
    final overrides = await fakeOverrides(conversations: repo);
    await tester.pumpWidget(
      ProviderScope(overrides: overrides, retry: (_, _) => null, child: const VoiceAssistantApp()),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Conversation options'), findsNothing);
    await tester.longPress(find.text('Touch me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete conversation?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Touch me'), findsNothing);
    expect((await repo.list()).items, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
