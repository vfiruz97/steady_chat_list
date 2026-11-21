import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:test/test.dart';

import 'support.dart';

ViewportSnapshot _snapshot({required bool live}) => ViewportSnapshot(
      anchorKey: k(50),
      anchorOffset: 0,
      offsetFromBottom: 0,
      visibleKeys: [k(50)],
      connectedToNewest: live,
      viewportWidth: 400,
      savedAt: DateTime.utc(2026),
    );

void main() {
  group('OpenPolicy (§10.1)', () {
    const policy = OpenPolicy();
    const unread = ReadState(unreadCount: 3);

    test('session → persisted → unread → bottom', () {
      final session = policy.decide(
        OpenContext(
          target: const OpenTarget.auto(),
          readState: unread,
          sessionSnapshot: _snapshot(live: false),
          persistedSnapshot: _snapshot(live: true),
        ),
      );
      expect(
        (session as OpenPlanRestore).resolution,
        OpenResolution.sessionRestore,
      );

      final persisted = policy.decide(
        OpenContext(
          target: const OpenTarget.auto(),
          readState: unread,
          persistedSnapshot: _snapshot(live: true),
        ),
      );
      expect(
          (persisted as OpenPlanRestore).resolution, OpenResolution.snapshot);

      expect(
        policy.decide(
          const OpenContext(target: OpenTarget.auto(), readState: unread),
        ),
        isA<OpenPlanUnread>(),
      );
      expect(
        policy.decide(
          const OpenContext(
            target: OpenTarget.auto(),
            readState: ReadState.empty,
          ),
        ),
        isA<OpenPlanBottom>(),
      );
    });

    test('a persisted island needs restoreIslandsAfterRestart', () {
      OpenPlan decide({required bool restore}) => policy.decide(
            OpenContext(
              target: const OpenTarget.auto(),
              readState: ReadState.empty,
              persistedSnapshot: _snapshot(live: false),
              restoreIslandsAfterRestart: restore,
            ),
          );
      expect(decide(restore: false), isA<OpenPlanBottom>());
      expect(decide(restore: true), isA<OpenPlanRestore>());
    });

    test('explicit targets ignore saved positions', () {
      OpenPlan decide(OpenTarget target) => policy.decide(
            OpenContext(
              target: target,
              readState: unread,
              sessionSnapshot: _snapshot(live: true),
            ),
          );
      expect(decide(const OpenTarget.bottom()), isA<OpenPlanBottom>());
      expect(decide(const OpenTarget.firstUnread()), isA<OpenPlanUnread>());
      expect((decide(OpenTarget.message(k(7))) as OpenPlanMessage).key, k(7));
    });
  });

  test('ReadPolicy: fully visible, or half the viewport when tall', () {
    const policy = ReadPolicy();
    expect(policy.isRead(visibleFraction: 1, viewportCoverage: 0.1), isTrue);
    expect(policy.isRead(visibleFraction: 0.9, viewportCoverage: 0.1), isFalse);
    expect(policy.isRead(visibleFraction: 0.4, viewportCoverage: 0.5), isTrue);
  });

  test('AnchorPolicy: first visible item that is not being removed', () {
    const policy = AnchorPolicy();
    final picked = policy.pick([
      AnchorCandidate(key: k(1), top: -60, height: 50),
      AnchorCandidate(key: k(2), top: -10, height: 50, isRemoving: true),
      AnchorCandidate(key: k(3), top: 40, height: 50),
    ]);
    expect(picked!.key, k(3));
    expect(policy.pick(const []), isNull);
  });

  test('RetryPolicy: 0.5, 1, 2, 4 s, then stop', () {
    const policy = RetryPolicy();
    expect(
      [for (var i = 0; i < 5; i++) policy.delayFor(i)?.inMilliseconds],
      [500, 1000, 2000, 4000, null],
    );
    expect(const RetryPolicy.none().delayFor(0), isNull);
  });

  group('WindowPolicy (§10.2)', () {
    const policy = WindowPolicy();

    test('a window with room loads within the preload extent', () {
      bool at(double distance) => policy.shouldExtend(
            distanceToEdge: distance,
            distanceToOtherEdge: 0,
            averageItemExtent: 50,
            windowIsFull: false,
          );
      expect(at(1500), isTrue);
      expect(at(1501), isFalse);
    });

    test('a full window never makes its two edges trigger each other', () {
      // Whatever the item height and position, after loading a page on one
      // side (and unmounting a page on the other) the other side must not
      // ask for it back.
      for (final extent in [20.0, 40.0, 50.0, 80.0, 200.0]) {
        const viewport = 600.0;
        final scrollable = extent * 80 - viewport;
        final page = extent * 40;
        if (scrollable <= page) continue; // window too small to page
        for (var before = 0.0; before <= scrollable; before += 10) {
          final after = scrollable - before;
          final older = policy.shouldExtend(
            distanceToEdge: before,
            distanceToOtherEdge: after,
            averageItemExtent: extent,
            windowIsFull: true,
          );
          if (!older) continue;
          final backDown = policy.shouldExtend(
            distanceToEdge: after - page,
            distanceToOtherEdge: before + page,
            averageItemExtent: extent,
            windowIsFull: true,
          );
          expect(backDown, isFalse, reason: 'extent $extent, before $before');
        }
      }
    });
  });

  test('GroupingPolicy: same sender, same day, within the gap', () {
    const policy = GroupingPolicy<_Chat>();
    const adapter = _ChatAdapter();
    const gap = Duration(minutes: 5);
    final t = DateTime(2026, 11, 20, 12);
    _Chat m(String sender, int minutes, {bool service = false}) =>
        _Chat(sender, t.add(Duration(minutes: minutes)), service: service);

    expect(policy.sameGroup(adapter, m('a', 0), m('a', 4), gap), isTrue);
    expect(policy.sameGroup(adapter, m('a', 0), m('a', 6), gap), isFalse);
    expect(policy.sameGroup(adapter, m('a', 0), m('b', 1), gap), isFalse);
    expect(
      policy.sameGroup(adapter, m('a', 0), m('a', 1, service: true), gap),
      isFalse,
    );
    expect(
      policy.sameGroup(
        adapter,
        _Chat('a', DateTime(2026, 11, 20, 23, 59)),
        _Chat('a', DateTime(2026, 11, 21, 0, 1)),
        gap,
      ),
      isFalse,
      reason: 'a new day starts a new group',
    );
    expect(policy.dayOf(adapter, m('a', 30)), DateTime(2026, 11, 20));
  });

  test('default divider, selection and pinned policies', () {
    final store = newStore();
    final server = TestServer()..seed([10, 20, 30, 40]);
    store.page(server.latest(10));
    store.apply(
      ReadStateChanged<Msg>(
        chat,
        ReadState(lastReadInbox: k(20), unreadCount: 2),
      ),
    );
    store.apply(PinnedChanged<Msg>(chat, [k(10), k(30)]));
    expect(const UnreadDividerPolicy<Msg>().dividerBefore(store), k(30));
    expect(const PinnedPolicy<Msg>().currentPinned(store, k(25)), k(10));
    expect(
      const SelectionPolicy<Msg>()
          .isSelectable(const MsgAdapter(), const Msg(1, service: true)),
      isFalse,
    );
    expect(const BottomStickPolicy().shouldStick(userDragging: true), isFalse);
  });
}

class _Chat {
  const _Chat(this.sender, this.at, {this.service = false});
  final String sender;
  final DateTime at;
  final bool service;
}

class _ChatAdapter extends MessageAdapter<_Chat> {
  const _ChatAdapter();
  @override
  MessageKey keyOf(_Chat m) =>
      MessageKey(order: m.at.microsecondsSinceEpoch, id: '${m.at}');
  @override
  DateTime dateOf(_Chat m) => m.at;
  @override
  String? senderIdOf(_Chat m) => m.sender;
  @override
  bool isService(_Chat m) => m.service;
}
