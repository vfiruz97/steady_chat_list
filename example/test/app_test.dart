import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_chat_list/steady_chat_list.dart';
import 'package:steady_chat_list_example/data/models.dart';
import 'package:steady_chat_list_example/demo.dart';
import 'package:steady_chat_list_example/main.dart';
import 'package:steady_chat_list_example/widgets/bubble.dart';

Future<Demo> newDemo() async =>
    Demo(preferences: await SharedPreferences.getInstance());

Future<void> settle(WidgetTester tester, [int ms = 1200]) async {
  for (var t = 0; t < ms; t += 50) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> resize(WidgetTester tester, Size size) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() async {
    tester.view.reset();
    await tester.binding.setSurfaceSize(null);
  });
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Hubs release their lists 30 s after the last view is gone.
  await tester.pump(const Duration(seconds: 40));
}

/// Top edge of every message on screen, by id.
Map<String, double> tops(WidgetTester tester) {
  final list = tester.getRect(find.byType(MessageListView<ChatMessage>));
  final result = <String, double>{};
  for (final element in find.byType(MessageBubble).evaluate()) {
    final bubble = element.widget as MessageBubble;
    final box = element.renderObject! as RenderBox;
    final top = box.localToGlobal(Offset.zero).dy;
    if (top + box.size.height > list.top && top < list.bottom) {
      result[bubble.message.id] = top;
    }
  }
  return result;
}

void main() {
  setUp(() {
    // The Drift cache needs a real SQLite; the in-memory one is used here.
    SharedPreferences.setMockInitialValues({'demo.cache': 'memory'});
  });

  testWidgets('every demo page opens and shows its description',
      (tester) async {
    // Tall enough for the whole menu.
    await resize(tester, const Size(1400, 2000));
    await tester.pumpWidget(ExampleApp(demo: await newDemo()));
    await settle(tester);
    for (final page in demoPages) {
      // The menu is the first scrollable; a tile may be below its end.
      final tile = find.descendant(
        of: find.byType(ListTile),
        matching: find.text(page.title),
      );
      await tester.scrollUntilVisible(
        tile,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(tile);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: page.title);
      // In the menu and in the page header.
      expect(find.text(page.subtitle), findsNWidgets(2), reason: page.title);
      expect(
        find.byType(MessageBubble),
        findsWidgets,
        reason: '${page.title} shows messages',
      );
    }
    await close(tester);
  });

  testWidgets('a narrow screen has the menu in a drawer', (tester) async {
    await resize(tester, const Size(400, 800));
    await tester.pumpWidget(ExampleApp(demo: await newDemo()));
    await settle(tester);
    expect(find.byType(Drawer), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await settle(tester, 500);
    expect(find.text(demoPages[3].subtitle), findsOneWidget);
    await tester.tap(find.text(demoPages[3].title));
    await settle(tester);
    expect(find.byType(MessageBubble), findsWidgets);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a restart (browser reload) returns to the page and position',
      (tester) async {
    await resize(tester, const Size(1400, 900));
    await tester.pumpWidget(ExampleApp(demo: await newDemo()));
    await settle(tester);
    await tester.tap(find.text('10,000,000 messages'));
    await settle(tester);
    // Deep into the history of a chat with thousands of unread messages.
    for (var i = 0; i < 6; i++) {
      await tester.drag(
        find.byType(MessageListView<ChatMessage>),
        const Offset(0, 500),
      );
      await settle(tester, 400);
    }
    await settle(tester, 1500); // the position is saved when scrolling stops
    final before = tops(tester);
    expect(before, isNotEmpty);
    await close(tester);

    // A new app on the same storage, as after a reload.
    await tester.pumpWidget(ExampleApp(demo: await newDemo()));
    await settle(tester);
    expect(find.text('10,000,000 messages'), findsNWidgets(2));
    final after = tops(tester);
    expect(after.keys.toSet(), before.keys.toSet());
    for (final id in before.keys) {
      expect(after[id], closeTo(before[id]!, 0.5), reason: 'message $id');
    }
    await close(tester);
  });
}
