import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A source whose fetches complete when the test says so.
class ManualSource implements MessageSource<Msg> {
  final List<PageRequest> requests = [];
  final List<Completer<PageResult<Msg>>> pending = [];
  final StreamController<ListEvent<Msg>> events_ =
      StreamController<ListEvent<Msg>>.broadcast();
  final List<MessageKey> read = [];
  int subscriptions = 0;
  int cancellations = 0;

  @override
  Future<PageResult<Msg>> fetch(PageRequest request) {
    requests.add(request);
    final completer = Completer<PageResult<Msg>>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Stream<ListEvent<Msg>> events(ListId list) {
    subscriptions++;
    final controller = StreamController<ListEvent<Msg>>(
      onCancel: () => cancellations++,
    );
    final sub = events_.stream.listen(
      controller.add,
      onError: controller.addError,
    );
    controller.onCancel = () {
      cancellations++;
      return sub.cancel();
    };
    return controller.stream;
  }

  @override
  Future<void> markRead(ListId list, MessageKey upTo) async => read.add(upTo);
}

PageRequest latest({CancellationToken? cancel, int limit = 20}) => PageRequest(
      list: chat,
      direction: PageDirection.latest,
      limit: limit,
      cancel: cancel,
    );

void main() {
  late ManualSource source;
  late MessageListHub<Msg> hub;
  final errors = <Object>[];

  setUp(() {
    source = ManualSource();
    errors.clear();
    hub = MessageListHub<Msg>(
      source: source,
      adapter: const MsgAdapter(),
      viewportStore: InMemoryViewportStore(),
      memoryLimitPerList: 5,
      openListsInMemory: 2,
      onError: (error, stackTrace) => errors.add(error),
      clock: () => DateTime.utc(2026, 11, 20),
    );
  });

  test('fetch applies the page and reports the outcome', () async {
    final future = hub.fetch(latest());
    source.pending.single.complete(
      const PageResult(items: [Msg(10), Msg(20)], reachedOldest: true),
    );
    final outcome = await future;
    expect(outcome.applied, isTrue);
    expect(outcome.origin, PageOrigin.remote);
    expect(outcome.delta.inserted, hasLength(2));
    expect(outcome.result.items, hasLength(2));
    expect(outcome.request.direction, PageDirection.latest);
    expect(outcome.duration, greaterThanOrEqualTo(Duration.zero));
    expect(hub.store.peek(chat)!.length, 2);
    expect(hub.now(), DateTime.utc(2026, 11, 20));
  });

  test('identical requests share one call; different ones do not', () async {
    final a = hub.fetch(latest());
    final b = hub.fetch(latest());
    final c = hub.fetch(latest(limit: 40));
    PageRequest older(int anchor) => PageRequest(
          list: chat,
          direction: PageDirection.older,
          anchor: k(anchor),
          limit: 20,
        );
    final d = hub.fetch(older(50));
    final e = hub.fetch(older(50));
    final f = hub.fetch(older(60));
    expect(source.requests, hasLength(4));
    for (final completer in source.pending) {
      completer.complete(const PageResult(items: [Msg(10)]));
    }
    expect(identical(await a, await b), isTrue);
    expect((await c).applied, isTrue);
    expect(identical(await d, await e), isTrue);
    expect(identical(await d, await f), isFalse);
    // A new identical request after completion is a new call.
    unawaited(hub.fetch(latest()));
    expect(source.requests, hasLength(5));
  });

  test('a result nobody wants any more is dropped', () async {
    final first = CancellationToken();
    final second = CancellationToken();
    final a = hub.fetch(latest(cancel: first));
    final b = hub.fetch(latest(cancel: second));
    first.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(source.requests.single.cancel.isCancelled, isFalse);
    second.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(source.requests.single.cancel.isCancelled, isTrue);
    source.pending.single.complete(const PageResult(items: [Msg(10)]));
    expect((await a).applied, isFalse);
    expect((await b).delta.isEmpty, isTrue);
    expect(hub.store.peek(chat), isNull);
  });

  test('a failed fetch fails every requester and frees the slot', () async {
    final a = hub.fetch(latest());
    final b = hub.fetch(latest());
    source.pending.single.completeError(StateError('offline'));
    await expectLater(a, throwsStateError);
    await expectLater(b, throwsStateError);
    unawaited(hub.fetch(latest()));
    expect(source.requests, hasLength(2));
    source.pending.last.complete(const PageResult(items: []));
  });

  test('a source that throws synchronously is a failed fetch', () async {
    final throwing = MessageListHub<Msg>(
      source: _ThrowingSource(),
      adapter: const MsgAdapter(),
    );
    await expectLater(throwing.fetch(latest()), throwsUnsupportedError);
  });

  test('events reach attached lists only; stream errors are reported', () {
    fakeAsync((async) {
      expect(hub.apply(const MessagesAdded(chat, [Msg(10)])).isEmpty, isTrue);
      final store = hub.attach(chat);
      source.events_.add(const MessagesAdded(chat, [Msg(10)]));
      source.events_.addError(StateError('socket'));
      async.flushMicrotasks();
      expect(store.contains('m10'), isTrue);
      expect(errors.single, isStateError);
      expect(hub.apply(const MessagesDeleted<Msg>(chat, ['m10'])).removed,
          hasLength(1));
    });
  });

  test('one subscription per list, released after the delay', () {
    fakeAsync((async) {
      hub.attach(chat);
      hub.attach(chat);
      expect(source.subscriptions, 1);
      expect(hub.attachedLists, [chat]);
      hub.detach(chat);
      expect(hub.attachedLists, [chat]);
      hub.detach(chat);
      hub.detach(chat); // more detaches than attaches are ignored
      expect(hub.attachedLists, isEmpty);
      async.elapse(const Duration(seconds: 29));
      expect(source.cancellations, 0);
      hub.attach(chat); // back in time: the subscription is kept
      async.elapse(const Duration(seconds: 60));
      expect(source.cancellations, 0);
      hub.detach(chat);
      async.elapse(const Duration(seconds: 31));
      expect(source.cancellations, greaterThan(0));
      hub.attach(chat);
      expect(source.subscriptions, 2);
    });
  });

  test('trim keeps what controllers show; lists are evicted by use', () async {
    final store = hub.attach(chat);
    final future = hub.fetch(latest());
    source.pending.single.complete(
      PageResult(items: [for (var i = 1; i <= 20; i++) Msg(i * 10)]),
    );
    await future;
    final a = Object();
    final b = Object();
    hub.protect(chat, a, KeyRange(k(30), k(50)));
    hub.protect(chat, b, KeyRange(k(170), k(180)));
    hub.protect(const ListId('unknown'), a, KeyRange(k(1), k(2)));
    // Both windows stay, and so does what lies between them: a segment is
    // never split.
    expect(orders(hub.trim(chat).evicted), unorderedEquals([10, 20, 190, 200]));
    expect(orders(store.keys), [for (var o = 30; o <= 180; o += 10) o]);
    hub.protect(chat, b, null);
    expect(orders(store.keys).length - hub.trim(chat).evicted.length, 5);
    expect(orders(store.keys), [30, 40, 50, 60, 70]);
    hub.detach(chat, owner: a);
    expect(hub.trim(chat).isEmpty, isTrue, reason: 'already at the limit');
    expect(hub.trim(const ListId('unknown')).isEmpty, isTrue);

    hub.attach(const ListId('b'));
    hub.attach(const ListId('c'));
    expect(hub.store.lists.length, 3, reason: 'attached lists are kept');
  });

  test('markRead goes to the source', () async {
    await hub.markRead(chat, k(10));
    expect(source.read, [k(10)]);
  });

  test('dispose cancels everything and ignores what comes later', () async {
    hub.attach(chat);
    final future = hub.fetch(latest());
    hub
      ..dispose()
      ..dispose();
    expect(hub.isDisposed, isTrue);
    expect(source.requests.single.cancel.isCancelled, isTrue);
    source.pending.single.complete(const PageResult(items: [Msg(10)]));
    expect((await future).applied, isFalse);
    expect(hub.apply(const MessagesAdded(chat, [Msg(20)])).isEmpty, isTrue);
    hub.detach(chat);
    expect(hub.attachedLists, isEmpty);
  });

  test('the in-memory viewport store keeps the latest snapshot', () {
    final store = InMemoryViewportStore();
    expect(store.load(chat), isNull);
    final snapshot = ViewportSnapshot(
      anchorKey: k(10),
      anchorOffset: 0,
      offsetFromBottom: 0,
      visibleKeys: [k(10)],
      connectedToNewest: true,
      viewportWidth: 400,
      savedAt: DateTime.utc(2026),
    );
    store.save(chat, snapshot);
    expect(identical(store.load(chat), snapshot), isTrue);
    expect('$snapshot', contains('live: true'));
  });
}

class _ThrowingSource implements MessageSource<Msg> {
  @override
  Future<PageResult<Msg>> fetch(PageRequest request) =>
      throw UnsupportedError('no network in this build');

  @override
  Stream<ListEvent<Msg>> events(ListId list) => const Stream.empty();

  @override
  Future<void> markRead(ListId list, MessageKey upTo) async {}
}
