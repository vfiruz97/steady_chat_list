// Milestone 6: selection (SPEC §18 test 23), visibility and dwell
// callbacks, prefetch, geometry.
// ignore_for_file: unawaited_futures
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/env.dart';
import 'support/fake_chat_server.dart';
import 'support/fake_viewport.dart';
import 'support/list_harness.dart' show ListHarness;

void main() {
  group('test 23: selection (§10.11)', () {
    test('toggle, shift-range, survives paging, cleared by a batch delete', () {
      run(
        // Every 7th message is a service message.
        env: (async) => Env(
          async,
          count: 300,
          decorate: (m) => Msg(m.order, service: (m.order ~/ 10) % 7 == 0),
        ),
        (env) {
          final controller = env.controller()..open();
          final view = FakeViewport(controller);
          env.settle();
          final selection = controller.selection;
          var changes = 0;
          selection.addListener(() => changes++);
          expect(selection.active, isFalse);

          selection.toggle('m3000');
          expect(selection.active, isTrue);
          expect(selection.selectedIds, {'m3000'});
          expect(selection.isSelected('m3000'), isTrue);
          // Shift-click eight messages up: the range, minus the service
          // message (2940 = 7 × 420).
          selection.extendTo(k(2920));
          expect(selection.count, 8);
          expect(selection.isSelected('m2940'), isFalse);
          expect(selection.isSelectable(k(2940)), isFalse);
          expect(selection.isSelectable(k(2950)), isTrue);
          expect(selection.isSelectable(k(5)), isFalse, reason: 'unknown');
          // A service message can't be toggled either.
          selection.toggle('m2940');
          expect(selection.count, 8);
          selection.toggle('m2930');
          expect(selection.count, 7);
          expect(changes, 3);

          // Page far away: the selection is still there.
          for (var i = 0; i < 12; i++) {
            view.scrollToTop();
            env.settle(const Duration(milliseconds: 500));
          }
          expect(view.keys.contains(k(3000)), isFalse);
          expect(selection.count, 7);

          // Deleting the selected messages is a batch delete and clears it.
          final removed = <MessageKey>[];
          controller.events.listen((e) {
            if (e is MessageRemoved) removed.addAll(e.keys);
          });
          controller.remove(selection.selectedIds.toList());
          env.settle();
          expect(removed, hasLength(7));
          expect(selection.count, 0);
          expect(selection.active, isFalse);
        },
      );
    });

    test('select all, explicit range, drag select, start and clear', () {
      run(
        env: (async) => Env(async, count: 30),
        (env) {
          final controller = env.controller()..open();
          FakeViewport(controller); // loads all 30 messages
          env.settle();
          final selection = controller.selection;
          selection.start();
          selection.start();
          expect(selection.active, isTrue);
          expect(selection.count, 0);

          selection.selectRange(k(200), k(150)); // either order
          expect(selection.count, 6);
          selection.selectRange(k(200), k(150));
          expect(selection.count, 6);

          // A drag adds a range on top and follows the finger back.
          selection.dragSelect(k(50), k(90));
          expect(selection.count, 11);
          selection.dragSelect(k(50), k(60));
          expect(selection.count, 8);
          selection.dragSelect(k(50), k(60));
          selection.endDrag();
          selection.dragSelect(k(10), k(20));
          expect(selection.count, 10);
          selection.endDrag();

          selection.selectAllLoaded();
          expect(selection.count, 30);
          selection.selectAllLoaded();
          selection.forget(['m10', 'unknown']);
          expect(selection.count, 29);
          selection.forget(['unknown']);

          selection.clear();
          selection.clear();
          expect(selection.active, isFalse);
          selection.extendTo(k(100));
          expect(selection.selectedIds, {'m100'});
          selection.toggle('unknown');
          expect(selection.count, 1);

          // Another chat: nothing selected.
          controller.switchTo(other);
          env.settle();
          expect(selection.count, 0);
        },
      );
    });

    testWidgets('items learn whether they are selected', (tester) async {
      final h = ListHarness(tester);
      h.controller.open();
      await h.pump();
      expect(h.infos['m10000']!.selectionActive, isFalse);
      h.builds.clear();
      h.controller.selection.toggle('m10000');
      await tester.pump();
      expect(h.infos['m10000']!.isSelected, isTrue);
      expect(h.infos['m9990']!.isSelected, isFalse);
      expect(h.infos['m9990']!.selectionActive, isTrue);
      h.builds.clear();
      h.controller.selection.toggle('m9990');
      await tester.pump();
      expect(h.builds.keys, ['m9990'], reason: 'only the toggled row');
      h.controller.selection.clear();
      await tester.pump();
      expect(h.infos['m9990']!.selectionActive, isFalse);
      await h.dispose();
    });
  });

  group('visibility (§10.12)', () {
    test('range, thresholds, seen once, disposed, top day', () {
      run((env) {
        final ranges = <VisibleRange?>[];
        final visibility = <String, double>{};
        final seen = <MessageKey>[];
        final disposed = <MessageKey>[];
        final days = <DateTime?>[];
        final controller = env.controller(
          callbacks: MessageListCallbacks(
            onVisibleRangeChanged: (list, range) => ranges.add(range),
            onItemVisibility: (list, key, fraction) =>
                visibility[key.id] = fraction,
            onMessagesSeen: (list, keys) => seen.addAll(keys),
            onItemDisposed: (list, key) => disposed.add(key),
            onTopVisibleDayChanged: (list, day) => days.add(day),
          ),
        )..open();
        final view = FakeViewport(controller);
        env.settle();
        expect(ranges.last!.first, k(9890));
        expect(ranges.last!.last, k(10000));
        expect(ranges.last!.count, 12);
        expect('${ranges.last}', 'VisibleRange(m9890..m10000, 12)');
        expect(controller.visibleItems, hasLength(12));
        expect(visibility['m10000'], 1);
        expect(seen, hasLength(12));
        expect(days.single, isNotNull);
        expect(controller.topVisibleDay.value, days.single);

        // Half a row up: the top row is half visible, the bottom one too.
        final before = ranges.length;
        view.scrollBy(-25);
        env.settle(Duration.zero);
        expect(ranges.length, before + 1);
        expect(visibility['m9880'], 0.5);
        expect(visibility['m10000'], 0.5);
        expect(seen.last, k(9880), reason: 'at least half visible');
        expect(seen, hasLength(13));
        // A few pixels more: below half, no new "seen".
        view.scrollBy(10);
        env.settle(Duration.zero);
        expect(visibility['m9880'], lessThan(0.5));
        view.scrollBy(15);
        env.settle(Duration.zero);
        expect(visibility['m9880'], 0, reason: 'hidden again');
        expect(seen, hasLength(13), reason: 'once per visit');
        expect(
          env.eventsOf<ItemVisibilityChanged>().where((e) => e.key == k(9880)),
          hasLength(3),
        );

        // Pages away: rows that left the window are reported.
        for (var i = 0; i < 6; i++) {
          view.scrollToTop();
          env.settle(const Duration(milliseconds: 500));
        }
        expect(disposed, contains(k(10000)));
        expect(disposed.toSet().length, disposed.length);
        expect(env.eventsOf<ItemDisposed>(), hasLength(disposed.length));
        expect(env.eventsOf<MessagesSeen>(), isNotEmpty);
        expect(env.eventsOf<TopVisibleDayChanged>(), hasLength(days.length));
        expect(days.length, greaterThan(1));
      });
    });

    test('prefetch suggests what lies beyond the window, once per edge', () {
      run((env) {
        final upcoming = <List<Msg>>[];
        final controller = env.controller(
          callbacks: MessageListCallbacks(
            onPrefetch: (list, messages) => upcoming.add(messages),
          ),
        );
        final view = FakeViewport(controller);
        controller.open(target: OpenTarget.message(k(5000)));
        env.settle();
        // The island was loaded 20 each way; the window shows it all, so
        // nothing lies beyond yet. Page up twice: older rows get trimmed
        // from the other side and become "upcoming" again.
        for (var i = 0; i < 4; i++) {
          view.scrollToTop();
          env.settle(const Duration(milliseconds: 500));
        }
        expect(upcoming, isNotEmpty);
        for (final batch in upcoming) {
          expect(batch.length, lessThanOrEqualTo(40));
          for (final message in batch) {
            expect(view.keys.contains(message.key), isFalse);
          }
        }
        final count = upcoming.length;
        view.scrollBy(1);
        env.settle(Duration.zero);
        expect(upcoming, hasLength(count), reason: 'same edges: no repeat');
        expect(
          env.eventsOf<PrefetchSuggested>(),
          hasLength(upcoming.length),
        );
      });
    });

    test('ensureVisible scrolls just enough; day taps reach the app', () {
      run((env) {
        final taps = <DateTime>[];
        final controller = env.controller(
          callbacks: MessageListCallbacks(
            onDayTap: (list, day) => taps.add(day),
          ),
        )..open();
        final view = FakeViewport(controller);
        env.settle();
        view.scrollBy(-500);
        env.settle();
        // 10000 is below the viewport: it ends at the bottom edge.
        controller.ensureVisible(k(10000));
        env.settle();
        expect(view.yOf(k(10000)), 550);
        expect(controller.highlighted.value, isNull);
        // Already visible: nothing moves.
        final top = view.top;
        controller.ensureVisible(k(9950));
        env.settle();
        expect(view.top, top);
        controller.ensureVisible(
          k(9700),
          alignment: const JumpAlignment.top(),
        );
        env.settle();
        expect(view.yOf(k(9700)), 0);

        controller.notifyDayTap(DateTime(2026, 11, 20));
        env.settle(Duration.zero);
        expect(taps, [DateTime(2026, 11, 20)]);
        expect(env.eventsOf<DayTapped>().single.day, taps.single);
      });
    });
  });
}
