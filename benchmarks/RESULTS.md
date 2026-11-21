# Benchmark results

Budgets are from the internal specification (§14.1). Rows are added as each layer is built.

## Core store — macOS arm64, Dart 3.14.0 (JIT), 2026-11-20

`cd packages/steady_chat_list_core && dart run benchmark/store_benchmark.dart`

| Metric | Budget | Measured |
| --- | --- | --- |
| Page apply (40 items, 1,000 in memory, with eviction) — store part only | ≤ 3 ms | 0.086 ms |
| One reaction update | – | 0.7 µs |
| One incoming message | – | 0.5 µs |
| Window of 80 keys around a key | – | 7.6 µs |

## Controller, headless — macOS arm64, Flutter 3.50.1 (JIT), 2026-11-20

`cd packages/steady_chat_list && flutter test benchmark/controller_benchmark_test.dart`

| Metric | Budget | Measured |
| --- | --- | --- |
| Open cached chat at its saved position — controller part (the window is ready before `open()` returns) | same frame; build ≤ 16 ms | 0.09 ms |
| One frame with 50 incoming messages, pinned to the bottom — controller part | no dropped frames (16.6 ms) | 0.23 ms |

## Anchor stress test (milestone 3) — 2026-11-21

Random inserts, deletes and resizes above, inside and below the viewport on every frame for 10 s (600 frames). Budget: the first visible item never moves more than 1 px.

| Platform | Runs | Largest anchor movement |
| --- | --- | --- |
| Dart VM, Flutter 3.50.1 (`flutter test`) | 6 (3 seeds × rows above / below the center) | 4.5e-13 px |
| Dart VM, Flutter 3.24.4 (minimum SDK) | 6 | passes (≤ 1 px) |
| Chrome 158 (`flutter test --platform chrome`) | 6 | 4.5e-13 px |
| Android 15 emulator, API 35 (`integration_test`) | 2 | 4.5e-13 px |

```sh
cd packages/steady_chat_list && flutter test test/anchor_stress_test.dart
cd packages/steady_chat_list && flutter test --platform chrome test/anchor_stress_test.dart
cd benchmarks && flutter test integration_test/anchor_stress_test.dart -d <device>
```

Not measured yet (milestone 8, on devices): build and layout time while flinging, open cached chat with widgets, incoming and reaction storms on screen, jumps, memory, Drift reads.
