// More headless controller tests: local messages, history cleared, lost
// windows, the unread divider, read receipts and the remaining callbacks.
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/env.dart';
import 'support/fake_chat_server.dart';
import 'support/fake_viewport.dart';

void main() {
  test('scrollDownButtonDistance: the button shows that many px from the end',
      () {
    run((env) {
      final controller = env.controller(
        config: const MessageListConfig(scrollDownButtonDistance: 60),
      )..open();
      final view = FakeViewport(controller);
      env.settle();
      expect(controller.showScrollDownButton.value, isFalse);
      view.scrollBy(-50);
      env.settle();
      expect(controller.showScrollDownButton.value, isFalse);
      view.scrollBy(-20);
      env.settle();
      expect(controller.showScrollDownButton.value, isTrue);
      view.scrollBy(70);
      env.settle();
      expect(controller.showScrollDownButton.value, isFalse);
    });
  });

  test('local messages: sending, acked in place, failed', () {
    run((env) {
      final controller = env.controller()..open();
      final view = FakeViewport(controller);
      env.settle();
      final generation = controller.generation;
      expect(generation, greaterThan(0));

      final store = env.hub.store.peek(chat)!;
      Msg local(String id) {
        final key = store.nextLocalKey(id);
        return Msg(key.order, id: id, localSeq: key.localSeq, outgoing: true);
      }

      final first = local('c1');
      controller.apply(MessagesAdded(chat, [first]));
      env.settle(Duration.zero);
      expect(view.keys.last.id, 'c1');
      expect(view.extentAfter, 0);
      expect(controller.sendStateOf(first.key), SendState.sending);
      expect(env.eventsOf<MessageInserted>().last.cause, InsertCause.local);

      controller.apply(const LocalFailed<Msg>(chat, 'c1', 'offline'));
      env.settle(Duration.zero);
      expect(controller.sendStateOf(first.key), SendState.failed);

      controller.apply(
        const LocalAcked(chat, 'c1', Msg(10010, outgoing: true)),
      );
      env.settle(Duration.zero);
      final replaced = env.eventsOf<KeyReplaced>().single;
      expect(replaced.oldKey.id, 'c1');
      expect(replaced.newKey, k(10010));
      expect(view.keys.last, k(10010));
      expect(controller.sendStateOf(k(10010)), SendState.sent);
      expect(controller.sendStateOf(k(10000)), SendState.none);
      expect(controller.sendStateOf(k(5)), SendState.none);
      expect(controller.generation, generation);
    });
  });

  test('history cleared: the list becomes empty', () {
    run((env) {
      final controller = env.controller()..open();
      final view = FakeViewport(controller);
      env.settle();
      controller.apply(HistoryCleared<Msg>(chat, k(10000)));
      env.settle(Duration.zero);
      expect(view.keys, isEmpty);
      expect(controller.phase.value, ListPhase.empty);
      expect(
        env.eventsOf<MessageRemoved>().single.cause,
        RemoveCause.historyCleared,
      );
      expect(controller.isAtBottom.value, isFalse);
      expect(controller.showScrollDownButton.value, isFalse);
    });
  });

  test('an island whose messages are all deleted reopens at the bottom', () {
    run((env) {
      final controller = env.controller();
      final view = FakeViewport(controller);
      controller.open(target: OpenTarget.message(k(4000)));
      env.settle();
      final ids = [for (final key in view.keys) key.id];
      for (final key in view.keys) {
        env.server.deleted.add(key.order);
      }
      controller.remove(ids);
      env.settle();
      expect(view.keys.last, k(10000));
      expect(controller.phase.value, ListPhase.ready);
    });
  });

  test('everything deleted at once, some of it without animation', () {
    run(
      env: (async) => Env(async, count: 20),
      (env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        final ids = [for (final key in view.keys) key.id];
        controller.remove(ids.sublist(0, 10), animate: false);
        controller.remove(ids.sublist(10));
        env.settle(Duration.zero);
        expect(view.keys, hasLength(10), reason: 'only the fading ones');
        expect(controller.window.value.removing, hasLength(10));
        env.settle();
        expect(view.keys, isEmpty);
        expect(controller.phase.value, ListPhase.empty);
      },
    );
  });

  test('a page that brings nothing usable stops with an edge error', () {
    run(
      env: (async) => Env(async, count: 300),
      (env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        // The next older page was deleted here a moment ago; the server
        // still returns it.
        final first = view.keys.first.order;
        controller
            .remove([for (var o = first - 400; o < first; o += 10) 'm$o']);
        view.scrollToTop();
        env.settle();
        final edge = controller.olderEdge.value;
        expect(edge, isA<EdgeError>());
        expect('${(edge as EdgeError).error}', contains('no usable keys'));
        // A retry that fails differently replaces the error.
        env.server.failNextFetches = 100;
        controller.retry(ListEdge.older);
        env.settle(const Duration(seconds: 10));
        final again = controller.olderEdge.value as EdgeError;
        expect('${again.error}', contains('offline'));
        env.server.failNextFetches = 100;
        controller.retry(ListEdge.older);
        env.settle(const Duration(seconds: 10));
        expect(
          identical(
              (controller.olderEdge.value as EdgeError).error, again.error),
          isFalse,
        );
      },
    );
  });

  test('part of the window deleted: the rest stays', () {
    run((env) {
      final controller = env.controller()..open();
      final view = FakeViewport(controller);
      env.settle();
      final keys = view.keys;
      controller.remove([keys.first.id, keys.last.id]);
      env.settle(Duration.zero);
      expect(controller.window.value.removing, hasLength(2));
      expect(view.keys, keys, reason: 'still there while they fade out');
      env.settle(const Duration(milliseconds: 300));
      expect(controller.window.value.removing, isEmpty);
      expect(view.keys.first, keys[1]);
      expect(view.keys.last, keys[keys.length - 2]);
    });
  });

  test('the divider moves on when the first unread is deleted (§10.7)', () {
    run(
      env: (async) => Env(async, outgoingEvery: 2),
      (env) {
        // n = 997 (9970) is incoming, 998 outgoing, 999 incoming.
        env.server.readState =
            ReadState(lastReadInbox: k(9960), unreadCount: 2);
        final controller = env.controller()..open();
        FakeViewport(controller);
        env.settle(const Duration(milliseconds: 400));
        expect(controller.window.value.unreadDividerBefore, k(9970));
        controller.remove(['m9970']);
        env.settle(Duration.zero);
        expect(
          controller.window.value.unreadDividerBefore,
          k(9990),
          reason: '9980 is outgoing',
        );
        controller.remove(['m9990', 'm10000']);
        env.settle(Duration.zero);
        expect(controller.window.value.unreadDividerBefore, isNull);
      },
    );
  });

  test('unread without a read marker: everything loaded is unread', () {
    run(
      env: (async) => Env(async, count: 5),
      (env) {
        env.server.readState = const ReadState(unreadCount: 3);
        final controller = env.controller();
        FakeViewport(controller);
        OpenResolution? how;
        controller.open().then((r) => how = r);
        env.settle();
        expect(how, OpenResolution.firstUnread);
        expect(controller.window.value.unreadDividerBefore, k(10));
        // All five are on screen and read; three of them were unread.
        expect(controller.unreadCount.value, 0);
      },
    );
  });

  test('a persisted position that no longer exists falls back', () {
    final store = InMemoryViewportStore()
      ..save(chat, snapshotAt(5000, live: true));
    run(
      env: (async) => Env(async, count: 0, viewportStore: store),
      (env) {
        final controller = env.controller();
        OpenResolution? how;
        controller.open().then((r) => how = r);
        env.settle();
        expect(how, OpenResolution.bottom);
        expect(controller.phase.value, ListPhase.empty);
      },
    );
  });

  test('opening at a deleted message lands on the next one', () {
    run((env) {
      final controller = env.controller()..open();
      final view = FakeViewport(controller);
      env.settle();
      controller.remove(['m9500']);
      env.settle(Duration.zero);
      controller.open(target: OpenTarget.message(k(9500)));
      env.settle(Duration.zero);
      expect(view.yOf(k(9510)), 0);
    });
  });

  test('a reopen that missed more than a page moves to the real newest', () {
    run((env) {
      final first = env.controller()..open();
      env.settle();
      first.dispose();
      env.settle(const Duration(seconds: 40)); // subscription released
      for (var i = 0; i < 100; i++) {
        env.server.arrived.add(Msg(env.server.newest + 10)); // not pushed
      }
      final second = env.controller()..open();
      expect(second.window.value.keys.last, k(10000), reason: 'cached');
      env.settle();
      expect(second.window.value.keys.last, k(11000));
      expect(second.window.value.placement, isA<PlaceBottom>());
      expect(second.windowEndsAtNewest, isTrue);
    });
  });

  test('read receipts: zero dwell, give up without retries, catch up', () {
    run((env) {
      final read = <MessageKey>[];
      final controller = env.controller(
        config: const MessageListConfig(readDwell: Duration.zero),
        policies: const MessageListPolicies(retry: RetryPolicy.none()),
        callbacks: MessageListCallbacks(
          onReadUpTo: (list, key) async => read.add(key),
          onPageRequested: (list, request) {},
          onAtBottomChanged: (list, atBottom) {},
        ),
      )..open();
      FakeViewport(controller);
      env.server.failNextMarkRead = 1;
      env.settle(const Duration(milliseconds: 200));
      expect(controller.highestVisibleKey.value, k(10000), reason: 'no dwell');
      env.settle();
      expect(env.server.readReceipts, isEmpty, reason: 'gave up');
      expect(read, [k(10000)]);

      // A message read while a receipt is in flight is sent right after.
      env.server.latency = const Duration(seconds: 1);
      env.server.incoming(chat);
      env.settle(const Duration(milliseconds: 500));
      env.server.incoming(chat);
      env.settle(const Duration(seconds: 4));
      expect(env.server.readReceipts, [k(10010), k(10020)]);
      expect(env.eventsOf<DiagnosticReported>(), isEmpty);
    });
  });

  test('typing users are exposed for a footer', () {
    run((env) {
      final controller = env.controller()..open();
      env.settle();
      expect(controller.typingUserIds.value, isEmpty);
      env.server.push(const TypingChanged<Msg>(chat, {'alice'}));
      env.settle(Duration.zero);
      expect(controller.typingUserIds.value, {'alice'});
      env.server.push(const TypingChanged<Msg>(chat, {}));
      env.settle(Duration.zero);
      expect(controller.typingUserIds.value, isEmpty);
    });
  });

  test('events describe themselves; item info compares by value', () {
    expect(
      const CallbackError('onOpened', 'boom', StackTrace.empty).toString(),
      'CallbackError(onOpened: boom)',
    );
    expect(const AnchorCorrected(12).toString(), 'AnchorCorrected(12.0 px)');
    final a = MessageItemInfo(key: k(1), isFirstInDay: true);
    final b = MessageItemInfo(key: k(1), isFirstInDay: true, indexInWindow: 9);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(MessageItemInfo(key: k(1))));
    expect({a, b}, hasLength(1));
  });
}
