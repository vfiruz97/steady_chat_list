# steady_chat_list

A Flutter package that gives any chat app a steady message list: it opens at the right place, pages unlimited history with a fixed number of widgets, and never jumps under the reader's eyes.

**Status: `0.1.0`**, the first release. Everything described here is implemented and tested; the API may still change before 1.0. The [example app](https://github.com/vfiruz97/steady_chat_list/tree/main/example) shows every feature, and the design decisions are in [DECISIONS.md](https://github.com/vfiruz97/steady_chat_list/blob/main/DECISIONS.md).

It is made for conversations: chats, group chats, threads and comments, support chat inside any app, AI assistant chats, activity feeds. For product grids or settings lists use a plain `ListView`.

## Quick start

Add the package:

```sh
flutter pub add steady_chat_list
```

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

### Offline cache and saved position

```dart
final hub = MessageListHub<ChatMessage>(
  source: MyBackend(),
  adapter: adapter,
  // Chats open at once and work offline:
  cache: DriftMessageCache(
    SteadyCacheDatabase(driftDatabase(name: 'chat_cache')), // drift_flutter
    adapter: adapter,
    codec: JsonMessageCodec(ChatMessage.fromJson, (m) => m.toJson()),
  ),
);
```

Without a cache, `viewportStore: await SharedPreferencesViewportStore.create()` is enough to reopen a chat where the reader left it, also after a browser reload. After a reconnect call `controller.invalidate()`: what is on screen is refreshed without moving.

### Reacting to what the list does

Every decision is a replaceable policy (`MessageListPolicies`), and everything the list does is reported twice: as callbacks (`MessageListCallbacks`) and as a stream.

```dart
controller.events.listen((event) {
  switch (event) {
    case ReadUpTo(:final key): api.markRead(chat.id, key.id);
    case UnreadChanged(:final count): badges.set(chat.id, count);
    case MessagesSeen(:final keys): analytics.seen(keys);
    case PageFailed(:final error): log.warning('page failed', error);
    default:
  }
});
```

State you build UI from is exposed as `ValueListenable`s: `unreadCount`, `isAtBottom`, `showScrollDownButton`, `olderEdge` / `newerEdge`, `topVisibleDay`, `currentPinned`, `typingUserIds`, `jumpInProgress`, `selection`.

### Ready-made widgets

All optional and themed with `MessageListTheme` (no Material dependency): `MessageListButtons` (scroll down, next mention, next reaction, with badges), `DayHeader`, `UnreadDivider`, `SwipeToReply`, `JumpHighlightBackground`, default loading, empty and error states.

### Two rules for your item widgets

1. **Give media a size before it loads** (an `AspectRatio` from the dimensions your backend sends). The list keeps the viewport still when a row changes height, but a row that is on screen visibly grows.
2. **Change a message by sending a new object** (`controller.patch`, an event, or a new list). Only the changed rows rebuild.

### Using an AI coding assistant

[AI_GUIDE.md](https://github.com/vfiruz97/steady_chat_list/blob/main/packages/steady_chat_list/AI_GUIDE.md) is a short rule list for assistants that write code with this package: which mode to pick, layout rules, sending, and a checklist of the usual mistakes. It ships inside the package, but no assistant reads a dependency's files on its own. Add one line to your project's `AGENTS.md`, `CLAUDE.md` or editor rules:

```text
Before writing code that uses steady_chat_list, read AI_GUIDE.md in that package's root directory (its path is in .dart_tool/package_config.json) and follow it.
```

### Debugging

`MessageListView(debugOverlay: true)` draws the anchor line and the state of the window in debug builds; `controller.debugDescribe()` returns the same as text for bug reports.

## Example app

```sh
cd example
flutter run -d chrome        # or macos, an Android or iOS device
```

A menu on the left lists the demos; each has a line that says what it shows: the three simple modes, an AI reply that streams in, a chat with 10,000,000 messages, a group chat with every feature, search navigation, a control panel for the simulated server (latency, failures, storms, remote deletes and edits, lost connection), the offline cache (in memory or SQLite, also in the browser), split view, the event log and theming. Scroll anywhere and reload the browser tab: you are back at the same message, at the same pixel.

## Performance

Measured by the [benchmarks](https://github.com/vfiruz97/steady_chat_list/blob/main/benchmarks/RESULTS.md) in profile mode. On a desktop: a fling through 5,000 messages builds frames in 2 ms (95th percentile); 50 incoming messages per second or 200 reaction updates per second drop no frames; a jump across a million messages is one request; memory stays flat however far you scroll (1,000 messages per chat are kept, 80 rows are built).

## Related packages

- [`steady_chat_list_core`](https://pub.dev/packages/steady_chat_list_core): the pure Dart part (exported by this package).
- [`steady_chat_list_drift`](https://github.com/vfiruz97/steady_chat_list/tree/main/packages/steady_chat_list_drift): an optional SQLite cache. Not on pub.dev yet; add it as a git dependency.

Requires Dart 3.5 / Flutter 3.24 or newer. Android, iOS, web, macOS, Windows and Linux.
