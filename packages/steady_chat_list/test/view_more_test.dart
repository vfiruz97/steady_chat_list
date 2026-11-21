import 'dart:async';

// More widget tests: albums, day headers, padding, edges, lifecycle and
// swapping the controller.
// ignore_for_file: unawaited_futures
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/fake_chat_server.dart';
import 'support/list_harness.dart';

/// Messages 9910–9930 form one album; senders alternate every 4 messages.
Msg _decorate(Msg m) => Msg(
      m.order,
      outgoing: m.outgoing,
      group: m.order >= 9910 && m.order <= 9930 ? 'album' : null,
      sender: 'user${(m.order ~/ 40) % 2}',
    );

Widget _list(
  MessageListController<Msg> controller, {
  MessageGroupBuilder<Msg>? groupBuilder,
  DayHeaderBuilder? dayHeaderBuilder,
  void Function(DateTime)? onDayTap,
  EdgeBuilder? edgeBuilder,
  WidgetBuilder? historyStartBuilder,
  EdgeInsets padding = EdgeInsets.zero,
  bool scrollbar = true,
  List<MessageItemInfo>? infos,
}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 600,
          child: MessageListView<Msg>(
            controller: controller,
            itemBuilder: (context, message, info) {
              infos?.add(info);
              return SizedBox(
                key: ValueKey('item-${message.id}'),
                height: 50,
              );
            },
            groupBuilder: groupBuilder,
            dayHeaderBuilder: dayHeaderBuilder,
            onDayTap: onDayTap,
            edgeBuilder: edgeBuilder,
            historyStartBuilder: historyStartBuilder,
            padding: padding,
            scrollbar: scrollbar,
          ),
        ),
      ),
    );

Future<void> _settle(WidgetTester tester, [int frames = 20]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _dispose(
  WidgetTester tester,
  MessageListController<Msg> controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  await tester.pump(const Duration(seconds: 40));
}

void main() {
  testWidgets('albums are one row; grouping flags follow senders',
      (tester) async {
    final h = ListHarness(
      tester,
      decorate: _decorate,
      // Test messages are 10 minutes apart.
      config: const MessageListConfig(groupingGap: Duration(minutes: 15)),
    );
    h.controller.open();
    final infos = <MessageItemInfo>[];
    await tester.pumpWidget(
      _list(
        h.controller,
        infos: infos,
        groupBuilder: (context, messages, info) => SizedBox(
          key: const ValueKey('album'),
          height: 120,
          child: Text('${messages.length} photos'),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('3 photos'), findsOneWidget);
    expect(h.item(9920), findsNothing, reason: 'part of the album row');
    expect(tester.getSize(find.byKey(const ValueKey('album'))).height, 120);
    expect(h.bottomOf(10000), 600);

    // 9960..9990 share a sender (n ~/ 4 is constant): first, middle, last.
    MessageItemInfo of(int order) =>
        infos.lastWhere((info) => info.key == k(order));
    expect(of(9960).isFirstInGroup, isTrue);
    expect(of(9960).isLastInGroup, isFalse);
    expect(of(9970).isFirstInGroup, isFalse);
    expect(of(9970).isLastInGroup, isFalse);
    expect(of(9990).isLastInGroup, isTrue);
    expect(of(10000).isLastInGroup, isTrue);

    // Deleting one photo re-lays out the row; deleting all removes it.
    h.controller.remove(['m9920']);
    await _settle(tester, 7);
    expect(find.text('2 photos'), findsOneWidget);
    h.controller.remove(['m9910']);
    await _settle(tester, 7);
    expect(find.byKey(const ValueKey('album')), findsNothing);
    expect(h.item(9930), findsOneWidget, reason: 'a single message now');
    h.controller.remove(['m9930']);
    await _settle(tester, 7);
    expect(h.item(9930), findsNothing);
    expect(h.bottomOf(10000), 600);
    await _dispose(tester, h.controller);
  });

  testWidgets('without a group builder an album stacks its messages',
      (tester) async {
    final h = ListHarness(tester, decorate: _decorate);
    h.controller.open();
    await tester.pumpWidget(_list(h.controller));
    await _settle(tester);
    expect(h.item(9910), findsOneWidget);
    expect(h.yOf(9920)! - h.yOf(9910)!, 50);
    await _dispose(tester, h.controller);
  });

  testWidgets('day headers start each day and report taps', (tester) async {
    // One message per minute, 10 minutes apart per id step: 144 a day.
    final h = ListHarness(tester);
    h.controller.open();
    final tapped = <DateTime>[];
    await tester.pumpWidget(
      _list(
        h.controller,
        onDayTap: tapped.add,
        dayHeaderBuilder: (context, day, onTap) => GestureDetector(
          onTap: onTap,
          child: SizedBox(
            key: ValueKey('day-${day.day}'),
            height: 24,
            width: 400,
            child: const ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      ),
    );
    await _settle(tester);
    // Scroll until a header is on screen.
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    Finder header() => find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('day-'),
        );
    for (var i = 0; i < 40 && header().evaluate().isEmpty; i++) {
      position.jumpTo(
        (position.pixels - 400)
            .clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      await _settle(tester, 6);
    }
    expect(header(), findsWidgets);
    await tester.tap(header().first);
    expect(tapped, hasLength(1));
    expect(tapped.single.hour, 0);
    await _dispose(tester, h.controller);
  });

  testWidgets('padding, no scrollbar, history start and edge rows',
      (tester) async {
    final h = ListHarness(tester, count: 100);
    h.controller.open();
    Widget build() => _list(
          h.controller,
          padding: const EdgeInsets.fromLTRB(12, 30, 20, 8),
          scrollbar: false,
          historyStartBuilder: (context) =>
              const SizedBox(key: ValueKey('intro'), height: 70),
          edgeBuilder: (context, edge, state, retry) => switch (state) {
            EdgeLoading() => SizedBox(
                key: ValueKey('loading-${edge.name}'),
                height: 30,
              ),
            EdgeError() => GestureDetector(
                onTap: retry,
                child: SizedBox(
                  key: ValueKey('retry-${edge.name}'),
                  height: 30,
                  width: 400,
                  child: const ColoredBox(color: Color(0xFFFF0000)),
                ),
              ),
            _ => const SizedBox.shrink(),
          },
        );
    await tester.pumpWidget(build());
    await _settle(tester);
    final newest = tester.getRect(h.item(1000));
    expect(newest.left, 12);
    expect(newest.right, 380);
    expect(newest.bottom, 592, reason: 'bottom padding scrolls with it');

    // Up to the first message: a failing page, then the chat intro.
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    h.server.failNextFetches = 5;
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('loading-older')), findsOneWidget);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    expect(find.byKey(const ValueKey('retry-older')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-older')));
    for (var i = 0; i < 10; i++) {
      await _settle(tester, 6);
      position.jumpTo(position.minScrollExtent);
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('intro')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('intro'))).dy, 30);
    expect(h.yOf(10), 100);
    await _dispose(tester, h.controller);
  });

  testWidgets('the newer edge can fail and retry too', (tester) async {
    final h = ListHarness(tester);
    h.controller.open(target: OpenTarget.message(k(4000)));
    Widget build() => _list(
          h.controller,
          edgeBuilder: (context, edge, state, retry) => state is EdgeError
              ? GestureDetector(
                  onTap: retry,
                  child: SizedBox(
                    key: ValueKey('retry-${edge.name}'),
                    height: 30,
                    width: 400,
                    child: const ColoredBox(color: Color(0xFFFF0000)),
                  ),
                )
              : const SizedBox.shrink(),
        );
    await tester.pumpWidget(build());
    await _settle(tester, 40);
    final position =
        tester.state<ScrollableState>(find.byType(Scrollable)).position;
    // Scroll down until the window needs a page from the server.
    h.server.failNextFetches = 1000;
    for (var i = 0; i < 8; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      for (var s = 0; s < 10; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
      if (h.controller.newerEdge.value is EdgeError) break;
    }
    h.server.failNextFetches = 0;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(h.controller.newerEdge.value, isA<EdgeError>());
    final last = h.controller.window.value.keys.last;
    await tester.tap(find.byKey(const ValueKey('retry-newer')));
    await _settle(tester, 10);
    expect(h.controller.window.value.keys.last.order, greaterThan(last.order));
    await _dispose(tester, h.controller);
  });

  testWidgets('a page that arrives builds only the rows near the viewport',
      (tester) async {
    // When the window shifts, every row that stays gets another index. The
    // framework then builds a row at each index that became free: rows far
    // away, built in one frame and dropped by the next layout.
    final h = ListHarness(tester, count: 100000);
    unawaited(h.controller.open(target: OpenTarget.message(k(500000))));
    await h.pump();
    var most = 0;
    final start = h.inits.length;
    for (var frame = 0; frame < 300; frame++) {
      final before = h.inits.length;
      await h.scrollBy(-60);
      await tester.pump(const Duration(milliseconds: 16));
      final created = h.inits.length - before;
      if (created > most) most = created;
    }
    // 600 px of viewport and 800 px of cache area hold 28 rows of 50 px.
    expect(most, lessThanOrEqualTo(20));
    // Scrolling one way, a row is created once: none is built ahead of
    // time, dropped and built again.
    final counts = <String, int>{};
    for (final id in h.inits.skip(start)) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    expect(counts.values.where((n) => n > 1), isEmpty);
    expect(counts.length, greaterThan(300));
    await h.dispose();
  });

  testWidgets('memory stays bounded during one long uninterrupted scroll',
      (tester) async {
    // No pause, so the saved position stays where the scroll began: what
    // lies between it and the window must still be dropped.
    final h = ListHarness(tester, count: 100000);
    h.server.latency = const Duration(milliseconds: 1);
    unawaited(h.controller.open(target: OpenTarget.message(k(500000))));
    await h.pump();
    final start = h.visible.first;
    for (var i = 0; i < 400; i++) {
      await h.scrollBy(-1500);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(start - h.visible.first, greaterThan(50000));
    final store = h.hub.store.peek(chat)!;
    expect(store.length, lessThanOrEqualTo(1000 + 2 * 40));
    for (final key in h.controller.window.value.keys) {
      expect(store.contains(key.id), isTrue);
    }
    store.debugCheckInvariants();
    // Scrolling back down still works across the trimmed part.
    for (var i = 0; i < 40; i++) {
      await h.scrollBy(1500);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await h.settle();
    expect(h.visible, isNotEmpty);
    await h.dispose();
  });

  testWidgets('the debug overlay shows the window, segments and corrections',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open(target: OpenTarget.message(k(5000)));
    Widget build() => Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 600,
              child: MessageListView<Msg>(
                controller: h.controller,
                debugOverlay: true,
                itemBuilder: (context, m, info) => SizedBox(
                  key: ValueKey('item-${m.id}'),
                  height: h.heights[m.id] ?? 50,
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(build());
    await h.settle();
    await h.scrollBy(600);
    await h.settle(const Duration(milliseconds: 100));
    String overlay() => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .firstWhere((t) => t.contains('generation'));
    expect(overlay(), contains('list chat · generation'));
    expect(overlay(), contains('window: '));
    expect(overlay(), contains('island Segment('));
    expect(overlay(), contains('edges: older'));
    expect(overlay(), contains('pending fetches: none'));
    expect(overlay(), contains('last anchor correction: 0.00 px'));
    // A resize above the viewport: the correction shows up.
    h.resize(h.visible.first - 30, 250);
    await tester.pump();
    await tester.pump();
    expect(overlay(), contains('last anchor correction: 200.00 px'));

    final text = h.controller.debugDescribe();
    expect(text, contains('in memory: '));
    expect(text, contains('top of viewport: ${h.visible.first}'));
    h.server.latency = const Duration(seconds: 2);
    h.controller.jumpTo(k(100));
    await tester.pump(const Duration(milliseconds: 300));
    expect(h.controller.debugDescribe(), contains('jump: programmatic → 100'));
    expect(h.controller.debugDescribe(), contains('(loading)'));
    expect(h.controller.debugDescribe(), contains('pending fetches: jump'));
    await h.settle(const Duration(seconds: 3));
    // Live segment, an edge at its end, and an empty window.
    final bottom = h.controller.jumpToBottom();
    await h.settle(const Duration(seconds: 3));
    await bottom;
    expect(h.controller.debugDescribe(), contains('live Segment('));
    expect(h.controller.debugDescribe(), contains('newer end'));
    await h.dispose();
    final empty = MessageListController<Msg>(hub: h.hub, list: other);
    expect(empty.debugDescribe(), contains('window: empty'));
    empty.dispose();
  });

  testWidgets('going to the background saves the position and stops reading',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    h.events.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(
      h.events.whereType<SnapshotSaved>().single.reason,
      SaveReason.appPaused,
    );
    h.server.incoming(chat);
    await h.settle();
    expect(h.controller.unreadCount.value, 1, reason: 'not read while hidden');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await h.settle();
    expect(h.controller.unreadCount.value, 0);
    await h.dispose();
  });

  testWidgets('the view can be given another controller', (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    final first = h.controller;
    h.controller = h.newController(list: other)
      ..open(target: OpenTarget.message(k(3000)));
    await h.pump();
    expect(h.yOf(3000), 0);
    first.dispose();
    await h.dispose();
  });

  testWidgets('read receipts show on outgoing messages (isRead)',
      (tester) async {
    final h = ListHarness(tester, outgoingEvery: 2);
    h.controller.open();
    final infos = <MessageItemInfo>[];
    await tester.pumpWidget(_list(h.controller, infos: infos));
    await _settle(tester);
    MessageItemInfo of(int order) =>
        infos.lastWhere((info) => info.key == k(order));
    expect(of(10000).sendState, SendState.sent);
    expect(of(10000).isRead, isFalse);
    expect(of(9990).sendState, SendState.none);
    h.server.push(
      ReadStateChanged(chat, ReadState(lastReadOutbox: k(9980))),
    );
    await _settle(tester, 3);
    expect(of(9980).isRead, isTrue);
    expect(of(10000).isRead, isFalse);
    expect(h.controller.lastReadOutbox.value, k(9980));
    await _dispose(tester, h.controller);
  });
}
