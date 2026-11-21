# steady_chat_list

A Flutter package that gives any chat app a Telegram-grade message list: it opens at the right place, pages unlimited history with a fixed number of widgets, and never jumps under the reader's eyes.

**Status: in development.** Milestones 1–3 of 8 are done: the pure Dart core, the hub and controller, and the view with its no-jump scroll position. Jumps and search navigation come next. Design decisions are in [DECISIONS.md](DECISIONS.md).

## Packages

| Package | What it is | Status |
| --- | --- | --- |
| [`steady_chat_list_core`](packages/steady_chat_list_core) | Pure Dart: keys, segmented store, hub, policies | done so far |
| [`steady_chat_list`](packages/steady_chat_list) | Flutter: controller, view and scroll position (done); jumps, animations, default widgets (next) | in progress |
| [`steady_chat_list_drift`](packages/steady_chat_list_drift) | Drift (SQLite) cache, also on web | skeleton |
| [`example`](example) | Demo app with a 10,000,000-message chat | milestone 8 |
| [`benchmarks`](benchmarks) | Host app for device tests, and [results](benchmarks/RESULTS.md) | stress test done |

Requires Dart 3.5 / Flutter 3.24 or newer.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Development

The packages are linked with `pubspec_overrides.yaml` (no pub workspace, so Dart 3.5 keeps working).

```sh
cd packages/steady_chat_list_core
dart pub get
dart test                 # add `-p chrome` to run on the web
dart run benchmark/store_benchmark.dart

# from the repo root
dart format --set-exit-if-changed .
flutter analyze
```
