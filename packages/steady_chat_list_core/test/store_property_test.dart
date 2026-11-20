// §18 test 26 / §15: random operation sequences on the store.
//
// A [TestServer] is the truth. Pages are computed from it, sometimes applied
// late (stale); events are applied as they happen. After every operation:
//
// * the structural invariants hold (`debugCheckInvariants`);
// * every segment holds exactly the server's messages of its key range, so
//   the store never claims contiguity the server didn't prove;
// * `reachedNewest` / `reachedOldest` / known-empty are true statements;
// * applying the same operation again changes nothing (idempotence);
// * range queries agree with a naive scan.
import 'dart:math';

import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const int _sequences = 10000;
const int _steps = 40;

void main() {
  test('$_sequences random operation sequences keep the invariants', () {
    for (var seed = 0; seed < _sequences; seed++) {
      final run = _Run(seed);
      try {
        run.play();
      } catch (_) {
        // ignore: avoid_print
        print('seed $seed failed after:\n  ${run.log.join('\n  ')}');
        rethrow;
      }
    }
  });
}

final class _Run {
  _Run(int seed) : r = Random(seed) {
    var order = 100;
    final count = r.nextInt(70);
    for (var i = 0; i < count; i++) {
      order += 1 + r.nextInt(5);
      server.byOrder[order] = Msg(order);
      used.add(order);
    }
    top = order + 10;
  }

  final Random r;
  final TestServer server = TestServer();
  final ListStore<Msg> store = newStore(clock: FakeClock());
  final Set<int> used = <int>{};
  final List<(PageRequest, PageResult<Msg>)> pending = [];
  final List<String> locals = <String>[];
  final List<String> log = <String>[];
  int top = 0;
  int localCount = 0;

  void play() {
    for (var step = 0; step < _steps; step++) {
      _step();
      _check();
    }
  }

  void _step() {
    switch (r.nextInt(13)) {
      case 0:
        _page(server.latest(1 + r.nextInt(25)), canDelay: false);
      case 1:
        _page(server.older(_anchor(), 1 + r.nextInt(25)));
      case 2:
        _page(server.newer(_anchor(), 1 + r.nextInt(25)));
      case 3:
        _page(server.around(_anchor(), 2 + r.nextInt(25)));
      case 4:
        if (pending.isNotEmpty) {
          _applyPage(pending.removeAt(r.nextInt(pending.length)));
        }
      case 5:
        final added = [for (var i = r.nextInt(3); i >= 0; i--) _addOnTop()];
        _event(MessagesAdded(chat, added));
      case 6:
        // A late message. The store trusts "added" to be the newest
        // message unless it sorts below data it already has, so late
        // messages are only sent while the live segment is loaded.
        final min = server.min;
        final max = server.max;
        if (min == null || max == null || store.liveSegment == null) return;
        final order = min + r.nextInt(max - min + 1);
        if (!used.add(order)) return;
        server.byOrder[order] = Msg(order);
        _event(MessagesAdded(chat, [Msg(order)]));
      case 7:
        final ids = <String>[];
        for (var i = r.nextInt(3); i >= 0 && server.byOrder.isNotEmpty; i--) {
          final order = _serverOrder();
          server.byOrder.remove(order);
          ids.add('m$order');
        }
        if (locals.isNotEmpty && r.nextInt(4) == 0) {
          ids.add(locals.removeAt(r.nextInt(locals.length)));
        }
        _event(MessagesDeleted<Msg>(chat, ids));
      case 8:
        if (server.byOrder.isEmpty) return;
        final order = _serverOrder();
        final next = server.byOrder[order]!.bump();
        server.byOrder[order] = next;
        _event(MessagesUpdated(chat, [next]));
      case 9:
        // A page fetched before an orphan was evicted would claim a range
        // the store no longer fully holds; controllers drop such pages by
        // generation, the test drops them here.
        pending.clear();
        final protect = <KeyRange>[];
        if (!store.isEmpty && r.nextBool()) {
          final a = _storeKey();
          final b = _storeKey();
          protect.add(a <= b ? KeyRange(a, b) : KeyRange(b, a));
        }
        final limit = 1 + r.nextInt(40);
        log.add('evict $limit $protect');
        store.evict(limit: limit, protect: protect);
        expect(store.evict(limit: limit, protect: protect).isEmpty, isTrue);
      case 10:
        final id = 'c${localCount++}';
        final key = store.nextLocalKey(id);
        locals.add(id);
        _event(
          MessagesAdded(chat, [
            Msg(key.order, id: id, localSeq: key.localSeq, outgoing: true),
          ]),
        );
      case 11:
        if (locals.isEmpty) return;
        final id = locals.removeAt(r.nextInt(locals.length));
        final acked = _addOnTop();
        if (r.nextInt(3) == 0) _event(MessagesAdded(chat, [acked]));
        _event(LocalAcked(chat, id, acked));
      case 12:
        if (server.byOrder.isEmpty || r.nextInt(4) != 0) return;
        final upTo = k(_serverOrder() + r.nextInt(2));
        used.add(upTo.order);
        if (upTo.order > top) top = upTo.order;
        server.byOrder.removeWhere((order, _) => order <= upTo.order);
        _event(HistoryCleared<Msg>(chat, upTo));
    }
  }

  Msg _addOnTop() {
    top += 1 + r.nextInt(5);
    used.add(top);
    return server.byOrder[top] = Msg(top);
  }

  int _serverOrder() =>
      server.byOrder.keys.elementAt(r.nextInt(server.byOrder.length));

  MessageKey _storeKey() => store.keys.elementAt(r.nextInt(store.length));

  MessageKey _anchor() {
    final pick = r.nextInt(3);
    if (pick == 0 && !store.isEmpty) {
      final key = _storeKey();
      if (!key.isLocal) return key;
    }
    if (pick == 1 && server.byOrder.isNotEmpty) return k(_serverOrder());
    return k(95 + r.nextInt(top - 90));
  }

  void _page((PageRequest, PageResult<Msg>) page, {bool canDelay = true}) {
    // A late "this is the newest" answer is what generations guard against.
    if (canDelay && !page.$2.reachedNewest && r.nextInt(3) == 0) {
      pending.add(page);
    } else {
      _applyPage(page);
    }
  }

  void _applyPage((PageRequest, PageResult<Msg>) page) {
    log.add('${page.$1} → ${orders(page.$2.items.map((m) => m.key))} '
        'oldest=${page.$2.reachedOldest} newest=${page.$2.reachedNewest}');
    store.page(page);
    expect(store.page(page).isEmpty, isTrue, reason: 'page not idempotent');
  }

  void _event(ListEvent<Msg> event) {
    log.add(switch (event) {
      MessagesAdded<Msg>(:final items) => 'added $items',
      MessagesUpdated<Msg>(:final items) => 'updated $items',
      MessagesDeleted<Msg>(:final ids) => 'deleted $ids',
      LocalAcked<Msg>(:final localId, :final serverMessage) =>
        'acked $localId → $serverMessage',
      HistoryCleared<Msg>(:final upTo) => 'cleared up to $upTo',
      _ => '$event',
    });
    store.apply(event);
    expect(store.apply(event).isEmpty, isTrue, reason: 'event not idempotent');
  }

  void _check() {
    store.debugCheckInvariants();
    final serverKeys = [for (final order in server.byOrder.keys) k(order)];
    for (final s in store.segments) {
      expect(
        [
          for (final key in store.keysBetween(s.first, s.last))
            if (!key.isLocal) key.order,
        ],
        [
          for (final key in serverKeys)
            if (s.contains(key)) key.order,
        ],
        reason: '$s must hold exactly what the server has in its range',
      );
      if (s.reachedOldest && serverKeys.isNotEmpty) {
        expect(serverKeys.first >= s.first, isTrue, reason: '$s reachedOldest');
      }
      if (s.reachedNewest && serverKeys.isNotEmpty) {
        expect(serverKeys.last <= s.last, isTrue, reason: '$s reachedNewest');
      }
    }
    if (store.isKnownEmpty) expect(serverKeys, isEmpty);
    if (store.isEmpty) return;

    // Range queries against a naive scan.
    final key = _storeKey();
    final segment = store.segmentOf(key);
    final n = 1 + r.nextInt(6);
    final all = store.keys.toList();
    final inSegment = segment == null
        ? const <MessageKey>[]
        : [
            for (final other in all)
              if (segment.contains(other)) other,
          ];
    final before = [
      for (final other in inSegment)
        if (other < key) other,
    ];
    final after = [
      for (final other in inSegment)
        if (other > key) other,
    ];
    expect(
      store.keysBefore(key, n),
      before.sublist(before.length > n ? before.length - n : 0),
    );
    expect(store.keysAfter(key, n), after.take(n).toList());
    expect(store.nearestExisting(key, ScanDirection.older), key);
  }
}
