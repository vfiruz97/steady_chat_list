import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestServer server;
  late FakeClock clock;
  late ListStore<Msg> store;

  setUp(() {
    // 100 messages with gaps in the ids: 10, 20, … 1000.
    server = TestServer()..seed([for (var i = 1; i <= 100; i++) i * 10]);
    clock = FakeClock();
    store = newStore(clock: clock);
  });

  tearDown(() => store.debugCheckInvariants());

  group('applyPage (§7.1)', () {
    test('latest creates the live segment', () {
      final delta = store.page(server.latest(20));
      expect(delta.inserted, hasLength(20));
      expect(delta.segmentsChanged, isTrue);
      expect(store.segments, [
        Segment(first: k(810), last: k(1000), reachedNewest: true),
      ]);
      expect(store.liveSegment, isNotNull);
    });

    test('older pages extend the segment and find the oldest', () {
      store.page(server.latest(20));
      store.page(server.older(k(810), 40));
      expect(store.segments.single.first, k(410));
      expect(store.segments.single.reachedOldest, isFalse);
      final (last, all) = server.older(k(410), 40);
      store.applyPage(last, PageResult(items: all.items));
      expect(store.segments.single.first, k(10));
      // 40 of 40 returned: the server may have more.
      final (req, _) = server.older(k(10), 40);
      expect(store.segments.single.reachedOldest, isFalse);
      store.applyPage(req, const PageResult(items: []));
      expect(store.segments.single.reachedOldest, isTrue);
    });

    test('an older page shorter than the limit reaches the oldest', () {
      store.page(server.latest(20));
      final (req, res) = server.older(k(810), 200);
      store.applyPage(req, PageResult(items: res.items));
      expect(store.segments.single.reachedOldest, isTrue);
    });

    test('around creates an island; ids never prove contiguity', () {
      store.page(server.latest(20));
      store.page(server.around(k(800), 2)); // 790, 800, 810
      expect(store.segments, hasLength(1), reason: '810 is shared: merged');

      store.page(server.around(k(300), 10));
      expect(store.segments, hasLength(2));
      expect(store.segments.first, Segment(first: k(250), last: k(350)));
      expect(store.isContiguous(k(300), k(350)), isTrue);
      expect(store.isContiguous(k(350), k(790)), isFalse);

      // Fetch 360..780 exclusive of both neighbours: still three segments.
      final middle = [for (var o = 370; o <= 780; o += 10) Msg(o)];
      store.applyPage(
        PageRequest(
          list: chat,
          direction: PageDirection.around,
          anchor: k(500),
          limit: 100,
        ),
        PageResult(items: middle),
      );
      expect(store.segments, hasLength(3));
    });

    test('paging newer merges an island into the live segment', () {
      store.page(server.latest(20));
      store.page(server.around(k(700), 10)); // 650..750
      expect(store.segments, hasLength(2));
      store.page(server.newer(k(750), 40)); // 760..1000
      expect(store.segments, [
        Segment(first: k(650), last: k(1000), reachedNewest: true),
      ]);
    });

    test('the same page twice changes nothing', () {
      final page = server.latest(20);
      store.page(page);
      expect(store.page(page).isEmpty, isTrue);
      final older = server.older(k(810), 40);
      store.page(older);
      expect(store.page(older).isEmpty, isTrue);
    });

    test('a stale latest page below the live segment is not live', () {
      store.apply(const MessagesAdded(chat, [Msg(1010)]));
      expect(store.liveSegment!.first, k(1010));
      store.page(server.latest(20)); // fetched before 1010 existed
      expect(store.segments, [
        Segment(first: k(810), last: k(1000)),
        Segment(first: k(1010), last: k(1010), reachedNewest: true),
      ]);
    });

    test('newer data above a live segment makes it stale', () {
      store.page(server.latest(20));
      server.seed([for (var o = 1010; o <= 2000; o += 10) o]);
      store.page(server.around(k(1500), 10));
      expect(store.liveSegment, isNull);
      expect(store.segments, hasLength(2));
    });

    test('an empty latest page marks the list as known empty', () {
      final delta = store.page(TestServer().latest(20));
      expect(store.isKnownEmpty, isTrue);
      expect(delta.segmentsChanged, isTrue);
      expect(store.page(TestServer().latest(20)).isEmpty, isTrue);
      store.apply(const MessagesAdded(chat, [Msg(5)]));
      expect(store.isKnownEmpty, isFalse);
      expect(store.segments, [
        Segment(
          first: k(5),
          last: k(5),
          reachedOldest: true,
          reachedNewest: true,
        ),
      ]);
    });

    test('piggy-backed read state is applied', () {
      final (req, res) = server.latest(20);
      final delta = store.applyPage(
        req,
        PageResult(
          items: res.items,
          readState: ReadState(lastReadInbox: k(900), unreadCount: 10),
        ),
      );
      expect(delta.readStateChanged, isTrue);
      expect(store.readState.unreadCount, 10);
      expect(store.firstUnread(), k(910));
    });

    test('merge decides how versions combine', () {
      store = newStore(merge: (current, incoming) => current);
      store.page(server.latest(5));
      final delta =
          store.apply(MessagesUpdated(chat, [const Msg(1000).bump()]));
      expect(delta.isEmpty, isTrue);
      expect(store.messageOf('m1000')!.rev, 0);
    });
  });

  group('events (§7.2)', () {
    setUp(() => store.page(server.latest(20)));

    test('added extends the live segment', () {
      final delta = store.apply(const MessagesAdded(chat, [Msg(1010)]));
      expect(delta.inserted, [k(1010)]);
      expect(store.liveSegment!.last, k(1010));
      expect(
        store.apply(const MessagesAdded(chat, [Msg(1010)])).isEmpty,
        isTrue,
      );
    });

    test('a late message lands in its segment or becomes an orphan', () {
      store.apply(const MessagesAdded(chat, [Msg(905), Msg(305)]));
      expect(store.segmentOf(k(905)), isNotNull);
      expect(store.keysAfter(k(900), 1), [k(905)]);
      expect(store.contains('m305'), isTrue);
      expect(store.segmentOf(k(305)), isNull);
      expect(store.keysBefore(k(305), 5), isEmpty);
    });

    test('added without a live segment starts one', () {
      store = newStore();
      store.page(server.around(k(300), 10));
      store.apply(const MessagesAdded(chat, [Msg(1010)]));
      expect(
          store.segments.last,
          Segment(
            first: k(1010),
            last: k(1010),
            reachedNewest: true,
          ));
      expect(store.isContiguous(k(350), k(1010)), isFalse);
    });

    test('updated replaces in place and only when different', () {
      final edited = const Msg(900).bump();
      final delta = store.apply(MessagesUpdated(chat, [edited]));
      expect(delta.updated, [k(900)]);
      expect(delta.inserted, isEmpty);
      expect(store.messageOf('m900')!.rev, 1);
      expect(store.apply(MessagesUpdated(chat, [edited])).isEmpty, isTrue);
    });

    test('updated for an unknown id: ignored outside, stored inside', () {
      expect(
        store.apply(const MessagesUpdated(chat, [Msg(300)])).isEmpty,
        isTrue,
      );
      final delta = store.apply(const MessagesUpdated(chat, [Msg(905)]));
      expect(delta.inserted, [k(905)]);
    });

    test('updated with a new order re-keys the message', () {
      final moved = const Msg(955, id: 'm900');
      final delta = store.apply(MessagesUpdated(chat, [moved]));
      expect(delta.replaced.single.oldKey.order, 900);
      expect(delta.replaced.single.newKey.order, 955);
      expect(store.keyOf('m900')!.order, 955);
      expect(orders(store.keysAround(k(950), before: 1, after: 2)), [
        940,
        950,
        955,
        960,
      ]);
    });

    test('deleted moves segment bounds to the neighbours', () {
      final delta = store.apply(
        const MessagesDeleted<Msg>(chat, ['m810', 'm1000', 'm900']),
      );
      expect(orders(delta.removed), [810, 1000, 900]);
      expect(
        [for (final m in delta.removedMessages) (m! as Msg).order],
        [810, 1000, 900],
      );
      expect(store.segments, [
        Segment(first: k(820), last: k(990), reachedNewest: true),
      ]);
      expect(
        store.apply(const MessagesDeleted<Msg>(chat, ['m810'])).isEmpty,
        isTrue,
      );
    });

    test('a delete that arrives before its message wins', () {
      store.apply(const MessagesDeleted<Msg>(chat, ['m1010', 'm700']));
      expect(
        store.apply(const MessagesAdded(chat, [Msg(1010)])).isEmpty,
        isTrue,
      );
      store.page(server.older(k(810), 40));
      expect(store.contains('m700'), isFalse);
      expect(store.contains('m710'), isTrue);
    });

    test('tombstones expire after five minutes', () {
      store.apply(const MessagesDeleted<Msg>(chat, ['m1010']));
      clock.now = clock.now.add(const Duration(minutes: 4));
      expect(store.isTombstoned('m1010'), isTrue);
      clock.now = clock.now.add(const Duration(minutes: 2));
      expect(store.isTombstoned('m1010'), isFalse);
      store.apply(const MessagesAdded(chat, [Msg(1010)]));
      expect(store.contains('m1010'), isTrue);
    });

    test('deleting everything of a complete list makes it known empty', () {
      store = newStore();
      final small = TestServer()..seed([1, 2]);
      store.page(small.latest(20));
      expect(store.segments.single.reachedOldest, isTrue);
      store.apply(const MessagesDeleted<Msg>(chat, ['m1', 'm2']));
      expect(store.segments, isEmpty);
      expect(store.isKnownEmpty, isTrue);
    });

    test('read state replaces and drives the first unread', () {
      store.apply(
        const MessagesUpdated(chat, [
          Msg(910, rev: 1, outgoing: true),
          Msg(920, rev: 1, service: true),
        ]),
      );
      final state = ReadState(lastReadInbox: k(900), unreadCount: 9);
      expect(
        store.apply(ReadStateChanged<Msg>(chat, state)).readStateChanged,
        isTrue,
      );
      expect(store.apply(ReadStateChanged<Msg>(chat, state)).isEmpty, isTrue);
      expect(store.firstUnread(), k(930));
      store.apply(const MessagesDeleted<Msg>(chat, ['m930']));
      expect(store.firstUnread(), k(940), reason: 'divider moves on (§10.7)');
      store.apply(
        ReadStateChanged<Msg>(chat, ReadState(lastReadInbox: k(1000))),
      );
      expect(store.firstUnread(), isNull);
    });

    test('history cleared removes older keys and rejects late ones', () {
      final delta = store.apply(HistoryCleared<Msg>(chat, k(900)));
      expect(delta.removed, hasLength(10));
      expect(delta.historyCleared, isTrue);
      expect(store.segments, [
        Segment(
          first: k(910),
          last: k(1000),
          reachedOldest: true,
          reachedNewest: true,
        ),
      ]);
      expect(store.apply(HistoryCleared<Msg>(chat, k(900))).isEmpty, isTrue);
      expect(store.page(server.older(k(910), 40)).inserted, isEmpty);
      store.apply(HistoryCleared<Msg>(chat, k(1000)));
      expect(store.isKnownEmpty, isTrue);
    });

    test('pinned and typing replace their sets', () {
      expect(
        store.apply(PinnedChanged<Msg>(chat, [k(950), k(820)])).pinnedChanged,
        isTrue,
      );
      expect(orders(store.pinned), [820, 950]);
      expect(
        store.apply(PinnedChanged<Msg>(chat, [k(820), k(950)])).isEmpty,
        isTrue,
      );
      expect(store.pinnedAtOrBefore(k(900)), k(820));
      expect(store.pinnedAtOrBefore(k(950)), k(950));
      expect(store.pinnedAtOrBefore(k(815)), isNull);
      store.apply(const MessagesDeleted<Msg>(chat, ['m820']));
      expect(orders(store.pinned), [950]);

      expect(
        store.apply(const TypingChanged<Msg>(chat, {'a'})).typingChanged,
        isTrue,
      );
      expect(
          store.apply(const TypingChanged<Msg>(chat, {'a'})).isEmpty, isTrue);
      expect(store.typingUserIds, {'a'});
    });

    test('listeners get every non-empty delta', () {
      final seen = <StoreDelta>[];
      store.addListener(seen.add);
      store.apply(const MessagesAdded(chat, [Msg(1010)]));
      store.apply(const MessagesAdded(chat, [Msg(1010)]));
      expect(seen, hasLength(1));
      store.removeListener(seen.add);
    });
  });

  group('local messages (§10.6)', () {
    setUp(() => store.page(server.latest(20)));

    Msg local(String id) {
      final key = store.nextLocalKey(id);
      return Msg(key.order, id: id, localSeq: key.localSeq, outgoing: true);
    }

    test('local keys sort after the newest message, in send order', () {
      final a = local('c1');
      store.apply(MessagesAdded(chat, [a]));
      final b = local('c2');
      store.apply(MessagesAdded(chat, [b]));
      expect(a.key, k(1000, id: 'c1', localSeq: 1));
      expect(b.key, k(1000, id: 'c2', localSeq: 2));
      expect(store.liveSegment!.last, b.key);
      expect(store.newestKey!.isLocal, isTrue);
    });

    test('ack swaps the key in place and reports the replacement', () {
      store.apply(MessagesAdded(chat, [local('c1')]));
      final delta = store.apply(
        const LocalAcked(chat, 'c1', Msg(1010, outgoing: true)),
      );
      expect(delta.replaced.single.oldKey.id, 'c1');
      expect(delta.replaced.single.newKey, k(1010));
      expect(delta.inserted, isEmpty);
      expect(delta.removed, isEmpty);
      expect(store.contains('c1'), isFalse);
      expect(store.liveSegment!.last, k(1010));
      expect(
        store
            .apply(const LocalAcked(chat, 'c1', Msg(1010, outgoing: true)))
            .isEmpty,
        isTrue,
      );
    });

    test('out-of-order acks end sorted by server key', () {
      store.apply(MessagesAdded(chat, [local('c1')]));
      store.apply(MessagesAdded(chat, [local('c2')]));
      store.apply(const LocalAcked(chat, 'c2', Msg(1010, outgoing: true)));
      expect([
        for (final key in store.keysAfter(k(990), 9)) key.id
      ], [
        'm1000',
        'c1',
        'm1010',
      ]);
      store.apply(const LocalAcked(chat, 'c1', Msg(1020, outgoing: true)));
      expect(orders(store.keysAfter(k(990), 9)), [1000, 1010, 1020]);
      expect(store.liveSegment!.last, k(1020));
    });

    test('an ack after the server message drops the local copy', () {
      store.apply(MessagesAdded(chat, [local('c1')]));
      store.apply(const MessagesAdded(chat, [Msg(1010, outgoing: true)]));
      final delta = store.apply(
        const LocalAcked(chat, 'c1', Msg(1010, outgoing: true)),
      );
      expect(delta.replaced.single.newKey, k(1010));
      expect(store.contains('c1'), isFalse);
      expect(store.length, 21);
    });

    test('a failure is kept until cleared', () {
      store.apply(MessagesAdded(chat, [local('c1')]));
      final delta = store.apply(const LocalFailed<Msg>(chat, 'c1', 'offline'));
      expect(delta.updated.single.id, 'c1');
      expect(store.sendErrorOf('c1'), 'offline');
      expect(
        store.apply(const LocalFailed<Msg>(chat, 'c1', 'offline')).isEmpty,
        isTrue,
      );
      expect(store.clearSendError('c1').updated, hasLength(1));
      expect(store.sendErrorOf('c1'), isNull);
    });

    test('a local message alone never proves the newest', () {
      store = newStore();
      store.page(server.around(k(300), 10));
      store.apply(MessagesAdded(chat, [local('c1')]));
      expect(store.liveSegment, isNull);
      expect(store.segmentOf(store.keyOf('c1')!), isNull);
    });

    test('the first message of an empty chat is a complete segment', () {
      store = newStore();
      store.page(TestServer().latest(20));
      store.apply(MessagesAdded(chat, [local('c1')]));
      expect(store.segments.single.reachedOldest, isTrue);
      store.apply(const LocalAcked(chat, 'c1', Msg(7, outgoing: true)));
      expect(store.segments, [
        Segment(
          first: k(7),
          last: k(7),
          reachedOldest: true,
          reachedNewest: true,
        ),
      ]);
    });
  });

  group('queries (§7.3)', () {
    setUp(() {
      store.page(server.latest(20)); // 810..1000
      store.page(server.around(k(300), 10)); // 250..350
    });

    test('keysBefore / keysAfter / keysAround stay inside the segment', () {
      expect(orders(store.keysBefore(k(840), 5)), [810, 820, 830]);
      expect(orders(store.keysAfter(k(980), 5)), [990, 1000]);
      expect(orders(store.keysAfter(k(340), 5)), [350]);
      expect(orders(store.keysAround(k(300), before: 2, after: 2)), [
        280,
        290,
        300,
        310,
        320,
      ]);
      expect(store.keysBefore(k(500), 5), isEmpty);
    });

    test('keysBetween ignores segments', () {
      expect(orders(store.keysBetween(k(340), k(820))), [340, 350, 810, 820]);
    });

    test('nearestExisting follows the direction', () {
      expect(store.nearestExisting(k(300), ScanDirection.newer), k(300));
      expect(store.nearestExisting(k(500), ScanDirection.newer), k(810));
      expect(store.nearestExisting(k(500), ScanDirection.older), k(350));
      expect(store.nearestExisting(k(5), ScanDirection.older), isNull);
    });

    test('firstOnOrAfter searches loaded dates', () {
      DateTime at(int order) =>
          DateTime.fromMicrosecondsSinceEpoch(order * 1000000, isUtc: true);
      expect(store.firstOnOrAfter(at(300)), k(300));
      expect(store.firstOnOrAfter(at(301)), k(310));
      expect(store.firstOnOrAfter(at(400)), k(810));
      expect(store.firstOnOrAfter(at(2000)), isNull);
    });

    test('nextUnreadMention uses the server list when present', () {
      store.apply(
        ReadStateChanged<Msg>(
          chat,
          ReadState(unreadCount: 5, unreadMentions: [k(950), k(900)]),
        ),
      );
      expect(store.nextUnreadMention(), k(900));
      expect(store.nextUnreadMention(k(900)), k(950));
      expect(store.nextUnreadMention(k(950)), isNull);
      store.apply(const MessagesDeleted<Msg>(chat, ['m900']));
      expect(store.nextUnreadMention(), k(950));
    });

    test('nextUnreadMention falls back to the adapter', () {
      store.apply(
        const MessagesUpdated(chat, [
          Msg(850, rev: 1, mention: true),
          Msg(930, rev: 1, mention: true),
          Msg(960, rev: 1, mention: true),
        ]),
      );
      store.apply(
        ReadStateChanged<Msg>(
          chat,
          ReadState(lastReadInbox: k(900), unreadCount: 10),
        ),
      );
      expect(store.nextUnreadMention(), k(930));
      expect(store.nextUnreadMention(k(930)), k(960));
    });
  });

  group('eviction (§7.4)', () {
    setUp(() {
      store.page(server.latest(40)); // 610..1000
    });

    test('trims the far end and clears its flag', () {
      store.page(server.older(k(610), 200)); // everything, reachedOldest
      expect(store.segments.single.reachedOldest, isTrue);
      final delta = store.evict(limit: 30);
      expect(delta.evicted, hasLength(70));
      expect(store.segments, [
        Segment(first: k(710), last: k(1000), reachedNewest: true),
      ]);
    });

    test('never drops the protected window', () {
      store.page(server.older(k(610), 200));
      final window = KeyRange(k(300), k(400));
      store.evict(limit: 20, protect: [window]);
      expect(store.length, 20);
      expect(orders(store.keysBetween(k(300), k(400))), [
        for (var o = 300; o <= 400; o += 10) o,
      ]);
      final segment = store.segments.single;
      expect(segment.reachedNewest, isFalse);
      expect(segment.reachedOldest, isFalse);
      expect(store.evict(limit: 5, protect: [window]).evicted, hasLength(9));
      expect(store.evict(limit: 5, protect: [window]).isEmpty, isTrue);
    });

    test('protects the saved snapshot', () {
      store.page(server.around(k(200), 10)); // island 150..250
      store.snapshot = ViewportSnapshot(
        anchorKey: k(200),
        anchorOffset: 0,
        offsetFromBottom: 0,
        visibleKeys: [k(190), k(200), k(210)],
        connectedToNewest: false,
        viewportWidth: 400,
        savedAt: clock.now,
      );
      store.evict(limit: 3);
      expect(orders(store.keys), [190, 200, 210]);
    });

    test('orphans and unprotected islands go first', () {
      store.page(server.around(k(200), 10)); // island 150..250 (11)
      store.apply(const MessagesAdded(chat, [Msg(405)])); // orphan
      expect(store.length, 52);
      store.evict(limit: 51);
      expect(store.contains('m405'), isFalse);
      store.evict(limit: 45);
      expect(store.segments.first, Segment(first: k(210), last: k(250)));
      expect(store.liveSegment!.first, k(610));
    });
  });

  group('MessageStore', () {
    test('keeps the most recently used lists', () {
      final all = MessageStore<Msg>(
        adapter: const MsgAdapter(),
        openListsInMemory: 2,
        memoryLimitPerList: 10,
      );
      final a = all.list(const ListId('a'));
      all.list(const ListId('b'));
      all.list(const ListId('c', 'thread'));
      all.list(const ListId('a'));
      expect(identical(all.peek(const ListId('a')), a), isTrue);
      expect(all.evictLists(), [const ListId('b')]);
      expect(all.evictLists(keep: {const ListId('a')}), isEmpty);
      all.list(const ListId('d'));
      expect(
        all.evictLists(keep: {const ListId('c', 'thread')}),
        [const ListId('a')],
      );

      final d = all.list(const ListId('d'));
      d.applyPage(
        PageRequest(
          list: const ListId('d'),
          direction: PageDirection.latest,
          limit: 40,
        ),
        PageResult(items: [for (var i = 1; i <= 25; i++) Msg(i)]),
      );
      expect(all.evictMessages(const ListId('d')).evicted, hasLength(15));
      expect(all.evictMessages(const ListId('zzz')).isEmpty, isTrue);
      all.clear();
      expect(all.lists, isEmpty);
    });
  });
}
