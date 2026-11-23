# Decisions

Every interpretation of the project specification, with the reason. Section numbers (§) refer to that specification, which is an internal document and not part of this repository.

## Workspace

**D1. No pub workspace; sibling packages are linked with `pubspec_overrides.yaml` (§4).**
Pub workspaces need `sdk: ^3.6.0` in every member, but §4 sets the minimum to Dart 3.5 / Flutter 3.24 and the package must not require a recent SDK. Each package declares a normal version dependency on its siblings (what pub.dev needs) and a local `pubspec_overrides.yaml` points at the sibling folder. No melos dependency is needed. Lockfiles are not committed for the library packages.

**D2. The minimum SDK is checked with a real Dart 3.5.4 toolchain.**
Milestone 1 was analyzed, format-checked and tested on Dart 3.5.4 (Flutter 3.24.4) and on Dart 3.14. No language feature newer than Dart 3.5 is used.

**D3. `collection` is not a dependency of the core yet.**
§4 allows it; nothing needs it so far. `dart:collection` (SDK) provides `SplayTreeMap`.

**D4. `example/` and `benchmarks/` are placeholders until milestone 8; the Flutter and Drift packages are skeletons until milestones 2 and 7.**
Their dependencies (`shared_preferences`, `intl`, `drift`…) are added in the milestone that first uses them.

## Core data model (§6)

**D5. `MessageKey` has `<`, `<=`, `>`, `>=` and `isSamePosition`.**
`==` compares the id only (spec), so the store needs an explicit way to ask "same sort position". `isSamePosition` is `compareTo == 0`.

**D6. Models have `toJson` / `fromJson` in the core.**
`MessageKey`, `ReadState` and `ViewportSnapshot` are stored as JSON by the Drift schema (§8.3) and the default viewport store (§10.9). Keeping the format in one place stops the two from drifting apart.

**D7. `PageRequest` is not `const`; `cancel` defaults to a fresh token.**
A cancellation token is mutable, so a const request can't own one.

**D8. `CancellationToken`, `KeyRange`, `StoreDelta`, `KeyReplacement` and `ScanDirection` are additions.**
The spec names the token but not its shape. `KeyRange` describes protected windows for eviction (§7.4). `StoreDelta` is how the store tells the hub and controllers what changed (the basis for "rebuild one item", §14 rule 1). `ScanDirection` is the direction argument of `nearestExisting` (§7.3).

## Store and segments (§7)

**D9. Segment bounds are always keys that exist in memory.**
A page proves a raw range (returned keys plus the anchor). Overlap with existing segments is tested on the raw range, then the merged range is clamped to stored keys. This makes "delete moves the bounds to the neighbours" and trimming simple and keeps every bound a valid paging anchor.

**D10. Only the newest segment can be live.**
The spec asks for "at most one live segment". When a segment with `reachedNewest` ends up below another segment, its flag is cleared: data above it proves it is stale. Consequences: a late `latest` answer that arrives below a live segment becomes an island; an island proven above the live segment demotes it.

**D11. `added` creates a live segment only when the key sorts above everything known.**
Spec: "no live segment → create a 1-key live segment". If the key sorts below an existing island it is stored as an orphan instead, because a live segment below an island would break D10. The store trusts an `added` key above all known data to be the newest message; a backend that pushes old messages as "added" before anything is loaded should use a page instead.

**D12. A pending local message alone never creates a live segment.**
A local key proves nothing about the server's newest message. It extends an existing live segment (§10.6); without one it is an orphan until acknowledged. Exception: a list known to be empty (D13), where the first local message forms a complete segment.

**D13. `isKnownEmpty`.**
Segments need at least one key, so "the server says this chat is empty" needs its own flag. It is set by an empty `latest` page, by deleting the last message of a segment that had both flags, and by clearing history through the live segment. It lets the controller show the empty state without refetching (`ListPhase.empty`).

**D14. Page flags are read per direction.**
`older` can only set `reachedOldest` (flag, or fewer items than the limit, as specified); `newer` can only set `reachedNewest`; `around` and `latest` take `reachedOldest` from the result; `latest` always sets `reachedNewest`. A short `latest` page does not imply `reachedOldest`: the spec lists the "fewer than limit" rule for `older` only, and a wrong end-of-history is worse than one extra empty fetch.

**D15. History cleared (§7.2).**
A watermark (`clearedUpTo`) rejects late pages and events at or below the cleared key, which makes the event order-independent without tombstoning ids the store never saw. Only a segment that straddled the cut gets `reachedOldest`; an island that starts above the cut does not, because unknown messages may lie between.

**D16. `updated` with a changed order re-keys in place.**
The message stays in its segment when the new key is inside it or extends the live segment; otherwise it is removed and placed like an added message.

**D17. `LocalAcked` when the server message is already stored.**
(The `added` event won the race.) The local copy is dropped and the delta reports `replaced(local → server)`, so the view can keep the item's `State`.

**D18. Send failures live in the store (`sendErrorOf`, `clearSendError`).**
`LocalFailed` has to survive window trims and be shared by two controllers on one list, so it can't be controller state.

**D19. Deleting a message also removes it from the pinned keys and from the unread mention/reaction lists.** `unreadCount` is not guessed; it changes only with a `ReadStateChanged` event.

**D20. Jump-to-date uses a second index ordered by date (§7.3).**
`SplayTreeMap` can't be binary-searched by another field, and `firstOnOrAfter` must be O(log n). The store keeps a `SplayTreeMap` keyed by (date, key). It returns the earliest-dated loaded message at or after the date.

**D21. O(log n + k) with `SplayTreeMap`.**
Range queries walk with `firstKeyAfter` / `lastKeyBefore`. For a splay tree, k consecutive neighbours cost O(log n + k) amortized (dynamic finger property). Measured: 80 keys around a key in 7.6 µs with 1,000 loaded.

**D22. Eviction order (§7.4).**
Orphans first, then islands without protected keys (oldest keys first), then the ends of the remaining segments, farthest from the protected keys first. Keys between two protected ranges in one segment are kept, so eviction never splits a segment. Without any protected range the live segment keeps its newest keys. Eviction runs only when over the limit and is O(n log n) in the number of loaded keys (n ≤ limit + one page).

**D23. Invariant checks.**
Cheap checks (segments, index sizes) run in an `assert` after every operation. The full O(n) check is `debugCheckInvariants()`, used by the tests.

## Hub, controller and policies (§8.4, §9, §10, §13)

**D24. The hub and the policies are pure Dart and live in the core; the controller lives in the Flutter package.**
§4 puts "policies" in the core and "controller" in the Flutter package. The hub only needs streams and timers, so it is in the core too and can be tested without Flutter. The controller needs `ChangeNotifier` and `ValueListenable`.

**D25. `memoryLimitPerList`, `openListsInMemory` and `mergeMessage` belong to the hub, not to `MessageListConfig` / `MessageListCallbacks`.**
The store is shared by every controller of a hub, so two controllers can't have different limits or merge functions for the same list.

**D26. The controller talks to the view through two things: `controller.window` and `controller.reportViewport`.**
`MessageWindow` holds the keys to build, the unread divider key and a `WindowPlacement` (anchor at an offset / bottom / unread divider) that the view applies before it paints. The view answers with `ViewportMetrics`. This is what makes the controller testable headless: the tests use a `FakeViewport` (in `test/support/`) that lays items out as a column of boxes. The real view (milestone 3) implements the same contract.

**D27. Store changes are applied to the store at once and to the window once per frame.**
The hub applies events immediately (microseconds); each controller collects the deltas and updates its window in one frame callback (`FrameScheduler`, default `SchedulerBinding.scheduleFrameCallback`). So "all events in one frame produce one rebuild" (§10.3) holds, and the store is never behind.

**D28. Callbacks and stream events are delivered in a microtask.**
§13.1 forbids calling the app during build or layout. Every event is queued and delivered after the current task; one code path feeds both `controller.events` and the callbacks, so they always carry the same information. Exception: `saveSnapshot` is called at once (it must run before dispose or page hide completes).

**D29. `MessageInserted`, `MessageUpdated` and `MessageRemoved` carry a list of keys.**
One event per frame and cause instead of 40 events for a page. The spec's singular names are kept because `MessagesUpdated` is already a backend event in the core.

**D30. A persisted position whose anchor is not in memory is fetched (`around` the anchor) and restored.**
§10.1 rule 2 says "and the anchor is cached → restore". Without a cache that would mean a browser reload never restores. The controller loads around the anchor instead, so a reload restores the position even with the in-memory cache; with the Drift cache it is instant. The island rule is unchanged: a position that was not connected to the newest message is discarded unless `restoreIslandsAfterRestart` is set (test 3).

**D31. `ViewportStore.load` and `loadSnapshot` return `FutureOr`.**
A synchronous answer lets the list restore in the first frame (§11.4). A future gets the 50 ms budget (`snapshotLoadBudget`).

**D32. Restore is always by anchor.**
`offsetFromBottom` is saved (spec) but not used to restore: the anchor is exact at any width, and when the anchor was deleted the nearest key is used (§10.7).

**D33. A cold open with unread messages takes two fetches.**
The read state is unknown until the first page brings it (or the app calls `setReadState`). The controller loads `latest`, sees `unreadCount > 0`, and loads `around(lastReadInbox)` unless the first unread message is already in that page. The divider is only placed when the data around the read marker is loaded, so it can't land on a later message (see L2).

**D34. Every open ends with a background refresh.**
After a restore or an unread open: `newer` from the end of the segment. After a bottom open from memory: `latest`. This catches up with what was missed while the list had no subscription and never moves the viewport. To make this safe, a page that proves keys beyond a segment's end without claiming the end clears that segment's `reachedNewest` / `reachedOldest` (the flag was stale).

**D35. Scrolled up, new messages are added to the window only while it has room.**
§10.3 says "append to the window without moving". The window can't exceed `windowSize` and its top is on screen, so when it is full the new messages stay in the store and are paged in when the user scrolls down.

**D36. Paging trigger for a full window.**
When loading a page on one side unmounts a page on the other, the trigger distance is reduced to less than `(scrollable − page extent) / 2`. Otherwise small items make the two edges trigger each other forever (80 items of 20 px with a 1,500 px preload). Covered by a test over item heights from 20 to 200 px.

**D37. Unread counter.**
`unreadCount` = server count − server-counted messages read here + messages that arrived since the last server state and aren't read. A new server read state replaces the "arrived" part. Without a read marker (`lastReadInbox == null`) the unread messages are taken to be the newest incoming ones.

**D38. Read receipts are throttled, not restarted.**
The first read starts a `readDebounce` timer; later reads don't restart it, so continuous reading still sends a receipt every 300 ms. A failed receipt is retried with `RetryPolicy`; `onReadUpTo` is called once per key.

**D39. `open()` superseded by a newer `open()` / `switchTo()` completes with `OpenResolution.bottom`** and changes nothing. Only the last one emits `ListOpened`.

**D40. Not in this milestone:** `jumpTo…`, `reselect`, `search` (milestone 4); `insertLocal`, remove animations (5); selection, geometry, visibility, prefetch, the remaining callbacks (6); `invalidate`, `reset`, the cache (7); `debugDescribe` (8). `MessageListConfig` and `MessageListCallbacks` only have the fields that already work.

## View and scroll position (§11)

**D41. Scroll structure: two sliver lists around a center that is not an item.**
`CustomScrollView(center: …)` with an upper list (rows older than the split, index 0 nearest the center) and a lower list (the split row and newer). A placement sets the split, so the first frame needs no measuring (§11.4): for an anchor or the unread divider the anchor row is the first row below the center and `pixels = −offset`; for the bottom every row is above the center and `pixels = maxScrollExtent`.

**D42. The center is not moved to the anchor after trims (deviation from §11.1 "re-center").**
Moving the center moves rows from one sliver list to the other, which destroys their `State` (playing video, running animations) unless every item has a `GlobalKey` (forbidden by §14 rule 8). Instead:
- rows never change lists between placements;
- when one side of the center has no surviving row, the center moves to the edge of the other side, so rows that come back (a page re-added after a trim) grow away from the center;
- `_SteadySliverList` makes built rows keep their layout offsets when their indices change (D43).
A new placement (open, restore; jumps in milestone 4) builds fresh sliver lists.

**D43. `_SteadySliverList`: built rows keep their layout offsets across index changes.**
A stock `SliverList` ties layout offsets to indices. When rows are removed or added before the built ones (window trim), each moved child takes the offset of whatever used to be at its new index, or loses its offset and is destroyed together with its `State`. The subclass restores every surviving child's own offset after the element rebuilds. The list then reflows from its first built child as usual; a gap left at index 0 is closed by `RenderSliverList`'s own scroll offset correction when the viewport gets near it, and the anchor logic absorbs the remainder. This relies on documented `RenderSliverList` behavior and is covered by test 5 and the stress test on Flutter 3.24 and 3.50.

**D44. Anchor correction compares scroll offsets, not screen positions.**
At every accepted layout the position records the scroll offset of the first visible row (and three fallbacks). At the next layout, if that offset changed, content before the anchor changed size and `pixels` is corrected by the same amount in the same layout pass (§11.2). User scrolling changes `pixels`, not the row's offset, so it is never fought. Offsets are read from the sliver parent data (O(1) per row) instead of `getOffsetToReveal`.

**D45. Corrections made by the viewport itself are accounted for.**
When a sliver asks for a scroll offset correction, the viewport calls `correctBy`; the recorded anchor offsets are shifted by the same amount so the anchor logic doesn't apply it twice.

**D46. Bottom pinning keeps the distance to the bottom.**
A list within `stickToBottomThreshold` of the bottom is pinned: when content or the viewport changes size, the distance to the bottom (0 when exactly at the bottom) is kept. It does not snap to 0, otherwise a slow scroll away from the bottom would be pulled back on every frame. Pinning wins over the anchor (§11.2 rule 3); `BottomStickPolicy` can refuse it while dragging.

**D47. "Leading filler sliver" is implemented as scroll bounds.**
Content shorter than the viewport reports `min == max` at the bottom-aligned offset, computed from the slivers' real extents. No filler widget is needed and nothing can be scrolled.

**D48. One row per message or album; day header and unread divider are part of the row below them.**
The row is the direct child of the sliver list, a repaint boundary, and registers its render object by id (no `GlobalKey` per item, §14 rule 8). Rows are cached: a window change rebuilds only new rows and rows whose flags changed; a message update rebuilds one row through `controller.listenableFor(id)` (§14 rule 1). Rebuilding the `MessageListView` widget rebuilds the built rows, because its builders may close over new state.

**D49. The view reports to the controller after the frame.**
Metrics are collected during layout and sent in a post-frame callback, so no controller state or app callback changes during build or layout (§13.1).

**D50. The controller does not page on metrics that are older than its window.**
After a window change the extents are stale until the view reports again; paging on them fetched a second page for every page. Window trimming never unmounts a row that is on screen (the other side gives way).

**D51. In the background the controller updates on a timer.**
Flutter stops frames when the app is paused or hidden, so the per-frame batching would freeze the unread counter and `onUnreadChanged`. Without frames, changes are applied on the next event-loop turn.

**D52. `cacheExtent` is used although deprecated in Flutter 3.41+.**
Its replacement does not exist in Flutter 3.24, the minimum version.

**D53. App lifecycle.**
`paused`, `hidden` and `detached` save the position with `SaveReason.appPaused`; on the web, hiding or closing the tab reports `hidden`, so no `dart:html` listener is needed. `SaveReason.pageHide` is reserved.

**D54. Not in the view yet:** the debug overlay (milestone 8).

**D55. The stress test compares frames where holding the anchor is possible.**
A frame is skipped when the list is pinned, still settling, or within 700 px of an end of the content (deleting can then leave less content than the distance to the end, and the physics must move the list). At least 80% of the 600 frames per run are compared.

## Simple API (added on the owner's request, not in the specification)

**D56. The package must be easy for small apps, not only for very large ones.**
The owner's goal is a list that fits any app with a conversation. The specification only describes the full hub / controller / source setup, so a layer was added on top without changing the engine.

**D57. `SteadyChatList`: one widget with three constructors.**
`.list` (the app has a `List`), `.stream` (a stream of complete lists) and `.source` (a paged backend). It owns the hub, the controller and, in the first two modes, the source. Named constructors make it impossible to pass two data sources. `MessageListView` with an explicit hub and controller stays the API for split views, chat switching and shared caches.

**D58. List mode opens in the first frame.**
The newest `windowSize` messages are put into the store before `open()`, so there is no loading frame. A rebuilt widget diffs the list only when its items are not the same objects as before (this also catches a list changed in place).

**D59. `ListMessageSource` and `StreamMessageSource` live in the core.**
They are pure Dart. Both keep the whole conversation in memory; for huge histories the paged `MessageSource` is the right tool. A stream source listens while a list is attached and catches up by difference when it is attached again.

**D60. `MessageAdapter.from` builds an adapter from functions.** A subclass is still possible and slightly faster to call.

**D61. Page tokens.**
`PageResult.olderCursor` / `newerCursor` are stored at the edge key they belong to and come back as `PageRequest.cursor` when the list pages past that edge. Backends that page by key ignore them. If the edge key is deleted the token is dropped and the request has only the anchor.

**D62. An added message older than a segment that starts at the beginning of history becomes the new beginning.**
Before, it was stored as an orphan and never shown. This matters for list and stream mode, where older messages can appear after the whole history was loaded.

**D63. Default states were pulled forward from milestone 6.**
`DefaultLoadingState`, `DefaultEmptyState`, `DefaultErrorState` and `SteadySpinner` use only `package:flutter/widgets.dart`, so they work in Material, Cupertino and custom apps. The texts are English; apps localize by passing builders.

## Jumps and search (§10.4, §10.5, §10.10)

**D64. A jump outside the window swaps the window; the extra "current anchor message" is not kept.**
§10.4 builds the new window as "[current anchor message] + keys around the target". A web client needs that for its DOM; here the swap happens in one frame with fresh slivers, the first frame already shows content one viewport before the target, and the rest is animated. Keeping one stray old message at the edge would only add a visible artifact.

**D65. A jump inside the window scrolls only when the target is laid out and has room.**
If the target is in the window but not built (far away), or sits so close to the window edge that it could not be centered, the window is rebuilt around it (from memory, or with one `around` fetch). Otherwise the jump would stop early at the end of the loaded content.

**D66. The view decides how to move; the controller decides where.**
`MessageListViewport` (`scrollToItem`, `scrollToBottom`, `isBuilt`, `rectOf`) is implemented by `MessageListView`; tests and custom views can implement it. While a jump animates, anchor correction is off and the jump re-aims at where its target is now (media loading, rows changing).

**D67. Jump fetches run one at a time.**
A jump that is superseded while it waits for the running fetch never sends its own. Ten fast "next result" presses cause at most two requests in flight (test 12).

**D68. The highlight is timed by the controller and animated by the view.**
The controller sets `highlighted` and emits `highlightEnded` after `delay + duration`, so headless users and analytics get the same events. The view runs one animation and hands it to the target row as `MessageItemInfo.highlight`.

**D69. `highlightQuery` is given to every item while a search is active**, not only to the target, so all visible matches can be marked. `MessageSearchNavigator.close()` or `clearHighlightQuery()` clears it.

**D70. Jump to date aligns the row top.** Day headers are part of the first row of the day (D48), so "below the day header" needs no header height.

**D71. Unread mentions and reactions are removed locally on arrival** (the read state is updated as an event). A server read state that arrives later replaces it.

**D72. `jumpToPinned(key, barHeight:)`** takes the bar height as an argument; the list doesn't know the app's pinned bar.

**D73. `reselect()` stays `void`** (as specified) and reports through `onJump`. `switchTo` with a message target on the open list is a jump with `JumpReason.deepLink`.

**D74. Not done from §10.4:** moving accessibility focus to the target on arrival (milestone 6, with semantics).

## Sending, updates and deletes (§10.6, §10.7)

**D75. `insertLocal({id, build})` takes a builder.**
The specification passes a ready message, but the key of a pending message depends on the newest loaded message, and the list can't write a key into the app's message class. `build` receives the key the message must carry. If the newest messages are not loaded (the list shows an island), they are loaded first, so the pending message sorts after the real newest one.

**D76. A message keeps the widget id it was first shown with.**
`controller.stableIdOf(key)` maps a confirmed message back to the client id it was sent with, for as long as it is in the window. The row keeps its element and `State` through the ack (test 9). Out-of-order acks reorder rows by server key without recreating them.

**D77. A confirmed message sorts by its server key, pending ones stay right after the message that was newest when they were sent.** So when a later send is confirmed first it moves below the ones still pending, as in Telegram.

**D78. Deleted rows stay as "ghosts" until their animation ends.**
The store deletes at once (so counters, paging and the unread divider are right immediately). The controller keeps the deleted message in the window for `removeDuration` (`MessageWindow.removing`), the row plays the remove transition and ignores touches, then the row is removed in one step, or its height closes during a second `removeDuration` with `collapseRemovedRows`. All deletes of one frame form one batch: they finish together with one correction. The anchor is never a row that is being removed.

**D79. The transition wrappers are always present.**
Every row is wrapped in the appear and remove transitions with constant animations while nothing moves. Adding a wrapper when an animation starts would recreate the item's element and lose its state.

**D80. The day header leaves with the row only when no other row of that day remains**; otherwise it moves to the next row of the day when the row is removed.

**D81. Delivery state is read when a row builds**, so `LocalFailed` rebuilds one row and does not publish a window.

**D82. "Ends at the newest message" is judged against what the controller has processed.**
Events reach the store at once and the window once per frame. A window published in between (an appear mark ending, a page growing) compared itself with the store's newest key, concluded it had fallen behind and lost the bottom pin for good. Found by the 50 messages per second test.

**D83. After deletes at a window edge the window stays in the reader's segment** even if the nearest remaining key is an orphan or belongs to another island.

## Selection, visibility, theme and default widgets (§10.11, §10.12, §11.6, §11.7, §12)

**D84. The theme does not depend on Material.**
The specification asks for a `ThemeExtension`. `package:flutter/material.dart` is deprecated since Flutter 3.47 (Material moved to its own package), so a package that imports it would warn today and break later. `MessageListTheme` is a plain class provided by `MessageListThemeScope` (an `InheritedWidget`); without a scope it follows the platform brightness. Material apps can map their `ThemeData` to it in one place.

**D85. The default buttons draw their own icons.**
The chevron is painted and "@" / "♥" are text, so no icon font is required.

**D86. Floating overlays are opt-in on `MessageListView` and on by default in `SteadyChatList`.**
`scrollDownButtonBuilder` and `floatingDayBuilder` add overlays; `MessageListButtons` gives the three buttons to apps that place them themselves. `SteadyChatList` shows the default scroll-down button unless `scrollDownButton: false`.

**D87. Day labels are English ("Today", "Yesterday") with `intl` dates.** `DayHeader(label:)` and `formatDayLabel(locale:)` are the localization hooks; the package ships no translations.

**D88. Selection clears itself.** Deleted messages leave the selection, and selection mode ends when nothing is left, so "delete selected" is `controller.remove(selection.selectedIds.toList())`. Switching to another list clears it.

**D89. `onMessagesSeen` fires when at least half of a message is visible**, once per message per visit. `onItemVisibility` fires when a message crosses hidden / partly / mostly / fully visible.

**D90. Prefetch is suggested once per window edge**: up to 20 messages beyond each edge that are already in memory. Messages that are not loaded yet can't be suggested.

**D91. Keyboard shortcuts work on desktop and web after the list was clicked.** The list takes focus on pointer down only on those platforms; on phones that would close the keyboard. Home goes to the oldest loaded message, Ctrl/Cmd+Home to the first message of the chat (a date jump to 1970), End to the bottom.

**D92. `SwipeToReply` measures the angle from where the finger went down.** A horizontal drag recognizer only reports horizontal movement, so the 20° rule uses the raw pointer position at the moment the drag is recognized.

**D93. Semantics order uses the message key.** Each row has an `OrdinalSortKey` with `key.order`, which is stable when the window changes.

**D94. Not done from §11.6 / §11.7:** the iOS status-bar tap (it needs the list to be the primary scroll view of the route, which is the app's choice), announcing incoming messages and moving accessibility focus to a jump target (`SemanticsService.announce` changed between the supported Flutter versions; planned with the next SDK bump).

## Cache (§8.2, §8.3, §13.5)

**D95. The cache is a persistent mirror of the newest part of each list, managed by the hub.**
`MessageListHub(cache: …)` writes every page and event through, and reads a list once (`hydrate`). There is no separate `CachingMessageSource`: the hub already owns the store, the single-flight fetches and the events, so wrapping the source would duplicate that. With the default eviction (newest 500 messages per list plus the saved position) the cached part of a list always fits in memory, so `hydrate` loads all of it and no `range` query is needed (the method was dropped from the interface).

**D96. Segments are passed to the cache.**
`applyPage` and `applyEvents` receive the list's segments as they are in memory after the change. The cache stores them instead of re-implementing the segment algorithm in SQL. On load, the store only believes what it is given: a segment is cut down to the loaded messages and keeps an end flag only if that end was loaded.

**D97. Eviction splits segments at holes.**
When a cache keeps the newest messages and the ones around the saved position but drops what lies between, the two kept runs become two segments (`clampSegments`). Recording them as one run would hide the missing history after a restart.

**D98. A controller waits for `hydrate` when the list has not been read from the cache.**
SQLite is asynchronous, so the first frame shows the loading state unless the app calls `hub.hydrate(list)` before it builds the chat; then the first frame is already correct. Memory wins over the cache: only an empty list is filled from it.

**D99. After a restart the cached "newest" segment is shown at once and then verified.** The background refresh after every open (D34) merges what was missed, or demotes the cached segment when more than a page was missed.

**D100. Where the position is saved:** `callbacks.saveSnapshot` → else the cache → else the hub's `viewportStore`. `SharedPreferencesViewportStore` reads synchronously (local storage on the web), which together with D30 restores the position after a browser reload even without Drift.

**D101. `invalidate()` reconciles the page around the top of the viewport.** Stored confirmed messages inside the returned page that the server no longer returns are removed (a delete missed while offline). Pending local messages stay. Then the usual refresh loads what is newer.

**D102. `DriftMessageCache` has no generated code and takes a drift executor.**
The schema is plain SQL in `SteadyCacheDatabase`, so the package works with every drift 2.x version and both supported Dart versions, and has no build step. It depends on `drift` only; the app picks the executor (`drift_flutter` for Flutter including the web, `NativeDatabase` on the VM). Versus the specification: no `tombstones` table and no `version` column (the mirror design doesn't need them), `segments` stores the local sequence of its bounds, and schema changes are handled by rebuilding the cache (it can always be refilled from the server) instead of `drift_dev` schema dumps.

**D103. Web multi-tab.** `DriftMessageCache.watch()` forwards drift's table update notifications, which drift shares between tabs that use the same database; the hub then merges the cached data into its open lists. Own writes are filtered out. Verified on the VM with a simulated foreign notification; a real two-tab run is part of the example app checks.

**D104. Messages are decoded on the calling isolate.** At most about 600 small payloads are decoded per list, once. Moving that to another isolate needs sendable codecs, which closures over app classes often are not.

## Example, benchmarks, debug tools (§16, §17, §19)

**D105. A saved position deep in the history is restored after a restart by default** (`restoreIslandsAfterRestart: true`). §10.1 drops it (as Telegram does), and then a browser reload in a chat with unread messages opens at the first unread message instead of where the reader was. The owner's requirement is that a reload shows where the user was, so the default follows that; `false` gives the behavior of the specification. Found by reloading the example in a browser.

**D106. Eviction splits a segment instead of keeping everything between two protected ranges.** Before, the messages between two windows on one list, or between the saved position and the window, were never dropped, so one long scroll without a pause kept everything it passed (found by the memory benchmark: 100,029 messages after scrolling 100,000). Now the messages farthest from any protected range go first and each kept run becomes its own segment, the same rule the cache uses (D97). The controller trims after every window change, with one page of slack.

**D107. The debug overlay exists only in debug builds** (`kDebugMode`), so it costs nothing in release. `debugDescribe()` works in every build.

**D108. `typingUserIds` on the controller.** The store already tracked `TypingChanged`; a footer needs a listenable.

**D109. The example has one page per capability, a left menu with a one-line description under each title** (the owner's request), and remembers the open page, so a browser reload returns to the same page and position. Positions are kept by `SharedPreferencesViewportStore`; the Drift cache is one of the demos, not a requirement for restoring.

**D110. The example's server is deterministic and generated on demand**, including search: the first word of message *n* depends on *n* modulo the word list, so "3 of 250,000" over ten million messages is a formula. The hash uses small factors so that it gives the same content on the web, where integers are doubles.

**D111. Benchmarks measure frame times with `SchedulerBinding.addTimingsCallback` and run with `flutter drive --profile`.** `traceAction` needs a VM service connection that is not available on every target; frame timings are the same numbers the engine reports to DevTools. "Build" in the results is the whole UI-thread part of a frame (build, layout and paint), which is stricter than the "build + layout" of §14.1. Budgets are asserted with 10% slack in profile and release builds only. There is no CI in the repository yet; the same command is what a CI job would run.

**D112. Measured on: macOS, an Android emulator, a Galaxy S24 Ultra (profile), Chrome (release), and an iPhone simulator (debug, correctness only). Not measured: a mid-range Android phone and a physical iPhone.**

**D113. Every write of the Drift cache is one request that carries its own `BEGIN IMMEDIATE` and `COMMIT`; reads hold no transaction.** A drift transaction or batch is several messages to the database (begin, statements, commit). On the web all tabs share one connection in a worker, and a tab that the browser freezes between two of those messages (it goes into the back/forward cache when the user navigates away) leaves the transaction open: every other tab, and the same tab after coming back, then waits forever. Found with two real Chrome tabs. A write is now `executor.runBatched` with the transaction statements inside, which the worker runs to the end whatever happens to the tab; a failed statement is followed by `ROLLBACK`. Eviction reads first and then writes once.

**D114. `MessageListHub.cacheTimeout` (3 s).** `hydrate` gives up on a cache that does not answer, reports it through `onError`, and the list loads from the source. A cache may make a chat faster; it must never keep it from opening. Verified against the locked database of D113.

**D115. A message that another tab is still sending is not merged from the shared cache.** Only the sending tab receives the ack that replaces it; in the other tab it stayed "sending" forever next to the confirmed message. The confirmed message is merged as usual. (D103 is now verified with two real tabs.)

**D116. The sliver does not build rows at indices that became free.** When the window shifts, the rows that stay move to other indices. Flutter's `SliverMultiBoxAdaptorElement.performRebuild` then builds a new child at every index they left, at once: about 35 rows far from the viewport, built in one frame and dropped by the next layout. During a rebuild the delegate now returns nothing for indices beyond the last existing row, and the sliver is marked for layout, which builds only what the viewport and its cache area reach. A missing row before or between existing rows is still built at once, because layout would not look for it. Found by tracing slow frames of the fling in Chrome.

**D117. Paging distances are estimated from the number of messages, not from scroll extents.** The slivers keep the layout offsets of rows that stay (D-notes of milestone 3), so after rows near the center are unmounted the scroll extent still counts the space they left. With those extents the rule that keeps the two edges from triggering each other failed: a page was added on one side, and in the same frame the window was extended back on the other. The view now also reports the distance to each window edge as (messages there) × (average height of the visible ones), and paging uses that (`ViewportMetrics.windowExtentBefore` / `windowExtentAfter`; a custom view may leave them out).

**D118. What was read from the cache is checked against the server when it comes on screen.** Opening from the cache used to fetch only what is newer, so a message deleted or edited on the server while the app was closed stayed as cached until the app called `invalidate()`. Now the hub remembers the key ranges it read from the cache and that no page has confirmed (`isUnverified`). While a list has such ranges, every page fetched for it is reconciled, and the controller fetches the page around the first or last visible message when that message is unverified. The same message is asked for once; after a failed attempt (offline) the controller waits for a page that loads, a reopen or `invalidate()`. A reconciled `around` page also speaks for its anchor (a page around a deleted message does not contain it), and an empty page that reached both ends empties the list. Cost: reading cached history online is one request per page scrolled, as without a cache.

**D119. A list that nobody listens to any more is unverified, like a list read from the cache.** A chat closed and opened again in the same run opened from memory and fetched only the newest page without reconciling, so a message deleted on the server while the chat was closed stayed on screen even though the server no longer returned it. When the hub releases the events of a list (`releaseDelay` after the last controller detached), it marks every loaded range of that list unverified, and D118 does the rest. The refresh after an open runs first and the check of what is on screen after it, so a chat reopened at the bottom costs one request, not two. An app that delivers events itself and does not use `MessageSource.events` should set `releaseDelay` to zero.

**D120. An edge with nothing left to load does not take part in the paging rule.** `_maybePage` asked the older edge first and the newer one only otherwise. A window shorter than the preload distance at the start of the history is near both edges, so the older edge, already at the end, was chosen on every frame and the list never loaded downward. Found in the first real app: a chat opened at its first unread message, which was also its first message. The unread divider is also trusted when the read position is before the first message of a segment that reached the oldest end.

**D121. A list that opens at a saved position shows the unread divider too.** The divider was drawn only when the list opened at the first unread message. An app that prefers the saved position (the reader returns to where they were) then had no mark of where the new messages start. The divider is now set on a restore as well, under the same rule as before: only when the messages around the read position are loaded.

**D122. An open that fetched its page does not refresh it.** After an open at a saved position, the first unread message or a target message, the controller asked for the messages newer than the shown segment. When the page was fetched by that same open, the request brought nothing new. It is skipped; a list shown from memory still refreshes.

## Known limits

**L1. Stale pages are the controller's job.** The store accepts whatever it is given. Two cases can make a late page wrong and are excluded in the property test: a late "this is the newest" answer, and a page fetched before an orphan was evicted. Generations and single flight (§15, milestone 2) drop such pages before they reach the store.

**L2. `firstUnread` looks at loaded messages only.** If `lastReadInbox` is not loaded it returns the first loaded incoming message of a segment. The open rule (§10.1, milestone 2) fetches around `lastReadInbox` first.

**L3. A page whose items were all deleted locally makes no progress.** The edge then shows an error instead of fetching the same page forever; retry works once the tombstones expire (5 min).

**L4. A window smaller than the viewport plus one page can't page smoothly.** With tiny items or a huge viewport, raise `windowSize` (see D36).

**L5. Many rows inserted at once exactly at the center boundary are laid out one per layout cycle.** `RenderSliverList` adds one leading child per cycle when it sits at scroll offset 0. A batch of more than ten late messages landing exactly between the two lists can take more than one frame to settle.
