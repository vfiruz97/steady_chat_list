// The small things: defaults, descriptions and rarely taken store paths.
import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:test/test.dart';

import 'support.dart';

class _Plain {
  const _Plain(this.id);
  final int id;
}

class _PlainAdapter extends MessageAdapter<_Plain> {
  const _PlainAdapter();
  @override
  MessageKey keyOf(_Plain m) => MessageKey(order: m.id, id: '${m.id}');
  @override
  DateTime dateOf(_Plain m) => DateTime.utc(2026);
}

/// A message whose key can be changed behind the store's back.
class _Mutable {
  _Mutable(this.order);
  int order;
}

class _MutableAdapter extends MessageAdapter<_Mutable> {
  const _MutableAdapter();
  @override
  MessageKey keyOf(_Mutable m) => MessageKey(order: m.order, id: 'same');
  @override
  DateTime dateOf(_Mutable m) => DateTime.utc(2026);
}

void main() {
  test('adapter defaults', () {
    const adapter = _PlainAdapter();
    const a = _Plain(1);
    expect(adapter.groupIdOf(a), isNull);
    expect(adapter.senderIdOf(a), isNull);
    expect(adapter.isOutgoing(a), isFalse);
    expect(adapter.isService(a), isFalse);
    expect(adapter.mentionsMe(a), isFalse);
    expect(adapter.equals(a, a), isTrue);
    expect(adapter.equals(a, const _Plain(2)), isFalse);
  });

  test('descriptions are readable', () {
    expect('${const ListId('a', 't')}', 'ListId(a/t)');
    expect('${k(5)}', 'MessageKey(5, m5)');
    expect('${k(5, id: 'c', localSeq: 2)}', 'MessageKey(5+2, c)');
    expect('${KeyRange(k(1), k(2))}', contains('..'));
    expect(
      '${Segment(first: k(1), last: k(2, id: 'c', localSeq: 1), reachedOldest: true)}',
      'Segment(|1..2+1…)',
    );
    expect('${const ReadState(unreadCount: 3)}', contains('unread: 3'));
    expect('${KeyReplacement(k(1), k(2))}', contains('→'));
    final delta = StoreDelta(
      list: chat,
      inserted: [k(1)],
      segmentsChanged: true,
      readStateChanged: true,
      pinnedChanged: true,
      typingChanged: true,
      historyCleared: true,
    );
    expect(
      '$delta',
      'StoreDelta(chat: +1 ~0 -0 evicted 0 replaced 0 '
          'segments read pinned typing cleared)',
    );
    expect('${const StoreDelta(list: chat)}', endsWith('replaced 0)'));
    expect(
      '${PageRequest(list: chat, direction: PageDirection.latest, limit: 5)}',
      contains('latest'),
    );
    expect('${newStore()}', contains('0 messages'));
  });

  test('value types: equality, hashing, copies', () {
    final segment = Segment(first: k(1), last: k(9), reachedNewest: true);
    expect(segment.isLive, isTrue);
    expect(segment.range.contains(k(5)), isTrue);
    expect(segment.contains(k(10)), isFalse);
    expect(segment.copyWith(), segment);
    expect(segment.copyWith().hashCode, segment.hashCode);
    expect(segment.copyWith(reachedOldest: true), isNot(segment));

    const state = ReadState(unreadCount: 2);
    expect(state.copyWith().hashCode, state.hashCode);
    expect(state.copyWith(lastReadInbox: k(3)), isNot(state));
    expect(
      state.copyWith(lastReadOutbox: k(1), unreadMentions: [k(2)]).copyWith(),
      state.copyWith(lastReadOutbox: k(1), unreadMentions: [k(2)]),
    );
    expect(
      state.copyWith(unreadReactions: [k(1)]),
      isNot(state.copyWith(unreadReactions: [k(2)])),
    );
    const page = SearchPage(keys: [], totalCount: 0);
    expect(page.nextCursor, isNull);
    expect(const MessageListPolicies<Msg>().grouping, isNull);
  });

  group('rarely taken store paths', () {
    late TestServer server;
    late ListStore<Msg> store;

    setUp(() {
      server = TestServer()..seed([for (var i = 1; i <= 20; i++) i * 10]);
      store = newStore()..page(server.latest(40));
    });

    tearDown(() => store.debugCheckInvariants());

    test('accessors', () {
      expect(store.oldestKey, k(10));
      expect(store[k(10)]!.order, 10);
      expect(store[k(15)], isNull);
      expect(store.clearedUpTo, isNull);
      store.apply(HistoryCleared<Msg>(chat, k(50)));
      expect(store.clearedUpTo, k(50));
    });

    test('unread reactions are navigated oldest first', () {
      store.apply(
        ReadStateChanged<Msg>(
          chat,
          ReadState(unreadReactions: [k(150), k(90)], unreadMentions: [k(90)]),
        ),
      );
      expect(store.nextUnreadReaction(), k(90));
      expect(store.nextUnreadReaction(k(90)), k(150));
      expect(store.nextUnreadReaction(k(150)), isNull);
      // Deleting a message drops it from both lists, keeps the others.
      store.apply(const MessagesDeleted<Msg>(chat, ['m90']));
      expect(store.readState.unreadReactions, [k(150)]);
      expect(store.readState.unreadMentions, isEmpty);
      expect(store.nextUnreadMention(), isNull);
    });

    test('an edit that changes the date moves it in the date index', () {
      DateTime at(int seconds) =>
          DateTime.fromMicrosecondsSinceEpoch(seconds * 1000000, isUtc: true);
      store.apply(
        const MessagesUpdated(chat, [Msg(100, rev: 1, dateMicros: 500000000)]),
      );
      expect(store.firstOnOrAfter(at(100)), k(110));
      expect(store.firstOnOrAfter(at(201)), k(100));
    });

    test('a re-keyed failed local message keeps its error', () {
      final key = store.nextLocalKey('c1');
      store.apply(
        MessagesAdded(chat, [
          Msg(key.order, id: 'c1', localSeq: key.localSeq, outgoing: true),
        ]),
      );
      store.apply(const LocalFailed<Msg>(chat, 'c1', 'offline'));
      // Same id, new position (the app re-queued it).
      store.apply(
        const MessagesUpdated(chat, [
          Msg(200, id: 'c1', localSeq: 5, outgoing: true),
        ]),
      );
      expect(store.keyOf('c1')!.localSeq, 5);
      expect(store.sendErrorOf('c1'), 'offline');
    });

    test('re-keying the newest message backwards moves the bound', () {
      store.apply(const MessagesUpdated(chat, [Msg(155, id: 'm200')]));
      expect(store.segments.single.last, k(190));
      expect(store.keyOf('m200')!.order, 155);
    });

    test('an ack for a message the server already deleted drops the local', () {
      final key = store.nextLocalKey('c1');
      store.apply(
        MessagesAdded(chat, [
          Msg(key.order, id: 'c1', localSeq: key.localSeq, outgoing: true),
        ]),
      );
      store.apply(const MessagesDeleted<Msg>(chat, ['m210']));
      final delta = store.apply(const LocalAcked(chat, 'c1', Msg(210)));
      expect(delta.removed.single.id, 'c1');
      expect(store.contains('c1'), isFalse);
      expect(store.contains('m210'), isFalse);
    });

    test('an ack with the same id is an in-place update', () {
      final delta =
          store.apply(const LocalAcked(chat, 'm200', Msg(200, rev: 1)));
      expect(delta.updated, [k(200)]);
    });

    test('clearing one list from the multi-list store', () {
      final all = MessageStore<Msg>(adapter: const MsgAdapter());
      all.list(const ListId('a'));
      all.list(const ListId('b'));
      all.clear(const ListId('a'));
      expect(all.lists, [const ListId('b')]);
    });
  });

  test('a full window that barely covers the viewport pages at the edge', () {
    const policy = WindowPolicy();
    bool at(double edge, double otherEdge) => policy.shouldExtend(
          distanceToEdge: edge,
          distanceToOtherEdge: otherEdge,
          averageItemExtent: 20,
          windowIsFull: true,
        );
    // 80 items of 20 px in a 1,200 px viewport: 400 px to scroll, a page is
    // 800 px.
    expect(at(0, 400), isTrue);
    expect(at(10, 390), isFalse);
    expect(at(0, 0), isFalse);
  });

  test('the invariant check names what is broken', () {
    final store = ListStore<_Mutable>(
      id: chat,
      adapter: const _MutableAdapter(),
    );
    final message = _Mutable(10);
    store.apply(MessagesAdded(chat, [message]));
    expect(store.debugCheckInvariants(), isTrue);
    message.order = 99; // the app mutated a stored message
    expect(
      store.debugCheckInvariants,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('stored under the wrong key'),
        ),
      ),
    );
  });
}
