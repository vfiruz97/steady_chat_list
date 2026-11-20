import 'dart:collection';

import 'package:steady_chat_list_core/steady_chat_list_core.dart';

const ListId chat = ListId('chat');

/// Minimal app message used by the tests.
class Msg {
  const Msg(
    this.order, {
    String? id,
    this.localSeq = 0,
    this.rev = 0,
    this.outgoing = false,
    this.service = false,
    this.mention = false,
    this.dateMicros,
  }) : _id = id;

  final int order;
  final String? _id;
  final int localSeq;
  final int rev;
  final bool outgoing;
  final bool service;
  final bool mention;
  final int? dateMicros;

  String get id => _id ?? 'm$order';

  MessageKey get key => MessageKey(order: order, id: id, localSeq: localSeq);

  Msg bump() => Msg(
        order,
        id: _id,
        localSeq: localSeq,
        rev: rev + 1,
        outgoing: outgoing,
        service: service,
        mention: mention,
        dateMicros: dateMicros,
      );

  @override
  String toString() => 'Msg($key, rev $rev)';
}

class MsgAdapter extends MessageAdapter<Msg> {
  const MsgAdapter();

  @override
  MessageKey keyOf(Msg m) => m.key;

  @override
  DateTime dateOf(Msg m) => DateTime.fromMicrosecondsSinceEpoch(
        m.dateMicros ?? m.order * 1000000,
        isUtc: true,
      );

  @override
  bool isOutgoing(Msg m) => m.outgoing;

  @override
  bool isService(Msg m) => m.service;

  @override
  bool mentionsMe(Msg m) => m.mention;

  @override
  bool equals(Msg a, Msg b) => a.rev == b.rev && a.key.isSamePosition(b.key);
}

MessageKey k(int order, {String? id, int localSeq = 0}) =>
    MessageKey(order: order, id: id ?? 'm$order', localSeq: localSeq);

List<int> orders(Iterable<MessageKey> keys) => [for (final k in keys) k.order];

/// A mutable clock for tombstone tests.
class FakeClock {
  DateTime now = DateTime.utc(2026, 11, 20);
  DateTime call() => now;
}

ListStore<Msg> newStore({FakeClock? clock, MessageMerge<Msg>? merge}) =>
    ListStore<Msg>(
      id: chat,
      adapter: const MsgAdapter(),
      clock: clock?.call,
      merge: merge,
    );

/// The truth the store is tested against: a sorted set of server messages
/// that answers page requests the way a correct backend would.
class TestServer {
  final SplayTreeMap<int, Msg> byOrder = SplayTreeMap<int, Msg>();

  void seed(Iterable<int> orders) {
    for (final o in orders) {
      byOrder[o] = Msg(o);
    }
  }

  int? get min => byOrder.firstKey();
  int? get max => byOrder.lastKey();

  (PageRequest, PageResult<Msg>) latest(int limit) {
    final all = byOrder.values.toList();
    final items = all.sublist(all.length > limit ? all.length - limit : 0);
    return (
      PageRequest(list: chat, direction: PageDirection.latest, limit: limit),
      PageResult(items: items, reachedOldest: items.length == all.length),
    );
  }

  (PageRequest, PageResult<Msg>) older(MessageKey anchor, int limit) {
    final below = [
      for (final m in byOrder.values)
        if (m.key < anchor) m,
    ];
    final items =
        below.sublist(below.length > limit ? below.length - limit : 0);
    return (
      PageRequest(
        list: chat,
        direction: PageDirection.older,
        anchor: anchor,
        limit: limit,
      ),
      PageResult(items: items, reachedOldest: items.length == below.length),
    );
  }

  (PageRequest, PageResult<Msg>) newer(MessageKey anchor, int limit) {
    final above = [
      for (final m in byOrder.values)
        if (m.key > anchor) m,
    ];
    final items = above.take(limit).toList();
    return (
      PageRequest(
        list: chat,
        direction: PageDirection.newer,
        anchor: anchor,
        limit: limit,
      ),
      PageResult(items: items, reachedNewest: items.length == above.length),
    );
  }

  (PageRequest, PageResult<Msg>) around(MessageKey anchor, int limit) {
    final half = limit ~/ 2;
    final (_, before) = older(anchor, half);
    final (_, after) = newer(anchor, half);
    final self = byOrder[anchor.order];
    return (
      PageRequest(
        list: chat,
        direction: PageDirection.around,
        anchor: anchor,
        limit: limit,
      ),
      PageResult(
        items: [
          ...before.items,
          if (self != null && self.id == anchor.id) self,
          ...after.items,
        ],
        reachedOldest: before.reachedOldest,
        reachedNewest: after.reachedNewest,
      ),
    );
  }
}

extension ApplyPage on ListStore<Msg> {
  StoreDelta page((PageRequest, PageResult<Msg>) p) => applyPage(p.$1, p.$2);
}
