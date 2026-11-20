# Decisions

Every interpretation of `SPEC.md`, with the reason. Section numbers refer to the spec.

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

## Known limits

**L1. Stale pages are the controller's job.** The store accepts whatever it is given. Two cases can make a late page wrong and are excluded in the property test: a late "this is the newest" answer, and a page fetched before an orphan was evicted. Generations and single flight (§15, milestone 2) drop such pages before they reach the store.

**L2. `firstUnread` looks at loaded messages only.** If `lastReadInbox` is not loaded it returns the first loaded incoming message of a segment. The open rule (§10.1, milestone 2) fetches around `lastReadInbox` first.
