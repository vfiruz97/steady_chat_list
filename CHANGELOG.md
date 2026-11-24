# Changelog

All packages in this repository share one version.

## 0.1.8

- **Fixed (0.1.7 regression):** sending a message at the bottom of the list replayed the jump-to-bottom animation from a screen above. The list now moves up by the new message only.

## 0.1.7

- **Fixed:** a jump to the bottom could scroll past the last message, show blank space and fall back, when rows below were much taller or shorter than the list had estimated (an image, for example). It now always rises to the last message.

## 0.1.6

- A list that opens at a saved position shows the unread divider too, when the first unread message is loaded there. Before, the divider appeared only when the list opened at the first unread message.

## 0.1.5

- Fewer requests on open: a list that opens on a page it has just fetched (a saved position, the first unread message or a target message that was not in memory) no longer asks for the newer messages right after it. A list opened from memory still catches up as before.

## 0.1.4

- **Fixed:** a chat that was closed and opened again in the same app run kept showing messages deleted or edited on the server meanwhile. Once the hub stops listening to a closed list (`releaseDelay`), what stays in memory is checked against the server when it comes on screen again, like cached messages.
- **Fixed:** a list that opened with few messages at the very start of the history (a new chat, or a chat where every message is unread) did not load newer messages when scrolled down: the older edge, which had nothing left to load, kept the newer one from loading.
- **Fixed:** a chat where reading stopped before its first message now opens at the first unread message with the divider, not at the bottom.
- `MessageListConfig.scrollDownButtonDistance`: show the scroll-down button a number of pixels from the end instead of a share of the viewport height.
- Docs: `MessageListView.keyboardShortcuts` takes the keyboard focus on click; turn it off inside a `SelectionArea`.
- Docs: an `older` page shorter than `limit` is read as the start of the history. The guide said the opposite. A source whose server returns the anchor message too must ask for one more.

## 0.1.3

- **Fixed:** with a cache, messages deleted or edited on the server while the app was closed stayed on screen as cached until the app called `invalidate()`. Cached messages are now checked against the server when they come on screen and corrected without moving the viewport; the cache is corrected too. `MessageListHub.isUnverified`.
- **Fixed:** refreshing around a message that was deleted on the server removes it also when it was the first or last message loaded; a chat cleared on the server is emptied.

## 0.1.2

- `steady_chat_list_core`: a runnable `example/example.dart`; the README sample no longer uses `const PageRequest`, which does not compile.
- Doc comments on the `CancellationToken` and `InMemoryViewportStore` constructors.

## 0.1.1

- A screen recording and a screenshot in the README and on the pub.dev page.
- `steady_chat_list_drift` is not on pub.dev yet; the READMEs link to the repository.

## 0.1.0 — first release on pub.dev

The same code as `0.1.0-dev.9`, published as `steady_chat_list` and `steady_chat_list_core`. `steady_chat_list_drift` stays in the repository for now.

## 0.1.0-dev.9 — milestone 8: example app, benchmarks, debug tools

### steady_chat_list_core

- **Changed:** eviction drops what is farthest from the protected ranges, also between two of them, and splits the segment at the hole. Before, everything between two protected ranges (two views of one chat, or the saved position and the window during one long scroll) was kept, so memory grew with the distance scrolled.
- **Changed:** `OpenContext.restoreIslandsAfterRestart` defaults to true.

- `MessageListHub(cacheTimeout:)`: a cache that does not answer within 3 s is reported and the list loads from the source.
- **Fixed:** a message another browser tab was still sending was merged from the shared cache and stayed "sending" forever.

### steady_chat_list

- `MessageListView(debugOverlay: true)` and `controller.debugDescribe()`.
- **Performance:** when a page arrives, only the rows near the viewport are built (about 35 rows far away were built and dropped in one frame), and the window no longer bounces between two positions. `ViewportMetrics.windowExtentBefore` / `windowExtentAfter`.
- **Changed:** `SteadyChatList` no longer restarts the list when it is rebuilt with a new adapter object (an adapter written inline in `build`); it reads through the newest one.
- `controller.typingUserIds` for a typing indicator.
- **Changed:** `MessageListConfig.restoreIslandsAfterRestart` defaults to true: a position deep in the history is restored after a restart or a browser reload, also when the chat has unread messages. Set it to false for the previous behavior.
- **Fixed:** memory is trimmed whenever the window moves (paging, jumps, new messages at the bottom), not only when it grows from messages already in memory.

### steady_chat_list_drift

- **Fixed:** on the web, a tab that was navigated away in the middle of a write could leave a transaction open and block the cache for every tab. Each write is now a single atomic request; reads hold no transaction.
- `benchmark/drift_benchmark.dart`.

### Documentation

- `AI_GUIDE.md` in the package: rules for AI coding assistants that use it. `AGENTS.md` in the repository for assistants that change it.

### Example and benchmarks

- `example/`: a demo app with a left menu of twelve demos on a simulated server with a 10,000,000-message chat. Reloading the browser restores the page and the position.
- `benchmarks/integration_test/performance_test.dart`: fling, cached open, jumps, message and reaction storms, memory. Results in `benchmarks/RESULTS.md`.
- A README and CHANGELOG in every package.

## 0.1.0-dev.8 — milestone 7: cache

### steady_chat_list_core

- `MessageCache`, `CachedList`, `EvictionPolicy`, `CacheChange`, `InMemoryMessageCache`, `clampSegments`.
- `MessageListHub(cache:, evictionPolicy:)`: write-through of pages and events, `hydrate`, `loadSnapshot` / `persistSnapshot`, `reset`, merging changes from other tabs; `fetch(reconcile: true)`.
- `ListStore.restore`, `ListStore.reset`, `applyPage(reconcile: true)`.

### steady_chat_list

- Lists open from the cache, offline, at the saved position.
- `invalidate()` (refresh after a reconnect without moving) and `reset()`.
- `SharedPreferencesViewportStore`: positions survive restarts and browser reloads. New dependency: `shared_preferences`.

### steady_chat_list_drift

- `DriftMessageCache`, `SteadyCacheDatabase` (plain SQL schema, no code generation), `MessageCodec`, `JsonMessageCodec`.

### Tests

- Acceptance tests 24 and 25 (VM). 168 tests in `steady_chat_list`, 113 in the core, 9 in the Drift package.

## 0.1.0-dev.7 — milestone 6: selection, visibility, theme and widgets

### steady_chat_list

- `controller.selection` (`SelectionController`): toggle, shift-click range (`extendTo`), `selectRange`, `selectAllLoaded`, drag select, `SelectionPolicy`; survives paging; cleared by deletes. `MessageItemInfo.isSelected` / `selectionActive`.
- Visibility: `onVisibleRangeChanged`, `onItemVisibility` (hidden, partly, mostly, fully), `onMessagesSeen`, `onItemDisposed`, `onPrefetch`, `onTopVisibleDayChanged`, `onDayTap`, with matching events; `visibleItems`, `topVisibleDay`, `ensureVisible`.
- Default widgets: `ScrollDownButton` (badge 1–999, 1K, 7.2K, 1M; loading ring), `MentionButton`, `ReactionButton`, `MessageListButtons`, `DayHeader`, `UnreadDivider`, `VisibleWhen`, `SwipeToReply`; `formatUnreadCount`, `formatDayLabel`.
- `MessageListTheme` and `MessageListThemeScope` (no Material dependency), light and dark defaults.
- `MessageListView`: `scrollDownButtonBuilder`, `floatingDayBuilder` (chip that shows while scrolling), keyboard shortcuts on desktop and web, semantics order.
- `SteadyChatList` shows a scroll-down button by default.
- New dependency: `intl` (day labels).

### Tests

- Acceptance test 23. 162 tests in `steady_chat_list` (99.6% lines), 103 in the core (100%).

## 0.1.0-dev.6 — milestone 5: sending, incoming and deletes

### steady_chat_list

- `insertLocal({id, build})`: optimistic sending. The list goes to the bottom, the message fades in; `LocalAcked` swaps it in place and keeps its widget state (also when acks arrive out of order); `LocalFailed` shows `SendState.failed`.
- Appear animation for new messages (`appearDuration`, `appearTransitionBuilder`, `shouldAnimateInsert`, `MessageItemInfo.isJustAdded`).
- Delete animation: fade, shrink to 30% and slide toward the sender's side, then the row is removed in one step (`removeDuration`, `removeTransitionBuilder`, `shouldAnimateRemove`, `collapseRemovedRows`, `remove(ids, animate: false)`). Local, remote and batch deletes behave the same; a batch finishes together.
- `stableIdOf`, `nextLocalKey`; `MessageWindow.removing` and `justAdded`; `ItemTransitionBuilder`.
- Fixed: a list at the bottom could lose its pin when messages arrived faster than frames.
- Fixed: the unread divider moves at once when the first unread message is deleted.

### steady_chat_list_core

- `StoreDelta.removedMessages`.

### Tests

- Acceptance tests 7, 8 and 9. 140 tests in `steady_chat_list`, 103 in the core.

## 0.1.0-dev.5 — milestone 4: jumps and search

### steady_chat_list

- `jumpTo`, `jumpToBottom`, `jumpToDate`, `jumpToNextUnreadMention`, `jumpToNextUnreadReaction`, `jumpToPinned`, `reselect`.
  - Any distance: one fetch at most, the window is swapped in one frame, at most one viewport is animated, never a blank frame.
  - `JumpOptions`: alignment (center, top, bottom, fraction, minimal), scroll (animated or instant), highlight, reason.
  - A deleted target lands on the nearest message; a drag, a new jump, a chat switch or dispose cancels.
  - `onJump` / `Jumped` events: started, loading, scrolling, arrived (with the item rectangle), highlightEnded, cancelled, failed.
- Highlight: `MessageItemInfo.highlight` (1 → 0), `highlightQuery`, `highlightReason`; `JumpHighlightBackground`.
- `MessageSearchNavigator` (`controller.search`): debounced query, next / previous / goTo, result paging, neighbour prefetch.
- `currentPinned`, `unreadMentionsCount`, `unreadReactionsCount`, `jumpInProgress`, `highlighted`, `rectOf`, `prefetchAround`.
- `MessageListViewport` for custom views.

### steady_chat_list_core

- `JumpAlignment`, `JumpReason`, `JumpOutcome`, `JumpResult`.

### Tests

- Acceptance tests 10–17. 122 tests in `steady_chat_list` (99.9% lines), 103 in the core (100%).

## 0.1.0-dev.4 — simple API

### steady_chat_list

- `SteadyChatList`: the whole list in one widget.
  - `.list`: over a `List` the app has; opens in the first frame; rebuild with the changed list.
  - `.stream`: over a stream of complete lists (Drift, Firestore, Supabase).
  - `.source`: over a paged backend.
- Default states: `DefaultLoadingState`, `DefaultEmptyState`, `DefaultErrorState` (tap to retry), spinner and retry rows at the window edges, `SteadySpinner`. No Material or Cupertino needed.
- Page tokens are passed back to the backend when paging.

### steady_chat_list_core

- `ListMessageSource` and `StreamMessageSource`.
- `MessageAdapter.from` (an adapter from functions).
- `PageResult.olderCursor` / `newerCursor`, `PageRequest.cursor`, `ListStore.cursorAt`.
- A message older than the loaded beginning of history becomes the new beginning.

### Tests

- 89 tests in `steady_chat_list` (99.7% line coverage), 99 in `steady_chat_list_core` (100%), including a streaming (AI assistant) reply that grows at the bottom.

## 0.1.0-dev.3 — milestone 3: the view

### steady_chat_list

- `MessageListView`: center-keyed scroll view over the controller's window.
  - First frame at the right place: saved position, first unread (divider 10 px from the top) or bottom.
  - No movement when pages load, the window is trimmed, messages are inserted or deleted, media resizes, the keyboard opens, the footer grows or the width changes.
  - A delete above the viewport moves nothing.
  - Pinned to the bottom for incoming messages, keyboard and footer; content shorter than the viewport sits at the bottom.
  - Albums (`groupBuilder`), day headers (`dayHeaderBuilder`, `onDayTap`), unread divider, edge rows with retry, history start, footer, loading / empty / error builders, padding, scrollbar switch.
  - One message change rebuilds one row.
  - Saves the position when the app is paused or the tab is hidden.
- `AnchoredScrollPosition` and `AnchoredScrollHost`.
- `MessageItemInfo` (group, day, unread, send and read flags), `SendState`, builder typedefs.
- Controller: `listenableFor`, `keyBefore` / `keyAfter`, `sendStateOf`, `lastReadOutbox`, `windowEndsAtNewest`, `reportDiagnostic`; `AnchorCorrected` diagnostic; `cacheExtent` and `groupingGap` in the config.
- Fixes found by the view tests: no second page on stale metrics, visible rows are never unmounted by a trim, counters keep updating in the background.

### Tests

- Acceptance tests 1, 2, 5, 6, 18, 19 and the visual half of 4.
- Stress test: random inserts, deletes and resizes above, inside and below the viewport every frame for 10 s, three seeds, rows above and below the center. Largest anchor movement: 0 px. Passes on the Dart VM, Chrome and Android (API 35 emulator).
- 78 tests in `steady_chat_list` (99.8% line coverage), 85 in `steady_chat_list_core` (100%).

### benchmarks

- Host app with `integration_test/anchor_stress_test.dart` to run the stress test on a device.

## 0.1.0-dev.2 — milestone 2: hub and headless controller

### steady_chat_list_core

- `MessageListHub`: owns the store and the event subscriptions (one per list, released 30 s after the last controller), shares identical in-flight page requests, drops cancelled results, protects every controller's window from eviction.
- `ViewportStore` and `InMemoryViewportStore` for persisted positions.
- Policies with defaults: `OpenPolicy`, `ReadPolicy`, `AnchorPolicy`, `GroupingPolicy`, `UnreadDividerPolicy`, `RetryPolicy`, `WindowPolicy`, `BottomStickPolicy`, `SelectionPolicy`, `PinnedPolicy`, bundled in `MessageListPolicies`.
- `OpenTarget`, `OpenResolution`, `OpenPlan`.
- Store: a page that proves keys beyond a segment's end without claiming the end clears the stale end flag.

### steady_chat_list

- `MessageListController`:
  - `open` / `switchTo`: session position → persisted position → first unread → bottom; synchronous when the data is in memory.
  - Windowed paging in both directions (at most `windowSize` built), retries, edge states, `retry`.
  - Bottom tracking, incoming messages, one window update per frame.
  - Read tracking: dwell, monotonic debounced receipts, optimistic unread counter.
  - Position saving (scroll idle, switch, dispose, explicit).
  - Imperative API: `apply`, `upsert`, `patch`, `remove`, `setReadState`.
- `MessageListConfig`, `MessageListCallbacks`, the `MessageListEvent` stream, `MessageListDiagnostic`.
- View contract: `MessageWindow`, `WindowPlacement`, `ViewportMetrics`, `VisibleItem`.
- Tests: 36 headless tests (acceptance tests 3, 4, 20, 22 and more). Core: 61 tests.

### Repository

- `CONTRIBUTING.md`.
- `LICENSE`, `repository` and `issue_tracker` in every package.

## 0.1.0-dev.1 — milestone 1: core

### steady_chat_list_core

- `MessageKey`, `KeyRange`, `ListId`, `MessageAdapter`, `ReadState`, `Segment`, `ViewportSnapshot`.
- Paging models: `PageDirection`, `PageRequest`, `PageResult`, `CancellationToken`.
- Backend interfaces: `MessageSource`, `MessageSearchSource`, `SearchPage`.
- `ListEvent` and its nine events (added, updated, deleted, local acked/failed, read state, pinned, history cleared, typing).
- `ListStore`: segmented store for one list.
  - Pages prove contiguous ranges; contiguity is never inferred from ids.
  - Idempotent, order-independent events; tombstones (5 min); history-cleared watermark.
  - Local messages, acks (also out of order), send failures.
  - Queries: `keysBefore`, `keysAfter`, `keysAround`, `keysBetween`, `segmentOf`, `liveSegment`, `isContiguous`, `nearestExisting`, `firstOnOrAfter`, `nextUnreadMention`, `nextUnreadReaction`, `firstUnread`, `pinnedAtOrBefore`.
  - Memory eviction that protects windows and the saved snapshot.
  - `StoreDelta` returned by every operation and sent to listeners.
- `MessageStore`: one `ListStore` per list, least-recently-used eviction of lists.
- Tests: 51, including 10,000 random operation sequences checked against a fake server (acceptance test 26).
- `benchmark/store_benchmark.dart`.

### steady_chat_list, steady_chat_list_drift

- Package skeletons.
