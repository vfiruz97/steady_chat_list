# `steady_chat_list` — Full Specification

A Flutter package that gives any chat app a Telegram-grade message list on iOS, Android, Web, macOS, Windows and Linux. Features:

- Opens a chat instantly at the right place.
- Pages through unlimited history with a small, fixed number of built widgets.
- Never jumps under the reader's eyes.
- Jumps anywhere (search, reply, pinned message, date, mention, bottom) in under half a second.
- Supports every interaction a large chat app needs (reactions, selection, typing indicator, media autoplay, threads).
- Optionally caches everything in a local database.

This document is the complete brief for an AI coding agent. **MUST** = required, with an acceptance test. **SHOULD** = strong default. **MAY** = optional. Section numbers are referenced by `PROMPT.md`, `DECISIONS.md` and the tests.

---

## 0. Instructions for the agent

1. Read the whole spec before writing code. Re-read the relevant sections before each milestone (§20).
2. Tests first for every algorithm in §7–§12; widget tests for every acceptance criterion in §18.
3. Core logic has no Flutter imports, so it can be unit-tested in milliseconds.
4. Only the dependencies in §4. Anything else needs a reason in `DECISIONS.md`.
5. Every public symbol has a dartdoc with a short example. Use `sealed`, `final class` and `@immutable`. No `dynamic`, no global singletons, no `late` without a reason.
6. When the spec is ambiguous, pick the Telegram behavior (§2) and record the choice in `DECISIONS.md`.
7. The spec is the source of truth. If you must deviate (Flutter limitation, performance), write it in `DECISIONS.md` and report it in the milestone summary.

---

## 1. Goals, non-goals, scale targets

**Goals**

- Backend-agnostic: REST, WebSocket, GraphQL, Firebase, Supabase, MTProto, XMPP or Matrix, all through one adapter (§8.1).
- Generic over the app's message class `M`. The package never inspects message content.
- Zero visible jumps when:
  - older or newer pages arrive;
  - messages are inserted, edited, deleted or get reactions;
  - media loads;
  - the keyboard opens, the composer grows or the window is resized.
- Opens at: the saved position → else the first unread → else the bottom (§10.1).
- Every decision is replaceable (policies), and every state change is observable (callbacks and events) (§13).
- Optional persistence (Drift/SQLite, also on web) that makes chats open instantly and work offline (§8.3).

**Non-goals** (the app builds these with the provided hooks): message bubbles, composer, networking, media players, the search UI, context menus, reaction pickers.

**Scale targets** (all MUST hold in the example app, §17)

| Dimension | Target |
| --- | --- |
| Messages in one chat | 10,000,000 (server side); unlimited scrolling |
| Chats open in memory | 10 (LRU), unlimited in DB |
| Built message widgets | ≤ `windowSize` (default 80) + cache extent |
| Frame time while flinging | p95 ≤ 8 ms build+layout on a mid-range Android; no frame > 32 ms |
| Open cached chat | first correct frame in the same frame the route builds |
| Jump anywhere (target cached) | ≤ 450 ms total, no blank frame |
| Jump anywhere (target remote, 150 ms latency) | ≤ 700 ms total, no blank frame |
| Incoming messages | 50/s sustained without dropped frames (batched per frame) |
| Reaction updates | 200/s sustained without dropped frames |

---

## 2. Reference behavior (measured in Telegram Web A, 2026-11-20)

Measured by inspecting web.telegram.org/a: DOM, IndexedDB and frame-by-frame scroll sampling. These numbers are the defaults.

| Area | Observed |
| --- | --- |
| Page size | 40. First page of an uncached chat: 20. |
| Window | ≤ 80 mounted. Reaching the top loads 40 older and unmounts 40 newer. Loaded-but-unmounted messages stay in memory. |
| Paging latency (cached) | ~60 ms |
| Prepend | The first visible message keeps its y position within ~2 px. Correction happens in the same frame. |
| Saved per chat | Visible ids + `scrollHeight − scrollTop` (distance from the bottom edge). Written to IndexedDB within a few seconds. |
| Restore after reload | The first painted frame is at the saved position. A saved position not connected to the newest message is discarded on reload (opens at the bottom instead). |
| Restore within a session | A chat left in an old island (January 2025, not connected to the newest message) reopened at that same island. |
| Re-select the open chat | Clicking the already-open chat in the chat list = jump to bottom (newest 18 swapped in, ~300 ms animation). |
| Unread open | Fetch *around* the last read message (14 before / 19 after in one test). The "Unread messages" divider sits 10 px below the top. |
| Read tracking | Messages count as read as they become visible. The badge on the scroll-down button counts down (18 → 16). |
| Go to bottom across a 7.2K gap | Window = [current anchor message + newest page]. The view starts about one screen from the bottom and animates the rest (~490 ms). It never scrolls through the gap. |
| Search jump (24K ids back) | One `around` fetch (18 + target + 19). Window swapped in one frame. The view starts ~680 px (< 1 viewport) from the target, then scrolls ~370 ms ease-out. The target ends centered (top-aligned if taller than the viewport). Background flash for ~1 s; the search term is highlighted in the text. |
| Send | Optimistic temporary id = last id + 0.000001 (then .000002…). Fade-in ~200 ms. List animates to the bottom (~350 ms). The server id replaces the temporary one in place after ~520 ms (no remount). Fast consecutive sends can be acknowledged out of order. |
| Incoming | At bottom: stays pinned, new item fades in. Scrolled up: position kept, badge +1. |
| Delete animation | The bubble and avatar fade to 0, scale to 0.3 and slide sideways (own messages right, incoming left), 200 ms ease-in. At ~250–300 ms the row is removed and the gap closes in one step (no height animation). Neighbors are re-rendered for grouping. |
| Delete, scrolled up, visible | Messages above stay still; messages below move up one row. |
| Delete above the viewport (from another device) | **Telegram does not compensate: every visible message jumps up by the row height. Our package MUST do better** (§11.2). |
| Delete while at bottom | Stays pinned to the bottom; messages above move down. |
| Batch delete | All rows animate together; one correction. |
| Remote delete | Same animation as a local delete. |
| Ids | Private chats: one counter per account shared across chats → gaps inside a chat. Channels: a counter per chat. **Contiguity can never be inferred from ids.** |
| Albums | Several ids, one row (grouped id). |
| Day headers | One group per calendar day ("November 13", "Yesterday", "Today"); sticky header; clicking it opens a calendar. |
| Floating buttons | Scroll to bottom (unread badge, e.g. 7.2K), next unread mention, next unread reaction, next unread poll vote. |

---

## 3. Feature checklist (what "big functional chat" means)

Owner: **P** = the package implements it; **H** = the package provides the hook and the app draws it.

| Feature | Owner | Section |
| --- | --- | --- |
| Windowed bidirectional paging, unlimited history | P | §10.2 |
| No-jump anchor correction (insert, delete, edit, media, keyboard, resize) | P | §11.2 |
| Open at saved position / first unread / bottom / message | P | §10.1 |
| Re-open the same chat in the session, re-select = jump to bottom | P | §10.1 |
| Position persistence across restarts | P | §10.9 |
| Unread divider, unread counter, read receipts | P (divider widget H) | §10.8 |
| Scroll-to-bottom button with badge; mentions and reactions buttons | P logic, H widget | §12.1 |
| Jump to message (search, reply, pinned, deep link, mention, reaction, date) | P | §10.4 |
| Async search navigation (next/previous, paging results) | P helper, H UI | §10.5 |
| Target alignment, scroll animation, highlight animation | P + H | §10.4 |
| Optimistic send, ack, failure, retry, out-of-order acks | P | §10.6 |
| Edits, reactions, status checks, view counters (in-place updates) | P | §10.7 |
| Delete (single, batch, remote, above/inside/below viewport) | P | §10.7 |
| Day grouping, sticky day header, floating day chip, jump to date | P + H | §12.2 |
| Sender grouping (first/last in group), albums | P | §6, §13.3 |
| Service messages (joined, pinned, date changes) | H (just another `M`) | §6 |
| Typing indicator / footer at the bottom | P slot, H widget | §12.3 |
| History start header (chat intro), "history cleared" state | P slot, H widget | §12.3 |
| Pinned messages bar support (current pinned by scroll position) | P | §10.10 |
| Selection mode (tap, long-press, range, shift-click, select all loaded) | P state, H visuals | §10.11 |
| Swipe-to-reply and other item gestures not fighting the scroll | P rules, H gesture | §11.6 |
| Item rect API (overlays: reaction effects, tooltips, context menus) | P | §13.4 |
| Visibility and dwell callbacks (media autoplay, view counters, "seen") | P | §10.12 |
| Prefetch hooks for media of the next page | P | §10.2 |
| Threads, topics, comments as separate lists sharing one store | P | §8.4 |
| Same list shown twice (split view, side panel) | P | §8.4 |
| Offline cache, instant open, eviction | P (Drift package) | §8.3 |
| Keyboard, composer growth, safe areas | P | §11.5 |
| Web/desktop: wheel, scrollbar, keys, text selection | P | §11.6 |
| Accessibility, RTL, text scale | P | §11.7 |
| Theming and default widgets | P | §12 |
| Debug overlay (window, segments, anchor) | P | §16 |

---

## 4. Package layout and dependencies

Dart pub workspace (or melos):

```
packages/
  steady_chat_list_core/     pure Dart: keys, store, segments, window, policies, search navigator logic
  steady_chat_list/          Flutter: controller, view, scroll position, default widgets, persistence glue
  steady_chat_list_drift/    Drift (SQLite) cache, works on mobile, desktop and web (sqlite3 WASM)
example/                      big-number demo app (§17)
benchmarks/                   integration performance tests
```

| Package | Allowed dependencies |
| --- | --- |
| core | `meta`, `collection` |
| flutter | core, `flutter`, `shared_preferences` (default viewport store), `intl` (default day labels) |
| drift | core, `drift`, `drift_flutter`, `sqlite3_flutter_libs` |
| dev | `flutter_test`, `test`, `mocktail`, `fake_async`, `integration_test`, `drift_dev`, `build_runner`, `flutter_lints` or `very_good_analysis` |

Dart ≥ 3.5, Flutter ≥ 3.24. Semantic versioning; public API documented and stable from 1.0.

---

## 5. Glossary

| Term | Meaning |
| --- | --- |
| List | One sequence of messages: a chat, a thread, a topic or a comment section. `ListId(chatId, threadId?)`. |
| Key | Sortable identity of a message (`MessageKey`). |
| Segment | Sorted run of keys proven contiguous by server responses. |
| Live segment | The segment containing the newest message of the list (`reachedNewest`). At most one. |
| Island | Any non-live segment (created by jumps). |
| Window | Keys currently built as widgets; a sub-range of one segment, ≤ `windowSize`. |
| Anchor | The item that keeps the screen still during changes, plus its offset from the viewport top. |
| Snapshot | Saved position of a list (§6). |
| Generation | Counter incremented on every open/jump; async results from older generations are dropped. |

---

## 6. Data model (core)

```dart
/// Sortable identity. Int server ids: order = id. String ids (UUID, Firestore): order = server time in µs.
@immutable
final class MessageKey implements Comparable<MessageKey> {
  const MessageKey({required this.order, required this.id, this.localSeq = 0});
  final int order;       // primary sort
  final String id;       // stable identity (server id or client id)
  final int localSeq;    // 0 = confirmed; 1, 2… = pending local messages after `order`
  bool get isLocal => localSeq > 0;
  @override
  int compareTo(MessageKey o) => order != o.order ? order.compareTo(o.order)
      : localSeq != o.localSeq ? localSeq.compareTo(o.localSeq) : id.compareTo(o.id);
  // == / hashCode use `id` only: identity survives the local → server re-key.
}

@immutable
final class ListId {
  const ListId(this.chatId, [this.threadId]);
  final String chatId;
  final String? threadId;
  String get storageKey => threadId == null ? chatId : '$chatId/$threadId';
}

/// How the package reads the app's message class. Only `keyOf` and `dateOf` are required.
abstract class MessageAdapter<M> {
  const MessageAdapter();
  MessageKey keyOf(M m);
  DateTime dateOf(M m);
  String? groupIdOf(M m) => null;      // albums: same group id → one row
  String? senderIdOf(M m) => null;     // sender grouping
  bool isOutgoing(M m) => false;       // never unread
  bool isService(M m) => false;        // service rows break sender groups, never "first unread"
  bool mentionsMe(M m) => false;       // drives mention navigation if the server doesn't
  bool equals(M a, M b) => a == b;     // rebuild only when false
}

@immutable
final class ReadState {
  final MessageKey? lastReadInbox;     // last incoming message read by me
  final MessageKey? lastReadOutbox;    // last outgoing message read by the peer (for checkmarks)
  final int unreadCount;
  final List<MessageKey> unreadMentions;
  final List<MessageKey> unreadReactions;
}

@immutable
final class Segment {
  final MessageKey first, last;        // inclusive
  final bool reachedOldest, reachedNewest;
}

@immutable
final class ViewportSnapshot {
  final MessageKey anchorKey;
  final double anchorOffset;           // px from viewport top to the anchor's top
  final double offsetFromBottom;       // scrollExtent − pixels (fallback)
  final List<MessageKey> visibleKeys;
  final bool connectedToNewest;        // window was in the live segment
  final double viewportWidth;          // detect layout changes
  final DateTime savedAt;
}
```

---

## 7. Store and segments (core)

`MessageStore<M>` holds per `ListId`: `SplayTreeMap<MessageKey, M> byKey`, `Map<String, MessageKey> keyById`, sorted `List<Segment>`, `ReadState`, a tombstone set `Map<String, DateTime>`, and pinned keys.

### 7.1 Applying a page

1. Upsert all items (by `id`; skip items whose id is tombstoned).
2. Proven range: `older`/`newer` → from the anchor to the farthest returned key; `around`/`latest` → first..last returned key (plus the anchor for `around`).
3. Flags:
   - `older` with fewer items than the limit, or `reachedOldest` → `reachedOldest`;
   - `latest` → `reachedNewest`;
   - `newer` with `reachedNewest` → `reachedNewest`.
4. Merge with every segment the range overlaps or touches; flags are unioned.
5. Invariants (asserted in debug):
   - at most one live segment;
   - segments are sorted and don't overlap;
   - every key in a segment's range that is in `byKey` belongs to it.

### 7.2 Events

| Event | Effect |
| --- | --- |
| Added | Upsert. If the live segment exists and the key is newer than its last → extend it. Older than the live segment's first (a late message) → insert only if inside a segment's range, else store as an orphan. No live segment → create a 1-key live segment. |
| Updated | Upsert by id; re-key if `order` changed (§10.6). Unknown id outside every segment → ignore. |
| Deleted | Remove; add a tombstone (kept 5 min). Move segment bounds to the neighbors; drop empty segments. |
| Read state | Replace; recompute the divider candidate. |
| History cleared up to key | Remove all keys ≤ key; segment from the next key gets `reachedOldest`. |

All event handling is idempotent and order-independent (a delete that arrives before its message wins thanks to tombstones).

### 7.3 Queries (O(log n + k))

`keysBefore(key, n)`, `keysAfter(key, n)`, `keysAround(key, before, after)` — only inside the segment of `key`. Also `segmentOf(key)`, `liveSegment`, `isContiguous(a, b)`, `nearestExisting(key, direction)`, `firstOnOrAfter(DateTime)` (within loaded data), and `nextUnreadMention(after)`.

### 7.4 Memory eviction

Per list keep ≤ `memoryLimitPerList` (default 1,000) messages, and keep ≤ `openListsInMemory` (default 10) lists (LRU). Never evict keys in the current window or the saved snapshot's window. Trim segments from the far end and clear the flag on the trimmed side.

---

## 8. Data sources, cache, sharing

### 8.1 Remote source (app implements)

```dart
enum PageDirection { older, newer, around, latest }

@immutable
final class PageRequest {
  final ListId list;
  final PageDirection direction;
  final MessageKey? anchor;            // null only for `latest`
  final DateTime? anchorDate;          // set for jump-to-date when no key is known
  final int limit;                     // `around`: ~half older, ~half newer
  final int generation;
  final CancellationToken cancel;      // the app SHOULD abort the HTTP call when cancelled
}

@immutable
final class PageResult<M> {
  final List<M> items;                 // any order
  final bool reachedOldest, reachedNewest;
  final ReadState? readState;          // optional piggy-back
}

sealed class ListEvent<M> { ListId get list; }
// MessagesAdded(items), MessagesUpdated(items), MessagesDeleted(ids), LocalAcked(localId, serverMessage),
// LocalFailed(localId, error), ReadStateChanged(state), PinnedChanged(keys), HistoryCleared(upTo),
// TypingChanged(userIds)

abstract interface class MessageSource<M> {
  Future<PageResult<M>> fetch(PageRequest request);
  Stream<ListEvent<M>> events(ListId list);                // may be Stream.empty(): see §13.5
  Future<void> markRead(ListId list, MessageKey upTo);
}

/// Optional, for async search (§10.5).
abstract interface class MessageSearchSource {
  Future<SearchPage> search(ListId list, String query, {String? cursor, int limit = 50});
}
@immutable final class SearchPage { final List<MessageKey> keys; final int? totalCount; final String? nextCursor; }
```

### 8.2 Cache interface

```dart
abstract interface class MessageCache<M> {
  Future<CachedList<M>?> load(ListId list, {int around = 100});  // segments, read state, snapshot, messages near the snapshot/newest
  Future<List<M>> range(ListId list, MessageKey from, PageDirection dir, int limit); // within a cached segment only
  Future<void> applyPage(PageRequest req, PageResult<M> res);
  Future<void> applyEvents(List<ListEvent<M>> events);           // batched
  Future<void> saveSnapshot(ListId list, ViewportSnapshot s);
  Future<void> evict(EvictionPolicy policy);
  Future<void> clear([ListId? list]);
  Stream<CacheChange> watch();                                   // other tabs/isolates wrote (web multi-tab)
}
```

`CachingMessageSource` wraps `MessageSource` + `MessageCache`:

1. Answer from the cache when the cached segment covers the request (`PageOrigin.cache`).
2. Then fetch remote, reconcile and emit the difference (`PageOrigin.remote`).
3. On reconnect, `invalidate()` refetches around the anchor (§13.5).

Implementations: `InMemoryMessageCache` (default) and `DriftMessageCache`.

### 8.3 Drift schema

```sql
CREATE TABLE messages (
  list_key TEXT NOT NULL, id TEXT NOT NULL,
  ord INTEGER NOT NULL, local_seq INTEGER NOT NULL DEFAULT 0,
  date_ms INTEGER NOT NULL, group_id TEXT, sender_id TEXT,
  is_outgoing INTEGER NOT NULL DEFAULT 0, mentions_me INTEGER NOT NULL DEFAULT 0,
  payload BLOB NOT NULL, version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (list_key, id)
);
CREATE INDEX messages_order ON messages (list_key, ord, local_seq, id);
CREATE INDEX messages_date  ON messages (list_key, date_ms);
CREATE TABLE segments  (list_key TEXT NOT NULL, first_ord INTEGER, first_id TEXT, last_ord INTEGER, last_id TEXT,
                        reached_oldest INTEGER NOT NULL, reached_newest INTEGER NOT NULL);
CREATE TABLE read_state (list_key TEXT PRIMARY KEY, json TEXT NOT NULL);
CREATE TABLE snapshots  (list_key TEXT PRIMARY KEY, json TEXT NOT NULL, saved_at INTEGER NOT NULL);
CREATE TABLE tombstones (list_key TEXT NOT NULL, id TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (list_key, id));
CREATE TABLE lists_meta (list_key TEXT PRIMARY KEY, last_opened_at INTEGER NOT NULL, approx_bytes INTEGER NOT NULL DEFAULT 0);
```

- `MessageCodec<M>` (app): `Uint8List encode(M)` and `M decode(Uint8List)`. Ship `JsonMessageCodec<M>`.
- One transaction per page or event batch. SQLite runs off the UI isolate (Drift background isolate; a web worker on web).
- Eviction (`EvictionPolicy`): per list keep the newest N (default 500) of the live segment, plus the snapshot window; lists unopened for 30 days are dropped; global cap 50,000 messages / 200 MB, LRU by `last_opened_at`.
- Schema migrations are versioned and tested with `drift_dev` schema dumps.
- Web multi-tab: changes are broadcast through `watch()` so two tabs stay consistent.

### 8.4 Sharing: `MessageListHub`

One `MessageListHub<M>` per app (passed in, not global). It owns the store, the source subscriptions and the cache for every list. Controllers are cheap views on it:

- Two controllers on the same `ListId` (split view, a thread in a side panel, a search preview) share data and events; each keeps its own window and position.
- A thread is a separate `ListId`; the hub routes events by list.
- One subscription to `source.events(list)` per list while any controller is attached; it is released 30 s after the last controller detaches.

---

## 9. Configuration

```dart
@immutable
class MessageListConfig {
  const MessageListConfig({
    this.pageSize = 40, this.firstOpenPageSize = 20, this.windowSize = 80,
    this.preloadExtent = 1500, this.cacheExtent = 800,
    this.stickToBottomThreshold = 24, this.scrollDownButtonThreshold = 1.0,
    this.unreadDividerTopInset = 10,
    this.jump = const JumpOptions(),
    this.appearDuration = const Duration(milliseconds: 200),
    this.removeDuration = const Duration(milliseconds: 200),
    this.collapseRemovedRows = false,
    this.persistDebounce = const Duration(milliseconds: 800),
    this.readDebounce = const Duration(milliseconds: 300),
    this.readDwell = const Duration(milliseconds: 100),
    this.groupingGap = const Duration(minutes: 5),
    this.memoryLimitPerList = 1000, this.openListsInMemory = 10,
    this.reselectBehavior = ReselectBehavior.jumpToBottom,
    this.restoreIslandsAfterRestart = false,       // Telegram: false (only within a session)
    this.loadingIndicatorDelay = const Duration(milliseconds: 150),
  });
}
```

---

## 10. Controller behavior

```dart
class MessageListController<M> extends ChangeNotifier {
  MessageListController({
    required MessageListHub<M> hub,
    required ListId list,
    MessageListConfig config = const MessageListConfig(),
    MessageListCallbacks<M> callbacks = const MessageListCallbacks(),   // §13.1
    MessageListPolicies<M> policies = const MessageListPolicies(),      // §13.3
  });

  // lifecycle
  Future<OpenResolution> open({OpenTarget target = const OpenTarget.auto()});
  Future<OpenResolution> switchTo(ListId list, {OpenTarget target = const OpenTarget.auto()});
  void reselect();                                     // the user tapped the open chat again
  Future<void> saveSnapshot({SaveReason reason = SaveReason.explicit});
  @override void dispose();

  // navigation (§10.4)
  Future<JumpResult> jumpTo(MessageKey key, {JumpOptions? options});
  Future<JumpResult> jumpToBottom({JumpScroll? scroll});
  Future<JumpResult> jumpToDate(DateTime day, {JumpOptions? options});
  Future<JumpResult> jumpToNextUnreadMention();
  Future<JumpResult> jumpToNextUnreadReaction();
  Future<JumpResult> jumpToPinned(MessageKey key);
  MessageSearchNavigator<M> search(MessageSearchSource source); // §10.5

  // local messages (§10.6) and imperative updates (§13.5)
  void insertLocal(M message, {bool scrollToBottom = true});
  void apply(ListEvent<M> event);
  void upsert(List<M> messages);
  void patch(String id, M Function(M current) update);
  void remove(List<String> ids, {bool animate = true});
  void setReadState(ReadState state);
  Future<void> invalidate({bool keepPosition = true});
  Future<void> reset();

  // selection (§10.11)
  SelectionController get selection;

  // geometry (§13.4)
  Rect? rectOf(MessageKey key);                        // global coordinates, null if not built
  List<VisibleItem> get visibleItems;
  Future<void> ensureVisible(MessageKey key, {JumpAlignment alignment = const JumpAlignment.minimal()});

  // observable state
  ValueListenable<ListPhase> get phase;                // loading | ready | empty | error
  ValueListenable<bool> get isAtBottom;
  ValueListenable<bool> get showScrollDownButton;
  ValueListenable<int> get unreadCount;
  ValueListenable<int> get unreadMentionsCount;
  ValueListenable<int> get unreadReactionsCount;
  ValueListenable<MessageKey?> get highestVisibleKey;
  ValueListenable<DateTime?> get topVisibleDay;
  ValueListenable<MessageKey?> get currentPinned;      // §10.10
  ValueListenable<EdgeState> get olderEdge;            // idle | loading | error(e) | end
  ValueListenable<EdgeState> get newerEdge;
  ValueListenable<JumpState?> get jumpInProgress;
  Stream<MessageListEvent> get events;                 // §13.2
  Future<void> retry(ListEdge edge);
}
```

### 10.1 Open, reopen, reselect

Decision order (`OpenPolicy` default, `OpenTarget.auto`):

1. **Session memory:** the hub already has this list in memory with a snapshot from this session → restore it exactly, even if it is an island (Telegram behavior).
2. **Persisted snapshot:** `connectedToNewest` (or `restoreIslandsAfterRestart`) and the anchor is cached → restore.
3. **Unread:** `unreadCount > 0` → `around(lastReadInbox)`; divider before the first unread non-outgoing, non-service key; divider at `unreadDividerTopInset` from the top. If the content below the divider is shorter than the viewport, align to the bottom.
4. **Bottom:** cached newest → show immediately, then `latest(firstOpenPageSize)`.

Rules:

- Restoring places the anchor at `anchorOffset` **before the first paint** (§11.4).
- Then the controller refreshes `newer` from the remote in the background without moving the viewport.
- If `viewportWidth` changed, restore by anchor (never by `offsetFromBottom`).
- `switchTo` keeps the previous list painted until the new one has a first frame (no blank frame) and saves the previous snapshot.
- `reselect()` (the user taps the open chat): per `reselectBehavior` — `jumpToBottom` (Telegram default) | `scrollToTopOfWindow` | `none`.
- Opening a deep link to a message in the chat that is already open = `jumpTo` in place, never a reopen.

### 10.2 Paging and windowing

- When the viewport is within `preloadExtent` of a window edge:
  - extend from the store if the segment has more keys;
  - else fetch `older`/`newer` (single flight per direction).
- After extending, if the window has more than `windowSize` keys → unmount from the far side down to `windowSize`.
- `onPrefetch(keys)` callback: called with the next ~20 keys beyond each window edge, so the app can warm image and video caches.
- Paging stops at `reachedOldest` / at the live segment's newest. The edge shows `EdgeState.end` (the app may show a "chat start" header, §12.3).
- An island grows by paging; when it touches the live segment they merge and the window continues seamlessly.

### 10.3 Bottom pinning and incoming messages

- `isAtBottom` = distance to the bottom ≤ `stickToBottomThreshold` and the window holds the live segment's newest key.
- Incoming while at bottom → append, stay pinned, appear animation; trim the top if over `windowSize`.
- Incoming while not at bottom → store only (append to the window without moving if the window ends at the previous newest); badge +1 if incoming and not read.
- Viewport height changes (keyboard, composer growth, typing footer, resize) while at bottom → stay pinned; otherwise keep the anchor.
- `BottomStickPolicy` can refuse pinning while the user is dragging.
- Batching: all events in one frame produce one rebuild and one correction.

### 10.4 Jumps

**Mechanism** (all jumps: search, reply, pinned, mention, reaction, date, deep link, bottom, reselect):

1. The target is in the window → animate to it. If the distance is more than `maxAnimatedDistance` viewports, first jump without animation to one viewport before the target, then animate.
2. The target is outside the window:
   1. Get keys around it — from the store if cached, else one `around` fetch (or `latest` for bottom, or `anchorDate` for dates).
   2. Build the new window = [current anchor message] + keys around the target.
   3. Place the viewport one viewport before the target, on the side it came from.
   4. Animate the rest.
   5. The extra anchor message is unmounted at the next trim.
3. If the fetch takes longer than `loadingIndicatorDelay`, `jumpInProgress` reports `loading`. The app shows a spinner on the scroll-down button or the search arrow, never in the list. The old content stays visible.
4. A new jump cancels the running one (its fetch gets the cancel token). So does a user drag/fling, a chat switch or dispose.

**Options (where it lands, how it moves, how it looks):**

```dart
@immutable
class JumpOptions {
  const JumpOptions({
    this.alignment = const JumpAlignment.centerIfFits(),
    this.scroll = const JumpScroll.animated(),
    this.highlight = const JumpHighlight(),
    this.highlightQuery,
    this.reason = JumpReason.programmatic,
  });
}
sealed class JumpAlignment {
  const factory JumpAlignment.centerIfFits({double topInset}) = _CenterIfFits; // default; top-aligned if taller than viewport
  const factory JumpAlignment.top({double inset}) = _Top;                      // e.g. below the pinned bar
  const factory JumpAlignment.bottom({double inset}) = _Bottom;
  const factory JumpAlignment.fraction(double f) = _Fraction;
  const factory JumpAlignment.minimal() = _Minimal;                            // only if not fully visible
}
@immutable
class JumpScroll {
  const JumpScroll.animated({this.duration = const Duration(milliseconds: 400),
      this.curve = Curves.easeOutCubic, this.maxAnimatedDistance = 1.0});
  const JumpScroll.instant();
}
@immutable
class JumpHighlight {
  const JumpHighlight({this.duration = const Duration(milliseconds: 1000),
      this.delay = Duration.zero, this.curve = Curves.easeOut});
  const JumpHighlight.none();
}
enum JumpReason { programmatic, search, reply, pinned, mention, reaction, date, deepLink, bottom, reselect }

@immutable
class JumpResult {
  final JumpOutcome outcome;     // arrived | arrivedNearest | alreadyVisible | cancelled | failed
  final MessageKey? landedOn;
  final int fetchedPages;
  final Duration took;
  final Object? error;
}
```

**Rules:**

- *Split of responsibility:* the package decides where the target lands and how the scroll moves. The bubble decides how it looks, using `MessageItemInfo.highlight` (an `Animation<double>` from 1 → 0), `highlightQuery` and `highlightReason`. The default `JumpHighlightBackground` wrapper reproduces Telegram's flash.
- `JumpAlignment.centerIfFits` with the target already fully visible → no scroll, highlight only (`alreadyVisible`).
- A missing target (deleted, or not returned) → land on the nearest existing message in the travel direction, `arrivedNearest`, no highlight.
- The target's height changes during the animation (media loads) → retarget so the final alignment is correct.
- Jumping to the same key again restarts the highlight.
- `onJump` (§13.1) emits `started → loading? → scrolling → arrived(rect) → highlightEnded`, or `cancelled` / `failed`.
- After `arrived`, move accessibility focus to the target (except for `bottom`/`reselect`).
- `jumpToDate(day)` → the first message on or after local midnight of `day` (`anchorDate` fetch if not cached), `alignment: top(inset: dayHeaderHeight)`.
- `jumpToNextUnreadMention()` → the oldest unread mention newer than the current anchor; it is removed from `unreadMentions` on arrival; the counter updates. Same for reactions.
- `jumpToBottom()` across a gap of any size: at most one fetch (`latest`), never more than one viewport animated.

### 10.5 Async search navigation

```dart
class MessageSearchNavigator<M> extends ChangeNotifier {
  Future<void> setQuery(String query);      // debounced 300 ms; cancels the previous query's requests
  ValueListenable<SearchStatus> get status; // idle | searching | ready | empty | error
  int? get total;                           // from server if known
  int get loaded;
  int? get index;                           // current result, 0 = newest
  MessageKey? get current;
  Future<JumpResult> next();                // older result; loads the next result page when needed
  Future<JumpResult> previous();            // newer result
  Future<JumpResult> goTo(int index);
  List<MessageKey> get results;             // for a results list UI
  void close();                             // clears highlightQuery, keeps the position
}
```

- Each navigation = `controller.jumpTo(key, options: JumpOptions(reason: JumpReason.search, highlightQuery: query))`.
- Fast repeated presses: only the last jump completes (the earlier ones get `cancelled`), and its fetch is single-flight.
- Prefetch: after arriving at result i, warm the store around results i±1 in the background (an `around` fetch with low priority), so the next press is instant.
- Results paging: when `index` reaches `loaded − 5` and `nextCursor != null`, fetch the next result page.

### 10.6 Local messages, acks, failures

- `insertLocal(m)` gives `m` a key with `order = live.last.order`, `localSeq = next` and the client `id`. It is appended to the live segment and the window. If the user is not at bottom and `scrollToBottom` is true → `jumpToBottom` first, then append. `isJustAdded` → appear animation.
- `LocalAcked(localId, server)` swaps the message keeping widget identity (the stable item key is the client id until the item is unmounted). If the server order puts it elsewhere (out-of-order acks), move it without animation and keep the anchor.
- `LocalFailed(localId, error)` keeps the item with `MessageItemInfo.sendState = failed`. The app may retry (`patch`) or `remove`.
- Local messages survive restarts when the Drift cache is used (pending queue is the app's job; the list only displays them).

### 10.7 Updates, reactions, deletes

- **Updates** (edit, reactions, status checks, view counters): rebuild only the affected item (`adapter.equals`). A height change keeps the anchor (§11.2). Reaction bursts are batched per frame.
- **Deletes** (local, remote, batch) — required behavior:
  - Content animates out (opacity → 0, scale → 0.3, slide toward its side, `removeDuration` ease-in). Then the row is removed in one step (or the height animates if `collapseRemovedRows`).
  - Not at bottom: rows above stay still, rows below move up. Anchor = the first visible row not being removed.
  - At bottom: stays pinned.
  - **Above the viewport: nothing visible moves** (better than Telegram).
  - Below the viewport: nothing to correct.
  - Batch: one animation pass, one correction.
  - Neighbors' grouping flags and day headers are recomputed; an empty day group's header animates out with it.
  - The first unread deleted → the divider moves to the next unread.
  - The jump target deleted → `arrivedNearest`.
  - The snapshot anchor deleted → restore at the nearest key.
  - Albums: deleting one item re-lays out the row; deleting all removes it.

### 10.8 Read tracking and unread UI

- `ReadPolicy` default: a message is read when fully visible (or covering ≥ 50% of the viewport if taller) for `readDwell` while the app is in the foreground.
- `highestVisibleKey` only increases. `source.markRead` / `onReadUpTo` is called debounced; outgoing and local messages are ignored. Failures retry with backoff.
- Optimistic counter: `unreadCount` = server count − locally read but unconfirmed.
- The divider stays where it was placed for the whole visit (it doesn't move as messages get read). It is removed on the next open if nothing is unread.

### 10.9 Persistence

- Snapshot on:
  - scroll idle (+ `persistDebounce`);
  - `switchTo`;
  - `dispose`;
  - `AppLifecycleState.paused/hidden/detached`;
  - web `visibilitychange`/`pagehide`.
- Writes go to `callbacks.saveSnapshot` if given, else to the cache, else to `SharedPreferencesViewportStore`.
- The latest snapshot wins; writes are coalesced.

### 10.10 Pinned messages bar support

- `currentPinned` = the newest pinned key older than or equal to the anchor (Telegram's bar shows the pinned message relevant to where you are). It updates on scroll, throttled.
- `jumpToPinned(key)` uses `JumpReason.pinned` with `alignment: top(inset: pinnedBarHeight)`.
- Tapping the bar cycles to the previous pinned message (the app calls `jumpToPinned(previous)`).

### 10.11 Selection

```dart
class SelectionController extends ChangeNotifier {
  bool get active;
  Set<String> get selectedIds;
  void toggle(String id);
  void selectRange(MessageKey from, MessageKey to);  // only loaded keys; shift-click on web/desktop
  void selectAllLoaded();
  void clear();
  bool isSelectable(MessageKey key);                 // via SelectionPolicy (e.g. service messages not selectable)
}
```

- Long-press enters selection on mobile (the app decides via `itemBuilder`). Drag-to-select over items SHOULD be supported via `selection.dragSelect(start, current)`.
- Deleting selected messages is a batch delete; selection clears after the delete.
- Selected ids survive window trims and paging.

### 10.12 Visibility and dwell

- `onVisibleRangeChanged(range)` at most once per frame.
- `onItemVisibility(key, fraction)` for items whose fraction crosses thresholds [0, 0.5, 1] → media autoplay/pause.
- `onMessagesSeen(keys)` once per key per open (view counters).
- Items leaving the window get `onItemDisposed(key)` so the app can release video controllers.

---

## 11. View

```dart
class MessageListView<M> extends StatefulWidget {
  const MessageListView({
    super.key,
    required this.controller,
    required this.itemBuilder,             // Widget Function(BuildContext, M, MessageItemInfo)
    this.groupBuilder,                     // albums: Widget Function(BuildContext, List<M>, MessageItemInfo)
    this.dayHeaderBuilder,                 // Widget Function(BuildContext, DateTime day, VoidCallback onTap)
    this.floatingDayBuilder,
    this.unreadDividerBuilder,
    this.edgeBuilder,                      // Widget Function(BuildContext, ListEdge, EdgeState, VoidCallback retry)
    this.historyStartBuilder,              // shown at reachedOldest (chat intro)
    this.footerBuilder,                    // typing indicator etc.; height changes keep bottom pinning
    this.emptyBuilder, this.loadingBuilder, this.errorBuilder,
    this.appearTransitionBuilder,
    this.removeTransitionBuilder,          // default: fade + scale 0.3 + slide (Telegram)
    this.scrollDownButtonBuilder,          // optional built-in overlay; or build your own from controller state
    this.padding = EdgeInsets.zero,
    this.physics,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.onDrag,
    this.scrollbar = true,
    this.debugOverlay = false,             // §16
  });
}

@immutable
class MessageItemInfo {
  final MessageKey key;
  final bool isFirstInGroup, isLastInGroup, isFirstInDay;
  final bool isFirstUnread;
  final bool isJustAdded;
  final bool isLocal;
  final SendState sendState;             // sending | sent | failed | none
  final bool isRead;                     // outgoing read by peer (lastReadOutbox)
  final Animation<double>? highlight;    // 1 → 0 after a jump; null otherwise
  final String? highlightQuery;
  final JumpReason? highlightReason;
  final bool isSelected, selectionActive;
  final int indexInWindow;               // debug only
}
```

### 11.1 Scroll structure

- `CustomScrollView` with a `center` key. Keys older than the center go into the upper `SliverList` (index 0 = nearest the center); the center and newer keys go into the lower one.
- Prepending older → appends to the upper list → zero offset change. Appending newer → appends to the lower list → zero offset change.
- Re-center (move the center key to the anchor) after jumps and trims, adjusting `pixels` in the same layout pass.
- Content shorter than the viewport sits at the bottom (leading filler sliver).
- Items use `ValueKey(stableId)` and `findChildIndexCallback`, so inserts and moves keep `State`.
- Each item is wrapped in `RepaintBoundary` and registers its `RenderBox` in a key → render object registry (for anchors, `rectOf` and visibility).

### 11.2 Anchor correction (no jumps)

Custom `AnchoredScrollPosition extends ScrollPositionWithSingleContext`, created by the controller's internal `ScrollController.createScrollPosition`:

1. Before any layout that follows a structural or size change, record `anchorKey` and `anchorOffset` (`AnchorPolicy`: by default the first visible item not being removed).
2. In `applyContentDimensions` (called by the viewport after the slivers are laid out):
   1. Find the anchor's `RenderBox`.
   2. Compute `reveal = getOffsetToReveal(box, 0).offset`.
   3. If `reveal − anchorOffset ≠ pixels`, call `correctPixels` and return `false` (one relayout in the same frame).
3. Skip it while bottom-pinned (pinning wins) and while a jump animation owns the position (the jump retargets instead).
4. It covers prepend, append, delete, edit, reactions, media load, window trim, keyboard, resize and the footer appearing.
5. Emit a `MessageListDiagnostic.anchorCorrected(px)` in debug.

### 11.3 Heights

- Variable heights. Cache measured extents per `(stableId, widthBucket)` to estimate offsets for jumps and restores before layout.
- README: give media a known aspect ratio. Even if apps don't, §11.2 keeps the view stable.

### 11.4 First frame

The controller resolves the target window synchronously from memory when possible. The view's first layout uses center = anchor and `pixels = −anchorOffset`. If data is async (cold DB), show `loadingBuilder` (or keep the previous list during `switchTo`). It never paints at a wrong offset and then jumps.

### 11.5 Keyboard, composer and safe areas

- The list is laid out above the composer. Bottom inset changes (keyboard animation frames, composer growth, reply-preview bar) keep the bottom pinned when `isAtBottom`, else keep the anchor.
- No jank during the keyboard animation: corrections run in the same frame as each inset change.

### 11.6 Input and gestures

- Mobile:
  - Platform physics.
  - Horizontal item gestures (swipe to reply) MUST NOT start while a vertical scroll is in progress. The package exposes `MessageListGestureArena` helpers that use a direction lock (> 20° from horizontal = vertical).
  - iOS status-bar tap → top of the loaded window; override with `onStatusBarTap`.
- Web/desktop:
  - Wheel and trackpad, a draggable scrollbar (over the loaded window).
  - Keys: PageUp/PageDown, Home (`jumpTo` oldest loaded; Ctrl+Home → `reachedOldest` via fetch), End (`jumpToBottom`), arrows (40 px).
  - Text selection inside bubbles doesn't trigger scrolling, except auto-scroll at the edges while drag-selecting.
  - Right-click is the app's (context menu) — on web, document `BrowserContextMenu.disableContextMenu()`.

### 11.7 Accessibility, RTL, text scale

- Each item's semantics come from the app. The list provides `SemanticsSortKey` order (oldest → newest) and announces incoming messages politely when at bottom (opt-in).
- RTL: directionality comes from context; slide directions for remove animations mirror.
- Text scale changes → heights change → handled by §11.2/§11.3.

---

## 12. Default widgets and theming

`MessageListTheme` (`ThemeExtension`) styles every default widget. All are optional.

### 12.1 Floating buttons

- `ScrollDownButton`: appears with scale + fade when `showScrollDownButton`; badge 1–999, then 1K, 7.2K, 1M. Shows a progress ring while `jumpInProgress.loading`.
- `MentionButton`, `ReactionButton`: shown when their counts are > 0; tap → `jumpToNextUnread…`.

### 12.2 Days

- `DayHeader` inline at the start of each day group, label via `intl` ("Today", "Yesterday", weekday within 7 days, else a date).
- `FloatingDayChip`, driven by `topVisibleDay`, fades out 1 s after scroll idle.
- Tapping either → `onDayTap(day)` (the app opens a date picker and calls `jumpToDate`).

### 12.3 Slots

- `UnreadDivider` ("Unread messages").
- `historyStartBuilder` (chat intro).
- `footerBuilder` (typing indicator).
- `edgeBuilder` (spinner / error + retry).

---

## 13. Extension points

### 13.1 Callbacks

```dart
@immutable
class MessageListCallbacks<M> {
  const MessageListCallbacks({
    // position
    this.loadSnapshot,          // Future<ViewportSnapshot?> Function(ListId)     (50 ms budget, then ignored)
    this.saveSnapshot,          // FutureOr<void> Function(ListId, ViewportSnapshot, SaveReason)
    // reading & visibility
    this.onReadUpTo,            // FutureOr<void> Function(ListId, MessageKey)    (debounced, monotonic)
    this.onMessagesSeen,        // void Function(ListId, List<MessageKey>)
    this.onVisibleRangeChanged, // void Function(ListId, VisibleRange)
    this.onItemVisibility,      // void Function(ListId, MessageKey, double fraction)
    this.onItemDisposed,        // void Function(ListId, MessageKey)
    this.onUnreadChanged,       // void Function(ListId, int)
    // loading
    this.onPageRequested,       // void Function(ListId, PageRequest)
    this.onPageLoaded,          // void Function(ListId, PageRequest, PageResult<M>, PageOrigin, Duration)
    this.onPageError,           // void Function(ListId, PageRequest, Object, StackTrace)
    this.onPrefetch,            // void Function(ListId, List<M> upcoming)
    // navigation
    this.onOpened,              // void Function(ListId, OpenResolution)  sessionRestore | snapshot | firstUnread | bottom | target
    this.onJump,                // void Function(ListId, JumpEvent)       started | loading | scrolling | arrived(rect) | highlightEnded | cancelled | failed
    this.onAtBottomChanged,     // void Function(ListId, bool)
    this.onTopVisibleDayChanged,// void Function(ListId, DateTime?)
    this.onCurrentPinnedChanged,// void Function(ListId, MessageKey?)
    this.onDayTap,              // void Function(ListId, DateTime)
    // data
    this.mergeMessage,          // M Function(M current, M incoming)      default: incoming
    this.shouldAnimateInsert,   // bool Function(M, InsertCause)
    this.shouldAnimateRemove,   // bool Function(MessageKey, RemoveCause)
    // diagnostics
    this.onDiagnostic,          // void Function(MessageListDiagnostic)
  });
}
enum SaveReason { scrollIdle, chatSwitch, dispose, appPaused, pageHide, explicit }
```

Rules:

- Callbacks are never called during build or layout (post-frame or async).
- Async callbacks are not awaited by the UI. Errors are caught and reported as `MessageListDiagnostic.callbackError`; the list keeps working.
- `saveSnapshot` is debounced, except for dispose/appPaused/pageHide (immediate). The latest wins.

### 13.2 Event stream

`controller.events` (broadcast) carries a sealed `MessageListEvent` for everything the callbacks report, plus `WindowChanged(first, last, count)`, `MessageInserted/Updated/Removed(cause)`, `KeyReplaced` and `SnapshotSaved`. Callbacks and events MUST carry the same information.

### 13.3 Policies (`MessageListPolicies<M>`, each with a Telegram-like default)

| Policy | Decides | Default |
| --- | --- | --- |
| `OpenPolicy` | where to open | §10.1 order |
| `ReadPolicy` | what counts as read | fully visible (or ≥ 50% if tall) for 100 ms, foreground |
| `AnchorPolicy` | which item keeps the screen still | first visible, not being removed |
| `GroupingPolicy<M>` | first/last in group, day of a message | same sender, same day, within 5 min, service breaks groups; local midnight |
| `UnreadDividerPolicy` | where the divider goes | before the first unread incoming non-service message |
| `RetryPolicy` | page/read retry delays | 0.5, 1, 2, 4 s, then error state |
| `WindowPolicy` | page sizes, window size, preload | 40 / 80 / 1500 px |
| `BottomStickPolicy` | whether to stay pinned | stick unless the user is dragging |
| `SelectionPolicy` | selectable items | all except service |
| `PinnedPolicy` | current pinned for the anchor | newest pinned ≤ anchor |

### 13.4 Geometry API

`rectOf(key)`, `visibleItems` (key, rect, visible fraction) and `ensureVisible`. These let apps place overlays: reaction burst effects, context menus, tooltips, "message copied" toasts. `rectOf` is valid after layout; listen to `onVisibleRangeChanged` to update overlays while scrolling.

### 13.5 Imperative API

`apply`, `upsert`, `patch`, `remove`, `setReadState`, `invalidate(keepPosition)` (after reconnect: refetch around the anchor and merge without moving) and `reset()`. All are batched per frame.

---

## 14. Performance rules (MUST)

1. Never rebuild the whole list for a single message change. Each item listens to its own entry (`ValueListenable` per stable id inside the store), so a reaction update rebuilds one bubble.
2. `RepaintBoundary` per item; no `Opacity` widgets for animations (use `FadeTransition`); no `IntrinsicHeight` inside items in the example.
3. The window is never larger than `windowSize`; `cacheExtent` is bounded.
4. All store operations O(log n + k); no list copies of the whole store per frame.
5. Events are coalesced per frame (`SchedulerBinding.scheduleFrameCallback`).
6. Drift reads and writes run off the UI isolate; JSON decoding of large pages runs in an isolate (`Isolate.run`) above 200 items.
7. Images: the example uses `cacheWidth`/`cacheHeight` and `ResizeImage`; media is released in `onItemDisposed`.
8. No `GlobalKey` per item (the registry uses render objects).
9. Jump animations run on the scroll position (`animateTo`), not by rebuilding.
10. Diagnostics and the debug overlay are tree-shaken in release (`kDebugMode` guards).

### 14.1 Budgets (measured by `benchmarks/`)

| Metric | Budget |
| --- | --- |
| Open cached chat → correct first frame | same frame as the route build; build ≤ 16 ms |
| Page apply (40 items) on the UI isolate | ≤ 3 ms |
| Fling 5,000 messages | p95 build+layout ≤ 8 ms; no frame > 32 ms (mid-range Android, Chrome) |
| 50 incoming/s for 30 s while at bottom | no dropped frames |
| 200 reaction updates/s on visible items | no dropped frames |
| Jump across 1,000,000 messages, target cached | ≤ 450 ms; no blank frame |
| Jump, target remote with 150 ms latency | ≤ 700 ms; no blank frame |
| Memory after scrolling 100,000 messages | flat ±10% after the first 2,000 |
| Drift page read (40) | ≤ 10 ms device, ≤ 25 ms web |

---

## 15. Robustness (MUST)

- **Idempotent:** the same page or event twice → no change.
- **Order-independent:** tombstones make a delete win over a late page; acks can arrive out of order.
- **Stale-safe:** every async result carries `generation`; older ones are dropped and their requests cancelled.
- **Single flight:** at most one fetch per direction per list; identical requests share one future.
- **Reconnect:** `invalidate()` refetches around the anchor, merges, and never moves the viewport.
- **Clock skew:** sort only by `MessageKey`, never by local time.
- **Disposal:** after `dispose()`, late results, events and callbacks are ignored without throwing.
- **Errors:** a failed page never clears the window; the edge shows the error with retry.
- **Assertions:** store invariants are asserted in debug builds and covered by property-based tests (random operation sequences, 10,000 iterations).

---

## 16. Debug tools

`MessageListView(debugOverlay: true)` draws:
- the window range;
- segment bars (live vs islands);
- the anchor line and its offset;
- the last anchor correction in px;
- pending fetches;
- the current generation.

`controller.debugDescribe()` returns the same as text, for bug reports.

---

## 17. Example app (big numbers) — deliverable

`example/` runs on Android, iOS, Chrome and macOS with a **simulated server** (`FakeChatServer`, in-process, deterministic seed):

**Data**

| Chat | Messages | Unread | Notes |
| --- | --- | --- | --- |
| "Big channel" | 10,000,000 | 7,200 | generated lazily from the seed (no memory blow-up); ids with gaps; 10% images (known aspect ratio, loading after 300–1500 ms), 5% albums, 2% service messages |
| "Group" | 200,000 | 18 | several senders, replies, reactions, 5 pinned messages, mentions of me |
| "Friend" | 5,000 | 0 | 1:1, read receipts, typing indicator every 20 s |
| "Saved" | 300 | 0 | for delete tests |

**Server behavior** (adjustable in a debug panel): latency 0–2,000 ms (default 150), failure rate 0–50%, out-of-order acks, incoming message rate (0–50/s), reaction storm (0–200/s), remote deletes (random visible / above viewport / below viewport / batch of 5), remote edits that change height, reconnect simulation.

**Search:** an async `MessageSearchSource` over the generated text (simulated latency, paged results of 50, total count). The UI has a search bar with up/down arrows, "3 of 1,248", a results list, and highlights in bubbles.

**Screens and actions**

- Chat list (open, reselect → bottom).
- Chat screen:
  - message bubbles with reply previews (tap → jump), reactions (tap → toggle, burst effect positioned by `rectOf`) and swipe-to-reply;
  - long-press selection with batch delete, a pinned bar, a typing footer, a composer (`insertLocal`);
  - scroll-down / mention / reaction buttons, a day chip with a date picker (`jumpToDate`).
- A split view on tablet/desktop: the same chat in two panes, or a thread in a side panel (shared hub).
- A toggle for `InMemoryMessageCache` ↔ `DriftMessageCache`; restart the app and see the exact restore.
- Debug overlay toggle and a perf HUD (frame times).

---

## 18. Acceptance tests (widget tests with `FakeChatServer`; one test each, MUST pass)

1. **Restore after restart:** scroll 1,600 px from the bottom, dispose, recreate → same anchor key at the same y (±1 px) on the first `pump()`.
2. **Session restore of an island:** jump far back, switch chat, come back → same island position.
3. **Stale persisted island:** after a restart with `restoreIslandsAfterRestart: false` → opens by the unread/bottom rule.
4. **Unread open:** 30 unread → divider 10 px from the top; 2 unread → aligned to the bottom; the divider doesn't move while reading.
5. **Windowing:** page up 20 pages → item widget count ≤ 80 + cache extent at every frame; the anchor is stable within 1 px after each page.
6. **Media resize above the viewport (+200 px)** → visible items don't move.
7. **Deletes:** inside the viewport (rows above still, below move up), **above the viewport (nothing moves)**, below, at bottom (pinned), batch of 3, an album item, the last item of a day (header removed), the first unread (divider moves).
8. **Incoming:** at bottom → pinned with appear animation; scrolled up → no movement, badge +1; 50/s burst → one rebuild per frame.
9. **Send:** `insertLocal` while scrolled up → ends at the bottom with the item visible; an ack keeps the same `State` (`initState` count = 1); out-of-order acks keep the order by server key; a failure shows `failed`.
10. **Jump to bottom across a 1,000,000 gap:** ≤ 1 fetch, no blank frame, ≤ 1 viewport animated.
11. **Search jump:** one `around` fetch, window swapped in one frame, the start ≤ 1 viewport away, ends centered (top-aligned if taller), highlight 1 → 0 over 1 s; scrolling down afterwards merges the island with the live segment.
12. **Rapid search next ×10:** only the last jump arrives; the others are `cancelled`; ≤ 2 fetches in flight at any time.
13. **Jump options:** each alignment within 1 px; a drag during a jump → `cancelled` with no highlight; a deleted target → `arrivedNearest`; media loading mid-jump still ends aligned; `onJump` phases in order with `rect` at `arrived`.
14. **Jump to date:** lands on the first message of that day, below the day header.
15. **Mentions/reactions navigation:** jumps oldest-first; the counters decrease.
16. **Pinned:** `currentPinned` follows the scroll; `jumpToPinned` aligns below the bar.
17. **Reselect** the open chat → jump to bottom.
18. **Keyboard open/close and footer appear** at bottom → stays pinned; scrolled up → anchor kept.
19. **Resize width (web/desktop)** → anchor kept.
20. **Stale results:** a page from a previous `switchTo`/jump is ignored.
21. **Errors:** an older page fails → edge error; `retry` loads; the window is untouched.
22. **Read receipts:** `markRead` keys strictly increase; debounced; outgoing ignored.
23. **Selection:** range select with shift; the selection survives paging; a batch delete clears it.
24. **Two controllers on one list** (split view): an event updates both; positions are independent.
25. **Drift:** migration test, page round trip, segments persisted, eviction respects snapshot windows, web run (`--platform chrome`).
26. **Property test:** 10,000 random operation sequences on the store → invariants hold.

---

## 19. Benchmarks (`benchmarks/`, integration_test with `traceAction`)

Fling 5,000; open cached chat; jump ×20 across 1M; 50 msg/s incoming; 200 reactions/s; memory after 100,000 scrolled. Results are written to `benchmarks/RESULTS.md` per platform and compared with §14.1. CI fails if a budget regresses by more than 10%.

---

## 20. Milestones

| # | Deliverable | Tests from §18 |
| --- | --- | --- |
| 1 | Core: keys, store, segments, events, tombstones, queries, eviction, property tests | 26 |
| 2 | Hub + controller headless (`FakeViewport`): open rules, paging, window, bottom logic, read tracking, callbacks/events/policies | 3, 4 (logic), 20, 22 |
| 3 | View: center-key scroll view, `AnchoredScrollPosition`, first-frame restore, keyboard/footer, stress test (random insert/delete/resize every frame for 10 s, anchor ≤ 1 px) | 1, 2, 5, 6, 18, 19 |
| 4 | Jumps: options, highlight, results, bottom, date, pinned, mentions/reactions, reselect, search navigator | 10–17 |
| 5 | Local messages, acks, failures; updates; delete animations | 7, 8, 9 |
| 6 | Selection, geometry API, visibility/dwell, prefetch, default widgets and theme | 23 |
| 7 | Drift cache, `CachingMessageSource`, multi-controller hub, web multi-tab | 24, 25 |
| 8 | Example app (§17), benchmarks (§19), debug overlay, README, API docs, CHANGELOG | 21 + all budgets |

Each milestone ends with: `dart format`, analyzer clean, all tests green, `CHANGELOG.md` and `DECISIONS.md` updated, and a short summary for review.

---

## 21. README quick start (must appear as written, adapted to the final API)

```dart
final hub = MessageListHub<ChatMessage>(
  source: MyBackendSource(api, socket),                  // implements MessageSource<ChatMessage>
  adapter: ChatMessageAdapter(),                          // keyOf, dateOf, senderIdOf, isOutgoing…
  cache: DriftMessageCache(db, codec: JsonMessageCodec(ChatMessage.fromJson, (m) => m.toJson())),
);

final controller = MessageListController<ChatMessage>(
  hub: hub,
  list: ListId(chat.id),
  callbacks: MessageListCallbacks(
    onReadUpTo: (list, key) => api.markRead(list.chatId, key.id),
    onJump: (list, e) => analytics.log('jump', e.toMap()),
  ),
)..open();

MessageListView<ChatMessage>(
  controller: controller,
  itemBuilder: (context, m, info) => JumpHighlightBackground(
    info: info,
    child: MessageBubble(m, grouped: !info.isFirstInGroup, query: info.highlightQuery),
  ),
  dayHeaderBuilder: (context, day, onTap) => DayHeader(day: day, onTap: onTap),
  footerBuilder: (context) => TypingIndicator(chat.id),
  scrollDownButtonBuilder: (context, unread, onTap) => ScrollDownButton(unread: unread, onTap: onTap),
);

controller.insertLocal(ChatMessage.pending(text));                         // send
final search = controller.search(MySearchSource(api))..setQuery('invoice'); // search
await search.next();                                                       // jumps to the newest hit
```
