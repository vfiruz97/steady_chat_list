# Contributing to steady_chat_list

Thanks for helping. This page covers how the repository is laid out, how to run the checks, and what a pull request needs.

## Before you start

- **Bugs and small fixes:** open an issue or send a pull request directly.
- **New features or API changes:** open an issue first. The behavior follows an internal specification, summarized in `DECISIONS.md`; changes to it are discussed before code is written.
- **Scroll jumps:** the most useful bug report is a failing test. `packages/steady_chat_list/test/support/` has a fake server and a fake viewport that reproduce most cases in a few lines.

## Layout

| Path | What it is |
| --- | --- |
| `packages/steady_chat_list_core` | Pure Dart: keys, store, segments, hub, policies. No Flutter imports. |
| `packages/steady_chat_list` | Flutter: controller, view, default widgets. |
| `packages/steady_chat_list_drift` | Drift (SQLite) cache. |
| `example` | Demo app. |
| `benchmarks` | Host app for device tests and benchmarks, and `RESULTS.md`. |
| `DECISIONS.md` | Design decisions with their reasons. The `§` numbers in code comments and tests refer to the internal specification. |

The packages are linked with `pubspec_overrides.yaml`. There is no pub workspace and no melos, so nothing needs to be installed besides Flutter.

## Setup

You need Flutter 3.24 or newer (Dart 3.5 or newer).

```sh
git clone https://github.com/vfiruz97/steady_chat_list.git
cd steady_chat_list
(cd packages/steady_chat_list_core && dart pub get)
(cd packages/steady_chat_list && flutter pub get)
(cd packages/steady_chat_list_drift && dart pub get)
```

## Checks

All of these must pass before a pull request is merged:

```sh
# from the repository root
dart format --set-exit-if-changed .
flutter analyze                          # zero issues

(cd packages/steady_chat_list_core && dart test)
(cd packages/steady_chat_list_core && dart test -p chrome)
(cd packages/steady_chat_list && flutter test)
(cd packages/steady_chat_list_drift && dart test)
```

When you touch the view or the scroll position, also run the stress test in a browser and on a device:

```sh
(cd packages/steady_chat_list && flutter test --platform chrome test/anchor_stress_test.dart)
(cd benchmarks && flutter pub get && flutter test integration_test/anchor_stress_test.dart -d <device>)
```

Benchmarks (run them when you touch the store, the controller or the view, and update `benchmarks/RESULTS.md` if a number moves by more than 10%):

```sh
(cd packages/steady_chat_list_core && dart run benchmark/store_benchmark.dart)
(cd packages/steady_chat_list && flutter test benchmark/controller_benchmark_test.dart)
```

## Rules for code

- **Minimum SDK is Dart 3.5 / Flutter 3.24.** Don't use newer language features (wildcard variables, null-aware elements, dot shorthands) or newer framework APIs. If you have an older Flutter installed, run the tests with it too.
- **Tests first.** Store and policy logic gets unit tests in the core; controller behavior gets headless tests with `FakeChatServer` and `FakeViewport`; anything visual gets a widget test.
- **The core has no Flutter imports** and depends only on `meta`.
- **No new dependencies** beyond `meta`, `collection`, `flutter`, `shared_preferences`, `intl`, `drift`, `drift_flutter` and `sqlite3_flutter_libs` without a reason in `DECISIONS.md`.
- **No Material or Cupertino imports in the packages.** Use `package:flutter/widgets.dart`; `material.dart` is deprecated in new Flutter versions.
- **Public API:** every public symbol has a dartdoc comment, and classes have a short example. Use `final class`, `sealed` and `@immutable`. No `dynamic`, no global singletons.
- **Performance rules are requirements.** Don't rebuild the whole list for one message, don't copy the store per frame, don't add a `GlobalKey` per item.
- **Never infer contiguity from ids.** Only a server page proves that no message is missing between two keys.
- **App callbacks are never called during build or layout**, and a throwing callback must not break the list.

## Rules for pull requests

- One topic per pull request, with tests.
- Update `CHANGELOG.md` for anything a user of the package can notice.
- If you had to interpret the spec, or deviate from it, add an entry to `DECISIONS.md` with the reason.
- Describe how you tested it. For scroll behavior, say which platforms you ran it on.

## Reporting bugs

Please include the package version, the Flutter version, the platform, and one of:

- a failing test, or
- the output of the debug overlay or `controller.events` around the problem, plus the steps to reproduce it.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
