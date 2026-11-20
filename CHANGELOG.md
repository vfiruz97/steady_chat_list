# Changelog

All packages in this repository share one version.

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
- Tests: 51, including 10,000 random operation sequences checked against a fake server (SPEC §18 test 26).
- `benchmark/store_benchmark.dart`.

### steady_chat_list, steady_chat_list_drift

- Package skeletons.
