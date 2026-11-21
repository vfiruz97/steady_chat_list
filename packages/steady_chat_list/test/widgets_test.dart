// Milestone 6: the default widgets, the theme, the floating overlays,
// keyboard shortcuts and the swipe-to-reply helper.
// ignore_for_file: unawaited_futures
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/fake_chat_server.dart';
import 'support/list_harness.dart';

Widget _host(Widget child, {TextDirection direction = TextDirection.ltr}) =>
    Directionality(
      textDirection: direction,
      child: Align(alignment: Alignment.topLeft, child: child),
    );

Widget _listWith(
  ListHarness h, {
  bool button = false,
  bool chip = false,
  bool keys = true,
}) =>
    _host(
      SizedBox(
        width: 400,
        height: 600,
        child: MessageListView<Msg>(
          controller: h.controller,
          itemBuilder: (context, m, info) =>
              SizedBox(key: ValueKey('item-${m.id}'), height: 50),
          keyboardShortcuts: keys,
          scrollDownButtonBuilder: button
              ? (context, unread, onTap) =>
                  ScrollDownButton(unread: unread, onTap: onTap)
              : null,
          floatingDayBuilder: chip
              ? (context, day, onTap) => DayHeader(day: day, onTap: onTap)
              : null,
          dayHeaderBuilder: (context, day, onTap) =>
              DayHeader(day: day, onTap: onTap),
        ),
      ),
    );

void main() {
  test('formatUnreadCount', () {
    expect(
      [
        0,
        7,
        999,
        1000,
        1049,
        7200,
        9999,
        12345,
        999999,
        1000000,
        1500000,
        25000000
      ].map(formatUnreadCount),
      [
        '0',
        '7',
        '999',
        '1K',
        '1K',
        '7.2K',
        '9.9K',
        '12K',
        '999K',
        '1M',
        '1.5M',
        '25M'
      ],
    );
  });

  test('formatDayLabel', () {
    final now = DateTime(2026, 11, 20, 15);
    String label(int year, int month, int day) =>
        formatDayLabel(DateTime(year, month, day, 9), now: now);
    expect(label(2026, 11, 20), 'Today');
    expect(label(2026, 11, 19), 'Yesterday');
    expect(label(2026, 11, 17), 'Tuesday');
    expect(label(2026, 11, 14), 'Saturday');
    expect(label(2026, 11, 13), 'November 13');
    expect(label(2025, 1, 5), 'January 5, 2025');
    expect(label(2026, 11, 25), 'November 25', reason: 'the future');
    expect(formatDayLabel(DateTime.now()), 'Today');
  });

  testWidgets('theme: defaults, dark, scope, copyWith and lerp',
      (tester) async {
    MessageListTheme? seen;
    Widget probe() => Builder(
          builder: (context) {
            seen = MessageListTheme.of(context);
            return const SizedBox.shrink();
          },
        );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(), // light, whatever the machine uses
        child: _host(probe()),
      ),
    );
    expect(seen!.badgeColor, const MessageListTheme().badgeColor);

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(platformBrightness: Brightness.dark),
        child: _host(probe()),
      ),
    );
    expect(seen!.buttonColor, const MessageListTheme.dark().buttonColor);

    const custom = MessageListTheme(badgeColor: Color(0xFF112233));
    await tester.pumpWidget(
      MessageListThemeScope(theme: custom, child: _host(probe())),
    );
    expect(seen!.badgeColor, const Color(0xFF112233));
    final changed = custom.copyWith(
      buttonColor: const Color(0xFF000001),
      buttonIconColor: const Color(0xFF000002),
      buttonShadowColor: const Color(0xFF000003),
      badgeTextColor: const Color(0xFF000004),
      chipColor: const Color(0xFF000005),
      chipTextColor: const Color(0xFF000006),
      dividerColor: const Color(0xFF000007),
      dividerTextColor: const Color(0xFF000008),
      highlightColor: const Color(0xFF000009),
    );
    await tester.pumpWidget(
      MessageListThemeScope(theme: changed, child: _host(probe())),
    );
    expect(seen!.chipColor, const Color(0xFF000005));
    expect(seen!.badgeColor, const Color(0xFF112233), reason: 'kept');
    expect(custom.copyWith(badgeColor: const Color(0xFF445566)).badgeColor,
        const Color(0xFF445566));
    expect(custom.lerp(null, 0.5), same(custom));
    final mid = const MessageListTheme().lerp(const MessageListTheme.dark(), 1);
    expect(mid.buttonColor, const MessageListTheme.dark().buttonColor);
    expect(mid.highlightColor, const MessageListTheme.dark().highlightColor);
  });

  testWidgets('round buttons: badge, loading ring, taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScrollDownButton(unread: 7200, onTap: () => taps++),
            ScrollDownButton(unread: 0, loading: true, onTap: () => taps++),
            MentionButton(count: 3, onTap: () => taps++),
            ReactionButton(count: 12, onTap: () => taps++),
            DayHeader(day: DateTime(2020, 5, 17), label: 'May 17'),
            const UnreadDivider(text: 'New messages'),
          ],
        ),
      ),
    );
    expect(find.text('7.2K'), findsOneWidget);
    expect(find.text('@'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('May 17'), findsOneWidget);
    expect(find.text('New messages'), findsOneWidget);
    expect(find.byType(SteadySpinner), findsOneWidget);
    await tester.tap(find.byType(ScrollDownButton).first);
    await tester.tap(find.byType(MentionButton));
    await tester.tap(find.byType(ReactionButton));
    expect(taps, 3);
    // A different icon color repaints the chevron.
    await tester.pumpWidget(
      MessageListThemeScope(
        theme: const MessageListTheme.dark(),
        child: _host(ScrollDownButton(unread: 1, onTap: () {})),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('VisibleWhen keeps the last value while it animates out',
      (tester) async {
    final count = ValueNotifier(0);
    final second = ValueNotifier(5);
    Widget build(ValueNotifier<int> value) => _host(
          VisibleWhen<int>(
            value: value,
            shown: (n) => n > 0,
            builder: (context, n) => Text('$n new'),
          ),
        );
    await tester.pumpWidget(build(count));
    expect(find.textContaining('new'), findsNothing);
    count.value = 3;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('3 new'), findsOneWidget);
    count.value = 0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('3 new'), findsOneWidget, reason: 'fading out');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('new'), findsNothing);
    // Another listenable.
    await tester.pumpWidget(build(second));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('5 new'), findsOneWidget);
    count.value = 9; // the old one is no longer listened to
    await tester.pump();
    expect(find.text('5 new'), findsOneWidget);
  });

  testWidgets('the scroll-down button floats in when the bottom is far',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await tester.pumpWidget(_listWith(h, button: true));
    await h.settle();
    expect(find.byType(ScrollDownButton), findsNothing);
    await h.scrollBy(-1500);
    await h.settle(const Duration(milliseconds: 300));
    expect(find.byType(ScrollDownButton), findsOneWidget);
    final corner = tester.getBottomRight(find.byType(ScrollDownButton));
    expect(corner, const Offset(388, 588));
    for (var i = 0; i < 3; i++) {
      h.server.incoming(chat);
    }
    await h.settle(const Duration(milliseconds: 100));
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byType(ScrollDownButton));
    await h.settle();
    expect(h.controller.isAtBottom.value, isTrue);
    expect(find.byType(ScrollDownButton), findsNothing);
    await h.dispose();
  });

  testWidgets('MessageListButtons shows what has something to do',
      (tester) async {
    final h = ListHarness(tester);
    h.server.readState = ReadState(
      lastReadInbox: k(10000),
      unreadMentions: [k(9200)],
      unreadReactions: [k(9300)],
    );
    h.controller.open();
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 400,
          height: 600,
          child: Stack(
            children: [
              MessageListView<Msg>(
                controller: h.controller,
                itemBuilder: (context, m, info) =>
                    SizedBox(key: ValueKey('item-${m.id}'), height: 50),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: MessageListButtons<Msg>(controller: h.controller),
              ),
            ],
          ),
        ),
      ),
    );
    await h.settle();
    h.server.readState = null;
    expect(find.byType(MentionButton), findsOneWidget);
    expect(find.byType(ReactionButton), findsOneWidget);
    expect(find.byType(ScrollDownButton), findsNothing);
    await tester.tap(find.byType(MentionButton));
    await h.settle();
    expect(h.yOf(9200), moreOrLessEquals(275, epsilon: 1));
    expect(find.byType(MentionButton), findsNothing);
    expect(find.byType(ScrollDownButton), findsOneWidget);
    await tester.tap(find.byType(ReactionButton));
    await h.settle();
    expect(find.byType(ReactionButton), findsNothing);
    // A slow jump shows the ring on the scroll-down button.
    h.server.latency = const Duration(milliseconds: 600);
    h.controller.jumpTo(k(3000));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(SteadySpinner), findsOneWidget);
    await h.settle(const Duration(seconds: 2));
    await tester.tap(find.byType(ScrollDownButton));
    await h.settle(const Duration(seconds: 2));
    expect(h.controller.isAtBottom.value, isTrue);
    await h.dispose();
  });

  testWidgets('the floating day chip shows while scrolling, then fades',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    final taps = <DateTime>[];
    h.controller.events.listen((e) {
      if (e is DayTapped) taps.add(e.day);
    });
    await tester.pumpWidget(_listWith(h, chip: true));
    await h.settle();
    double chipOpacity() => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(DayHeader).first,
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    expect(chipOpacity(), 0);
    // A drag: the chip appears with the day of the top message.
    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(chipOpacity(), 1);
    expect(tester.getTopLeft(find.byType(DayHeader).first).dy, 0);
    await tester.tap(find.byType(DayHeader).first, warnIfMissed: false);
    await gesture.up();
    await tester.pump();
    expect(taps, [h.controller.topVisibleDay.value]);
    // A second after it stopped it fades out.
    await tester.pump(const Duration(milliseconds: 600));
    expect(chipOpacity(), 1);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));
    expect(chipOpacity(), 0);
    await h.dispose();
  });

  testWidgets('keyboard: arrows, page keys, Home and End', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final h = ListHarness(tester);
    h.controller.open();
    await tester.pumpWidget(_listWith(h));
    await h.settle();
    // Click the list to focus it.
    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    final bottom = h.position.pixels;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(h.position.pixels, bottom - 40);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(h.position.pixels, bottom);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await h.settle(const Duration(milliseconds: 300));
    expect(h.position.pixels, moreOrLessEquals(bottom - 510, epsilon: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await h.settle(const Duration(milliseconds: 300));
    expect(h.position.pixels, moreOrLessEquals(bottom, epsilon: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(h.position.pixels, moreOrLessEquals(bottom, epsilon: 1));

    final oldest = h.controller.window.value.keys.first.order;
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await h.settle();
    expect(h.yOf(oldest), isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await h.settle();
    expect(h.controller.isAtBottom.value, isTrue);
    // Ctrl+Home: the very first message of the chat.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await h.settle(const Duration(seconds: 2));
    // Its day header is at the very top, the message right below.
    expect(tester.getTopLeft(find.byType(DayHeader).first).dy, 0);
    expect(h.yOf(10), lessThan(60));
    debugDefaultTargetPlatformOverride = null;
    await h.dispose();
  });

  testWidgets('keyboard shortcuts are off on phones and when disabled',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await tester.pumpWidget(_listWith(h));
    await h.settle();
    expect(
      find.descendant(
        of: find.byType(MessageListView<Msg>),
        matching: find.byWidgetPredicate(
          (w) => w is Focus && w.debugLabel == null && w.onKeyEvent != null,
        ),
      ),
      findsNothing,
      reason: 'android: no key handling',
    );
    await h.dispose();
  });

  testWidgets('screen readers get the messages oldest to newest',
      (tester) async {
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    final keys = tester
        .widgetList<Semantics>(
          find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.sortKey is OrdinalSortKey,
          ),
        )
        .map((s) => (s.properties.sortKey! as OrdinalSortKey).order)
        .toList();
    expect(keys, isNotEmpty);
    expect(keys.toSet(), contains(10000));
    await h.dispose();
  });

  group('SwipeToReply', () {
    Future<int> swipe(
      WidgetTester tester,
      List<Offset> moves, {
      TextDirection direction = TextDirection.ltr,
      bool inScrollingList = false,
    }) async {
      var triggered = 0;
      final controller = ScrollController();
      await tester.pumpWidget(
        _host(
          direction: direction,
          SizedBox(
            width: 400,
            height: 600,
            child: ListView(
              controller: controller,
              children: [
                SwipeToReply(
                  onTriggered: () => triggered++,
                  background: (context, progress) => FadeTransition(
                    opacity: progress,
                    child: const Text('reply'),
                  ),
                  child: const SizedBox(
                    key: ValueKey('bubble'),
                    height: 80,
                    width: 400,
                    child: ColoredBox(color: Color(0xFF00FF00)),
                  ),
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      );
      if (inScrollingList) {
        controller.animateTo(
          300,
          duration: const Duration(seconds: 1),
          curve: Curves.linear,
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      final gesture = await tester.startGesture(const Offset(200, 40));
      for (final move in moves) {
        await gesture.moveBy(move);
        await tester.pump();
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      controller.dispose();
      return triggered;
    }

    testWidgets('a horizontal drag past the threshold triggers once',
        (tester) async {
      expect(
        await swipe(
            tester, const [Offset(-30, 2), Offset(-30, 1), Offset(-30, 0)]),
        1,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('bubble'))).dx,
        0,
        reason: 'it springs back',
      );
    });

    testWidgets('too short, the wrong way, or too steep: nothing',
        (tester) async {
      expect(await swipe(tester, const [Offset(-25, 0), Offset(-10, 0)]), 0);
      expect(await swipe(tester, const [Offset(40, 0), Offset(40, 0)]), 0);
      // 45°: a vertical gesture as far as the list is concerned.
      expect(
        await swipe(tester, const [Offset(-30, 30), Offset(-60, 30)]),
        0,
      );
    });

    testWidgets('right-to-left swipes the other way', (tester) async {
      expect(
        await swipe(
          tester,
          const [Offset(30, 0), Offset(30, 0), Offset(30, 0)],
          direction: TextDirection.rtl,
        ),
        1,
      );
    });

    testWidgets('never while the list is scrolling', (tester) async {
      expect(
        await swipe(
          tester,
          const [Offset(-30, 0), Offset(-30, 0), Offset(-30, 0)],
          inScrollingList: true,
        ),
        0,
      );
    });
  });

  testWidgets('SteadyChatList has a scroll-down button by default',
      (tester) async {
    final messages = [for (var i = 1; i <= 200; i++) Msg(i * 10)];
    final adapter = MessageAdapter<Msg>.from(
      key: (m) => m.key,
      date: (m) => DateTime.fromMillisecondsSinceEpoch(m.order * 60000),
    );
    MessageListController<Msg>? controller;
    Widget build({bool button = true}) => _host(
          SizedBox(
            width: 400,
            height: 600,
            child: SteadyChatList<Msg>.list(
              messages: messages,
              adapter: adapter,
              scrollDownButton: button,
              onController: (c) => controller = c,
              floatingDayBuilder: (context, day, onTap) =>
                  DayHeader(day: day, onTap: onTap),
              itemBuilder: (context, m, info) => const SizedBox(height: 50),
            ),
          ),
        );
    await tester.pumpWidget(build());
    await tester.pump(const Duration(milliseconds: 100));
    controller!.jumpTo(k(500));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(ScrollDownButton), findsOneWidget);
    await tester.pumpWidget(build(button: false));
    await tester.pump();
    expect(find.byType(ScrollDownButton), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 40));
  });
}
