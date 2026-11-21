# steady_chat_list_core

The pure Dart part of [`steady_chat_list`](https://pub.dev/packages/steady_chat_list): no Flutter, usable in tests, servers and isolates. Flutter apps depend on `steady_chat_list`, which exports everything here.

What is inside:

- `MessageKey` and `MessageAdapter`: how the list reads your message class.
- `MessageSource`, `PageRequest`, `PageResult`, `ListEvent`: the contract with your backend, plus `ListMessageSource` and `StreamMessageSource` for apps that simply have the messages.
- `ListStore`: sorted messages with *segments*, the runs of history that pages have proven to be gap-free. The store never guesses that two messages are neighbors.
- `MessageListHub`: one per app; shares stores between controllers, runs one fetch per direction, trims memory, writes through to a `MessageCache`.
- Policies (`OpenPolicy`, `WindowPolicy`, `ReadPolicy`, `RetryPolicy`, …) and the jump model.
- `MessageCache` with `InMemoryMessageCache`; the SQLite cache is [`steady_chat_list_drift`](https://github.com/vfiruz97/steady_chat_list/tree/main/packages/steady_chat_list_drift) (not on pub.dev yet).

```dart
final hub = MessageListHub<Message>(source: backend, adapter: adapter);
final store = hub.attach(const ListId('chat-1'));
await hub.fetch(
  const PageRequest(
    list: ListId('chat-1'),
    direction: PageDirection.latest,
    limit: 40,
  ),
);
print(store.liveSegment); // the run that reaches the newest message
```

Requires Dart 3.5 or newer.
