# Changelog

All packages in this repository share one version.

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
- Policies with Telegram-like defaults: `OpenPolicy`, `ReadPolicy`, `AnchorPolicy`, `GroupingPolicy`, `UnreadDividerPolicy`, `RetryPolicy`, `WindowPolicy`, `BottomStickPolicy`, `SelectionPolicy`, `PinnedPolicy`, bundled in `MessageListPolicies`.
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
