# steady_chat_list

A Flutter package that gives any chat app a Telegram-grade message list: it opens at the right place, pages unlimited history with a fixed number of widgets, and never jumps under the reader's eyes.

**Status: in development** (not on pub.dev yet). Built so far: the core store, the controller, the no-jump view, the simple one-widget API, jumps with search navigation, optimistic sending and animated deletes. Next: selection and theming, the offline cache and the example app. Design decisions are in [DECISIONS.md](DECISIONS.md).

It is made for conversations: chats, group chats, threads and comments, support chat inside any app, AI assistant chats, activity feeds. For product grids or settings lists use a plain `ListView`.

## Quick start

Tell the list how to read your message class, then pick where the messages come from.

```dart
final adapter = MessageAdapter<ChatMessage>.from(
  key: (m) => MessageKey(order: m.sentAt.microsecondsSinceEpoch, id: m.id),
  date: (m) => m.sentAt,
  isOutgoing: (m) => m.authorId == myId,
);
```

**You have the messages in a list** (local chats, AI assistants, small conversations). Rebuild with the changed list and the view follows; nothing on screen jumps.

```dart
SteadyChatList<ChatMessage>.list(
  messages: messages,
  adapter: adapter,
  itemBuilder: (context, message, info) => MessageBubble(message),
)
```

**A reactive query delivers the whole conversation** (Drift `watch()`, Firestore `snapshots()`, Supabase realtime):

```dart
SteadyChatList<ChatMessage>.stream(
  stream: db.watchMessages(chatId),
  adapter: adapter,
  itemBuilder: (context, message, info) => MessageBubble(message),
)
```

**A paged backend** (REST, WebSocket, GraphQL…) for histories of any size. Implement three methods:

```dart
class MyBackend implements MessageSource<ChatMessage> {
  @override
  Future<PageResult<ChatMessage>> fetch(PageRequest request) async {
    final rows = await api.history(
      chat: request.list.chatId,
      direction: request.direction.name, // older | newer | around | latest
      anchor: request.anchor?.id,
      limit: request.limit,
    );
    return PageResult(items: rows);
  }

  @override
  Stream<ListEvent<ChatMessage>> events(ListId list) => socket.eventsOf(list);

  @override
  Future<void> markRead(ListId list, MessageKey upTo) =>
      api.markRead(list.chatId, upTo.id);
}

SteadyChatList<ChatMessage>.source(
  source: MyBackend(),
  adapter: adapter,
  list: ListId(chat.id),
  itemBuilder: (context, message, info) => MessageBubble(message),
)
```

What you get in all three modes: the list opens at the saved position, the first unread message or the bottom; it pages in both directions with at most 80 built items; it stays pinned to the bottom for new messages, the keyboard and a growing reply; nothing moves when messages are inserted, edited, deleted or resized; the unread counter and read receipts are tracked; loading, empty and error states have defaults.

### More control

`SteadyChatList` creates a `MessageListHub` (data, shared by lists) and a `MessageListController` (one list) for you; `onController` hands you the controller. Apps that show the same chat twice, keep chats in memory while switching, or share a cache create them once and use `MessageListView`:

```dart
final hub = MessageListHub<ChatMessage>(source: MyBackend(), adapter: adapter);
final controller = MessageListController<ChatMessage>(
  hub: hub,
  list: ListId(chat.id),
  callbacks: MessageListCallbacks(
    onUnreadChanged: (list, count) => badges.set(list.chatId, count),
  ),
)..open();

MessageListView<ChatMessage>(
  controller: controller,
  itemBuilder: (context, message, info) => MessageBubble(
    message,
    showAvatar: info.isLastInGroup,
  ),
  dayHeaderBuilder: (context, day, onTap) => DayChip(day, onTap: onTap),
  footerBuilder: (context) => TypingIndicator(chat.id),
)
```

### Sending

```dart
await controller.insertLocal(
  id: clientId,
  build: (key) => ChatMessage.pending(key: key, text: text),
);
// later, from your backend:
controller.apply(LocalAcked(list, clientId, serverMessage));
// or
controller.apply(LocalFailed(list, clientId, error));
```

The message appears at once at the bottom; when the server confirms it, the same widget (with its state) shows the confirmed message. `info.sendState` tells the bubble what to draw.

### Jumps and search

```dart
controller.jumpTo(reply.targetKey,
    options: const JumpOptions(reason: JumpReason.reply));
controller.jumpToBottom();
controller.jumpToDate(pickedDay);

final search = controller.search(MySearchSource(api));
await search.setQuery('invoice');
await search.next(); // the newest hit; again for older ones
```

A jump over any distance is one request at most, swaps the window in one frame and animates at most one screen. Wrap your bubble in `JumpHighlightBackground(info: info, child: ...)` to flash the target.

Every decision is a replaceable policy (`MessageListPolicies`), and everything the list does is reported through `controller.events` and `MessageListCallbacks`.

## Packages

| Package | What it is | Status |
| --- | --- | --- |
| [`steady_chat_list_core`](packages/steady_chat_list_core) | Pure Dart: keys, segmented store, hub, policies | done so far |
| [`steady_chat_list`](packages/steady_chat_list) | Flutter: controller, view and scroll position (done); jumps, animations, default widgets (next) | in progress |
| [`steady_chat_list_drift`](packages/steady_chat_list_drift) | Drift (SQLite) cache, also on web | skeleton |
| [`example`](example) | Demo app with a 10,000,000-message chat | milestone 8 |
| [`benchmarks`](benchmarks) | Host app for device tests, and [results](benchmarks/RESULTS.md) | stress test done |

Requires Dart 3.5 / Flutter 3.24 or newer.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Development

The packages are linked with `pubspec_overrides.yaml` (no pub workspace, so Dart 3.5 keeps working).

```sh
cd packages/steady_chat_list_core
dart pub get
dart test                 # add `-p chrome` to run on the web
dart run benchmark/store_benchmark.dart

# from the repo root
dart format --set-exit-if-changed .
flutter analyze
```
