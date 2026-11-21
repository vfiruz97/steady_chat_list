// SPEC §18 test 25: migration, page round trip, segments persisted,
// eviction respects snapshot windows.
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryExecutor, TableUpdate;
import 'package:drift/native.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:steady_chat_list_drift/steady_chat_list_drift.dart';
import 'package:test/test.dart';

class Chat {
  const Chat(this.id, this.text, {this.localSeq = 0, this.outgoing = false});

  factory Chat.fromJson(Map<String, Object?> json) => Chat(
        json['id']! as int,
        json['text']! as String,
        localSeq: json['seq']! as int,
        outgoing: json['out']! as bool,
      );

  final int id;
  final String text;
  final int localSeq;
  final bool outgoing;

  Map<String, Object?> toJson() =>
      {'id': id, 'text': text, 'seq': localSeq, 'out': outgoing};
}

class ChatAdapter extends MessageAdapter<Chat> {
  const ChatAdapter();

  @override
  MessageKey keyOf(Chat m) => MessageKey(
        order: m.id,
        id: m.localSeq > 0 ? 'local-${m.id}-${m.localSeq}' : '${m.id}',
        localSeq: m.localSeq,
      );

  @override
  DateTime dateOf(Chat m) =>
      DateTime.fromMillisecondsSinceEpoch(m.id * 60000, isUtc: true);

  @override
  String? senderIdOf(Chat m) => m.outgoing ? 'me' : 'them';

  @override
  bool isOutgoing(Chat m) => m.outgoing;

  @override
  bool equals(Chat a, Chat b) => a.text == b.text && a.id == b.id;
}

const chat = ListId('chat');
const other = ListId('other', 'thread');
const codec = JsonMessageCodec<Chat>(Chat.fromJson, _toJson);

Map<String, Object?> _toJson(Chat m) => m.toJson();

MessageKey k(int id) => MessageKey(order: id, id: '$id');

List<Chat> chats(int from, int to) =>
    [for (var i = from; i <= to; i++) Chat(i, 'message $i')];

Segment seg(int first, int last, {bool oldest = false, bool newest = false}) =>
    Segment(
      first: k(first),
      last: k(last),
      reachedOldest: oldest,
      reachedNewest: newest,
    );

PageRequest latest([ListId list = chat]) =>
    PageRequest(list: list, direction: PageDirection.latest, limit: 100);

ViewportSnapshot snapshot(int id) => ViewportSnapshot(
      anchorKey: k(id),
      anchorOffset: -7.5,
      offsetFromBottom: 1200,
      visibleKeys: [k(id), k(id + 1), k(id + 2)],
      connectedToNewest: true,
      viewportWidth: 390,
      savedAt: DateTime.utc(2026, 11, 20),
    );

List<int> ids(CachedList<Chat> cached) =>
    [for (final m in cached.messages) m.id]..sort();

void main() {
  late DateTime now;
  late DriftMessageCache<Chat> cache;

  DriftMessageCache<Chat> open(QueryExecutor executor) =>
      DriftMessageCache<Chat>(
        SteadyCacheDatabase(executor),
        adapter: const ChatAdapter(),
        codec: codec,
        clock: () => now,
      );

  setUp(() {
    now = DateTime.utc(2026, 11, 20);
    cache = open(NativeDatabase.memory());
  });

  tearDown(() => cache.close());

  test('the JSON codec round-trips a message', () {
    final bytes = codec.encode(const Chat(7, 'héllo 👋', outgoing: true));
    expect(bytes, isA<Uint8List>());
    final back = codec.decode(bytes);
    expect(back.id, 7);
    expect(back.text, 'héllo 👋');
    expect(back.outgoing, isTrue);
  });

  test('a page round-trips with its segments and read state', () async {
    expect(await cache.load(chat), isNull);
    await cache.applyPage(
      latest(),
      PageResult(
        items: chats(1, 40),
        readState: ReadState(lastReadInbox: k(30), unreadCount: 10),
      ),
      segments: [seg(1, 40, oldest: true, newest: true)],
    );
    final cached = (await cache.load(chat))!;
    expect(ids(cached), [for (var i = 1; i <= 40; i++) i]);
    expect(cached.messages.first.text, startsWith('message '));
    expect(cached.segments, [seg(1, 40, oldest: true, newest: true)]);
    expect(cached.readState!.unreadCount, 10);
    expect(cached.readState!.lastReadInbox, k(30));
    expect(cached.snapshot, isNull);
    // Lists are separate.
    expect(await cache.load(other), isNull);
    // The same page again changes nothing.
    await cache.applyPage(
      latest(),
      PageResult(items: chats(1, 40)),
      segments: [seg(1, 40, oldest: true, newest: true)],
    );
    expect(ids((await cache.load(chat))!), hasLength(40));
    // A limit keeps the newest ones.
    expect(ids((await cache.load(chat, limit: 5))!), [36, 37, 38, 39, 40]);
  });

  test('events are stored in one batch', () async {
    await cache.applyPage(
      latest(),
      PageResult(items: chats(1, 10)),
      segments: [seg(1, 10, newest: true)],
    );
    await cache.applyEvents(
      [
        MessagesAdded(chat, chats(11, 12)),
        const MessagesAdded(chat, [Chat(12, 'pending', localSeq: 1)]),
        const MessagesUpdated(chat, [Chat(5, 'edited')]),
        const MessagesDeleted<Chat>(chat, ['3', 'missing']),
        const LocalAcked(chat, 'local-12-1', Chat(13, 'sent')),
        const LocalFailed<Chat>(chat, 'x', 'offline'),
        const PinnedChanged<Chat>(chat, []),
        const TypingChanged<Chat>(chat, {'a'}),
        ReadStateChanged<Chat>(chat, ReadState(lastReadInbox: k(13))),
        MessagesAdded(other, chats(1, 2)),
      ],
      segments: {
        chat: [seg(1, 13, newest: true)],
        other: [seg(1, 2, newest: true)],
      },
    );
    var cached = (await cache.load(chat))!;
    expect(ids(cached), [1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);
    expect(cached.messages.firstWhere((m) => m.id == 5).text, 'edited');
    expect(cached.messages.firstWhere((m) => m.id == 13).text, 'sent');
    expect(cached.segments, [seg(1, 13, newest: true)]);
    expect(cached.readState!.lastReadInbox, k(13));
    expect(ids((await cache.load(other))!), [1, 2]);

    await cache.applyEvents(
      [HistoryCleared<Chat>(chat, k(9))],
      segments: {
        chat: [seg(10, 13, oldest: true, newest: true)],
      },
    );
    cached = (await cache.load(chat))!;
    expect(ids(cached), [10, 11, 12, 13]);
    expect(cached.segments.single.reachedOldest, isTrue);
  });

  test('the saved position survives and pulls its messages into load',
      () async {
    await cache.applyPage(
      latest(),
      PageResult(items: chats(1, 100)),
      segments: [seg(1, 100, oldest: true, newest: true)],
    );
    await cache.saveSnapshot(chat, snapshot(20));
    await cache.saveSnapshot(chat, snapshot(30)); // the latest wins
    final cached = (await cache.load(chat, limit: 10))!;
    expect(cached.snapshot!.anchorKey, k(30));
    expect(cached.snapshot!.anchorOffset, -7.5);
    expect(cached.snapshot!.viewportWidth, 390);
    expect(ids(cached), [30, 31, 32, for (var i = 91; i <= 100; i++) i]);
    // A snapshot from an unknown version is ignored, not fatal.
    await cache.database.customStatement(
      "UPDATE snapshots SET json = '{\"v\": 99}'",
    );
    expect((await cache.load(chat))!.snapshot, isNull);
  });

  test('eviction keeps the newest messages and the snapshot window', () async {
    await cache.applyPage(
      latest(),
      PageResult(items: chats(1, 200)),
      segments: [seg(1, 200, oldest: true, newest: true)],
    );
    await cache.saveSnapshot(chat, snapshot(50));
    await cache.evict(const EvictionPolicy(keepNewestPerList: 20));
    final cached = (await cache.load(chat))!;
    expect(ids(cached), [50, 51, 52, for (var i = 181; i <= 200; i++) i]);
    // Two runs with a hole between them are two segments.
    expect(cached.segments, [seg(50, 52), seg(181, 200, newest: true)]);
    // Under the limit nothing happens.
    await cache.evict(const EvictionPolicy(keepNewestPerList: 500));
    expect(ids((await cache.load(chat))!), hasLength(23));

    final store = ListStore<Chat>(id: chat, adapter: const ChatAdapter())
      ..restore(cached.messages, cached.segments);
    expect(store.isContiguous(k(52), k(181)), isFalse);
    expect(store.liveSegment!.first, k(181));
    store.debugCheckInvariants();
  });

  test('old lists are dropped; the global cap drops the oldest first',
      () async {
    Future<void> fill(ListId list, int count) => cache.applyPage(
          latest(list),
          PageResult(items: chats(1, count)),
          segments: [seg(1, count, newest: true)],
        );
    await fill(const ListId('ancient'), 5);
    now = now.add(const Duration(days: 31));
    await fill(chat, 30);
    now = now.add(const Duration(hours: 1));
    await fill(other, 30);
    await cache.evict(const EvictionPolicy());
    expect(await cache.load(const ListId('ancient')), isNull);
    expect(await cache.load(chat), isNotNull);

    now = now.add(const Duration(hours: 1));
    await cache.load(chat); // opened most recently
    await cache.evict(const EvictionPolicy(maxMessages: 40));
    expect(await cache.load(other), isNull, reason: 'least recently opened');
    expect(ids((await cache.load(chat))!), hasLength(30));

    await cache.clear(chat);
    expect(await cache.load(chat), isNull);
    await fill(chat, 3);
    await fill(other, 3);
    await cache.clear();
    expect(await cache.load(chat), isNull);
    expect(await cache.load(other), isNull);
  });

  test('the database file is created once and reopened with its data',
      () async {
    final directory = await Directory.systemTemp.createTemp('steady_cache');
    final file = File('${directory.path}/cache.sqlite');
    addTearDown(() => directory.delete(recursive: true));

    final first = open(NativeDatabase(file));
    await first.applyPage(
      latest(),
      PageResult(items: chats(1, 25)),
      segments: [seg(1, 25, oldest: true, newest: true)],
    );
    await first.saveSnapshot(chat, snapshot(10));
    final version =
        await first.database.customSelect('PRAGMA user_version').getSingle();
    expect(
      version.read<int>('user_version'),
      SteadyCacheDatabase.currentSchemaVersion,
    );
    await first.close();

    final second = open(NativeDatabase(file));
    final cached = (await second.load(chat))!;
    expect(ids(cached), hasLength(25));
    expect(cached.segments, [seg(1, 25, oldest: true, newest: true)]);
    expect(cached.snapshot!.anchorKey, k(10));
    await second.close();

    // A file with an unknown layout (no version, a table missing) is
    // rebuilt instead of failing.
    final raw = SteadyCacheDatabase(NativeDatabase(file));
    await raw.customStatement('PRAGMA user_version = 0');
    await raw.customStatement('DROP TABLE lists_meta');
    await raw.close();
    final rebuilt = open(NativeDatabase(file));
    expect(await rebuilt.load(chat), isNull);
    await rebuilt.applyPage(
      latest(),
      PageResult(items: chats(1, 2)),
      segments: [seg(1, 2)],
    );
    expect(ids((await rebuilt.load(chat))!), [1, 2]);
    await rebuilt.close();
  });

  test('a write that fails changes nothing and leaves no transaction open',
      () async {
    await cache.applyPage(
      latest(),
      PageResult(items: chats(1, 3)),
      segments: [seg(1, 3)],
    );
    // Break the second half of the next write.
    await cache.database.customStatement(
      'ALTER TABLE segments RENAME TO segments_gone',
    );
    await expectLater(
      cache.applyPage(
        latest(),
        PageResult(items: chats(4, 9)),
        segments: [seg(1, 9)],
      ),
      throwsA(anything),
    );
    await cache.database.customStatement(
      'ALTER TABLE segments_gone RENAME TO segments',
    );
    // The messages of the failed page were rolled back with it.
    final cached = (await cache.load(chat))!;
    expect(ids(cached), [1, 2, 3]);
    expect(cached.segments, [seg(1, 3)]);
    // And the next write starts its own transaction without trouble.
    await cache.applyPage(
      latest(),
      PageResult(items: chats(4, 5)),
      segments: [seg(1, 5)],
    );
    expect(ids((await cache.load(chat))!), [1, 2, 3, 4, 5]);
  });

  test('many writes and reads at the same time stay consistent', () async {
    await Future.wait([
      for (var page = 0; page < 20; page++) ...[
        cache.applyPage(
          latest(),
          PageResult(items: chats(page * 10 + 1, page * 10 + 10)),
          segments: [seg(1, page * 10 + 10)],
        ),
        cache.load(chat),
        cache.saveSnapshot(chat, snapshot(1)),
      ],
    ]);
    final cached = (await cache.load(chat))!;
    expect(ids(cached), hasLength(200));
    expect(cached.snapshot, isNotNull);
  });

  test('watch reports changes made by others, not our own', () async {
    final changes = <CacheChange>[];
    final sub = cache.watch().listen(changes.add);
    await cache.applyPage(
      latest(),
      PageResult(items: chats(1, 3)),
      segments: [seg(1, 3)],
    );
    await cache.saveSnapshot(chat, snapshot(1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(changes, isEmpty, reason: 'own writes are filtered');
    // Another tab sharing the database writes: drift tells every tab.
    cache.database.notifyUpdates({const TableUpdate('messages')});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(changes, hasLength(1));
    expect(changes.single.list, isNull);
    await sub.cancel();
  });

  test('a hub restarts from the Drift cache without the network', () async {
    final source = _Source();
    MessageListHub<Chat> hub() => MessageListHub<Chat>(
          source: source,
          adapter: const ChatAdapter(),
          cache: cache,
        );
    final first = hub();
    await first.hydrate(chat);
    final store = first.attach(chat);
    await first.fetch(latest());
    first.apply(const MessagesAdded(chat, [Chat(101, 'new')]));
    first.apply(const MessagesDeleted<Chat>(chat, ['95']));
    first.persistSnapshot(chat, snapshot(80));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(store.length, 100);
    first.dispose();

    source.offline = true;
    final second = hub();
    await second.hydrate(chat);
    final restored = second.attach(chat);
    expect(restored.length, 100);
    expect(restored.contains('95'), isFalse);
    expect(restored.messageOf('101')!.text, 'new');
    expect(restored.liveSegment!.last, k(101));
    expect(second.cachedSnapshot(chat)!.anchorKey, k(80));
    expect(source.fetches, 1);
    second.dispose();
  });
}

class _Source implements MessageSource<Chat> {
  bool offline = false;
  int fetches = 0;

  @override
  Future<PageResult<Chat>> fetch(PageRequest request) async {
    fetches++;
    if (offline) throw StateError('offline');
    return PageResult(items: chats(1, 100), reachedOldest: true);
  }

  @override
  Stream<ListEvent<Chat>> events(ListId list) => const Stream.empty();

  @override
  Future<void> markRead(ListId list, MessageKey upTo) async {}
}
