# steady_chat_list_drift

An offline cache for [`steady_chat_list`](https://pub.dev/packages/steady_chat_list) in SQLite, built on [drift](https://pub.dev/packages/drift). Chats open at once, also without a network, at the position the reader left, on every platform including the web.

```dart
import 'package:drift_flutter/drift_flutter.dart';
import 'package:steady_chat_list/steady_chat_list.dart';
import 'package:steady_chat_list_drift/steady_chat_list_drift.dart';

final hub = MessageListHub<ChatMessage>(
  source: MyBackend(),
  adapter: adapter,
  cache: DriftMessageCache(
    SteadyCacheDatabase(driftDatabase(name: 'chat_cache')),
    adapter: adapter,
    codec: JsonMessageCodec(ChatMessage.fromJson, (m) => m.toJson()),
  ),
);

// Optional: read a chat before its screen is built, so that the very
// first frame already shows it.
await hub.hydrate(ListId(chat.id));
```

- **No code generation.** The schema is plain SQL inside the package; it works with every drift 2.x release.
- **You choose the executor**: `drift_flutter` in Flutter apps (follow its [web setup](https://drift.simonbinder.eu/platforms/web/) to add `sqlite3.wasm` and `drift_worker.js`), `NativeDatabase` in Dart programs and tests. The database must be used only for this cache.
- **Bounded size.** By default the newest 500 messages of each chat and the messages around the saved position are kept; chats not opened for 30 days are dropped (`EvictionPolicy`).
- **Several browser tabs** sharing the database see each other's changes.
- Messages are stored with a `MessageCodec`; `JsonMessageCodec` takes your `fromJson` / `toJson`.

A cache can always be refilled from your backend, so a database with an unknown layout is rebuilt instead of migrated.

Requires Dart 3.5 or newer.
