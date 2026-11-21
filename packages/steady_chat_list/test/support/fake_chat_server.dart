import 'dart:async';

import 'package:steady_chat_list/steady_chat_list.dart';

/// Minimal app message used by the tests.
class Msg {
  const Msg(
    this.order, {
    String? id,
    this.localSeq = 0,
    this.rev = 0,
    this.outgoing = false,
    this.service = false,
    this.group,
    this.sender,
  }) : _id = id;

  final int order;
  final String? _id;
  final int localSeq;
  final int rev;
  final bool outgoing;
  final bool service;
  final String? group;
  final String? sender;

  String get id => _id ?? 'm$order';

  MessageKey get key => MessageKey(order: order, id: id, localSeq: localSeq);

  @override
  String toString() => 'Msg($order)';
}

class MsgAdapter extends MessageAdapter<Msg> {
  const MsgAdapter();

  @override
  MessageKey keyOf(Msg m) => m.key;

  @override
  DateTime dateOf(Msg m) =>
      DateTime.fromMillisecondsSinceEpoch(m.order * 60000, isUtc: true);

  @override
  String? groupIdOf(Msg m) => m.group;

  @override
  String? senderIdOf(Msg m) => m.sender;

  @override
  bool isOutgoing(Msg m) => m.outgoing;

  @override
  bool isService(Msg m) => m.service;

  @override
  bool equals(Msg a, Msg b) => a.rev == b.rev && a.key.isSamePosition(b.key);
}

MessageKey k(int order) => MessageKey(order: order, id: 'm$order');

/// An in-process backend: [count] messages per chat with ids `step`,
/// `2 * step`, … generated on demand (a 10,000,000-message chat costs
/// nothing), plus whatever arrives later.
class FakeChatServer implements MessageSource<Msg> {
  FakeChatServer({
    required this.count,
    this.step = 10,
    this.latency = const Duration(milliseconds: 150),
    this.outgoingEvery = 0,
    this.decorate,
  });

  final int count;
  final int step;
  Duration latency;

  /// Every n-th message is outgoing (0 = none).
  final int outgoingEvery;

  /// Rewrites generated messages (albums, senders).
  final Msg Function(Msg message)? decorate;

  /// Sent along with every page when set.
  ReadState? readState;

  int failNextFetches = 0;
  int failNextMarkRead = 0;
  int subscriptions = 0;

  final List<PageRequest> requests = [];
  final List<MessageKey> readReceipts = [];
  final Set<int> deleted = {};
  final List<Msg> arrived = [];
  final StreamController<ListEvent<Msg>> _events =
      StreamController<ListEvent<Msg>>.broadcast();

  int get newest => arrived.isEmpty ? count * step : arrived.last.order;

  Iterable<PageRequest> requestsOf(PageDirection direction) =>
      requests.where((r) => r.direction == direction);

  Msg? at(int order) {
    if (deleted.contains(order)) return null;
    for (final m in arrived) {
      if (m.order == order) return m;
    }
    if (order <= 0 || order % step != 0 || order ~/ step > count) return null;
    final n = order ~/ step;
    final message =
        Msg(order, outgoing: outgoingEvery > 0 && n % outgoingEvery == 0);
    return decorate?.call(message) ?? message;
  }

  int? _next(int order) {
    for (var i = order < 0 ? 1 : order ~/ step + 1; i <= count; i++) {
      if (!deleted.contains(i * step)) return i * step;
    }
    for (final m in arrived) {
      if (m.order > order && !deleted.contains(m.order)) return m.order;
    }
    return null;
  }

  int? _previous(int order) {
    for (final m in arrived.reversed) {
      if (m.order < order && !deleted.contains(m.order)) return m.order;
    }
    var i = (order - 1) ~/ step;
    if (i > count) i = count;
    for (; i >= 1; i--) {
      if (!deleted.contains(i * step)) return i * step;
    }
    return null;
  }

  ({List<Msg> items, bool end}) _walk(
      int from, int limit, int? Function(int) f) {
    final items = <Msg>[];
    int? cursor = from;
    while (items.length < limit) {
      cursor = f(cursor!);
      if (cursor == null) break;
      items.add(at(cursor)!);
    }
    return (items: items, end: cursor == null || f(cursor) == null);
  }

  @override
  Future<PageResult<Msg>> fetch(PageRequest request) async {
    requests.add(request);
    await Future<void>.delayed(latency);
    if (failNextFetches > 0) {
      failNextFetches--;
      throw StateError('offline');
    }
    final anchor = request.anchor?.order;
    switch (request.direction) {
      case PageDirection.latest:
        final page = _walk(newest + 1, request.limit, _previous);
        return PageResult(
          items: page.items,
          reachedOldest: page.end,
          reachedNewest: true,
          readState: readState,
        );
      case PageDirection.older:
        final page = _walk(anchor!, request.limit, _previous);
        return PageResult(
          items: page.items,
          reachedOldest: page.end,
          readState: readState,
        );
      case PageDirection.newer:
        final page = _walk(anchor!, request.limit, _next);
        return PageResult(
          items: page.items,
          reachedNewest: page.end,
          readState: readState,
        );
      case PageDirection.around:
        final half = request.limit ~/ 2;
        final before = _walk(anchor!, half, _previous);
        final after = _walk(anchor, half, _next);
        final self = at(anchor);
        return PageResult(
          items: [...before.items, if (self != null) self, ...after.items],
          reachedOldest: before.end,
          reachedNewest: after.end,
          readState: readState,
        );
    }
  }

  @override
  Stream<ListEvent<Msg>> events(ListId list) {
    subscriptions++;
    return _events.stream.where((event) => event.list == list);
  }

  @override
  Future<void> markRead(ListId list, MessageKey upTo) async {
    await Future<void>.delayed(latency);
    if (failNextMarkRead > 0) {
      failNextMarkRead--;
      throw StateError('offline');
    }
    readReceipts.add(upTo);
  }

  void push(ListEvent<Msg> event) => _events.add(event);

  /// A new message arrives in [list].
  Msg incoming(ListId list, {bool outgoing = false}) {
    final message = Msg(newest + step, outgoing: outgoing);
    arrived.add(message);
    push(MessagesAdded(list, [message]));
    return message;
  }
}
