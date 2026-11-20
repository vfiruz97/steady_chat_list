// Micro-benchmark of the store part of the §14.1 budgets.
//
//   dart run benchmark/store_benchmark.dart
//
// ignore_for_file: avoid_print
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

final class _Msg {
  const _Msg(this.id, this.rev);
  final int id;
  final int rev;
}

final class _Adapter extends MessageAdapter<_Msg> {
  const _Adapter();
  @override
  MessageKey keyOf(_Msg m) => MessageKey(order: m.id, id: '${m.id}');
  @override
  DateTime dateOf(_Msg m) =>
      DateTime.fromMillisecondsSinceEpoch(m.id * 60000, isUtc: true);
  @override
  bool equals(_Msg a, _Msg b) => a.rev == b.rev;
}

const _list = ListId('bench');

MessageKey _key(int id) => MessageKey(order: id, id: '$id');

double _micros(int runs, void Function(int run) body) {
  final watch = Stopwatch()..start();
  for (var i = 0; i < runs; i++) {
    body(i);
  }
  return watch.elapsedMicroseconds / runs;
}

void main() {
  const loaded = 1000; // memoryLimitPerList
  const page = 40;
  ListStore<_Msg> filled() {
    final store = ListStore<_Msg>(id: _list, adapter: const _Adapter());
    store.applyPage(
      PageRequest(list: _list, direction: PageDirection.latest, limit: loaded),
      PageResult(
          items: [for (var i = 0; i < loaded; i++) _Msg(1000000 + i, 0)]),
    );
    return store;
  }

  // Warm up the JIT.
  for (var i = 0; i < 20; i++) {
    filled().evict(limit: 10);
  }

  var store = filled();
  var oldest = 1000000;
  final apply = _micros(500, (_) {
    final items = [for (var i = 1; i <= page; i++) _Msg(oldest - i, 0)];
    store.applyPage(
      PageRequest(
        list: _list,
        direction: PageDirection.older,
        anchor: _key(oldest),
        limit: page,
      ),
      PageResult(items: items),
    );
    oldest -= page;
    if (store.length > loaded + page) {
      store.evict(
          limit: loaded, protect: [KeyRange(_key(oldest), _key(oldest + 80))]);
    }
  });
  print('apply page of $page (+ eviction at $loaded): '
      '${apply.toStringAsFixed(1)} µs   budget 3000 µs');

  store = filled();
  var rev = 0;
  final update = _micros(20000, (i) {
    store.apply(MessagesUpdated(_list, [_Msg(1000000 + i % loaded, ++rev)]));
  });
  print('one reaction update: ${update.toStringAsFixed(2)} µs');

  var next = 1000000 + loaded;
  final added = _micros(20000, (_) {
    store.apply(MessagesAdded(_list, [_Msg(next++, 0)]));
  });
  print('one incoming message: ${added.toStringAsFixed(2)} µs');

  store = filled();
  final window = _micros(20000, (i) {
    store.keysAround(_key(1000000 + i % loaded), before: 40, after: 40);
  });
  print('window of 80 keys around a key: ${window.toStringAsFixed(2)} µs');
}
