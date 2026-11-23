// Headless controller tests (milestone 2): SPEC §18 tests 3, 4 (logic), 20
// and 22, plus open rules, paging, windowing, bottom logic, persistence and
// callbacks.
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/env.dart';
import 'support/fake_chat_server.dart';
import 'support/fake_viewport.dart';

void main() {
  group('open (§10.1)', () {
    test('cold open loads the newest page and lands at the bottom', () {
      run((env) {
        final controller = env.controller();
        final view = FakeViewport(controller);
        OpenResolution? how;
        controller.open().then((r) => how = r);
        expect(controller.phase.value, ListPhase.loading);
        expect(env.server.requests.single.direction, PageDirection.latest);
        expect(env.server.requests.single.limit, 20);

        env.settle(const Duration(milliseconds: 160));
        expect(how, OpenResolution.bottom);
        expect(controller.phase.value, ListPhase.ready);
        expect(view.keys.first, k(9810));
        expect(view.keys.last, k(10000));
        expect(view.extentAfter, 0);
        expect(controller.isAtBottom.value, isTrue);
        expect(controller.showScrollDownButton.value, isFalse);
        expect(controller.newerEdge.value, isA<EdgeEnd>());
        expect(env.eventsOf<ListOpened>().single.resolution, how);

        // The viewport is close to the top of 20 items: one more page.
        env.settle();
        expect(view.keys, hasLength(60));
        expect(view.extentAfter, 0, reason: 'still pinned to the bottom');
      });
    });

    test('an open that fetched its page does not refresh it', () {
      run((env) {
        final controller = env.controller();
        FakeViewport(controller, height: 100);
        controller.open(target: OpenTarget.message(k(5000)));
        env.settle();
        expect(controller.phase.value, ListPhase.ready);
        expect(env.server.requestsOf(PageDirection.around), hasLength(1));
        expect(
          env.server.requestsOf(PageDirection.newer),
          isEmpty,
          reason: 'the page is seconds old: nothing to catch up with',
        );
      });
    });

    test('an empty list opens as empty and shows its first message', () {
      run(
        env: (async) => Env(async, count: 0),
        (env) {
          final controller = env.controller();
          final view = FakeViewport(controller);
          controller.open();
          env.settle();
          expect(controller.phase.value, ListPhase.empty);
          env.server.incoming(chat);
          env.settle();
          expect(controller.phase.value, ListPhase.ready);
          expect(view.keys, [k(10)]);
        },
      );
    });

    test('a list in memory opens synchronously', () {
      run((env) {
        final first = env.controller()..open();
        env.settle();
        first.dispose();
        env.server.requests.clear();

        final second = env.controller(list: chat);
        // No session position was saved (no viewport ever reported).
        second.open();
        expect(second.phase.value, ListPhase.ready);
        expect(second.window.value.keys.last, k(10000));
        expect(second.window.value.placement, isA<PlaceBottom>());
        // …and refreshes in the background.
        expect(env.server.requests.single.direction, PageDirection.latest);
        expect(env.server.subscriptions, 1, reason: 'subscription was kept');
      });
    });

    test('the session position is restored exactly, in the same frame', () {
      run((env) {
        final first = env.controller()..open();
        final view = FakeViewport(first);
        env.settle();
        view.scrollBy(-725);
        env.settle(Duration.zero);
        expect(view.yOf(k(9740)), -25);
        first.dispose();

        final second = env.controller();
        OpenResolution? how;
        second.open().then((r) => how = r);
        final placement = second.window.value.placement! as PlaceAnchor;
        expect(placement.key, k(9740));
        expect(placement.offset, -25);
        final restored = FakeViewport(second);
        expect(restored.yOf(k(9740)), -25);
        env.settle();
        expect(how, OpenResolution.sessionRestore);
        expect(restored.yOf(k(9740)), -25, reason: 'the refresh moves nothing');
        expect(env.server.requests.last.direction, PageDirection.newer);
      });
    });

    test('test 3: a persisted island is discarded after a restart when asked',
        () {
      final store = InMemoryViewportStore()
        ..save(chat, snapshotAt(5000, live: false));
      run(
        env: (async) => Env(async, viewportStore: store),
        (env) {
          final controller = env.controller(
            config: const MessageListConfig(restoreIslandsAfterRestart: false),
          );
          OpenResolution? how;
          controller.open().then((r) => how = r);
          env.settle();
          expect(how, OpenResolution.bottom);
          expect(controller.window.value.keys.last, k(10000));
          expect(env.server.requestsOf(PageDirection.around), isEmpty);
        },
      );
    });

    test('a persisted island is restored by default (browser reload)', () {
      final store = InMemoryViewportStore()
        ..save(chat, snapshotAt(5000, live: false, offset: 30));
      run(
        env: (async) => Env(async, viewportStore: store),
        (env) {
          final controller = env.controller();
          final view = FakeViewport(controller);
          OpenResolution? how;
          controller.open().then((r) => how = r);
          expect(controller.phase.value, ListPhase.loading);
          env.settle();
          expect(how, OpenResolution.snapshot);
          expect(env.server.requests.first.direction, PageDirection.around);
          expect(env.server.requests.first.anchor, k(5000));
          expect(view.yOf(k(5000)), 30);
          expect(controller.isAtBottom.value, isFalse);
          expect(controller.showScrollDownButton.value, isTrue);
        },
      );
    });

    test('a persisted position in the live segment is restored', () {
      final store = InMemoryViewportStore()
        ..save(chat, snapshotAt(9700, live: true, offset: -10));
      run(
        env: (async) => Env(async, viewportStore: store),
        (env) {
          final controller = env.controller();
          final view = FakeViewport(controller);
          OpenResolution? how;
          controller.open().then((r) => how = r);
          env.settle();
          expect(how, OpenResolution.snapshot);
          expect(view.yOf(k(9700)), -10);
        },
      );
    });

    test('a deleted anchor restores at the nearest message', () {
      final store = InMemoryViewportStore()
        ..save(chat, snapshotAt(9700, live: true, offset: -10));
      run(
        env: (async) => Env(async, viewportStore: store),
        (env) {
          env.server.deleted.addAll([9700, 9710]);
          final controller = env.controller();
          final view = FakeViewport(controller);
          controller.open();
          env.settle();
          expect(view.yOf(k(9720)), 0);
        },
      );
    });

    test('loadSnapshot may be slow or broken without blocking the open', () {
      run((env) {
        final diagnostics = <MessageListDiagnostic>[];
        final slow = env.controller(
          callbacks: MessageListCallbacks(
            loadSnapshot: (list) => Future.delayed(
              const Duration(seconds: 5),
              () => snapshotAt(9000, live: true),
            ),
          ),
        );
        OpenResolution? how;
        slow.open().then((r) => how = r);
        env.settle();
        expect(how, OpenResolution.bottom, reason: '50 ms budget');
        slow.dispose();

        final broken = env.controller(
          list: other,
          callbacks: MessageListCallbacks(
            loadSnapshot: (list) => throw StateError('disk'),
            onDiagnostic: diagnostics.add,
          ),
        );
        broken.open().then((r) => how = r);
        env.settle();
        expect(how, OpenResolution.bottom);
        expect((diagnostics.single as CallbackError).callback, 'loadSnapshot');
      });
    });

    test('an explicit target wins over the saved position', () {
      run((env) {
        final controller = env.controller();
        final view = FakeViewport(controller);
        OpenResolution? how;
        controller
            .open(target: OpenTarget.message(k(4000)))
            .then((r) => how = r);
        env.settle();
        expect(how, OpenResolution.target);
        expect(view.yOf(k(4000)), 0);
        expect(env.server.requests.first.direction, PageDirection.around);
      });
    });

    test('a failed first page shows the error phase; open() retries', () {
      run((env) {
        env.server.failNextFetches = 5;
        final controller = env.controller()..open();
        env.settle(const Duration(seconds: 10));
        expect(controller.phase.value, ListPhase.error);
        expect(env.eventsOf<PageFailed>(), hasLength(5));
        controller.open();
        expect(controller.phase.value, ListPhase.loading);
        env.settle();
        expect(controller.phase.value, ListPhase.ready);
      });
    });
  });

  group('test 4: unread open (§10.1 rule 3, §10.8)', () {
    test('30 unread: divider 10 px from the top, and it stays there', () {
      run((env) {
        env.server.readState =
            ReadState(lastReadInbox: k(9700), unreadCount: 30);
        final controller = env.controller();
        final view = FakeViewport(controller);
        OpenResolution? how;
        controller.open().then((r) => how = r);
        env.settle(const Duration(milliseconds: 320));
        expect(how, OpenResolution.firstUnread);
        expect(
          [for (final r in env.server.requests.take(2)) r.direction],
          [PageDirection.latest, PageDirection.around],
          reason: 'fetched around the last read message',
        );
        expect(controller.window.value.unreadDividerBefore, k(9710));
        expect(view.dividerY, 10);
        expect(view.yOf(k(9710)), 40);
        expect(controller.unreadCount.value, 30);
        expect(controller.isAtBottom.value, isFalse);

        // Reading: 11 messages are fully visible.
        env.settle();
        expect(controller.highestVisibleKey.value, k(9810));
        expect(controller.unreadCount.value, 19);
        expect(env.server.readReceipts, [k(9810)]);
        expect(controller.window.value.unreadDividerBefore, k(9710));
        expect(view.dividerY, 10);

        // The server confirms: still no movement.
        env.server.readState =
            ReadState(lastReadInbox: k(9810), unreadCount: 19);
        env.server.push(ReadStateChanged(chat, env.server.readState!));
        env.settle();
        expect(controller.unreadCount.value, 19);
        expect(controller.window.value.unreadDividerBefore, k(9710));
        expect(view.dividerY, 10);
      });
    });

    test('a restored position still shows the divider', () {
      run((env) {
        final first = env.controller()..open();
        final view = FakeViewport(first);
        env.settle();
        view.scrollBy(-725);
        env.settle(Duration.zero);
        first.dispose();

        // 20 messages arrived meanwhile; the app knows where reading
        // stopped.
        final second = env.controller()
          ..setReadState(ReadState(lastReadInbox: k(9800), unreadCount: 20));
        OpenResolution? how;
        second.open().then((r) => how = r);
        final restored = FakeViewport(second);
        env.settle();
        expect(how, OpenResolution.sessionRestore);
        expect(restored.yOf(k(9740)), -25, reason: 'where the reader left');
        expect(second.window.value.unreadDividerBefore, k(9810));
      });
    });

    test('2 unread: aligned to the bottom, no extra fetch', () {
      run((env) {
        env.server.readState =
            ReadState(lastReadInbox: k(9980), unreadCount: 2);
        final controller = env.controller();
        final view = FakeViewport(controller);
        OpenResolution? how;
        controller.open().then((r) => how = r);
        env.settle(const Duration(milliseconds: 160));
        expect(how, OpenResolution.firstUnread);
        expect(env.server.requestsOf(PageDirection.around), isEmpty);
        expect(controller.window.value.unreadDividerBefore, k(9990));
        expect(view.extentAfter, 0);
        expect(view.yOf(k(10000)), 550);
        env.settle();
        expect(controller.unreadCount.value, 0);
        expect(controller.window.value.unreadDividerBefore, k(9990));
      });
    });

    test('outgoing and service messages are never the first unread', () {
      run(
        env: (async) => Env(async, outgoingEvery: 2),
        (env) {
          // 9990 is incoming (n = 999), 10000 is outgoing (n = 1000).
          env.server.readState =
              ReadState(lastReadInbox: k(9970), unreadCount: 1);
          final controller = env.controller()..open();
          env.settle();
          expect(controller.window.value.unreadDividerBefore, k(9990));
        },
      );
    });
  });

  group('paging and windowing (§10.2)', () {
    test('pages up to the oldest message with at most 80 built', () {
      run(
        env: (async) => Env(async, count: 300),
        (env) {
          final controller = env.controller()..open();
          final view = FakeViewport(controller);
          env.settle();
          for (var i = 0; i < 20; i++) {
            view.scrollToTop();
            final anchor = view.keys.first;
            final before = view.yOf(anchor);
            env.settle(const Duration(milliseconds: 500));
            expect(view.keys.length, lessThanOrEqualTo(80));
            if (view.yOf(anchor) != null) {
              expect(view.yOf(anchor), before, reason: 'page $i moved');
            }
          }
          expect(view.keys.first, k(10));
          expect(controller.olderEdge.value, isA<EdgeEnd>());
          expect(controller.newerEdge.value, isA<EdgeIdle>());
          expect(controller.showScrollDownButton.value, isTrue);
          // Single flight: no anchor was requested twice.
          final anchors = [
            for (final r in env.server.requestsOf(PageDirection.older))
              r.anchor!.order,
          ];
          expect(anchors.toSet(), hasLength(anchors.length));

          // …and back down, from memory.
          env.server.requests.clear();
          for (var i = 0; i < 20; i++) {
            view.dragToBottom();
            env.settle(const Duration(milliseconds: 100));
            expect(view.keys.length, lessThanOrEqualTo(80));
          }
          expect(view.keys.last, k(3000));
          expect(controller.isAtBottom.value, isTrue);
          expect(controller.newerEdge.value, isA<EdgeEnd>());
          expect(env.server.requests, isEmpty);
        },
      );
    });

    test('a failed page shows an edge error, keeps the window, retries', () {
      run(
        env: (async) => Env(async, count: 300),
        (env) {
          final controller = env.controller(
            callbacks: MessageListCallbacks(
              onPageError: (list, request, error, stack) {},
            ),
          )..open();
          final view = FakeViewport(controller);
          env.settle();
          final keys = view.keys;
          env.server.failNextFetches = 5;
          view.scrollToTop();
          env.settle(const Duration(milliseconds: 200));
          expect(controller.olderEdge.value, isA<EdgeLoading>());
          env.settle(const Duration(seconds: 10));
          expect(controller.olderEdge.value, isA<EdgeError>());
          expect(env.eventsOf<PageFailed>(), hasLength(5));
          expect(view.keys, keys, reason: 'the window is untouched');
          expect(controller.phase.value, ListPhase.ready);

          controller.retry(ListEdge.older);
          env.settle();
          expect(controller.olderEdge.value, isA<EdgeIdle>());
          expect(view.keys.first.order, lessThan(keys.first.order));
        },
      );
    });

    test('memory is trimmed around the window', () {
      run((env) {
        env.hub = MessageListHub<Msg>(
          source: env.server,
          adapter: const MsgAdapter(),
          memoryLimitPerList: 120,
        );
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        for (var i = 0; i < 12; i++) {
          view.scrollToTop();
          env.settle(const Duration(milliseconds: 500));
        }
        final store = env.hub.store.peek(chat)!;
        expect(store.length, lessThanOrEqualTo(160));
        expect(store.liveSegment, isNull, reason: 'the newest end was trimmed');
        for (final key in view.keys) {
          expect(store.contains(key.id), isTrue);
        }
      });
    });
  });

  group('bottom and incoming (§10.3)', () {
    test('at bottom: stays pinned, the window follows and stays ≤ 80', () {
      run((env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        for (var i = 0; i < 3; i++) {
          env.server.incoming(chat);
        }
        env.settle(Duration.zero);
        expect(view.keys.last, k(10030));
        expect(view.extentAfter, 0);
        expect(controller.isAtBottom.value, isTrue);
        expect(controller.unreadCount.value, 3);
        env.settle();
        expect(controller.unreadCount.value, 0, reason: 'read after the dwell');

        for (var i = 0; i < 100; i++) {
          env.server.incoming(chat);
        }
        env.settle();
        expect(view.keys, hasLength(80));
        expect(view.keys.last, k(11030));
        expect(view.extentAfter, 0);
      });
    });

    test('scrolled up: nothing moves, the badge counts', () {
      run((env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        view.scrollBy(-1000);
        env.settle();
        final anchor = k(view.visibleOrders.first);
        final y = view.yOf(anchor);
        expect(controller.isAtBottom.value, isFalse);
        expect(controller.showScrollDownButton.value, isTrue);

        env.server.incoming(chat);
        env.server.incoming(chat);
        env.server.incoming(chat, outgoing: true);
        env.settle();
        expect(view.yOf(anchor), y);
        expect(controller.unreadCount.value, 2);
        expect(view.keys.last, k(10030), reason: 'appended below, unseen');
        expect(env.eventsOf<UnreadChanged>().last.count, 2);
      });
    });

    test('everything in one frame is one window update', () {
      run((env) {
        final controller = env.controller()..open();
        FakeViewport(controller);
        env.settle();
        env.events.clear();
        for (var i = 0; i < 10; i++) {
          env.server.incoming(chat);
        }
        env.settle(Duration.zero);
        expect(env.eventsOf<WindowChanged>(), hasLength(1));
        final inserted = env.eventsOf<MessageInserted>().single;
        expect(inserted.cause, InsertCause.incoming);
        expect(inserted.keys, hasLength(10));
      });
    });

    test('the stick policy can refuse pinning while dragging', () {
      run((env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        view.scrollBy(-100);
        env.settle(Duration.zero);
        expect(controller.isAtBottom.value, isFalse);
        view
          ..dragging = true
          ..dragToBottom();
        env.settle(Duration.zero);
        expect(controller.isAtBottom.value, isFalse);
        view
          ..dragging = false
          ..scrollBy(0);
        env.settle(Duration.zero);
        expect(controller.isAtBottom.value, isTrue);
      });
    });
  });

  group('test 22: read receipts (§10.8)', () {
    test('keys strictly increase, debounced, outgoing ignored', () {
      run((env) {
        final read = <MessageKey>[];
        final controller = env.controller(
          callbacks: MessageListCallbacks(
            onReadUpTo: (list, key) => read.add(key),
          ),
        )..open();
        FakeViewport(controller);
        env.settle();
        expect(env.server.readReceipts, [k(10000)]);

        // A burst inside one debounce window is one receipt.
        env.server.incoming(chat);
        env.settle(const Duration(milliseconds: 120));
        env.server.incoming(chat);
        env.settle(const Duration(milliseconds: 120));
        expect(controller.highestVisibleKey.value, k(10020));
        expect(env.server.readReceipts, hasLength(1), reason: 'debounced');
        env.settle();
        expect(env.server.readReceipts, [k(10000), k(10020)]);

        // My own message is not something I read.
        env.server.incoming(chat, outgoing: true);
        env.settle();
        expect(env.server.readReceipts, hasLength(2));

        env.server.incoming(chat);
        env.settle();
        expect(env.server.readReceipts, [k(10000), k(10020), k(10040)]);
        expect(read, env.server.readReceipts);
        expect(
          [for (final e in env.eventsOf<ReadUpTo>()) e.key],
          env.server.readReceipts,
        );
        for (var i = 1; i < read.length; i++) {
          expect(read[i] > read[i - 1], isTrue);
        }
        expect(controller.highestVisibleKey.value, k(10040));
      });
    });

    test('a failed receipt is retried, and announced once', () {
      run((env) {
        final controller = env.controller()..open();
        FakeViewport(controller);
        env.server.failNextMarkRead = 2;
        env.settle(const Duration(seconds: 5));
        expect(env.server.readReceipts, [k(10000)]);
        expect(env.eventsOf<ReadUpTo>(), hasLength(1));
      });
    });

    test('nothing is read in the background', () {
      run((env) {
        final controller = env.controller()..open();
        FakeViewport(controller);
        env.settle();
        controller.setForeground(foreground: false);
        env.server.incoming(chat);
        env.settle();
        expect(controller.unreadCount.value, 1);
        expect(env.server.readReceipts, [k(10000)]);
        controller.setForeground(foreground: true);
        env.settle();
        expect(controller.unreadCount.value, 0);
        expect(env.server.readReceipts.last, k(10010));
      });
    });

    test('a read policy can replace the rule', () {
      run((env) {
        final controller = env.controller(
          policies: const MessageListPolicies(read: _NeverRead()),
        )..open();
        FakeViewport(controller);
        env.settle();
        expect(env.server.readReceipts, isEmpty);
        expect(controller.highestVisibleKey.value, isNull);
      });
    });
  });

  group('test 20: stale results (§15)', () {
    test('a page from before a switch is dropped', () {
      run((env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        final loaded = env.hub.store.peek(chat)!.length;
        view.scrollToTop();
        env.settle(const Duration(milliseconds: 50));
        expect(env.server.requests.last.direction, PageDirection.older);
        final stale = env.server.requests.last;

        controller.switchTo(other);
        // The previous list stays on screen until the new one is ready.
        expect(controller.window.value.list, chat);
        expect(controller.phase.value, ListPhase.ready);
        env.settle(Duration.zero);
        expect(stale.cancel.isCancelled, isTrue);
        env.settle();
        expect(controller.window.value.list, other);
        expect(controller.list, other);
        expect(env.hub.store.peek(chat)!.length, loaded, reason: 'dropped');
        expect(controller.olderEdge.value, isNot(isA<EdgeLoading>()));
      });
    });

    test('test 2 (logic): switching back restores the island position', () {
      run((env) {
        final controller = env.controller();
        final view = FakeViewport(controller);
        controller.open(target: OpenTarget.message(k(4000)));
        env.settle();
        view.scrollBy(120);
        env.settle(Duration.zero);
        final anchor = k(view.visibleOrders.first);
        final y = view.yOf(anchor);

        controller.switchTo(other);
        env.settle();
        expect(view.keys.last, k(10000));

        OpenResolution? how;
        controller.switchTo(chat).then((r) => how = r);
        env.settle();
        expect(how, OpenResolution.sessionRestore);
        expect(view.yOf(anchor), y);
        expect(controller.isAtBottom.value, isFalse);
      });
    });

    test('only the last of two opens takes effect', () {
      run((env) {
        final controller = env.controller();
        controller.open();
        controller.open(target: OpenTarget.message(k(4000)));
        env.settle();
        expect(env.eventsOf<ListOpened>().single.resolution,
            OpenResolution.target);
        expect(controller.window.value.keys.contains(k(4000)), isTrue);
      });
    });

    test('dispose in the middle of a fetch is silent', () {
      run((env) {
        final controller = env.controller()..open();
        env.settle(const Duration(milliseconds: 50));
        controller.dispose();
        env.settle(const Duration(seconds: 40));
        expect(env.hub.store.peek(chat)?.length ?? 0, 0);
        expect(env.hub.attachedLists, isEmpty);
      });
    });
  });

  group('persistence (§10.9)', () {
    test('the position is saved after scroll idle and on dispose', () {
      final saved = InMemoryViewportStore();
      run(
        env: (async) => Env(async, viewportStore: saved),
        (env) {
          final controller = env.controller()..open();
          final view = FakeViewport(controller);
          env.settle();
          view.scrollBy(-725);
          env.settle(const Duration(milliseconds: 500));
          expect(
              env.eventsOf<SnapshotSaved>().where(
                    (e) => e.snapshot.anchorKey == k(9740),
                  ),
              isEmpty,
              reason: 'debounced 800 ms');
          env.settle();
          final snapshot = saved.load(chat)!;
          expect(snapshot.anchorKey, k(9740));
          expect(snapshot.anchorOffset, -25);
          expect(snapshot.connectedToNewest, isTrue);
          expect(snapshot.viewportWidth, 400);
          expect(
              env.eventsOf<SnapshotSaved>().last.reason, SaveReason.scrollIdle);

          view.scrollBy(-50);
          env.settle(Duration.zero);
          controller.dispose();
          expect(saved.load(chat)!.anchorKey, k(9730));
        },
      );
    });

    test('saveSnapshot replaces the viewport store', () {
      final saved = InMemoryViewportStore();
      run(
        env: (async) => Env(async, viewportStore: saved),
        (env) {
          final reasons = <SaveReason>[];
          final controller = env.controller(
            callbacks: MessageListCallbacks(
              saveSnapshot: (list, snapshot, reason) => reasons.add(reason),
            ),
          )..open();
          FakeViewport(controller);
          env.settle(const Duration(seconds: 3));
          controller.saveSnapshot();
          expect(reasons, [SaveReason.scrollIdle, SaveReason.explicit]);
          expect(saved.load(chat), isNull);
        },
      );
    });
  });

  group('callbacks and events (§13)', () {
    test('a throwing callback becomes a diagnostic; the list goes on', () {
      run((env) {
        final diagnostics = <MessageListDiagnostic>[];
        final pages = <PageOrigin>[];
        final controller = env.controller(
          callbacks: MessageListCallbacks(
            onOpened: (list, how) => throw StateError('app bug'),
            onUnreadChanged: (list, count) => throw StateError('app bug'),
            onReadUpTo: (list, key) async => throw StateError('async bug'),
            onPageLoaded: (list, request, result, origin, took) =>
                pages.add(origin),
            onDiagnostic: diagnostics.add,
          ),
        )..open();
        final view = FakeViewport(controller);
        env.settle();
        env.server.incoming(chat);
        env.settle();
        expect(
          {for (final d in diagnostics) (d as CallbackError).callback},
          {'onOpened', 'onUnreadChanged', 'onReadUpTo'},
        );
        expect(view.keys.last, k(10010));
        expect(pages, hasLength(env.eventsOf<PageLoaded>().length));
        expect(pages, isNotEmpty);
        expect(
            env.eventsOf<DiagnosticReported>(), hasLength(diagnostics.length));
      });
    });

    test('the imperative API goes through the same path', () {
      run((env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        env.events.clear();
        controller.patch('m10000', (m) => Msg(m.order, rev: m.rev + 1));
        controller.remove(['m9990'], animate: false);
        controller.upsert([const Msg(10010)]);
        controller.setReadState(
          ReadState(lastReadInbox: k(10000), unreadCount: 7),
        );
        env.settle(Duration.zero);
        expect(controller.messageOf(k(10000))!.rev, 1);
        expect(view.keys.contains(k(9990)), isFalse);
        expect(view.keys.last, k(10010));
        expect(env.eventsOf<MessageUpdated>().single.keys, [k(10000)]);
        expect(
            env.eventsOf<MessageRemoved>().single.cause, RemoveCause.deleted);
        expect(controller.unreadCount.value, 7);
        expect(view.extentAfter, 0, reason: 'still pinned after the delete');
      });
    });
  });

  group('hub (§8.4)', () {
    test('identical requests share one fetch; a cancelled one is dropped', () {
      run((env) {
        PageRequest request() => PageRequest(
              list: chat,
              direction: PageDirection.latest,
              limit: 20,
            );
        env.hub.attach(chat);
        final a = request();
        final b = request();
        final outcomes = <PageOutcome<Msg>>[];
        env.hub.fetch(a).then(outcomes.add);
        env.hub.fetch(b).then(outcomes.add);
        a.cancel.cancel();
        env.settle();
        expect(env.server.requests, hasLength(1));
        expect(outcomes, hasLength(2));
        expect(outcomes.first.applied, isTrue, reason: 'b still wants it');

        final c = request();
        env.hub.fetch(c).then(outcomes.add);
        c.cancel.cancel();
        env.settle(Duration.zero);
        expect(env.server.requests.last.cancel.isCancelled, isTrue);
        env.settle();
        expect(outcomes.last.applied, isFalse);
      });
    });

    test('one subscription per list, released 30 s after the last user', () {
      run((env) {
        env.hub.attach(chat);
        env.hub.attach(chat);
        expect(env.server.subscriptions, 1);
        env.hub.detach(chat);
        env.hub.detach(chat);
        env.settle(const Duration(seconds: 29));
        env.hub.attach(chat);
        expect(env.server.subscriptions, 1);
        env.hub.detach(chat);
        env.settle(const Duration(seconds: 31));
        expect(env.hub.attachedLists, isEmpty);
        env.hub.attach(chat);
        expect(env.server.subscriptions, 2);
      });
    });

    test('two controllers on one list share data, not positions', () {
      run((env) {
        final a = env.controller()..open();
        final b = env.controller()..open();
        final viewA = FakeViewport(a);
        final viewB = FakeViewport(b);
        env.settle();
        viewB.scrollBy(-800);
        env.settle();
        final y = viewB.yOf(k(view0(viewB)));
        env.server.incoming(chat);
        env.settle();
        expect(viewA.keys.last, k(10010));
        expect(viewA.extentAfter, 0);
        expect(viewB.keys.last, k(10010));
        expect(viewB.yOf(k(view0(viewB))), y);
        expect(env.server.subscriptions, 1);
      });
    });
  });
}

int view0(FakeViewport<Msg> view) => view.visibleOrders.first;

final class _NeverRead extends ReadPolicy {
  const _NeverRead();

  @override
  bool isRead({
    required double visibleFraction,
    required double viewportCoverage,
  }) =>
      false;
}
