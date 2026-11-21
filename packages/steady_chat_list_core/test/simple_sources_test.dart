import 'dart:async';

import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:test/test.dart';

import 'support.dart';

PageRequest request(
  PageDirection direction, {
  int? anchor,
  DateTime? date,
  int limit = 4,
}) =>
    PageRequest(
      list: chat,
      direction: direction,
      anchor: anchor == null ? null : k(anchor),
      anchorDate: date,
      limit: limit,
    );

List<int> ordersOf(PageResult<Msg> page) =>
    [for (final m in page.items) m.order]..sort();

void main() {
  test('MessageAdapter.from builds an adapter from functions', () {
    final plain = MessageAdapter<Msg>.from(
      key: (m) => m.key,
      date: (m) => DateTime.utc(2026, 1, m.order),
    );
    const a = Msg(1);
    expect(plain.keyOf(a), k(1));
    expect(plain.dateOf(a), DateTime.utc(2026, 1, 1));
    expect(plain.groupIdOf(a), isNull);
    expect(plain.senderIdOf(a), isNull);
    expect(plain.isOutgoing(a), isFalse);
    expect(plain.isService(a), isFalse);
    expect(plain.mentionsMe(a), isFalse);
    expect(plain.equals(a, a), isTrue);
    expect(plain.equals(a, a.bump()), isFalse, reason: 'default is ==');

    final full = MessageAdapter<Msg>.from(
      key: (m) => m.key,
      date: (m) => DateTime.utc(2026),
      groupId: (m) => 'g${m.order}',
      senderId: (m) => 's${m.order}',
      isOutgoing: (m) => m.outgoing,
      isService: (m) => m.service,
      mentionsMe: (m) => m.mention,
      equals: (a, b) => a.rev == b.rev,
    );
    const b = Msg(2, outgoing: true, service: true, mention: true);
    expect(full.groupIdOf(b), 'g2');
    expect(full.senderIdOf(b), 's2');
    expect(full.isOutgoing(b), isTrue);
    expect(full.isService(b), isTrue);
    expect(full.mentionsMe(b), isTrue);
    expect(full.equals(a, b), isTrue);
  });

  group('ListMessageSource', () {
    late ListMessageSource<Msg> source;
    late List<ListEvent<Msg>> events;

    setUp(() {
      source = ListMessageSource<Msg>(
        adapter: const MsgAdapter(),
        initial: {
          chat: [for (var i = 10; i >= 1; i--) Msg(i * 10)],
        },
      );
      events = [];
      source.events(chat).listen(events.add);
    });

    test('pages are cut from the sorted messages', () async {
      expect(source.messages(chat).first.order, 10);
      expect(source.messages(const ListId('none')), isEmpty);

      final latest = await source.fetch(request(PageDirection.latest));
      expect(ordersOf(latest), [70, 80, 90, 100]);
      expect(latest.reachedNewest, isTrue);
      expect(latest.reachedOldest, isFalse);
      expect(
        (await source.fetch(request(PageDirection.latest, limit: 50)))
            .reachedOldest,
        isTrue,
      );

      final older = source.page(request(PageDirection.older, anchor: 70));
      expect(ordersOf(older), [30, 40, 50, 60]);
      expect(older.reachedOldest, isFalse);
      final oldest = source.page(request(PageDirection.older, anchor: 30));
      expect(ordersOf(oldest), [10, 20]);
      expect(oldest.reachedOldest, isTrue);
      expect(
        source.page(request(PageDirection.older, anchor: 10)).reachedOldest,
        isTrue,
      );

      final newer = source.page(request(PageDirection.newer, anchor: 60));
      expect(ordersOf(newer), [70, 80, 90, 100]);
      expect(newer.reachedNewest, isTrue);
      expect(
        source.page(request(PageDirection.newer, anchor: 20)).reachedNewest,
        isFalse,
      );
      expect(
        source.page(request(PageDirection.newer, anchor: 100)).reachedNewest,
        isTrue,
      );

      final around = source.page(request(PageDirection.around, anchor: 50));
      expect(ordersOf(around), [30, 40, 50, 60, 70]);
      expect(around.reachedOldest, isFalse);
      expect(around.reachedNewest, isFalse);
      final gone = source.page(request(PageDirection.around, anchor: 55));
      expect(ordersOf(gone), [40, 50, 60, 70]);
      final edge = source.page(request(PageDirection.around, anchor: 100));
      expect(edge.reachedNewest, isTrue);
      expect(
        source.page(request(PageDirection.around, anchor: 10)).reachedOldest,
        isTrue,
      );
    });

    test('around a date finds the first message of that moment', () {
      DateTime at(int order) =>
          DateTime.fromMicrosecondsSinceEpoch(order * 1000000, isUtc: true);
      expect(
        ordersOf(source.page(request(PageDirection.around, date: at(45)))),
        [30, 40, 50, 60, 70],
      );
      expect(
        ordersOf(source.page(request(PageDirection.around, date: at(999)))),
        [80, 90, 100],
        reason: 'after everything: the newest',
      );
      final empty = ListMessageSource<Msg>(adapter: const MsgAdapter());
      expect(
        empty.page(request(PageDirection.around, date: at(1))).items,
        isEmpty,
      );
      expect(empty.page(request(PageDirection.latest)).reachedOldest, isTrue);
      expect(
        empty.page(request(PageDirection.older, anchor: 5)).reachedOldest,
        isTrue,
      );
      expect(
        empty.page(request(PageDirection.newer, anchor: 5)).reachedNewest,
        isTrue,
      );
    });

    test('upsert and remove report what changed', () async {
      source.upsert(chat, [
        const Msg(110),
        const Msg(50), // unchanged
        const Msg(60, rev: 1),
        const Msg(75, id: 'm70'), // moved
      ]);
      source.remove(chat, ['m10', 'missing']);
      source.remove(chat, ['missing']);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(3));
      expect(
        [for (final m in (events[0] as MessagesUpdated<Msg>).items) m.order],
        [60, 75],
      );
      expect((events[1] as MessagesAdded<Msg>).items.single.order, 110);
      expect((events[2] as MessagesDeleted<Msg>).ids, ['m10']);
      expect(
        [for (final m in source.messages(chat)) m.order],
        [20, 30, 40, 50, 60, 75, 80, 90, 100, 110],
      );
    });

    test('setAll reports the difference; the last duplicate wins', () async {
      source.setAll(chat, [
        const Msg(20),
        const Msg(30, rev: 1),
        const Msg(30, rev: 2),
        const Msg(120),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect((events[0] as MessagesDeleted<Msg>).ids, hasLength(8));
      expect((events[1] as MessagesUpdated<Msg>).items.single.rev, 2);
      expect((events[2] as MessagesAdded<Msg>).items.single.order, 120);
      events.clear();
      source.setAll(chat, source.messages(chat));
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty, reason: 'nothing changed');
      source.clear(chat);
      await Future<void>.delayed(Duration.zero);
      expect(source.messages(chat), isEmpty);
      expect(events.single, isA<MessagesDeleted<Msg>>());
    });

    test('read state, custom events, errors and markRead', () async {
      final read = <MessageKey>[];
      final own = ListMessageSource<Msg>(
        adapter: const MsgAdapter(),
        onMarkRead: (list, key) => read.add(key),
      );
      final seen = <Object>[];
      own.events(chat).listen(seen.add, onError: seen.add);
      expect(own.readStateOf(chat), isNull);
      own.setReadState(chat, const ReadState(unreadCount: 2));
      own.emit(const TypingChanged<Msg>(chat, {'a'}));
      own.addError(chat, StateError('socket'));
      await own.markRead(chat, k(5));
      await source.markRead(chat, k(5)); // no callback: nothing happens
      await Future<void>.delayed(Duration.zero);
      expect(own.readStateOf(chat)!.unreadCount, 2);
      expect(own.page(request(PageDirection.latest)).readState, isNotNull);
      expect(seen[0], isA<ReadStateChanged<Msg>>());
      expect(seen[1], isA<TypingChanged<Msg>>());
      expect(seen[2], isStateError);
      expect(read, [k(5)]);
      own
        ..dispose()
        ..dispose()
        ..upsert(chat, [const Msg(1)])
        ..addError(chat, 'late');
      expect(own.messages(chat), hasLength(1));
    });

    test('drives a store: a whole conversation in memory', () async {
      final hub = MessageListHub<Msg>(source: source, adapter: source.adapter);
      final store = hub.attach(chat);
      await hub.fetch(request(PageDirection.latest, limit: 50));
      expect(store.segments.single.reachedOldest, isTrue);
      source.upsert(chat, [const Msg(110), const Msg(5)]);
      source.remove(chat, ['m50']);
      await Future<void>.delayed(Duration.zero);
      expect(orders(store.keys), [5, 10, 20, 30, 40, 60, 70, 80, 90, 100, 110]);
      expect(
        store.segments.single,
        Segment(
          first: k(5),
          last: k(110),
          reachedOldest: true,
          reachedNewest: true,
        ),
        reason: 'older than the start of history is the new start',
      );
      hub.dispose();
    });
  });

  group('StreamMessageSource', () {
    late StreamController<List<Msg>> feed;
    late StreamMessageSource<Msg> source;
    late int listens;
    late int cancels;

    setUp(() {
      listens = 0;
      cancels = 0;
      feed = StreamController<List<Msg>>.broadcast(
        onListen: () => listens++,
        onCancel: () => cancels++,
      );
      source = StreamMessageSource<Msg>(
        adapter: const MsgAdapter(),
        snapshots: (list) => feed.stream,
      );
    });

    test('the first fetch waits for the first snapshot', () async {
      PageResult<Msg>? page;
      unawaited(
        source.fetch(request(PageDirection.latest)).then((p) => page = p),
      );
      await Future<void>.delayed(Duration.zero);
      expect(page, isNull);
      expect(listens, 1);
      feed.add(const [Msg(10), Msg(20)]);
      await Future<void>.delayed(Duration.zero);
      expect(ordersOf(page!), [10, 20]);
      expect(source.messages(chat), hasLength(2));
      // Later fetches answer at once.
      expect(
        ordersOf(await source.fetch(request(PageDirection.older, anchor: 20))),
        [10],
      );
    });

    test('snapshots become events while someone listens', () async {
      final events = <Object>[];
      final sub = source.events(chat).listen(events.add, onError: events.add);
      await Future<void>.delayed(Duration.zero);
      expect(listens, 1);
      feed.add(const [Msg(10), Msg(20)]);
      feed.add(const [Msg(10, rev: 1), Msg(30)]);
      feed.addError(StateError('permission'));
      await Future<void>.delayed(Duration.zero);
      source.setReadState(chat, const ReadState(unreadCount: 1));
      source.emit(const TypingChanged<Msg>(chat, {'a'}));
      await Future<void>.delayed(Duration.zero);
      expect(events[0], isA<MessagesAdded<Msg>>());
      expect(events[1], isA<MessagesDeleted<Msg>>());
      expect(events[2], isA<MessagesUpdated<Msg>>());
      expect(events[3], isA<MessagesAdded<Msg>>());
      expect(events[4], isStateError);
      expect(events[5], isA<ReadStateChanged<Msg>>());
      expect(events[6], isA<TypingChanged<Msg>>());

      await sub.cancel();
      expect(cancels, 1, reason: 'released with the last listener');
      // Listening again resubscribes and catches up by difference.
      final again = <Object>[];
      source.events(chat).listen(again.add);
      await Future<void>.delayed(Duration.zero);
      expect(listens, 2);
      feed.add(const [Msg(10, rev: 1), Msg(30), Msg(40)]);
      await Future<void>.delayed(Duration.zero);
      expect((again.single as MessagesAdded<Msg>).items.single.order, 40);
    });

    test('an error before the first snapshot fails the fetch; retry works',
        () async {
      final failing = source.fetch(request(PageDirection.latest));
      await Future<void>.delayed(Duration.zero);
      feed.addError(StateError('offline'));
      await expectLater(failing, throwsStateError);
      final retry = source.fetch(request(PageDirection.latest));
      await Future<void>.delayed(Duration.zero);
      expect(listens, 2);
      feed.add(const [Msg(10)]);
      expect(ordersOf(await retry), [10]);
    });

    test('a snapshots function that throws fails the fetch', () async {
      final broken = StreamMessageSource<Msg>(
        adapter: const MsgAdapter(),
        snapshots: (list) => throw UnsupportedError('no database'),
      );
      await expectLater(
        broken.fetch(request(PageDirection.latest)),
        throwsUnsupportedError,
      );
    });

    test('markRead and dispose', () async {
      final read = <MessageKey>[];
      final own = StreamMessageSource<Msg>(
        adapter: const MsgAdapter(),
        snapshots: (list) => feed.stream,
        onMarkRead: (list, key) async => read.add(key),
      );
      await own.markRead(chat, k(7));
      expect(read, [k(7)]);
      own.events(chat).listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(listens, 1);
      own
        ..dispose()
        ..dispose();
      expect(cancels, 1);
      own.events(chat).listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(listens, 1, reason: 'a disposed source listens to nothing');
    });
  });

  group('page cursors', () {
    test('a page token is kept at its edge and dropped when used', () {
      final store = newStore();
      PageResult<Msg> page(List<int> orders, {String? older, String? newer}) =>
          PageResult(
            items: [for (final o in orders) Msg(o)],
            olderCursor: older,
            newerCursor: newer,
          );
      store.applyPage(
        request(PageDirection.around, anchor: 50),
        page([40, 50, 60], older: 'before-40', newer: 'after-60'),
      );
      expect(store.cursorAt(k(40), ScanDirection.older), 'before-40');
      expect(store.cursorAt(k(60), ScanDirection.newer), 'after-60');
      expect(store.cursorAt(k(40), ScanDirection.newer), isNull);
      expect(store.cursorAt(k(50), ScanDirection.older), isNull);

      store.applyPage(
        request(PageDirection.older, anchor: 40),
        page([20, 30], older: 'before-20'),
      );
      expect(store.cursorAt(k(40), ScanDirection.older), isNull);
      expect(store.cursorAt(k(20), ScanDirection.older), 'before-20');
      store.applyPage(
        request(PageDirection.newer, anchor: 60),
        page([70], newer: 'after-70'),
      );
      expect(store.cursorAt(k(60), ScanDirection.newer), isNull);
      expect(store.cursorAt(k(70), ScanDirection.newer), 'after-70');

      // A deleted edge takes its token with it.
      store.apply(const MessagesDeleted<Msg>(chat, ['m20']));
      expect(store.cursorAt(k(20), ScanDirection.older), isNull);
      store.debugCheckInvariants();
    });

    test('the hub passes the token on to the source', () async {
      final source = _RecordingSource();
      final hub =
          MessageListHub<Msg>(source: source, adapter: const MsgAdapter());
      await hub.fetch(
        PageRequest(
          list: chat,
          direction: PageDirection.older,
          anchor: k(40),
          cursor: 'before-40',
          limit: 20,
        ),
      );
      expect(source.requests.single.cursor, 'before-40');
    });
  });
}

class _RecordingSource implements MessageSource<Msg> {
  final List<PageRequest> requests = [];

  @override
  Future<PageResult<Msg>> fetch(PageRequest request) async {
    requests.add(request);
    return const PageResult(items: []);
  }

  @override
  Stream<ListEvent<Msg>> events(ListId list) => const Stream.empty();

  @override
  Future<void> markRead(ListId list, MessageKey upTo) async {}
}
