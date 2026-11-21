# Changelog

All packages in this repository share one version.

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
