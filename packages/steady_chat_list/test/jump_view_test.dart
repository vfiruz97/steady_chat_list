// Widget tests of jumps (milestone 4): SPEC §18 tests 10–17.
// ignore_for_file: unawaited_futures
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/fake_chat_server.dart';
import 'support/list_harness.dart';

List<String> phases(ListHarness h) =>
    [for (final e in h.events.whereType<Jumped>()) e.jump.phase];

void main() {
  testWidgets('test 10: jump to bottom across a 1,000,000 gap', (tester) async {
    final h = ListHarness(tester, count: 1100000);
    h.controller.open(target: OpenTarget.message(k(1000000)));
    await h.pump();
    expect(h.yOf(1000000), 0);
    h.server.requests.clear();

    JumpResult? result;
    h.controller.jumpToBottom().then((r) => result = r);
    var travelled = 0.0;
    var swapped = false;
    double? last;
    for (var frame = 0; frame < 60 && result == null; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(h.visible, isNotEmpty, reason: 'frame $frame is blank');
      final atEnd = h.controller.window.value.keys.last.order == 11000000;
      if (atEnd && swapped && last != null) {
        travelled += (h.position.pixels - last).abs();
      }
      if (atEnd) {
        swapped = true;
        last = h.position.pixels;
      }
    }
    expect(result!.outcome, JumpOutcome.arrived);
    expect(result!.fetchedPages, 1);
    expect(h.server.requestsOf(PageDirection.latest), hasLength(1));
    expect(h.server.requestsOf(PageDirection.around), isEmpty);
    expect(travelled, lessThanOrEqualTo(601), reason: '≤ 1 viewport animated');
    expect(travelled, greaterThan(100), reason: 'the rest is animated');
    expect(h.bottomOf(11000000), 600);
    await h.settle(const Duration(milliseconds: 100));
    expect(h.controller.isAtBottom.value, isTrue);
    expect(h.controller.jumpInProgress.value, isNull);
    await h.dispose();
  });

  testWidgets('jump to bottom inside the window just scrolls', (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    await h.scrollBy(-900);
    await h.settle(const Duration(milliseconds: 100));
    h.server.requests.clear();
    final result = h.controller.jumpToBottom();
    await h.settle();
    expect((await result).outcome, JumpOutcome.arrived);
    expect((await result).fetchedPages, 0);
    expect(h.bottomOf(10000), 600);
    expect(h.server.requests, isEmpty);

    // Instant: no animation frames.
    await h.scrollBy(-900);
    final instant =
        h.controller.jumpToBottom(scroll: const JumpScroll.instant());
    await tester.pump();
    await tester.pump();
    expect(h.bottomOf(10000), 600);
    expect((await instant).outcome, JumpOutcome.arrived);
    await h.dispose();
  });

  testWidgets('test 11: a search jump swaps the window, centers and flashes',
      (tester) async {
    final h = ListHarness(tester)..flash = true;
    h.controller.open();
    await h.pump();
    h.server
      ..latency = const Duration(milliseconds: 100) // under the spinner delay
      ..requests.clear();
    h.events.clear();

    JumpResult? result;
    h.controller
        .jumpTo(
          k(8000),
          options: const JumpOptions(
            reason: JumpReason.search,
            highlightQuery: 'invoice',
          ),
        )
        .then((r) => result = r);
    // While the page loads the old content stays.
    await tester.pump(const Duration(milliseconds: 60));
    expect(h.yOf(10000), isNotNull);
    await tester.pump(const Duration(milliseconds: 60));
    // The frame the window is swapped: the target starts ≤ 1 viewport away
    // from where it will end (centered: y = 275).
    await tester.pump();
    final start = h.yOf(8000);
    expect(start, isNotNull, reason: 'swapped in one frame');
    expect((start! - 275).abs(), lessThanOrEqualTo(600));
    expect((start - 275).abs(), greaterThan(50), reason: 'the rest animates');
    expect(h.yOf(10000), isNull);
    await h.settle(const Duration(milliseconds: 500));
    expect(result!.outcome, JumpOutcome.arrived);
    expect(result!.fetchedPages, 1);
    expect(result!.landedOn, k(8000));
    expect(h.server.requestsOf(PageDirection.around), hasLength(1));
    expect(h.yOf(8000), moreOrLessEquals(275, epsilon: 1));

    // The flash: 1 → 0 over one second, then gone.
    final info = h.infos['m8000']!;
    expect(info.highlightReason, JumpReason.search);
    expect(info.highlightQuery, 'invoice');
    expect(h.infos['m8010']!.highlightQuery, 'invoice');
    expect(h.infos['m8010']!.highlight, isNull);
    expect(info.highlight!.value, greaterThan(0.2));
    await h.settle(const Duration(milliseconds: 1100));
    expect(h.infos['m8000']!.highlight, isNull);
    expect(phases(h), ['started', 'scrolling', 'arrived', 'highlightEnded']);
    expect(h.controller.highlighted.value, isNull);
    h.controller.clearHighlightQuery();
    await tester.pump();
    expect(h.infos['m8000']!.highlightQuery, isNull);

    // Scrolling down afterwards merges the island with the live segment.
    for (var i = 0; i < 80 && !h.controller.isAtBottom.value; i++) {
      h.position.jumpTo(h.position.maxScrollExtent);
      await h.settle(const Duration(milliseconds: 250));
    }
    expect(h.bottomOf(10000), 600);
    expect(h.hub.store.peek(chat)!.segments, hasLength(1));
    await h.dispose();
  });

  testWidgets('a target taller than the viewport is top-aligned',
      (tester) async {
    final h = ListHarness(tester);
    h.heights['m8000'] = 900;
    h.controller.open();
    await h.pump();
    final result = h.controller.jumpTo(k(8000));
    await h.settle();
    expect((await result).outcome, JumpOutcome.arrived);
    expect(h.yOf(8000), moreOrLessEquals(0, epsilon: 1));
    await h.dispose();
  });

  testWidgets('test 13: every alignment lands within 1 px', (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    Future<double> land(int order, JumpAlignment alignment) async {
      final result = h.controller.jumpTo(
        k(order),
        options: JumpOptions(alignment: alignment),
      );
      await h.settle();
      expect((await result).outcome, JumpOutcome.arrived, reason: '$alignment');
      return h.yOf(order)!;
    }

    expect(
      await land(5000, const JumpAlignment.top(inset: 40)),
      moreOrLessEquals(40, epsilon: 1),
    );
    expect(
      await land(6000, const JumpAlignment.bottom(inset: 20)),
      moreOrLessEquals(530, epsilon: 1),
    );
    expect(
      await land(7000, const JumpAlignment.fraction(0.25)),
      moreOrLessEquals(137.5, epsilon: 1),
    );
    expect(
      await land(4000, const JumpAlignment.centerIfFits(topInset: 100)),
      moreOrLessEquals(325, epsilon: 1),
    );
    // Minimal: from above it ends at the bottom edge, from below at the top.
    expect(
      await land(4200, const JumpAlignment.minimal()),
      moreOrLessEquals(550, epsilon: 1),
    );
    expect(
      await land(4050, const JumpAlignment.minimal()),
      moreOrLessEquals(0, epsilon: 1),
    );
    // In the window and built: a plain animated scroll, no swap, no fetch.
    h.server.requests.clear();
    final before = h.controller.generation;
    expect(
      await land(4100, const JumpAlignment.top()),
      moreOrLessEquals(0, epsilon: 1),
    );
    expect(h.controller.generation, before);
    expect(h.server.requestsOf(PageDirection.around), isEmpty);
    await h.dispose();
  });

  testWidgets('test 13: a fully visible target is only flashed',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    final y = h.yOf(9950)!;
    h.events.clear();
    final result = await h.controller.jumpTo(k(9950));
    await tester.pump();
    expect(result.outcome, JumpOutcome.alreadyVisible);
    expect(h.yOf(9950), y);
    expect(h.infos['m9950']!.highlight, isNotNull);
    expect(
        (await h.controller.jumpTo(
          k(9950),
          options: const JumpOptions(alignment: JumpAlignment.minimal()),
        ))
            .outcome,
        JumpOutcome.alreadyVisible);
    // Jumping to the same message again restarts the flash.
    final first = h.controller.highlighted.value!.serial;
    await h.controller.jumpTo(k(9950));
    expect(h.controller.highlighted.value!.serial, greaterThan(first));
    await h.settle(const Duration(milliseconds: 1200));
    await h.dispose();
  });

  testWidgets('test 13: a drag during a jump cancels it, without a flash',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    // Loaded but far away: no fetch, the window is swapped right away.
    h.controller.prefetchAround(k(8000));
    await h.settle(const Duration(milliseconds: 300));
    h.events.clear();
    JumpResult? result;
    h.controller.jumpTo(k(8000)).then((r) => result = r);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(result, isNull, reason: 'still animating');
    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.up();
    await h.settle(const Duration(milliseconds: 600));
    expect(result!.outcome, JumpOutcome.cancelled);
    expect(h.controller.highlighted.value, isNull);
    expect(phases(h).last, 'cancelled');
    expect(h.controller.jumpInProgress.value, isNull);
    await h.dispose();
  });

  testWidgets('test 13: a deleted target lands on the nearest message',
      (tester) async {
    final h = ListHarness(tester);
    h.server.deleted.add(8000);
    h.controller.open();
    await h.pump();
    final result = h.controller.jumpTo(k(8000));
    await h.settle();
    final landed = await result;
    expect(landed.outcome, JumpOutcome.arrivedNearest);
    // Travelling toward older messages: the next older one.
    expect(landed.landedOn, k(7990));
    expect(h.yOf(7990), moreOrLessEquals(275, epsilon: 1));
    expect(h.controller.highlighted.value, isNull, reason: 'no flash');
    await h.dispose();
  });

  testWidgets('test 13: media loading mid-jump still ends aligned',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    h.controller.prefetchAround(k(8000));
    await h.settle(const Duration(milliseconds: 300));
    JumpResult? result;
    h.controller.jumpTo(k(8000)).then((r) => result = r);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    // The target and the message before it grow while the list is moving.
    h.resize(8000, 250);
    h.resize(7990, 180);
    await h.settle(const Duration(milliseconds: 900));
    expect(result!.outcome, JumpOutcome.arrived);
    expect(tester.getSize(h.item(8000)).height, 250);
    expect(h.yOf(8000), moreOrLessEquals((600 - 250) / 2, epsilon: 1));
    await h.dispose();
  });

  testWidgets('test 13: onJump phases in order, with the rect on arrival',
      (tester) async {
    final h = ListHarness(tester);
    h.server.latency = const Duration(milliseconds: 400);
    h.controller.open();
    await h.pump();
    h.events.clear();
    final result = h.controller.jumpTo(
      k(8000),
      options: const JumpOptions(
        reason: JumpReason.reply,
        highlight: JumpHighlight(
          duration: Duration(milliseconds: 300),
          delay: Duration(milliseconds: 200),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.controller.jumpInProgress.value!.isLoading, isTrue);
    expect(h.controller.jumpInProgress.value!.target, k(8000));
    expect(h.yOf(10000), isNotNull, reason: 'no spinner in the list');
    await h.settle(const Duration(milliseconds: 900));
    await result;
    expect(h.controller.jumpInProgress.value, isNull);
    // The flash holds for the delay, then fades.
    expect(h.infos['m8000']!.highlight!.value, closeTo(1, 0.4));
    await h.settle(const Duration(milliseconds: 700));
    expect(phases(h), [
      'started',
      'loading',
      'scrolling',
      'arrived',
      'highlightEnded',
    ]);
    final arrived = h.events
        .whereType<Jumped>()
        .map((e) => e.jump)
        .whereType<JumpArrived>()
        .single;
    expect(arrived.rect!.top, moreOrLessEquals(275, epsilon: 1));
    expect(arrived.rect!.height, 50);
    expect(arrived.reason, JumpReason.reply);
    expect(arrived.toMap()['outcome'], 'arrived');
    expect(h.controller.rectOf(k(8000)), arrived.rect);
    expect(h.controller.rectOf(k(10)), isNull);
    await h.dispose();
  });

  testWidgets('test 14: jump to date lands on the first message of the day',
      (tester) async {
    final h = ListHarness(tester, count: 100000)..dayHeaders = true;
    h.controller.open();
    await h.pump();
    // The day of message 500,000 (one message every 10 minutes).
    final some = const MsgAdapter().dateOf(const Msg(500000)).toLocal();
    final day = DateTime(some.year, some.month, some.day);
    final result =
        h.controller.jumpToDate(DateTime(day.year, day.month, day.day, 15));
    await h.settle();
    final landed = await result;
    expect(landed.outcome, JumpOutcome.arrived);
    final first = landed.landedOn!;
    DateTime dateOf(int order) => const MsgAdapter().dateOf(Msg(order));
    expect(dateOf(first.order).isBefore(day), isFalse);
    expect(dateOf(first.order - 10).isBefore(day), isTrue);
    // The day header is at the top, the message right below it.
    final header =
        find.byKey(ValueKey('day-${day.year}-${day.month}-${day.day}'));
    expect(tester.getTopLeft(header).dy, moreOrLessEquals(0, epsilon: 1));
    expect(h.yOf(first.order), moreOrLessEquals(24, epsilon: 1));
    expect(h.controller.highlighted.value, isNull);

    // The same day again is in memory: no fetch.
    await h.scrollBy(900);
    h.server.requests.clear();
    final again = h.controller.jumpToDate(day);
    await h.settle();
    expect((await again).landedOn, first);
    expect(h.server.requestsOf(PageDirection.around), isEmpty);

    // A day after the last message: the newest one.
    final late = h.controller.jumpToDate(DateTime(2100));
    await h.settle();
    expect((await late).landedOn, k(1000000));
    await h.dispose();
  });

  testWidgets('test 15: mentions and reactions, oldest first', (tester) async {
    final h = ListHarness(tester);
    h.server.readState = ReadState(
      lastReadInbox: k(10000),
      unreadMentions: [k(9500), k(9200)],
      unreadReactions: [k(9700)],
    );
    h.controller.open();
    await h.pump();
    expect(h.controller.unreadMentionsCount.value, 2);
    expect(h.controller.unreadReactionsCount.value, 1);
    // The server no longer repeats the list once we changed it locally.
    h.server.readState = null;

    // Scroll far above both, so "after the top of the viewport" finds them.
    final up = h.controller.jumpTo(k(9000));
    await h.settle();
    await up;

    var result = h.controller.jumpToNextUnreadMention();
    await h.settle();
    expect((await result).landedOn, k(9200));
    expect(h.yOf(9200), moreOrLessEquals(275, epsilon: 1));
    expect(h.controller.unreadMentionsCount.value, 1);

    result = h.controller.jumpToNextUnreadMention();
    await h.settle();
    expect((await result).landedOn, k(9500));
    expect(h.controller.unreadMentionsCount.value, 0);
    expect(
      (await h.controller.jumpToNextUnreadMention()).outcome,
      JumpOutcome.failed,
    );

    result = h.controller.jumpToNextUnreadReaction();
    await h.settle();
    expect((await result).landedOn, k(9700));
    expect(h.controller.unreadReactionsCount.value, 0);
    expect(
      h.events
          .whereType<Jumped>()
          .where((e) => e.jump is JumpArrived)
          .last
          .jump
          .reason,
      JumpReason.reaction,
    );
    await h.dispose();
  });

  testWidgets('test 16: the current pinned message follows the scroll',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    h.server.push(PinnedChanged<Msg>(chat, [k(9000), k(9600), k(9950)]));
    await h.settle(const Duration(milliseconds: 100));
    // The top visible message is 9890: the newest pinned at or before it.
    expect(h.controller.currentPinned.value, k(9600));
    await h.scrollBy(-1600);
    await h.settle(const Duration(milliseconds: 100));
    expect(h.visible.first, lessThan(9600));
    expect(h.controller.currentPinned.value, k(9000));
    expect(
      [for (final e in h.events.whereType<CurrentPinnedChanged>()) e.key],
      [k(9600), k(9000)],
    );

    final result = h.controller.jumpToPinned(k(9600), barHeight: 48);
    await h.settle();
    expect((await result).outcome, JumpOutcome.arrived);
    expect(h.yOf(9600), moreOrLessEquals(48, epsilon: 1));
    await h.dispose();
  });

  for (final behavior in ReselectBehavior.values) {
    testWidgets('test 17: reselect (${behavior.name})', (tester) async {
      final h = ListHarness(
        tester,
        config: MessageListConfig(reselectBehavior: behavior),
      );
      h.controller.open();
      await h.pump();
      await h.scrollBy(-900);
      await h.settle(const Duration(milliseconds: 100));
      final top = h.visible.first;
      final y = h.yOf(top);
      h.events.clear();
      final oldest = h.controller.window.value.keys.first.order;
      h.controller.reselect();
      await h.settle();
      switch (behavior) {
        case ReselectBehavior.jumpToBottom:
          expect(h.bottomOf(10000), 600);
          expect(
            h.events.whereType<Jumped>().first.jump.reason,
            JumpReason.reselect,
          );
        case ReselectBehavior.scrollToTopOfWindow:
          expect(h.visible.first, lessThanOrEqualTo(oldest));
          expect(h.visible.first, lessThan(top));
        case ReselectBehavior.none:
          expect(h.yOf(top), y);
          expect(h.events.whereType<Jumped>(), isEmpty);
      }
      await h.dispose();
    });
  }

  testWidgets('a link to a message in the open chat jumps in place',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    final generation = h.controller.generation;
    final opened = h.controller.switchTo(
      chat,
      target: OpenTarget.message(k(9950)),
    );
    await h.settle();
    expect(await opened, OpenResolution.target);
    expect(h.controller.generation, generation, reason: 'no reopen');
    expect(
      h.events.whereType<Jumped>().first.jump.reason,
      JumpReason.deepLink,
    );
    await h.settle(const Duration(milliseconds: 1200));
    await h.dispose();
  });

  testWidgets('JumpHighlightBackground paints only while flashing',
      (tester) async {
    final controller = AnimationController(
      vsync: tester,
      value: 1,
      duration: const Duration(seconds: 1),
    );
    Widget build(MessageItemInfo info) => Directionality(
          textDirection: TextDirection.ltr,
          child: JumpHighlightBackground(
            info: info,
            color: const Color(0x80FF0000),
            child: const SizedBox(width: 10, height: 10),
          ),
        );
    await tester.pumpWidget(build(MessageItemInfo(key: k(1))));
    expect(find.byType(ColoredBox), findsNothing);
    await tester.pumpWidget(
      build(
          MessageItemInfo(key: k(1), highlight: ReverseAnimation(controller))),
    );
    controller.value = 0; // reversed: full strength
    await tester.pump();
    expect(
      tester.widget<ColoredBox>(find.byType(ColoredBox)).color,
      const Color(0x80FF0000),
    );
    controller.value = 1;
    await tester.pump();
    expect(
      tester.widget<ColoredBox>(find.byType(ColoredBox)).color,
      const Color(0x00FF0000),
    );
    controller.dispose();
  });
}
