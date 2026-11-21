// Widget tests of the view (milestone 3): SPEC §18 tests 1, 2, 5, 6, 18, 19
// and the visual half of test 4.
// ignore_for_file: unawaited_futures
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/fake_chat_server.dart';
import 'support/list_harness.dart';

void main() {
  testWidgets('cold open: loading, then the newest message at the bottom',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await tester.pumpWidget(h.build());
    expect(h.builtItems, 0);
    await h.settle();
    expect(h.bottomOf(10000), 600);
    expect(h.visible, [for (var o = 9890; o <= 10000; o += 10) o]);
    expect(h.controller.isAtBottom.value, isTrue);
    expect(h.position.isPinned, isTrue);
    await h.dispose();
  });

  testWidgets('content shorter than the viewport sits at the bottom',
      (tester) async {
    final h = ListHarness(tester, count: 3);
    h.controller.open();
    await h.pump();
    expect(h.yOf(10), 450);
    expect(h.bottomOf(30), 600);
    expect(h.position.minScrollExtent, h.position.maxScrollExtent);
    // The next messages push it up, still at the bottom.
    h.server.incoming(chat);
    await h.settle(const Duration(milliseconds: 100));
    expect(h.yOf(10), 400);
    expect(h.bottomOf(40), 600);
    await h.dispose();
  });

  testWidgets('test 1: restore after restart, on the first pump',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    await h.scrollBy(-1600);
    await h.scrollBy(-13);
    await h.settle(const Duration(milliseconds: 100));
    final anchor = h.visible.first;
    final y = h.yOf(anchor)!;
    expect(y, lessThan(0), reason: 'partly scrolled out, a real offset');
    await h.dispose();

    h.controller = h.newController()..open();
    await tester.pumpWidget(h.build()); // one pump, no settling
    expect(h.yOf(anchor), moreOrLessEquals(y, epsilon: 1));
    expect(h.visible.first, anchor);
    await h.settle();
    expect(h.yOf(anchor), moreOrLessEquals(y, epsilon: 1));
    await h.dispose();
  });

  testWidgets('test 1: a reload restores from the persisted position',
      (tester) async {
    final store = InMemoryViewportStore();
    final h = ListHarness(tester, viewportStore: store);
    h.controller.open();
    await h.pump();
    await h.scrollBy(-1613);
    await h.settle(const Duration(milliseconds: 100));
    final anchor = h.visible.first;
    final y = h.yOf(anchor)!;
    await h.dispose();

    // A new hub: nothing in memory, as after a browser reload.
    h.hub = h.newHub();
    h.controller = h.newController()..open();
    await h.pump();
    expect(h.yOf(anchor), moreOrLessEquals(y, epsilon: 1));
    await h.dispose();
  });

  testWidgets('test 2: an island position survives a chat switch',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open(target: OpenTarget.message(k(4000)));
    await h.pump();
    expect(h.yOf(4000), 0);
    await h.scrollBy(137);
    await h.settle(const Duration(milliseconds: 100));
    final anchor = h.visible.first;
    final y = h.yOf(anchor)!;

    h.controller.switchTo(other);
    await tester.pump();
    expect(h.yOf(anchor), y, reason: 'old list stays until the new is ready');
    await h.settle();
    expect(h.bottomOf(10000), 600);

    h.controller.switchTo(chat);
    await tester.pump();
    expect(h.yOf(anchor), moreOrLessEquals(y, epsilon: 1));
    await h.settle();
    expect(h.yOf(anchor), moreOrLessEquals(y, epsilon: 1));
    expect(h.controller.isAtBottom.value, isFalse);
    await h.dispose();
  });

  testWidgets('test 4: the unread divider is 10 px from the top',
      (tester) async {
    final h = ListHarness(tester);
    h.server.readState = ReadState(lastReadInbox: k(9700), unreadCount: 30);
    h.controller.open();
    await h.pump();
    expect(tester.getTopLeft(find.byKey(const ValueKey('divider'))).dy, 10);
    expect(h.yOf(9710), 40);
    await h.settle(const Duration(seconds: 2));
    expect(tester.getTopLeft(find.byKey(const ValueKey('divider'))).dy, 10);
    expect(h.controller.unreadCount.value, lessThan(30));
    await h.dispose();

    final two = ListHarness(tester);
    two.server.readState = ReadState(lastReadInbox: k(9980), unreadCount: 2);
    two.controller.open();
    await two.pump();
    expect(find.byKey(const ValueKey('divider')), findsOneWidget);
    expect(two.bottomOf(10000), 600, reason: 'aligned to the bottom');
    await two.dispose();
  });

  testWidgets('test 5: 20 pages up, ≤ 80 built, the anchor never moves',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    for (var page = 0; page < 20; page++) {
      h.position.jumpTo(h.position.minScrollExtent);
      await tester.pump();
      final anchor = h.visible.first;
      final y = h.yOf(anchor)!;
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(h.controller.window.value.keys.length, lessThanOrEqualTo(80));
        expect(h.builtItems, lessThanOrEqualTo(80));
        expect(
          h.yOf(anchor),
          moreOrLessEquals(y, epsilon: 1),
          reason: 'page $page, frame $frame',
        );
      }
    }
    expect(h.controller.window.value.keys.first.order, lessThan(2500));
    expect(h.server.requestsOf(PageDirection.older).length, greaterThan(15));

    // And back down to the newest message.
    for (var page = 0; page < 30; page++) {
      h.position.jumpTo(h.position.maxScrollExtent);
      await tester.pump();
      final anchor = h.visible.first;
      final y = h.yOf(anchor)!;
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(h.builtItems, lessThanOrEqualTo(80));
        expect(
          h.yOf(anchor),
          moreOrLessEquals(y, epsilon: 1),
          reason: 'down $page, frame $frame',
        );
      }
    }
    expect(h.bottomOf(10000), 600);
    expect(h.controller.isAtBottom.value, isTrue);
    await h.dispose();
  });

  for (final lower in [false, true]) {
    testWidgets(
        'test 6: media resize above the viewport moves nothing '
        '(${lower ? 'below' : 'above'} the center)', (tester) async {
      final h = ListHarness(tester);
      // Opening at a message puts the rows after it below the center;
      // opening at the bottom puts everything above the center.
      h.controller.open(
        target: lower ? OpenTarget.message(k(5000)) : const OpenTarget.bottom(),
      );
      await h.pump();
      await h.scrollBy(lower ? 720 : -720);
      await h.settle(const Duration(milliseconds: 100));
      final visible = h.visible;
      final ys = [for (final o in visible) h.yOf(o)!];
      final above = visible.first - 30;
      expect(h.yOf(above), isNotNull, reason: 'built in the cache area');
      expect(h.yOf(above)!, lessThan(-50));

      h.resize(above, 250); // +200 px
      await tester.pump();
      expect([for (final o in visible) h.yOf(o)!], ys);
      expect(tester.getSize(h.item(above)).height, 250);
      // Above the center, content grows away from the viewport by itself;
      // below it, the position had to correct.
      expect(
        h.events
            .whereType<DiagnosticReported>()
            .where((e) => e.diagnostic is AnchorCorrected)
            .isNotEmpty,
        lower,
      );

      // Below the viewport: nothing to correct either.
      h.resize(visible.last + 20, 250);
      await tester.pump();
      expect([for (final o in visible) h.yOf(o)!], ys);
      await h.dispose();
    });
  }

  testWidgets('one message change rebuilds one item', (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    h.builds.clear();
    h.controller.patch('m9950', (m) => Msg(m.order, rev: m.rev + 1));
    await tester.pump();
    expect(h.builds, {'m9950': 1});

    // A new message builds itself (and its neighbour's grouping may change).
    h.builds.clear();
    h.server.incoming(chat);
    await h.settle(const Duration(milliseconds: 100));
    expect(h.builds.keys.toSet().difference({'m10010', 'm10000'}), isEmpty);
    expect(h.builds['m10010'], 1);
    await h.dispose();
  });

  testWidgets('incoming: pinned at the bottom, still when scrolled up',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    for (var i = 0; i < 5; i++) {
      h.server.incoming(chat);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump();
      expect(h.bottomOf(h.server.newest), 600);
    }
    await h.settle();
    expect(h.controller.unreadCount.value, 0);
    await h.scrollBy(-700);
    await h.settle(const Duration(milliseconds: 100));
    final visible = h.visible;
    final ys = [for (final o in visible) h.yOf(o)!];
    for (var i = 0; i < 5; i++) {
      h.server.incoming(chat);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump();
    }
    expect([for (final o in visible) h.yOf(o)!], ys);
    expect(h.controller.unreadCount.value, 5);
    expect(h.controller.showScrollDownButton.value, isTrue);
    await h.dispose();
  });

  testWidgets(
      'a delete above the viewport moves nothing (better than '
      'Telegram)', (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    await h.scrollBy(-700);
    await h.settle(const Duration(milliseconds: 100));
    final visible = h.visible;
    final ys = [for (final o in visible) h.yOf(o)!];
    h.controller.remove(['m${visible.first - 20}', 'm${visible.first - 40}']);
    await tester.pump();
    await tester.pump();
    expect([for (final o in visible) h.yOf(o)!], ys);

    // Inside the viewport: rows above stay, rows below move up.
    h.controller.remove(['m${visible[3]}']);
    await tester.pump();
    await tester.pump();
    expect(h.yOf(visible[2]), ys[2]);
    expect(h.yOf(visible[4]), ys[3]);
    await h.dispose();
  });

  testWidgets('test 18: keyboard and footer at the bottom stay pinned',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    // The keyboard animates in: the viewport shrinks frame by frame.
    for (final height in [560.0, 480.0, 380.0, 300.0]) {
      h.size = Size(400, height);
      await tester.pumpWidget(h.build());
      expect(h.bottomOf(10000), height, reason: 'same frame, no jank');
    }
    for (final height in [380.0, 500.0, 600.0]) {
      h.size = Size(400, height);
      await tester.pumpWidget(h.build());
      expect(h.bottomOf(10000), height);
    }
    // A typing indicator appears, grows and goes away.
    for (final footer in [24.0, 40.0, 0.0]) {
      h.footer = footer;
      await tester.pumpWidget(h.build());
      expect(h.bottomOf(10000), 600 - footer);
    }
    expect(h.controller.isAtBottom.value, isTrue);
    await h.dispose();
  });

  testWidgets('test 18: keyboard and footer scrolled up keep the anchor',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    await h.scrollBy(-713);
    await h.settle(const Duration(milliseconds: 100));
    final anchor = h.visible.first;
    final y = h.yOf(anchor)!;
    for (final height in [480.0, 300.0, 600.0]) {
      h.size = Size(400, height);
      await tester.pumpWidget(h.build());
      expect(h.yOf(anchor), y);
    }
    h.footer = 40;
    await tester.pumpWidget(h.build());
    expect(h.yOf(anchor), y);
    await h.dispose();
  });

  testWidgets('test 19: a width change keeps the anchor', (tester) async {
    final h = ListHarness(tester)..area = 20000; // 50 px at 400 wide
    h.controller.open();
    await h.pump();
    await h.scrollBy(-713);
    await h.settle(const Duration(milliseconds: 100));
    final anchor = h.visible.first;
    final y = h.yOf(anchor)!;
    for (final width in [300.0, 250.0, 520.0, 400.0]) {
      h.size = Size(width, 600);
      await tester.pumpWidget(h.build());
      expect(
        h.yOf(anchor),
        moreOrLessEquals(y, epsilon: 1),
        reason: 'width $width',
      );
      await tester.pump();
      expect(h.yOf(anchor), moreOrLessEquals(y, epsilon: 1));
    }
    await h.dispose();
  });

  testWidgets('user scrolling is never fought', (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    // Leave the bottom slowly: small steps inside the stick threshold.
    for (var i = 1; i <= 10; i++) {
      await h.scrollBy(-5);
      expect(h.bottomOf(10000), 600 + 5.0 * i);
    }
    // A drag and a fling.
    await tester.drag(find.byType(MessageListView<Msg>), const Offset(0, 300));
    await tester.pump();
    expect(h.bottomOf(10000), greaterThan(900));
    await tester.fling(
      find.byType(MessageListView<Msg>),
      const Offset(0, 300),
      2000,
    );
    await h.settle(const Duration(seconds: 3));
    expect(h.controller.isAtBottom.value, isFalse);
    expect(h.visible, isNotEmpty);
    await h.dispose();
  });

  testWidgets('phases: loading, error and empty builders', (tester) async {
    final server = FakeChatServer(count: 0)..failNextFetches = 5;
    final hub =
        MessageListHub<Msg>(source: server, adapter: const MsgAdapter());
    final controller = MessageListController<Msg>(hub: hub, list: chat)..open();
    Widget view() => Directionality(
          textDirection: TextDirection.ltr,
          child: MessageListView<Msg>(
            controller: controller,
            itemBuilder: (context, m, info) => Text(m.id),
            loadingBuilder: (context) => const Text('loading'),
            errorBuilder: (context) => const Text('error'),
            emptyBuilder: (context) => const Text('empty'),
          ),
        );
    await tester.pumpWidget(view());
    expect(find.text('loading'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.text('error'), findsOneWidget);
    controller.open();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('empty'), findsOneWidget);
    server.incoming(chat);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(find.text('m10'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump(const Duration(seconds: 40));
  });
}
