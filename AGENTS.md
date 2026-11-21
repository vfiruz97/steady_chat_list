# Notes for AI coding assistants

**Using the package in an app?** Read [packages/steady_chat_list/AI_GUIDE.md](packages/steady_chat_list/AI_GUIDE.md). It is the rule list for writing code with `steady_chat_list`.

**Changing this repository?** Read [CONTRIBUTING.md](CONTRIBUTING.md) first. The short version:

- Three packages under `packages/`, linked with `pubspec_overrides.yaml`. `steady_chat_list_core` is pure Dart; do not import Flutter there.
- Minimum SDK is Dart 3.5 / Flutter 3.24. Do not use newer language features or APIs, and do not turn the repo into a pub workspace.
- Every change comes with tests. Line coverage of the packages is kept near 100%.
- Before you finish, from the repo root: `dart format --set-exit-if-changed .` and `flutter analyze` must be clean, and the tests of every package you touched must pass (`dart test` in `steady_chat_list_core` and `steady_chat_list_drift`, `flutter test` in `steady_chat_list` and `example`).
- Every public symbol has a dartdoc comment with a short example. No `dynamic`, no global singletons.
- Do not use `ListView(reverse: true)`, do not infer that two messages are neighbours from their ids, and do not call app callbacks during build or layout.
- Behaviour that differs from the obvious is recorded in [DECISIONS.md](DECISIONS.md); add an entry when you make such a choice. User-visible changes go in `CHANGELOG.md`.
- `packages/steady_chat_list/README.md` is a copy of the guide part of the root `README.md`; change both together.
