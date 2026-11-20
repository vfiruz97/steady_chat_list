# Benchmark results

Budgets are from SPEC §14.1. Rows are added as each layer is built.

## Core store — macOS arm64, Dart 3.14.0 (JIT), 2026-11-20

`cd packages/steady_chat_list_core && dart run benchmark/store_benchmark.dart`

| Metric | Budget | Measured |
| --- | --- | --- |
| Page apply (40 items, 1,000 in memory, with eviction) — store part only | ≤ 3 ms | 0.086 ms |
| One reaction update | – | 0.7 µs |
| One incoming message | – | 0.5 µs |
| Window of 80 keys around a key | – | 7.6 µs |

Not measured yet (need the view, milestone 3+): open cached chat, fling,
incoming and reaction storms on screen, jumps, memory, Drift reads.
