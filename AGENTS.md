# Notes for AI coding assistants

**Using the package in an app?** Read [packages/steady_chat_list/AI_GUIDE.md](packages/steady_chat_list/AI_GUIDE.md). It is the rule list for writing code with `steady_chat_list`.

**Changing this repository?** Read this page, then [CONTRIBUTING.md](CONTRIBUTING.md) for the commands and the code rules.

## What this package is for

- A message list for chat apps that never moves under the reader: paging, new messages, edits and jumps keep the visible message where it is.
- It is published on pub.dev and used in a production app. A regression reaches real users with the next release.
- It must stay simple to use and fit any chat app. When a change makes the public API harder to use, look for another way first.

## Hard limits

- Three packages under `packages/`, linked with `pubspec_overrides.yaml`. Do not turn the repo into a pub workspace.
- `steady_chat_list_core` is pure Dart. Do not import Flutter there.
- Minimum SDK is Dart 3.5 / Flutter 3.24. Do not use newer language features or APIs, even if your installed SDK accepts them.
- No Material or Cupertino imports in the packages, no `dynamic`, no global singletons, no `ListView(reverse: true)`.
- Do not infer that two messages are neighbours from their ids. Only a server page proves it.
- Do not call app callbacks during build or layout.
- Every public symbol has a dartdoc comment with a short example.

## How to fix a bug

1. **Reproduce it in a test first.** Write the failing test before touching the code, and see it fail for the reported reason. `packages/steady_chat_list/test/support/` has `ListHarness` (a real `MessageListView`), `FakeChatServer` and `FakeViewport`.
2. **Use real shapes in the test.** Bugs found so far came from rows of different heights, several messages in one second, a short history, state left from an earlier open, and rows added in the same frame as a scroll. Fixed 50 px rows and one message per second hide them.
3. **Assert every frame, not only the end.** For anything that scrolls, pump frame by frame and check positions on each one. Two shipped bugs ended in the right place and looked wrong on the way.
4. **Fix the cause in one place.** If a fix needs a number tuned to one case, the rule behind it is wrong.
5. **Ask what else takes the path you changed.** List the callers of the function before you finish. Version 0.1.7 fixed the scroll-down button and broke sending, because both call `jumpToBottom`.
6. **Run the whole suite**, not only the new test.

## Tests

- Every change comes with tests. Line coverage of the packages is kept near 100%.
- Where each kind of test goes:
  - store, segments, policies: unit tests in `steady_chat_list_core/test`;
  - controller behaviour without widgets: `controller_test.dart` and `controller_more_test.dart`, with `FakeViewport`;
  - anything that scrolls or is drawn: widget tests with `ListHarness`.
- A test that waits a fixed time can pass by luck. When a change moves a request earlier or later, read a failing test before you change its expectation: decide whether the test or the code is wrong.
- Never weaken an assertion to make a test pass. If an expectation is out of date, say why in the commit message.
- Before you finish, from the repo root:

  ```sh
  dart format --set-exit-if-changed .
  flutter analyze
  (cd packages/steady_chat_list_core && dart test)
  (cd packages/steady_chat_list && flutter test)
  (cd packages/steady_chat_list_drift && dart test)
  (cd example && flutter test)
  ```

  All must be clean. Changes to the view or the scroll position also need the stress tests listed in `CONTRIBUTING.md`.

## Behaviour changes

- Behaviour that differs from the obvious goes in [DECISIONS.md](DECISIONS.md) as the next `D` number, with the reason and how it was found. Read the entries near the code you change: many odd-looking lines have one.
- The `§` numbers in comments and tests point to an internal specification that is not in the repo. `DECISIONS.md` is the record you can rely on.
- A change in what users of the package see goes in `CHANGELOG.md` and in `packages/steady_chat_list/CHANGELOG.md`. Mark fixes with **Fixed:** and say what the user saw, not what the code did.
- If a rule in `AI_GUIDE.md` or a dartdoc comment disagrees with the code, one of them is a bug. Fix it in the same change. A wrong sentence in the guide once stalled paging in the app that followed it.
- `packages/steady_chat_list/README.md` is a copy of the guide part of the root `README.md`. Change both together.

## Releases

- All packages share one version. Bump the three `pubspec.yaml` files and the `steady_chat_list_core: ^x.y.z` constraints together, and add a changelog section to every package, also when it has no changes.
- Work on `develop`: commit and push there. `main` only moves forward to a release commit.
- **Publish only when the owner says so.** A go-ahead covers one version, not the next one.
- Order: merge `develop` into `main` (fast-forward) and push, publish `steady_chat_list_core`, wait until pub.dev lists it, then publish `steady_chat_list`. `publish.sh` does the two publishes. `steady_chat_list_drift` is not published.
- The dry run of `steady_chat_list` prints one hint about `pubspec_overrides.yaml`. That hint is expected. Any warning is not.
- A fix for a regression is a new version. Never republish or retract quietly, and name the version that introduced the problem in the changelog.

## Checking against a real app

- The package's own tests and the example did not catch the bugs fixed in 0.1.3 to 0.1.8. A real app with real data did.
- Before a release that changes scrolling, opening or paging, run it in an app through a local path override (`dependency_overrides` with `path:`), and remove the override after publishing.
- A hot restart does not pick up a changed dependency source. The app has to be stopped and started again.
- State what you verified and where. "Tests pass" and "seen working in the browser" are different claims, so do not merge them into one.

## Known weak spots

- **Overlays on the list.** The package cannot be told that part of the viewport is covered by a header. Apps work around it with fixed insets. A `coveredTop` setting is the planned fix.
- **Read state.** The package expects the server to send where reading stopped. An app that only has an unread count has to set and clear `ReadState` by hand, and stale state draws the divider in the wrong place.
- **Estimated extents.** Until the last row of a window is laid out, the end of the content is an estimate. Do not aim a scroll at `maxScrollExtent` unless that row is built (D123).
- **Platforms.** Most verification so far was on web. Say so when a change has not been run on Android or iOS.
