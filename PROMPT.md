You are building `steady_chat_list`, an open-source Flutter package that gives any chat app a Telegram-grade message list, plus a big-number example app that proves it. The complete specification is `SPEC.md` at the repo root. It is the source of truth. Read all of it before writing any code, and re-read the relevant sections before each milestone.

## What success looks like
- A chat app on iOS, Android, Web or desktop plugs in its backend and message class (`MessageSource<M>`, `MessageAdapter<M>`) and gets everything in the feature checklist (§3). That includes:
  - opening at the saved position, the first unread or the bottom;
  - unlimited paging with at most ~80 built items;
  - zero scroll jumps on insert, edit, reaction, delete, media load, keyboard or resize;
  - gap-free jumps (search, reply, pinned, date, mention, bottom) under half a second;
  - optimistic sending, read tracking, selection, pinned-bar support, typing footer, threads and split view;
  - an optional Drift (SQLite) cache that also works on web.
- Every decision is replaceable (policies) and every state change is observable (callbacks and events) (§13). Nothing an app plugs in can crash, block or jump the list.
- Where Telegram has a flaw, do better. A delete above the viewport must not move visible content (§2, §10.7, §11.2).
- The example app (§17) runs a 10,000,000-message chat, async search with "3 of 1,248" navigation, reaction storms, remote deletes and a perf HUD. The performance budgets in §14.1 are met and recorded in `benchmarks/RESULTS.md`.

## How to work
1. Create the workspace exactly as §4. Use only the allowed dependencies.
2. Follow the milestones in §20, in order. For each one:
   - write the tests listed for it first (unit tests for pure logic, widget tests for §18);
   - implement until `dart format --set-exit-if-changed .`, `flutter analyze` (zero issues) and all tests pass;
   - update `CHANGELOG.md` and `DECISIONS.md` (every interpretation of the spec, with the reason);
   - stop and print a summary: what's built, the test count, the budget numbers measured so far, and open questions. Wait for my "continue".
3. Milestone 3 is the hardest: `AnchoredScrollPosition` with a center-key `CustomScrollView` (§11.1–§11.2). Build the stress test first: random inserts, deletes and resizes above, inside and below the viewport every frame for 10 s. The anchor must never move more than 1 px. Don't move on until it passes on Android and Chrome.
4. Public API: dartdoc with an example on every public symbol; `sealed` / `final class` / `@immutable`; no `dynamic`, no global singletons.
5. Performance rules in §14 are requirements, not suggestions. Measure them with the benchmarks in §19 as soon as the view exists.
6. If the spec conflicts with a Flutter limitation, implement the closest behavior, record it in `DECISIONS.md`, and flag it in the milestone summary.

## Don'ts
- Don't build real networking. The example uses the in-process `FakeChatServer` (§17).
- Don't use `ListView(reverse: true)` as the whole solution.
- Don't infer contiguity from ids. Only server pages prove there's no gap (§2, §7).
- Don't call app callbacks during build or layout (§13.1).
- Don't rebuild the whole list for one message change (§14 rule 1).

Start now: read `SPEC.md`, set up the workspace, then do milestone 1.
