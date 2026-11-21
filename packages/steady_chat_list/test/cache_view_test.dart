// Milestone 7: the cache from the list's point of view (offline restart,
// invalidate, reset), the persistent position store, and two views on one
// list (SPEC §18 test 24).
// ignore_for_file: unawaited_futures
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/env.dart';
import 'support/fake_chat_server.dart';
import 'support/fake_viewport.dart';
import 'support/list_harness.dart' show ListHarness;

void main() {
  group('cache', () {
    testWidgets(
        'after a restart the chat opens from the cache, offline, at '
        'the saved position', (tester) async {
      final cache = InMemoryMessageCache<Msg>(adapter: const MsgAdapter());
      final h = ListHarness(tester, cache: cache);
      h.controller.open();
      await h.pump();
      await h.scrollBy(-913);
      await h.settle(const Duration(milliseconds: 100));
      final anchor = h.visible.first;
      final y = h.yOf(anchor)!;
      await h.dispose();
      h.hub.dispose();

      // Restart without a network.
      h.server
        ..failNextFetches = 1000
        ..requests.clear();
      h.hub = h.newHub();
      h.controller = h.newController();
      OpenResolution? how;
      h.controller.open().then((r) => how = r);
      await tester.pumpWidget(h.build());
      await tester.pump(); // the cache answered
      expect(how, OpenResolution.snapshot);
      expect(h.yOf(anchor), moreOrLessEquals(y, epsilon: 1));
      expect(h.controller.phase.value, ListPhase.ready);
      // Paging inside what is cached works without the server.
      await h.scrollBy(300);
      await h.settle(const Duration(milliseconds: 100));
      expect(h.visible, isNotEmpty);
      await h.dispose();
      h.hub.dispose();

      // With the list read beforehand, the very first frame is right.
      h.hub = h.newHub();
      h.hub.hydrate(chat);
      await tester.pump();
      h.controller = h.newController()..open();
      await tester.pumpWidget(h.build());
      expect(h.yOf(anchor), isNotNull, reason: 'first frame, no loading');
      await h.dispose();
    });
  });

  group('invalidate and reset (§13.5)', () {
    test('invalidate after a reconnect: merged, nothing moves', () {
      run((env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        view.scrollBy(-700);
        env.settle();
        final top = view.keys[view.keys.indexOf(k(view.visibleOrders.first))];
        final y = view.yOf(top);
        // While offline: two messages on screen were deleted, one arrived.
        final gone = [view.visibleOrders[3], view.visibleOrders[5]];
        env.server.deleted.addAll(gone);
        env.server.arrived.add(Msg(env.server.newest + 10));
        env.server.requests.clear();

        controller.invalidate();
        env.settle();
        expect(env.server.requests.first.direction, PageDirection.around);
        expect(env.server.requests.first.anchor, top);
        for (final order in gone) {
          expect(view.keys.contains(k(order)), isFalse);
        }
        expect(view.yOf(top), y, reason: 'the viewport did not move');
        expect(
          env.hub.store.peek(chat)!.contains('m${env.server.newest}'),
          isTrue,
        );

        // Not keeping the position reopens at the bottom.
        controller.invalidate(keepPosition: false);
        env.settle();
        expect(view.extentAfter, 0);
        expect(view.keys.last, k(env.server.newest));
        // A failing refresh changes nothing.
        final keys = view.keys;
        env.server.failNextFetches = 100;
        controller.invalidate();
        env.settle(const Duration(seconds: 10));
        expect(view.keys, keys);
      });
    });

    test('reset loads the list again from the server', () {
      final cache = InMemoryMessageCache<Msg>(adapter: const MsgAdapter());
      run(
        env: (async) => Env(async, cache: cache),
        (env) {
          final controller = env.controller()..open();
          final view = FakeViewport(controller);
          env.settle();
          view.scrollBy(-400);
          env.settle();
          controller.selection.toggle('m9990');
          expect(cache.count(chat), greaterThan(0));
          env.server.requests.clear();

          controller.reset();
          expect(controller.phase.value, ListPhase.loading);
          expect(view.keys, isEmpty);
          env.settle(const Duration(milliseconds: 10));
          expect(cache.count(chat), 0);
          env.settle();
          expect(controller.phase.value, ListPhase.ready);
          expect(env.server.requests.first.direction, PageDirection.latest);
          expect(view.keys.last, k(10000));
          expect(view.extentAfter, 0, reason: 'the saved position is gone');
          expect(controller.selection.count, 0);

          controller.dispose();
          controller.reset();
          controller.invalidate();
          env.settle();
        },
      );
    });
  });

  group('SharedPreferencesViewportStore', () {
    ViewportSnapshot snapshot(int order) => ViewportSnapshot(
          anchorKey: k(order),
          anchorOffset: -12,
          offsetFromBottom: 900,
          visibleKeys: [k(order), k(order + 10)],
          connectedToNewest: true,
          viewportWidth: 400,
          savedAt: DateTime.utc(2026, 11, 20),
        );

    test('saves, loads synchronously, removes and clears', () async {
      SharedPreferences.setMockInitialValues({
        'other.key': 'kept',
        'steady_chat_list.position.broken': '{not json',
      });
      final store = await SharedPreferencesViewportStore.create();
      expect(store.load(chat), isNull);
      expect(store.load(const ListId('broken')), isNull);
      await store.save(chat, snapshot(500));
      await store.save(const ListId('chat', 'thread'), snapshot(700));
      final loaded = store.load(chat)!;
      expect(loaded.anchorKey, k(500));
      expect(loaded.anchorOffset, -12);
      expect(store.load(const ListId('chat', 'thread'))!.anchorKey, k(700));

      // Another instance (after a reload) sees the same values.
      final preferences = await SharedPreferences.getInstance();
      final again = SharedPreferencesViewportStore(preferences);
      expect(again.load(chat)!.anchorKey, k(500));
      await again.remove(chat);
      expect(store.load(chat), isNull);
      await store.clear();
      expect(store.load(const ListId('chat', 'thread')), isNull);
      expect(preferences.getString('other.key'), 'kept');

      final scoped = SharedPreferencesViewportStore(preferences, prefix: 'p.');
      await scoped.save(chat, snapshot(1));
      expect(preferences.getKeys(), contains('p.chat'));
    });

    testWidgets('a reload restores the position through it', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = await SharedPreferencesViewportStore.create();
      final h = ListHarness(tester, viewportStore: store);
      h.controller.open();
      await h.pump();
      await h.scrollBy(-1313);
      await h.settle(const Duration(seconds: 1));
      final anchor = h.visible.first;
      final y = h.yOf(anchor)!;
      await h.dispose();

      // A browser reload: nothing in memory, a new store object.
      h.hub = MessageListHub<Msg>(
        source: h.server,
        adapter: const MsgAdapter(),
        viewportStore: await SharedPreferencesViewportStore.create(),
      );
      h.controller = h.newController()..open();
      await h.pump();
      expect(h.yOf(anchor), moreOrLessEquals(y, epsilon: 1));
      await h.dispose();
    });
  });

  testWidgets('test 24: two views on one list share data, not positions',
      (tester) async {
    final h = ListHarness(tester);
    final left = h.controller..open();
    final right = h.newController()..open();
    Widget pane(MessageListController<Msg> controller, String name) => Expanded(
          child: MessageListView<Msg>(
            controller: controller,
            itemBuilder: (context, m, info) => SizedBox(
              key: ValueKey('$name-${m.id}'),
              height: 50.0 + m.rev * 30,
            ),
          ),
        );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 600,
          child: Row(children: [pane(left, 'L'), pane(right, 'R')]),
        ),
      ),
    );
    await h.settle();
    Finder item(String name, int order) =>
        find.byKey(ValueKey('$name-m$order'), skipOffstage: false);
    double bottom(String name, int order) =>
        tester.getBottomLeft(item(name, order)).dy;
    double top(String name, int order) =>
        tester.getTopLeft(item(name, order)).dy;
    expect(bottom('L', 10000), 600);
    expect(bottom('R', 10000), 600);
    expect(h.server.subscriptions, 1, reason: 'one subscription for both');

    // The right pane scrolls up; the left one stays at the bottom.
    final positions = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((s) => s.position)
        .toList();
    positions[1].jumpTo(positions[1].pixels - 900);
    await h.settle(const Duration(milliseconds: 200));
    expect(bottom('L', 10000), 600);
    expect(right.isAtBottom.value, isFalse);
    final anchorY = top('R', 9750);

    // One new message, one edit, one delete: both panes follow.
    h.server.incoming(chat);
    await h.settle(const Duration(milliseconds: 100));
    expect(bottom('L', 10010), 600, reason: 'pinned');
    expect(top('R', 9750), anchorY, reason: 'scrolled up: nothing moves');
    await h.settle(const Duration(milliseconds: 300));
    expect(left.unreadCount.value, 0, reason: 'read at the bottom');
    expect(right.unreadCount.value, 1, reason: 'not seen up there');

    left.patch('m9760', (m) => Msg(m.order, rev: 1));
    await tester.pump();
    await tester.pump();
    expect(tester.getSize(item('R', 9760)).height, 80);
    expect(top('R', 9750), anchorY);

    right.remove(['m9990']);
    await h.settle(const Duration(milliseconds: 400));
    expect(item('L', 9990), findsNothing);
    expect(bottom('L', 10010), 600);
    expect(top('R', 9750), anchorY);

    // Selection is per view; the store is one.
    left.selection.toggle('m10000');
    expect(right.selection.count, 0);
    expect(identical(left.hub.store.peek(chat), right.hub.store.peek(chat)),
        isTrue);

    // Closing one pane leaves the other working.
    right.dispose();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 800,
          height: 600,
          child: Row(children: [pane(left, 'L')]),
        ),
      ),
    );
    h.server.incoming(chat);
    await h.settle(const Duration(milliseconds: 100));
    expect(bottom('L', 10020), 600);
    await h.dispose();
  });
}
