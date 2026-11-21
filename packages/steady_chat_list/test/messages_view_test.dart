// Widget tests of sending, incoming messages and deletes (milestone 5):
// SPEC §18 tests 7, 8 and 9.
// ignore_for_file: unawaited_futures
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/fake_chat_server.dart';
import 'support/list_harness.dart';

Msg _local(MessageKey key) =>
    Msg(key.order, id: key.id, localSeq: key.localSeq, outgoing: true);

Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('test 9: send', () {
    testWidgets('insertLocal while scrolled up ends at the bottom',
        (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      await h.scrollBy(-1200);
      await h.settle(const Duration(milliseconds: 100));
      expect(h.controller.isAtBottom.value, isFalse);

      MessageKey? key;
      h.controller
          .insertLocal(id: 'c1', build: _local)
          .then((value) => key = value);
      await tester.pump();
      expect(key, const MessageKey(order: 10000, id: 'c1', localSeq: 1));
      // It fades in while the list goes down.
      await tester.pump(const Duration(milliseconds: 16));
      expect(h.itemById('c1'), findsOneWidget);
      expect(h.infos['c1']!.isJustAdded, isTrue);
      expect(h.infos['c1']!.isLocal, isTrue);
      expect(h.infos['c1']!.sendState, SendState.sending);
      await h.settle(const Duration(milliseconds: 700));
      expect(tester.getBottomLeft(h.itemById('c1')).dy, 600);
      expect(h.opacityOf(h.itemById('c1')), 1);
      expect(h.infos['c1']!.isJustAdded, isFalse);
      expect(h.controller.isAtBottom.value, isTrue);
      expect(h.controller.unreadCount.value, 0, reason: 'own message');
      await h.dispose();
    });

    testWidgets(
        'an ack keeps the same State; out-of-order acks sort by '
        'server key; a failure shows', (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      for (final id in ['c1', 'c2', 'c3']) {
        h.controller.insertLocal(id: id, build: _local);
        await tester.pump();
      }
      await h.settle(const Duration(milliseconds: 600));
      double y(String id) => tester.getTopLeft(h.itemById(id)).dy;
      expect(y('c1'), lessThan(y('c2')));
      expect(y('c2'), lessThan(y('c3')));
      h.inits.clear();

      // The server confirms c2 first, then c1 (with a later id).
      h.controller.apply(
        const LocalAcked(chat, 'c2', Msg(10010, outgoing: true)),
      );
      await _frames(tester, 3);
      expect(h.itemById('c2'), findsNothing);
      expect(h.infos['m10010']!.sendState, SendState.sent);
      expect(h.infos['m10010']!.isLocal, isFalse);
      // A confirmed message sorts by its server key: after the two that
      // are still pending (they sit right after message 10000).
      expect(y('c1'), lessThan(y('c3')));
      expect(y('c3'), lessThan(y('m10010')));

      h.controller.apply(
        const LocalAcked(chat, 'c1', Msg(10020, outgoing: true)),
      );
      h.controller.apply(const LocalFailed<Msg>(chat, 'c3', 'offline'));
      await _frames(tester, 3);
      expect(y('c3'), lessThan(y('m10010')));
      expect(y('m10010'), lessThan(y('m10020')), reason: 'by server key');
      expect(h.infos['c3']!.sendState, SendState.failed);
      expect(h.inits, isEmpty, reason: 'no State was created again');
      expect(h.controller.stableIdOf(k(10010)), 'c2');
      expect(tester.getBottomLeft(h.itemById('m10020')).dy, 600);

      // A retry: clear the failure by replacing the message, then ack.
      h.controller.apply(
        const LocalAcked(chat, 'c3', Msg(10030, outgoing: true)),
      );
      await _frames(tester, 3);
      expect(h.infos['m10030']!.sendState, SendState.sent);
      expect(h.inits, isEmpty);
      expect(tester.getBottomLeft(h.itemById('m10030')).dy, 600);
      expect(
        h.events.whereType<KeyReplaced>().map((e) => e.oldKey.id).toList(),
        ['c2', 'c1', 'c3'],
      );
      await h.dispose();
    });

    testWidgets('a failure alone rebuilds just that message', (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      h.controller.insertLocal(id: 'c1', build: _local);
      await h.settle(const Duration(milliseconds: 600));
      h.builds.clear();
      h.events.clear();
      h.controller.apply(const LocalFailed<Msg>(chat, 'c1', 'offline'));
      await _frames(tester, 2);
      expect(h.infos['c1']!.sendState, SendState.failed);
      expect(h.infos['c1']!.isLocal, isTrue);
      expect(h.builds, {'c1': 1});
      expect(h.events.whereType<WindowChanged>(), isEmpty);
      await h.dispose();
    });

    testWidgets('sending from an island loads the newest messages first',
        (tester) async {
      final h = ListHarness(tester);
      h.controller.open(target: OpenTarget.message(k(4000)));
      await h.pump();
      MessageKey? key;
      h.controller
          .insertLocal(id: 'c1', build: _local)
          .then((value) => key = value);
      await h.settle();
      expect(key!.order, 10000, reason: 'after the real newest message');
      expect(tester.getBottomLeft(h.itemById('c1')).dy, 600);
      expect(h.yOf(10000), 500);

      // Without scrolling: the reader stays where they are.
      await h.scrollBy(-900);
      await h.settle(const Duration(milliseconds: 100));
      final top = h.visible.first;
      final y = h.yOf(top);
      h.controller.insertLocal(id: 'c2', build: _local, scrollToBottom: false);
      await h.settle(const Duration(milliseconds: 400));
      expect(h.yOf(top), y);
      expect(h.controller.nextLocalKey('c9')!.localSeq, 3);
      await h.dispose();
      expect(await h.controller.insertLocal(id: 'x', build: _local), isNull);
    });
  });

  group('test 8: incoming', () {
    testWidgets('at the bottom: pinned, with an appear animation',
        (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      h.server.incoming(chat);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(h.bottomOf(10010), 600);
      expect(h.opacityOf(h.item(10010)), lessThan(0.5));
      expect(h.opacityOf(h.item(10000)), 1);
      expect(h.infos['m10010']!.isJustAdded, isTrue);
      await _frames(tester, 16);
      expect(h.opacityOf(h.item(10010)), 1);
      expect(h.bottomOf(10010), 600);
      await h.dispose();
    });

    testWidgets(
        'a burst is one window update per frame and rebuilds only '
        'what is new', (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      h.builds.clear();
      h.events.clear();
      // 50 messages per second for one second: about one per frame.
      var windows = 0;
      for (var frame = 0; frame < 60; frame++) {
        if (frame % 6 != 5) h.server.incoming(chat);
        await tester.pump(const Duration(milliseconds: 16));
        final now = h.events.whereType<WindowChanged>().length;
        // The message itself, plus at most the end of an appear mark and
        // a page that grew.
        expect(now - windows, lessThanOrEqualTo(3), reason: 'frame $frame');
        windows = now;
        // Whatever is the newest message on screen sits at the bottom.
        expect(h.bottomOf(h.visible.last), 600, reason: 'frame $frame');
      }
      expect(h.server.arrived, hasLength(50));
      await _frames(tester, 2);
      expect(h.bottomOf(h.server.newest), 600);
      // Old messages were not rebuilt, except the one whose neighbour
      // changed.
      for (var order = 9800; order <= 9990; order += 10) {
        expect(h.builds['m$order'] ?? 0, 0, reason: 'm$order');
      }
      for (final message in h.server.arrived) {
        expect(h.builds[message.id], lessThanOrEqualTo(4));
      }
      expect(h.controller.window.value.keys.length, lessThanOrEqualTo(80));
      await h.dispose();
    });

    testWidgets('the app can turn the appear animation off', (tester) async {
      final h = ListHarness(tester);
      h.controller.dispose();
      h.controller = MessageListController<Msg>(
        hub: h.hub,
        list: chat,
        callbacks: MessageListCallbacks(
          shouldAnimateInsert: (message, cause) =>
              cause != InsertCause.incoming,
          shouldAnimateRemove: (key, cause) =>
              key.order == 9990 ? throw StateError('app bug') : false,
        ),
      )..events.listen(h.events.add);
      h.controller.open();
      await h.pump();
      h.server.incoming(chat);
      await _frames(tester, 2);
      expect(h.opacityOf(h.item(10010)), 1);
      expect(h.infos['m10010']!.isJustAdded, isFalse);

      // Deletes: off for one message; a throwing callback counts as "yes".
      h.controller.remove(['m9980']);
      await _frames(tester, 2);
      expect(h.item(9980), findsNothing);
      h.controller.remove(['m9990']);
      await _frames(tester, 2);
      expect(h.item(9990), findsOneWidget);
      expect(
        h.events
            .whereType<DiagnosticReported>()
            .map((e) => e.diagnostic)
            .whereType<CallbackError>()
            .single
            .callback,
        'shouldAnimate',
      );
      await h.settle(const Duration(milliseconds: 300));
      expect(h.item(9990), findsNothing);
      await h.dispose();
    });
  });

  group('test 7: deletes', () {
    testWidgets(
        'inside the viewport: fades out, rows above stay, rows '
        'below move up in one step', (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      await h.scrollBy(-700);
      await h.settle(const Duration(milliseconds: 100));
      final visible = h.visible;
      final ys = [for (final o in visible) h.yOf(o)!];
      final doomed = visible[4];

      h.server.push(MessagesDeleted<Msg>(chat, ['m$doomed'])); // remote
      var lastOpacity = 1.0;
      for (var frame = 0; frame < 11; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        // While it animates nothing else moves.
        for (var i = 0; i < visible.length; i++) {
          if (i != 4) expect(h.yOf(visible[i]), ys[i], reason: '$frame/$i');
        }
        final opacity = h.opacityOf(h.item(doomed));
        expect(opacity, lessThanOrEqualTo(lastOpacity));
        lastOpacity = opacity;
      }
      expect(lastOpacity, lessThan(0.5));
      // Incoming messages slide to the left, shrinking.
      final transform = tester.widget<Transform>(
        find
            .ancestor(of: h.item(doomed), matching: find.byType(Transform))
            .first,
      );
      expect(transform.transform.getTranslation().x, lessThan(0));
      expect(transform.transform.entry(0, 0), lessThan(0.9));

      await _frames(tester, 6);
      expect(h.item(doomed), findsNothing);
      for (var i = 0; i < visible.length; i++) {
        if (i == 4) continue;
        expect(h.yOf(visible[i]), i < 4 ? ys[i] : ys[i] - 50, reason: '$i');
      }
      expect(
        h.events.whereType<MessageRemoved>().single.cause,
        RemoveCause.deleted,
      );
      await h.dispose();
    });

    testWidgets('below the viewport: nothing moves', (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      await h.scrollBy(-700);
      await h.settle(const Duration(milliseconds: 100));
      final visible = h.visible;
      final ys = [for (final o in visible) h.yOf(o)!];
      h.controller.remove(['m${visible.last + 20}', 'm${visible.last + 40}']);
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect([for (final o in visible) h.yOf(o)!], ys, reason: '$frame');
      }
      await h.dispose();
    });

    testWidgets('at the bottom: stays pinned, rows above move down',
        (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      final above = h.yOf(9940)!;
      h.controller.remove(['m9960']);
      await _frames(tester, 10);
      expect(h.bottomOf(10000), 600);
      expect(h.yOf(9940), above);
      await _frames(tester, 6);
      expect(h.item(9960), findsNothing);
      expect(h.bottomOf(10000), 600);
      expect(h.yOf(9940), above + 50);

      // The newest message itself.
      h.controller.remove(['m10000']);
      await h.settle(const Duration(milliseconds: 300));
      expect(h.bottomOf(9990), 600);
      expect(h.controller.isAtBottom.value, isTrue);
      await h.dispose();
    });

    testWidgets('a batch of 3 goes together, with one correction',
        (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      await h.scrollBy(-700);
      await h.settle(const Duration(milliseconds: 100));
      final visible = h.visible;
      final ys = [for (final o in visible) h.yOf(o)!];
      h.events.clear();
      // One above the viewport, two inside.
      final batch = [visible.first - 10, visible[2], visible[5]];
      h.controller.remove([for (final o in batch) 'm$o']);
      int? goneAt;
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final present =
            batch.where((o) => h.item(o).evaluate().isNotEmpty).length;
        expect(present, anyOf(0, 3), reason: 'frame $frame: all together');
        if (present == 0) goneAt ??= frame;
      }
      expect(goneAt, isNotNull);
      // Rows above the first deleted visible row did not move.
      expect(h.yOf(visible[0]), ys[0]);
      expect(h.yOf(visible[1]), ys[1]);
      expect(h.yOf(visible[3]), ys[3] - 50);
      expect(h.yOf(visible[6]), ys[6] - 100);
      await h.dispose();
    });

    testWidgets('the last message of a day takes its header with it',
        (tester) async {
      final h = ListHarness(tester)..dayHeaders = true;
      h.controller.open();
      await h.pump();
      // Every message of the newest day.
      DateTime day(int order) {
        final date = const MsgAdapter().dateOf(Msg(order)).toLocal();
        return DateTime(date.year, date.month, date.day);
      }

      final today = day(10000);
      final orders = <int>[
        for (var o = 10000; o > 9000 && day(o) == today; o -= 10) o,
      ];
      final header = find.byKey(
        ValueKey('day-${today.year}-${today.month}-${today.day}'),
        skipOffstage: false,
      );
      // Leave only the newest one.
      h.controller.remove([for (final o in orders.skip(1)) 'm$o']);
      await h.settle(const Duration(milliseconds: 400));
      expect(header, findsOneWidget, reason: 'moved to the remaining row');
      expect(h.item(10000), findsOneWidget);

      h.controller.remove(['m10000']);
      await _frames(tester, 8);
      // The header fades with the row…
      expect(h.opacityOf(header), lessThan(1));
      // …and is gone with it.
      await h.settle(const Duration(milliseconds: 300));
      expect(header, findsNothing);
      expect(h.bottomOf(orders.last - 10), 600);
      await h.dispose();
    });

    testWidgets('collapseRemovedRows closes the gap with an animation',
        (tester) async {
      final h = ListHarness(
        tester,
        config: const MessageListConfig(collapseRemovedRows: true),
      );
      h.controller.open();
      await h.pump();
      await h.scrollBy(-700);
      await h.settle(const Duration(milliseconds: 100));
      final visible = h.visible;
      final below = h.yOf(visible[5])!;
      h.controller.remove(['m${visible[4]}']);
      await _frames(tester, 12); // the content is gone, the gap is open
      expect(h.yOf(visible[5]), below);
      await _frames(tester, 7); // half-way closing
      final mid = h.yOf(visible[5])!;
      expect(mid, lessThan(below));
      expect(mid, greaterThan(below - 50));
      await h.settle(const Duration(milliseconds: 300));
      expect(h.yOf(visible[5]), below - 50);
      expect(h.item(visible[4]), findsNothing);
      await h.dispose();
    });

    testWidgets('no animation: zero duration, or animate: false',
        (tester) async {
      final h = ListHarness(
        tester,
        config: const MessageListConfig(
          removeDuration: Duration.zero,
          appearDuration: Duration.zero,
        ),
      );
      h.controller.open();
      await h.pump();
      h.controller.remove(['m9950']);
      await _frames(tester, 2);
      expect(h.item(9950), findsNothing);
      h.server.incoming(chat);
      await _frames(tester, 2);
      expect(h.opacityOf(h.item(10010)), 1);
      await h.dispose();

      final g = ListHarness(tester);
      g.controller.open();
      await g.pump();
      g.controller.remove(['m9950'], animate: false);
      await _frames(tester, 2);
      expect(g.item(9950), findsNothing);
      expect(g.bottomOf(10000), 600);
      await g.dispose();
    });

    testWidgets('own messages slide right; right-to-left mirrors it',
        (tester) async {
      Future<double> slide({required bool rtl, required bool outgoing}) async {
        final h = ListHarness(tester, outgoingEvery: 2)..rtl = rtl;
        h.controller.open();
        await h.pump();
        // n = 1000 (10000) is outgoing, n = 999 (9990) incoming.
        final order = outgoing ? 10000 : 9990;
        h.controller.remove(['m$order']);
        await _frames(tester, 8);
        final transform = tester.widget<Transform>(
          find
              .ancestor(of: h.item(order), matching: find.byType(Transform))
              .first,
        );
        final x = transform.transform.getTranslation().x;
        await h.dispose();
        return x;
      }

      expect(await slide(rtl: false, outgoing: true), greaterThan(0));
      expect(await slide(rtl: false, outgoing: false), lessThan(0));
      expect(await slide(rtl: true, outgoing: true), lessThan(0));
      expect(await slide(rtl: true, outgoing: false), greaterThan(0));
    });

    testWidgets('custom appear and remove transitions', (tester) async {
      final appeared = <String>{};
      final removed = <String>{};
      final h = ListHarness(tester)
        ..appearBuilder = (context, animation, child, info) {
          if (animation.value < 1) appeared.add(info.key.id);
          return SizeTransition(sizeFactor: animation, child: child);
        }
        ..removeBuilder = (context, animation, child, info) {
          if (animation.value > 0) removed.add(info.key.id);
          return FadeTransition(
            opacity: ReverseAnimation(animation),
            child: child,
          );
        };
      h.controller.open();
      await h.pump();
      h.server.incoming(chat);
      await _frames(tester, 4);
      expect(appeared, {'m10010'});
      expect(tester.getSize(h.item(10010)).height, 50);
      h.controller.remove(['m9990']);
      await _frames(tester, 6);
      // The builder runs when the row rebuilds; force one.
      h.controller.patch('m9990', (m) => m);
      await h.settle(const Duration(milliseconds: 400));
      expect(h.item(9990), findsNothing);
      expect(h.bottomOf(10010), 600);
      await h.dispose();
    });
  });
}
