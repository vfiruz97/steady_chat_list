// Headless tests of jump edge cases and search navigation (§10.4, §10.5),
// including SPEC §18 test 12.
import 'package:fake_async/fake_async.dart';
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/env.dart';
import 'support/fake_chat_server.dart';
import 'support/fake_viewport.dart';

List<String> phases(Env env) =>
    [for (final e in env.eventsOf<Jumped>()) e.jump.phase];

void main() {
  group('jumps without a view', () {
    test('a jump is a window swap; the result says what happened', () {
      run((env) {
        final jumps = <JumpEvent>[];
        final controller = env.controller(
          callbacks: MessageListCallbacks(onJump: (list, e) => jumps.add(e)),
        )..open();
        env.settle();
        JumpResult? result;
        controller.jumpTo(k(5000)).then((r) => result = r);
        env.settle();
        expect(result!.outcome, JumpOutcome.arrived);
        expect(result!.landedOn, k(5000));
        expect(result!.fetchedPages, 1);
        final placement = controller.window.value.placement! as PlaceJump;
        expect(placement.key, k(5000));
        expect(placement.fromNewer, isTrue);
        expect(controller.rectOf(k(5000)), isNull, reason: 'no view');
        expect(controller.highlighted.value!.key, k(5000));
        env.settle(const Duration(seconds: 2));
        expect(controller.highlighted.value, isNull);
        expect(
          [for (final e in jumps) e.phase],
          ['started', 'loading', 'scrolling', 'arrived', 'highlightEnded'],
        );
        expect(jumps.first.toMap(), {
          'phase': 'started',
          'reason': 'programmatic',
          'target': 'm5000',
        });
        expect('${jumps.first}', contains('started'));

        // Coming from older messages this time.
        controller.jumpTo(k(9000)).then((r) => result = r);
        env.settle();
        expect(
          (controller.window.value.placement! as PlaceJump).fromNewer,
          isFalse,
        );
        // To the bottom: a window at the newest messages.
        controller.jumpToBottom().then((r) => result = r);
        env.settle();
        expect(result!.outcome, JumpOutcome.arrived);
        expect(result!.landedOn, k(10000));
        expect(controller.window.value.placement, isA<PlaceBottom>());
        expect(controller.windowEndsAtNewest, isTrue);
      });
    });

    test('a failed page fails the jump and leaves the list alone', () {
      run((env) {
        final controller = env.controller()..open();
        env.settle();
        final keys = controller.window.value.keys;
        env.server.failNextFetches = 1;
        JumpResult? result;
        controller.jumpTo(k(5000)).then((r) => result = r);
        env.settle();
        expect(result!.outcome, JumpOutcome.failed);
        expect(result!.error, isStateError);
        expect(result!.succeeded, isFalse);
        expect(controller.window.value.keys, keys);
        expect(controller.jumpInProgress.value, isNull);
        final failed = env.eventsOf<Jumped>().last.jump as JumpFailed;
        expect(failed.toMap()['error'], contains('offline'));
        expect(env.eventsOf<PageFailed>(), hasLength(1));

        // To the bottom of a list that was never loaded at the bottom.
        env.server.failNextFetches = 1;
        controller.jumpTo(k(5000)).then((r) => result = r);
        env.settle();
        env.server.failNextFetches = 0;
        controller.jumpTo(k(5000)).then((r) => result = r);
        env.settle();
        expect(result!.outcome, JumpOutcome.arrived);
      });
    });

    test('a message that does not exist anywhere fails', () {
      run(
        env: (async) => Env(async, count: 0),
        (env) {
          final controller = env.controller()..open();
          env.settle();
          JumpResult? result;
          controller.jumpTo(k(5000)).then((r) => result = r);
          env.settle();
          expect(result!.outcome, JumpOutcome.failed);
          controller.jumpToBottom().then((r) => result = r);
          env.settle();
          expect(result!.outcome, JumpOutcome.arrived);
          expect(result!.landedOn, isNull, reason: 'an empty list');
          controller.jumpToNextUnreadReaction().then((r) => result = r);
          env.settle();
          expect(result!.outcome, JumpOutcome.failed);
          controller.reselect();
          env.settle();
        },
      );
    });

    test('near the start of history, and a deleted first message', () {
      run(
        env: (async) => Env(async, count: 60),
        (env) {
          final pinned = <MessageKey?>[];
          final controller = env.controller(
            callbacks: MessageListCallbacks(
              onCurrentPinnedChanged: (list, key) => pinned.add(key),
            ),
          )..open();
          final view = FakeViewport(controller);
          env.settle();
          env.server.push(PinnedChanged<Msg>(chat, [k(100)]));
          env.settle();
          expect(pinned, [k(100)]);
          // Fully loaded: a jump next to the first message needs no fetch.
          env.server.requests.clear();
          JumpResult? result;
          controller
              .jumpTo(k(20),
                  options: const JumpOptions(
                    alignment: JumpAlignment.top(),
                  ))
              .then((r) => result = r);
          env.settle();
          expect(result!.outcome, JumpOutcome.arrived);
          expect(result!.fetchedPages, 0);
          expect(view.yOf(k(20)), 0);
          expect(pinned.last, isNull, reason: 'above the pinned message');
        },
      );
      run(
        env: (async) => Env(async, count: 1000),
        (env) {
          env.server.deleted.add(10);
          final controller = env.controller()..open();
          FakeViewport(controller);
          env.settle();
          JumpResult? result;
          controller.jumpTo(k(10)).then((r) => result = r);
          env.settle();
          expect(result!.outcome, JumpOutcome.arrivedNearest);
          expect(result!.landedOn, k(20));
        },
      );
    });

    test('jump to a date, headless', () {
      run((env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        JumpResult? result;
        // After everything while only an island is loaded.
        controller.jumpTo(k(5000)).then((r) => result = r);
        env.settle();
        controller.jumpToDate(DateTime(2100)).then((r) => result = r);
        env.settle();
        expect(result!.outcome, JumpOutcome.arrived);
        expect(result!.landedOn, k(100000 ~/ 10));
        expect(view.keys.last, k(10000));
        // Before everything: the first message.
        controller.jumpToDate(DateTime(1960)).then((r) => result = r);
        env.settle();
        expect(result!.landedOn, k(10));
      });
    });

    test('a jump to the bottom can be superseded while it loads', () {
      run((env) {
        final controller = env.controller();
        FakeViewport(controller);
        controller.open(target: OpenTarget.message(k(5000)));
        env.settle();
        final outcomes = <JumpOutcome>[];
        // The island's own refresh marked nothing as newest: a fetch.
        env.hub.store.peek(chat)!.evict(
          limit: 5,
          protect: [KeyRange(k(4990), k(5010))],
        );
        controller.jumpToBottom().then((r) => outcomes.add(r.outcome));
        env.settle(const Duration(milliseconds: 20));
        controller.jumpTo(k(5000)).then((r) => outcomes.add(r.outcome));
        env.settle();
        expect(outcomes.first, JumpOutcome.cancelled);
        expect(outcomes.last, isNot(JumpOutcome.cancelled));
      });
    });

    test('a jump before the list is open fails at once', () {
      run((env) {
        final controller = env.controller();
        JumpResult? result;
        controller.jumpTo(k(5000)).then((r) => result = r);
        env.settle(Duration.zero);
        expect(result!.outcome, JumpOutcome.failed);
        controller.dispose();
        controller.jumpToBottom().then((r) => result = r);
        env.settle(Duration.zero);
        expect(result!.outcome, JumpOutcome.failed);
      });
    });

    test('opening, switching and disposing cancel a running jump', () {
      run((env) {
        final controller = env.controller()..open();
        env.settle();
        final results = <JumpOutcome>[];
        controller.jumpTo(k(5000)).then((r) => results.add(r.outcome));
        env.settle(const Duration(milliseconds: 50));
        controller.switchTo(other);
        env.settle();
        controller.jumpTo(k(4000)).then((r) => results.add(r.outcome));
        env.settle(const Duration(milliseconds: 50));
        controller.dispose();
        env.settle();
        expect(results, [JumpOutcome.cancelled, JumpOutcome.cancelled]);
        expect(env.hub.store.peek(chat)!.contains('m5000'), isFalse);
      });
    });

    test('the view can report an interrupted scroll', () {
      run((env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        view.completeJumps = false;
        final results = <JumpOutcome>[];
        controller.jumpTo(k(5000)).then((r) => results.add(r.outcome));
        env.settle();
        view.dragToBottom();
        controller.jumpToBottom().then((r) => results.add(r.outcome));
        env.settle();
        expect(results, [JumpOutcome.cancelled, JumpOutcome.cancelled]);
        expect(controller.highlighted.value, isNull);
        expect(view.scrolls, ['item 5000', 'bottom']);

        // A view swapped for another one.
        final second = FakeViewport(controller);
        view.dispose();
        controller.detachViewport(view);
        controller.jumpTo(k(5000)).then((r) => results.add(r.outcome));
        env.settle();
        expect(results.last, JumpOutcome.arrived);
        expect(second.yOf(k(5000)), 275);
        expect(controller.rectOf(k(5000))!.top, 275);
      });
    });

    test('prefetchAround warms the store once', () {
      run((env) {
        final controller = env.controller()..open();
        env.settle();
        env.server.requests.clear();
        controller.prefetchAround(k(5000));
        env.settle();
        controller.prefetchAround(k(5000));
        controller.prefetchAround(k(10000));
        env.settle();
        expect(env.server.requestsOf(PageDirection.around), hasLength(1));
        JumpResult? result;
        controller.jumpTo(k(5000)).then((r) => result = r);
        env.settle(Duration.zero);
        expect(result!.fetchedPages, 0, reason: 'already in memory');
      });
    });

    test('jump options are value objects', () {
      const options = JumpOptions();
      expect(options.alignment, isA<AlignCenter>());
      expect(options.scroll.isInstant, isFalse);
      expect(options.highlight.isEnabled, isTrue);
      final changed = options.copyWith(
        alignment: const JumpAlignment.top(),
        scroll: const JumpScroll.instant(),
        highlight: const JumpHighlight.none(),
        highlightQuery: 'x',
        reason: JumpReason.reply,
      );
      expect(changed.alignment, isA<AlignTop>());
      expect(changed.scroll.isInstant, isTrue);
      expect(changed.scroll.curve, Curves.linear);
      expect(changed.highlight.isEnabled, isFalse);
      expect(changed.highlightQuery, 'x');
      expect(changed.reason, JumpReason.reply);
      expect(changed.copyWith().reason, JumpReason.reply);
      const state = JumpState(reason: JumpReason.bottom);
      expect(state.isLoading, isFalse);
      expect(state.target, isNull);
      const cancelled = JumpCancelled(JumpReason.date, null);
      expect(cancelled.toMap(), {'phase': 'cancelled', 'reason': 'date'});
      expect(
        const JumpHighlightEnded(JumpReason.pinned, null).phase,
        'highlightEnded',
      );
    });
  });

  group('search navigation (§10.5)', () {
    late FakeSearch source;

    Env build(FakeAsync async) {
      final env = Env(async, count: 10000);
      source = FakeSearch(env.server); // 125 hits, newest first
      return env;
    }

    test('query, step through results, page results, close', () {
      run(env: build, (env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        final search = controller.search(source);
        var changes = 0;
        search.addListener(() => changes++);
        expect(search.status.value, SearchStatus.idle);
        expect(search.hasNext, isFalse);

        // Typing: only the last query is sent.
        search.setQuery('inv');
        search.setQuery('invo');
        search.setQuery(' invoice ');
        expect(search.status.value, SearchStatus.searching);
        env.settle(const Duration(milliseconds: 200));
        expect(source.queries, isEmpty, reason: 'debounced 300 ms');
        env.settle();
        expect(source.queries, ['invoice']);
        expect(search.query, 'invoice');
        expect(search.status.value, SearchStatus.ready);
        expect(search.total, 125);
        expect(search.loaded, 50);
        expect(search.index, isNull);
        expect(search.current, isNull);
        expect(search.results.first, k(100000));
        expect(search.hasNext, isTrue);
        expect(search.hasPrevious, isFalse);
        expect(changes, greaterThan(0));

        // next() = the newest hit, then older ones.
        JumpResult? result;
        search.next().then((r) => result = r);
        env.settle();
        // The newest hit is the newest message, which is on screen.
        expect(result!.outcome, JumpOutcome.alreadyVisible);
        expect(search.index, 0);
        expect(search.current, k(100000));
        expect(view.yOf(k(100000)), isNotNull);
        expect(controller.highlightQuery.value, 'invoice');
        expect(
          env.eventsOf<Jumped>().last.jump.reason,
          JumpReason.search,
        );

        search.next().then((r) => result = r);
        env.settle();
        expect(search.index, 1);
        expect(result!.landedOn, k(99200));
        expect(search.hasPrevious, isTrue);
        // The neighbours were warmed: the next step needs no fetch.
        search.next().then((r) => result = r);
        env.settle();
        expect(result!.fetchedPages, 0);
        search.previous().then((r) => result = r);
        env.settle();
        expect(search.index, 1);

        // Near the end of the loaded results the next page is loaded.
        search.goTo(46).then((r) => result = r);
        env.settle();
        expect(result!.succeeded, isTrue);
        expect(search.loaded, 100);
        expect(source.cursors.last, '50');
        // Beyond what is loaded: loads, then goes there.
        search.goTo(110).then((r) => result = r);
        env.settle();
        expect(search.loaded, 125);
        expect(search.index, 110);
        expect(search.hasNext, isTrue);
        search.goTo(124).then((r) => result = r);
        env.settle();
        expect(search.hasNext, isFalse);
        search.goTo(125).then((r) => result = r);
        env.settle();
        expect(result!.outcome, JumpOutcome.failed);
        search.goTo(-1).then((r) => result = r);
        env.settle();
        expect(result!.outcome, JumpOutcome.failed);
        expect(search.index, 124);

        // Closing keeps the position and stops marking the term.
        final keys = view.keys;
        search.close();
        env.settle();
        expect(search.status.value, SearchStatus.idle);
        expect(search.results, isEmpty);
        expect(controller.highlightQuery.value, isNull);
        expect(view.keys, keys);
        search.dispose();
        search.dispose();
        search.close();
      });
    });

    test('test 12: rapid next ×10, only the last jump arrives', () {
      run(env: build, (env) {
        final controller = env.controller()..open();
        FakeViewport(controller);
        env.settle();
        final search = controller.search(source)..setQuery('invoice');
        env.settle();
        search.goTo(20);
        env.settle(const Duration(seconds: 3));
        env.server
          ..requests.clear()
          ..maxInFlight = 0;
        final outcomes = <JumpOutcome>[];
        for (var i = 0; i < 10; i++) {
          search.next().then((r) => outcomes.add(r.outcome));
        }
        env.settle(const Duration(seconds: 3));
        expect(outcomes, hasLength(10));
        expect(outcomes.where((o) => o == JumpOutcome.arrived), hasLength(1));
        expect(
          outcomes.where((o) => o == JumpOutcome.cancelled),
          hasLength(9),
        );
        expect(outcomes.last, JumpOutcome.arrived);
        expect(search.index, 30);
        expect(env.server.maxInFlight, lessThanOrEqualTo(2));
        expect(controller.window.value.keys.contains(search.current), isTrue);
      });
    });

    test('empty results, errors and replaced queries', () {
      run(env: build, (env) {
        final controller = env.controller()..open();
        env.settle();
        final search = controller.search(source);
        var done = 0;
        search.setQuery('nothing').then((_) => done++);
        env.settle();
        expect(search.status.value, SearchStatus.empty);
        expect(search.hasNext, isFalse);
        expect(done, 1);
        JumpResult? result;
        search.next().then((r) => result = r);
        env.settle();
        expect(result!.outcome, JumpOutcome.failed);

        source.failNext = 1;
        search.setQuery('broken');
        env.settle();
        expect(search.status.value, SearchStatus.error);
        expect(search.error, isStateError);

        // A query replaced while its request is in flight is dropped.
        source.latency = const Duration(seconds: 1);
        search.setQuery('first').then((_) => done++);
        env.settle(const Duration(milliseconds: 500));
        search.setQuery('second').then((_) => done++);
        env.settle(const Duration(seconds: 3));
        expect(search.query, 'second');
        expect(search.status.value, SearchStatus.ready);
        expect(done, 3);

        // A failing results page keeps what is loaded.
        source
          ..latency = const Duration(milliseconds: 50)
          ..failNext = 1;
        search.goTo(48).then((r) => result = r);
        env.settle();
        expect(search.loaded, 50);
        expect(search.error, isStateError);

        // The query changes while more results load.
        search.goTo(80).then((r) => result = r);
        search.setQuery('third');
        env.settle();
        expect(result!.outcome, JumpOutcome.failed);

        // Disposing the controller disposes its searches.
        controller.dispose();
        search.setQuery('late');
        search.next().then((r) => result = r);
        env.settle();
        expect(result!.outcome, JumpOutcome.failed);
      });
    });

    test('a server that does not count results', () {
      run(env: build, (env) {
        source = FakeSearch(env.server, withTotal: false);
        final controller = env.controller()..open();
        env.settle();
        final search = controller.search(source)..setQuery('x');
        env.settle();
        expect(search.total, isNull);
        expect(search.loaded, 50);
        search.goTo(49);
        env.settle();
        expect(search.loaded, 100);
        expect(search.total, isNull);
      });
    });
  });
}
