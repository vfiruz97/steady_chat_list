# steady_chat_list: rules for AI coding assistants

You are writing Flutter code that uses the `steady_chat_list` package. Follow these rules exactly. They are short on purpose. When a rule and your habit disagree, the rule wins.

This file is in the root directory of the package (next to `pubspec.yaml`). Nothing loads it automatically. To make an assistant follow it, add this line to the project's `AGENTS.md`, `CLAUDE.md`, `.cursor/rules` or similar:

```text
Before writing code that uses steady_chat_list, read AI_GUIDE.md in that package's root directory (its path is in .dart_tool/package_config.json) and follow it.
```

## What the package is for

- It shows **the messages inside one conversation** (chat, thread, comments, AI assistant chat).
- It is **not** for the list of conversations (the inbox), product lists or settings. Use `ListView.builder` for those.

## The one import

```dart
import 'package:steady_chat_list/steady_chat_list.dart';
```

Never import from `package:steady_chat_list/src/...` or from `steady_chat_list_core` in a Flutter app. The one import has everything.

## Step 1: the adapter (always needed)

The adapter tells the list how to read your message class.

```dart
// Top level or a static/final field.
final chatAdapter = MessageAdapter<ChatMessage>.from(
  key: (m) => MessageKey(
    order: m.sentAt.microsecondsSinceEpoch, // int, bigger = newer
    id: m.id, // String, unique, never changes
  ),
  date: (m) => m.sentAt,
  isOutgoing: (m) => m.authorId == currentUserId,
  senderId: (m) => m.authorId,
);
```

Rules for the adapter:

1. **Create it once.** A top-level `final`, a `static final`, or a field of a `State`. (`SteadyChatList` tolerates an adapter written inline in `build()`, but a `MessageListHub` you create yourself needs one fixed adapter.)
2. **`id` must be unique and must never change** for a message. Use the server id. Do not use the list index. Do not use the text.
3. **`order` is an `int` that sorts messages oldest to newest.** A timestamp in microseconds or a server sequence number. It must not change for a message, except when a pending message gets confirmed.
4. **`id` is a `String`.** If your id is an int, write `id: '${m.id}'`.

## Step 2: pick ONE of three modes

Ask: where do the messages come from?

| You have | Use |
| --- | --- |
| A `List<ChatMessage>` in memory (state, bloc, provider) | `SteadyChatList.list` |
| A `Stream<List<ChatMessage>>` with the whole conversation each time (Firestore `snapshots()`, Drift `watch()`, Supabase) | `SteadyChatList.stream` |
| A backend you ask for pages (REST, GraphQL, WebSocket) | `SteadyChatList.source` |

Do not mix modes. Do not wrap one mode in another.

### Mode A: a list

```dart
SteadyChatList<ChatMessage>.list(
  messages: messages, // any order; the list sorts by key
  adapter: chatAdapter,
  itemBuilder: (context, message, info) => MessageBubble(message: message),
)
```

To add, change or remove a message: change your list and rebuild (`setState`, bloc emit…). That is all. Do not call any method of the package for that.

### Mode B: a stream

```dart
class ChatScreen extends StatefulWidget { /* ... */ }

class _ChatScreenState extends State<ChatScreen> {
  // Created ONCE. Not inside build().
  late final Stream<List<ChatMessage>> _messages =
      repository.watchMessages(widget.chatId);

  @override
  Widget build(BuildContext context) => SteadyChatList<ChatMessage>.stream(
        stream: _messages,
        adapter: chatAdapter,
        itemBuilder: (context, message, info) => MessageBubble(message: message),
      );
}
```

The stream must be the **same object** on every rebuild. `stream: repository.watchMessages(id)` written inside `build()` creates a new stream each time and resets the list. Store it in a field.

### Mode C: a paged backend

Implement three methods:

```dart
class ChatBackend implements MessageSource<ChatMessage> {
  @override
  Future<PageResult<ChatMessage>> fetch(PageRequest request) async {
    // request.direction is one of:
    //   PageDirection.latest  -> the newest `limit` messages
    //   PageDirection.older   -> `limit` messages BEFORE request.anchor
    //   PageDirection.newer   -> `limit` messages AFTER request.anchor
    //   PageDirection.around  -> limit/2 before and after request.anchor,
    //                            including the anchor message itself
    final rows = await api.messages(
      chatId: request.list.chatId,
      direction: request.direction.name,
      anchorId: request.anchor?.id,
      limit: request.limit,
    );
    return PageResult(
      items: rows,
      // Set these when you KNOW there is nothing further. An `older` page
      // with fewer than `limit` messages is also read as the start of the
      // history, so return a full page unless the history ends there. If
      // your server returns the anchor message too, ask it for one more.
      reachedOldest: rows.isEmpty && request.direction == PageDirection.older,
      reachedNewest: request.direction == PageDirection.latest,
    );
  }

  @override
  Stream<ListEvent<ChatMessage>> events(ListId list) =>
      socket.messagesOf(list.chatId).map(
            (event) => switch (event) {
              NewMessage(:final message) => MessagesAdded(list, [message]),
              EditedMessage(:final message) => MessagesUpdated(list, [message]),
              DeletedMessage(:final id) =>
                MessagesDeleted<ChatMessage>(list, [id]),
            },
          );

  @override
  Future<void> markRead(ListId list, MessageKey upTo) =>
      api.markRead(chatId: list.chatId, messageId: upTo.id);
}
```

```dart
// Created ONCE (a field, a provider). Not inside build().
final backend = ChatBackend();

SteadyChatList<ChatMessage>.source(
  source: backend,
  adapter: chatAdapter,
  list: ListId(chatId),
  itemBuilder: (context, message, info) => MessageBubble(message: message),
)
```

Rules for `fetch`:

5. Return the messages of **one contiguous page**: no gaps inside it. The order inside `items` does not matter.
6. `older` and `newer` must **not** include the anchor message. `around` must include it (if it still exists).
7. If there are no events to send, return `const Stream.empty()` from `events`. Never return `null`, never throw.
8. Throw from `fetch` when the request fails. The list shows a retry state and retries by itself. Do not return an empty page for an error.

## Layout rules

9. **Give the list a bounded height.** Inside a `Column`, wrap it in `Expanded`. It is a scroll view.

```dart
Column(
  children: [
    Expanded(child: SteadyChatList<ChatMessage>.list(/* ... */)),
    MessageComposer(),
  ],
)
```

10. **Never put it inside** `ListView`, `SingleChildScrollView`, `CustomScrollView` or another scrollable.
11. **Never use `reverse: true`**, never sort or reverse the messages yourself, never add your own `ScrollController`. The list opens at the bottom and handles its own scrolling.
12. **Do not build day separators, "unread" lines or a scroll-to-bottom button by hand.** Use `dayHeaderBuilder`, `unreadDividerBuilder` and the built-in button:

```dart
dayHeaderBuilder: (context, day, onTap) => DayHeader(day: day, onTap: onTap),
```

13. **Images and videos need a size before they load.** Wrap them in `AspectRatio` (or a `SizedBox`) using the width and height your backend sends. A row that grows after loading makes the screen visibly shift.

## Message objects

14. **Treat messages as immutable.** To change a message, create a new object (`copyWith`) and hand it to the list (new list, new stream snapshot, or an event). Changing a field of the existing object in place does nothing on screen.
15. **A row rebuilds only when the message is not equal to the old one.** Either implement `==`/`hashCode` on your message class (or use `freezed`/`equatable`), or pass `equals:` to the adapter:

```dart
equals: (a, b) => a.text == b.text && a.editedAt == b.editedAt,
```

## The item builder

`itemBuilder` gets `(context, message, info)`. Use `info` instead of computing things yourself:

| Need | Use |
| --- | --- |
| Show the avatar / name only once per group | `info.isFirstInGroup`, `info.isLastInGroup` |
| Sending spinner, sent, failed | `info.sendState` (`SendState.sending`, `.sent`, `.failed`, `.none`) |
| Is it a not-yet-confirmed message | `info.isLocal` |
| The message's key | `info.key` |

16. Do not look at neighbouring messages by index to decide grouping. There is no index. Use `info`.
17. Do not give item widgets a `GlobalKey`. Do not wrap them in your own `KeyedSubtree`. The list keys them.

## Getting the controller

Modes A–C create a controller for you. Take it with `onController` and keep it in a field:

```dart
MessageListController<ChatMessage>? _controller;

SteadyChatList<ChatMessage>.source(
  // ...
  onController: (controller) => _controller = controller,
)
```

18. Do not create a `MessageListController` yourself when you use `SteadyChatList`. Do not dispose the one you get from `onController`; the widget owns it.

Things the controller does:

```dart
_controller?.jumpToBottom();
_controller?.jumpTo(message.replyToKey); // a MessageKey
_controller?.jumpToDate(DateTime(2026, 3, 14));
_controller?.unreadCount; // ValueListenable<int>
_controller?.isAtBottom; // ValueListenable<bool>
```

19. `jumpTo` takes a `MessageKey`, not an index and not an id string. Build the key the same way the adapter does: `MessageKey(order: ..., id: ...)`.

## Sending a message

**Mode A and B:** add the message to your list / database with a temporary id. When the server answers, replace it. Nothing else.

**Mode C** (paged backend): show it at once, then confirm it.

```dart
Future<void> send(String text) async {
  final controller = _controller;
  if (controller == null) return;
  final localId = 'local-${DateTime.now().microsecondsSinceEpoch}';
  // 1. It appears at the bottom immediately.
  await controller.insertLocal(
    id: localId,
    build: (key) => ChatMessage.pending(
      id: key.id, // MUST be key.id
      order: key.order, // MUST come from the key you are given
      localSeq: key.localSeq,
      text: text,
    ),
  );
  try {
    final saved = await api.send(chatId, text);
    // 2. The server's message replaces the pending one. Same row, no flicker.
    controller.apply(LocalAcked(controller.list, localId, saved));
  } catch (error) {
    // 3. Or mark it failed; the bubble gets SendState.failed.
    controller.apply(LocalFailed<ChatMessage>(controller.list, localId, error));
  }
}
```

20. For a pending message the adapter's `key` must return **the key `insertLocal` gave you**, including `localSeq`. Store `order`, `id` and `localSeq` on the pending message and return `MessageKey(order: m.order, id: m.id, localSeq: m.localSeq)`. Confirmed messages have `localSeq` 0 (the default).
21. Do not also add the confirmed message with `MessagesAdded`. `LocalAcked` already does it. Adding it twice shows it twice.
22. If your socket also delivers your own sent message as a "new message" event, drop that event (compare ids) or the message appears twice.

## Changing messages from code (Mode C)

```dart
controller.upsert([message]); // add or replace
controller.patch(message.id, (m) => m.copyWith(text: 'edited'));
controller.remove([message.id]); // animated
```

In Mode A and B do **not** use these. Change your list or your database.

## Read receipts and unread

- The list calls `markRead` (Mode C) or `onMarkRead` (Mode A/B) when the reader has seen messages. Send that to your server there. Do not track visibility yourself.
- To show the "unread messages" line and counter, give the read state: `PageResult(readState: ReadState(lastReadInbox: key, unreadCount: n))` in Mode C, or `readState:` on `SteadyChatList.list`.

## Remembering the scroll position

```dart
final positions = await SharedPreferencesViewportStore.create(); // once, at app start

SteadyChatList<ChatMessage>.source(
  // ...
  viewportStore: positions,
)
```

23. Do not save or restore scroll offsets yourself.

## Several chats

24. One `ListId` per conversation: `ListId(chatId)`, or `ListId(chatId, threadId)` for a thread. When the user opens another chat, pass the new `list:`. Do not reuse one `ListId` for different chats.

## Mistakes to check before you finish

Go through this list. Each line is a bug an assistant has written.

- [ ] Stream or source created inside `build()` (it restarts the list on every rebuild).
- [ ] The list is inside a `Column` without `Expanded`, or inside another scrollable.
- [ ] `reverse: true`, a manual sort, or a `ScrollController` was added.
- [ ] Message ids come from the list index, or change after an edit.
- [ ] A message was mutated in place instead of replaced.
- [ ] No `==` on the message class and no `equals:` on the adapter, so edits never show (or everything rebuilds).
- [ ] Images without a fixed aspect ratio.
- [ ] Hand-made date headers or scroll-to-bottom button next to the built-in ones.
- [ ] `LocalAcked` **and** `MessagesAdded` for the same sent message.
- [ ] `fetch` returns an empty page on an error instead of throwing.
- [ ] `reachedOldest` / `reachedNewest` set to true without knowing it (history stops loading), or never set (the spinner at the top never goes away).
- [ ] An import from `src/`.

## When you need more

The full guide, with caching, search, selection, theming and events: the package `README.md`. A complete app: the `example/` folder of the repository. Read those before inventing an API; if a method is not in the README or in the library's dartdoc, it does not exist.
