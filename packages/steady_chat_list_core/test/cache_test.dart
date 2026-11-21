import 'dart:async';

import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A backend over [TestServer] with an event stream.
class ServerSource implements MessageSource<Msg> {
  ServerSource(this.server);

  final TestServer server;
  final StreamController<ListEvent<Msg>> events_ =
      StreamController<ListEvent<Msg>>.broadcast();
  int fetches = 0;
  bool offline = false;

  @override
  Future<PageResult<Msg>> fetch(PageRequest request) async {
    fetches++;
    if (offline) throw StateError('offline');
    final anchor = request.anchor;
    final (_, result) = switch (request.direction) {
      PageDirection.latest => server.latest(request.limit),
      PageDirection.older => server.older(anchor!, request.limit),
      PageDirection.newer => server.newer(anchor!, request.limit),
      PageDirection.around => server.around(anchor!, request.limit),
    };
    return result;
  }

  @override
  Stream<ListEvent<Msg>> events(ListId list) => events_.stream;

  @override
  Future<void> markRead(ListId list, MessageKey upTo) async {}
}

PageRequest req(PageDirection direction, {int? anchor, int limit = 20}) =>
    PageRequest(
      list: chat,
      direction: direction,
      anchor: anchor == null ? null : k(anchor),
      limit: limit,
    );

ViewportSnapshot snap(int order) => ViewportSnapshot(
      anchorKey: k(order),
      anchorOffset: 5,
      offsetFromBottom: 0,
      visibleKeys: [k(order), k(order + 10)],
      connectedToNewest: true,
      viewportWidth: 400,
      savedAt: DateTime.utc(2026),
    );

Future<void> turn() => Future<void>.delayed(Duration.zero);

void main() {
  late TestServer server;
  late ServerSource source;
  late InMemoryMessageCache<Msg> cache;
  final errors = <Object>[];
  var now = DateTime.utc(2026, 11, 20);

  MessageListHub<Msg> newHub([MessageCache<Msg>? other]) => MessageListHub<Msg>(
        source: source,
        adapter: const MsgAdapter(),
        cache: other ?? cache,
        onError: (error, stackTrace) => errors.add(error),
        evictionPolicy: const EvictionPolicy(keepNewestPerList: 30),
      );

  setUp(() {
    server = TestServer()..seed([for (var i = 1; i <= 100; i++) i * 10]);
    source = ServerSource(server);
    now = DateTime.utc(2026, 11, 20);
    cache = InMemoryMessageCache<Msg>(
      adapter: const MsgAdapter(),
      clock: () => now,
    );
    errors.clear();
  });

  group('hub with a cache', () {
    test('writes pages and events through; a new hub opens from the cache',
        () async {
      final hub = newHub();
      expect(hub.needsHydration(chat), isTrue);
      await hub.hydrate(chat);
      expect(hub.needsHydration(chat), isFalse);
      hub.attach(chat);
      await hub.fetch(req(PageDirection.latest));
      source.events_.add(const MessagesAdded(chat, [Msg(1010)]));
      source.events_.add(MessagesUpdated(chat, [const Msg(990).bump()]));
      source.events_.add(const MessagesDeleted<Msg>(chat, ['m980']));
      source.events_.add(
        ReadStateChanged<Msg>(chat, ReadState(lastReadInbox: k(1000))),
      );
      await turn();
      await turn();
      hub.persistSnapshot(chat, snap(900));
      await turn();
      expect(cache.count(chat), 20);
      hub.dispose();
      expect(errors, isEmpty);

      // "Restart": a new hub, offline.
      source.offline = true;
      final restarted = newHub();
      await Future.wait([restarted.hydrate(chat), restarted.hydrate(chat)]);
      final store = restarted.attach(chat);
      expect(store.length, 20);
      expect(store.contains('m980'), isFalse);
      expect(store.messageOf('m990')!.rev, 1);
      expect(store.liveSegment!.last, k(1010));
      expect(store.readState.lastReadInbox, k(1000));
      expect(restarted.cachedSnapshot(chat)!.anchorKey, k(900));
      expect(await restarted.loadSnapshot(chat), isNotNull);
      expect(source.fetches, 1, reason: 'nothing was fetched after restart');
      restarted.dispose();
    });

    test('memory wins over the cache; a list without cache data is fine',
        () async {
      final hub = newHub();
      final store = hub.attach(chat);
      await hub.fetch(req(PageDirection.latest));
      await turn();
      final second = newHub();
      final fresh = second.attach(chat);
      await second.fetch(req(PageDirection.latest, limit: 5));
      await second.hydrate(chat); // too late: memory has data
      expect(fresh.length, 5);
      await second.hydrate(const ListId('never'));
      expect(second.cachedSnapshot(const ListId('never')), isNull);
      expect(store.length, 20);
      hub.dispose();
      second.dispose();
    });

    test('without a cache, snapshots go to the viewport store', () async {
      final viewports = InMemoryViewportStore();
      final hub = MessageListHub<Msg>(
        source: source,
        adapter: const MsgAdapter(),
        viewportStore: viewports,
      );
      expect(hub.needsHydration(chat), isFalse);
      await hub.hydrate(chat);
      hub.persistSnapshot(chat, snap(900));
      await turn();
      expect(viewports.load(chat)!.anchorKey, k(900));
      expect((await hub.loadSnapshot(chat))!.anchorKey, k(900));
      final bare =
          MessageListHub<Msg>(source: source, adapter: const MsgAdapter());
      bare.persistSnapshot(chat, snap(900));
      expect(await bare.loadSnapshot(chat), isNull);
      expect(bare.reset(chat).isEmpty, isTrue);
    });

    test('reconcile removes what the server no longer has', () async {
      final hub = newHub();
      final store = hub.attach(chat);
      await hub.fetch(req(PageDirection.latest));
      // Deleted on the server while we were offline; one local message.
      server.byOrder
        ..remove(950)
        ..remove(960);
      final local = store.nextLocalKey('c1');
      hub.apply(
        MessagesAdded(
            chat, [Msg(local.order, id: 'c1', localSeq: local.localSeq)]),
      );
      final outcome = await hub.fetch(
        req(PageDirection.around, anchor: 950, limit: 20),
        reconcile: true,
      );
      expect(orders(outcome.delta.removed), unorderedEquals([950, 960]));
      expect(store.contains('m950'), isFalse);
      expect(store.contains('c1'), isTrue, reason: 'pending messages stay');
      await turn();
      await turn();
      expect(cache.count(chat), 19, reason: '18 confirmed + the pending one');
      hub.dispose();
    });

    test('reset forgets the list in memory and in the cache', () async {
      final hub = newHub();
      final store = hub.attach(chat);
      await hub.fetch(req(PageDirection.latest));
      hub.persistSnapshot(chat, snap(900));
      store.snapshot = snap(900);
      hub.apply(PinnedChanged<Msg>(chat, [k(900)]));
      await turn();
      final delta = hub.reset(chat);
      expect(delta.pinnedChanged, isTrue);
      expect(delta.removed, hasLength(20));
      expect(delta.removedMessages, hasLength(20));
      expect(store.isEmpty, isTrue);
      expect(store.segments, isEmpty);
      expect(store.snapshot, isNull);
      expect(hub.cachedSnapshot(chat), isNull);
      await turn();
      expect(cache.count(chat), 0);
      expect(store.reset().isEmpty, isTrue);
      store.debugCheckInvariants();
      hub.dispose();
    });

    test('another tab wrote: open lists merge what the cache has', () async {
      final shared = _SharedCache(cache);
      final hub = newHub(shared);
      final store = hub.attach(chat);
      hub.attach(const ListId('other'));
      await hub.fetch(req(PageDirection.latest));
      await turn();
      // The other tab received two more messages.
      await cache.applyEvents(
        const [
          MessagesAdded(chat, [Msg(1010), Msg(1020)]),
        ],
        segments: {
          chat: [Segment(first: k(810), last: k(1020), reachedNewest: true)],
        },
      );
      shared.changes.add(const CacheChange(chat));
      await turn();
      await turn();
      expect(store.liveSegment!.last, k(1020));
      shared.changes.add(const CacheChange()); // "something changed"
      shared.changes.add(const CacheChange(ListId('closed')));
      shared.changes.addError(StateError('channel'));
      await turn();
      await turn();
      expect(errors.single, isStateError);
      hub.dispose();
      shared.changes.add(const CacheChange(chat));
      await turn();
    });

    test('a broken cache is reported and the list still works', () async {
      final hub = newHub(_BrokenCache());
      await hub.hydrate(chat);
      expect(errors, hasLength(1));
      final store = hub.attach(chat);
      await hub.fetch(req(PageDirection.latest));
      hub.apply(const MessagesAdded(chat, [Msg(1010)]));
      hub.persistSnapshot(chat, snap(900));
      hub.reset(chat);
      await turn();
      await turn();
      expect(errors.length, greaterThanOrEqualTo(4));
      expect(store.isEmpty, isTrue);
      hub.dispose();
    });
  });

  group('InMemoryMessageCache', () {
    test('load prefers the newest messages and the saved position', () async {
      expect(await cache.load(chat), isNull);
      final (request, result) = server.latest(100);
      await cache.applyPage(
        request,
        PageResult(
          items: result.items,
          readState: const ReadState(unreadCount: 4),
        ),
        segments: [
          Segment(
            first: k(10),
            last: k(1000),
            reachedOldest: true,
            reachedNewest: true,
          ),
        ],
      );
      await cache.saveSnapshot(chat, snap(100));
      final loaded = (await cache.load(chat, limit: 10))!;
      expect(
        orders(loaded.messages.map((m) => m.key).toList()..sort()),
        [100, 110, for (var o = 910; o <= 1000; o += 10) o],
      );
      expect(loaded.readState!.unreadCount, 4);
      expect(loaded.snapshot!.anchorKey, k(100));
      expect(loaded.segments.single.reachedOldest, isTrue);

      // The store only believes what it was given.
      final store = newStore()
        ..restore(loaded.messages, loaded.segments,
            readState: loaded.readState);
      expect(store.segments.single.first, k(100));
      expect(store.segments.single.reachedOldest, isFalse);
      expect(store.segments.single.reachedNewest, isTrue);
      expect(store.readState.unreadCount, 4);
      store.debugCheckInvariants();
      // Inverted and empty segments from a damaged cache are ignored.
      final odd = newStore()
        ..restore(
          const [Msg(10)],
          [
            Segment(first: k(50), last: k(40)),
            Segment(first: k(400), last: k(500)),
          ],
        );
      expect(odd.segments, isEmpty);
    });

    test('events: re-keys, acks, deletes, history cleared', () async {
      await cache.applyEvents(
        const [
          MessagesAdded(chat, [Msg(10), Msg(20), Msg(30)]),
          MessagesAdded(chat, [Msg(30, id: 'c1', localSeq: 1)]),
          MessagesUpdated(chat, [Msg(25, id: 'm20')]),
          LocalAcked(chat, 'c1', Msg(40)),
          LocalFailed<Msg>(chat, 'c9', 'x'),
          PinnedChanged<Msg>(chat, []),
          TypingChanged<Msg>(chat, {}),
          MessagesDeleted<Msg>(chat, ['m30', 'missing']),
        ],
        segments: {
          chat: [Segment(first: k(10), last: k(40), reachedNewest: true)],
        },
      );
      var loaded = (await cache.load(chat))!;
      expect(
        orders(loaded.messages.map((m) => m.key).toList()..sort()),
        [10, 25, 40],
      );
      await cache.applyEvents(
        [HistoryCleared<Msg>(chat, k(25))],
        segments: {
          chat: [Segment(first: k(40), last: k(40), reachedNewest: true)],
        },
      );
      loaded = (await cache.load(chat))!;
      expect(loaded.messages.single.order, 40);
      expect(cache.watch(), emitsDone);
    });

    test('eviction: per list, by age, and the global cap', () async {
      Future<void> fill(ListId list, int count) => cache.applyPage(
            PageRequest(
                list: list, direction: PageDirection.latest, limit: count),
            PageResult(items: [for (var i = 1; i <= count; i++) Msg(i * 10)]),
            segments: [
              Segment(
                first: k(10),
                last: k(count * 10),
                reachedOldest: true,
                reachedNewest: true,
              ),
            ],
          );
      const old = ListId('old');
      const big = ListId('big');
      await fill(old, 5);
      now = now.add(const Duration(days: 31));
      await fill(chat, 100);
      await cache.saveSnapshot(chat, snap(100));
      now = now.add(const Duration(minutes: 1));
      await fill(big, 40);

      await cache.evict(const EvictionPolicy(keepNewestPerList: 20));
      expect(cache.count(old), 0, reason: 'not opened for 30 days');
      expect(cache.count(chat), 22, reason: 'newest 20 + the saved position');
      expect(cache.count(big), 20);
      final loaded = (await cache.load(chat))!;
      // What lies between the two kept runs is gone, so they are two
      // segments now: nothing claims the hole is contiguous.
      expect(loaded.segments, [
        Segment(first: k(100), last: k(110)),
        Segment(first: k(810), last: k(1000), reachedNewest: true),
      ]);
      final store = newStore()..restore(loaded.messages, loaded.segments);
      expect(store.isContiguous(k(110), k(810)), isFalse);
      expect(store.liveSegment!.first, k(810));

      // The global cap drops the least recently opened list first.
      now = now.add(const Duration(minutes: 1));
      await cache.load(big);
      await cache.evict(
        const EvictionPolicy(keepNewestPerList: 20, maxMessages: 25),
      );
      expect(cache.count(chat), 0);
      expect(cache.count(big), 20);
      await cache.clear(big);
      expect(cache.count(big), 0);
      await fill(chat, 3);
      await cache.clear();
      expect(await cache.load(chat), isNull);
    });
  });
}

/// A cache that tells its hub when "another tab" wrote.
class _SharedCache implements MessageCache<Msg> {
  _SharedCache(this.inner);

  final InMemoryMessageCache<Msg> inner;
  final StreamController<CacheChange> changes =
      StreamController<CacheChange>.broadcast();

  @override
  Stream<CacheChange> watch() => changes.stream;

  @override
  Future<CachedList<Msg>?> load(ListId list, {int limit = 600}) =>
      inner.load(list, limit: limit);

  @override
  Future<void> applyPage(
    PageRequest request,
    PageResult<Msg> result, {
    required List<Segment> segments,
  }) =>
      inner.applyPage(request, result, segments: segments);

  @override
  Future<void> applyEvents(
    List<ListEvent<Msg>> events, {
    required Map<ListId, List<Segment>> segments,
  }) =>
      inner.applyEvents(events, segments: segments);

  @override
  Future<void> saveSnapshot(ListId list, ViewportSnapshot snapshot) =>
      inner.saveSnapshot(list, snapshot);

  @override
  Future<void> evict(EvictionPolicy policy) => inner.evict(policy);

  @override
  Future<void> clear([ListId? list]) => inner.clear(list);
}

class _BrokenCache implements MessageCache<Msg> {
  Never _fail() => throw StateError('disk full');

  @override
  Stream<CacheChange> watch() => const Stream.empty();

  @override
  Future<CachedList<Msg>?> load(ListId list, {int limit = 600}) async =>
      _fail();

  @override
  Future<void> applyPage(
    PageRequest request,
    PageResult<Msg> result, {
    required List<Segment> segments,
  }) async =>
      _fail();

  @override
  Future<void> applyEvents(
    List<ListEvent<Msg>> events, {
    required Map<ListId, List<Segment>> segments,
  }) =>
      _fail();

  @override
  Future<void> saveSnapshot(ListId list, ViewportSnapshot snapshot) async =>
      _fail();

  @override
  Future<void> evict(EvictionPolicy policy) async {}

  @override
  Future<void> clear([ListId? list]) async => _fail();
}
