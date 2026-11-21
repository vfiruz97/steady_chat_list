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

Not measured yet (need the view, milestone 3+): open cached chat, fling,
incoming and reaction storms on screen, jumps, memory, Drift reads.
