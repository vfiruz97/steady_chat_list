import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'fake_chat_server.dart';

const chat = ListId('chat');
const other = ListId('other');

class Env {
  Env(
    this.async, {
    int count = 1000,
    int outgoingEvery = 0,
    this.viewportStore,
    Msg Function(Msg message)? decorate,
  }) : server = FakeChatServer(
          count: count,
          outgoingEvery: outgoingEvery,
          decorate: decorate,
        ) {
    hub = newHub();
  }

  final FakeAsync async;
  final FakeChatServer server;
  final ViewportStore? viewportStore;
  late MessageListHub<Msg> hub;
  final List<MessageListEvent> events = [];

  /// A fresh hub on the same server = an app restart.
  MessageListHub<Msg> newHub() => MessageListHub<Msg>(
        source: server,
        adapter: const MsgAdapter(),
        viewportStore: viewportStore,
        clock: () => async.getClock(DateTime.utc(2026, 11, 20)).now(),
      );

  MessageListController<Msg> controller({
    ListId list = chat,
    MessageListConfig config = const MessageListConfig(),
    MessageListCallbacks<Msg> callbacks = const MessageListCallbacks(),
    MessageListPolicies<Msg> policies = const MessageListPolicies(),
  }) {
    final controller = MessageListController<Msg>(
      hub: hub,
      list: list,
      config: config,
      callbacks: callbacks,
      policies: policies,
      // A "frame": runs after every microtask of the current turn.
      scheduler: Timer.run,
    );
    controller.events.listen(events.add);
    return controller;
  }

  void settle([Duration time = const Duration(seconds: 1)]) {
    async.flushMicrotasks();
    async.elapse(time);
    async.flushMicrotasks();
  }

  Iterable<T> eventsOf<T extends MessageListEvent>() => events.whereType<T>();
}

void run(void Function(Env env) body, {Env Function(FakeAsync)? env}) {
  fakeAsync((async) => body(env?.call(async) ?? Env(async)));
}

ViewportSnapshot snapshotAt(int order,
        {required bool live, double offset = 0}) =>
    ViewportSnapshot(
      anchorKey: k(order),
      anchorOffset: offset,
      offsetFromBottom: 5000,
      visibleKeys: [k(order), k(order + 10)],
      connectedToNewest: live,
      viewportWidth: 400,
      savedAt: DateTime.utc(2026, 11, 19),
    );
