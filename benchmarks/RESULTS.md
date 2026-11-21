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

## Performance (milestone 8) — 2026-11-21

`integration_test/performance_test.dart` in profile mode, a 390 × 760 list of text bubbles on a simulated server with 1,000,000 messages and 150 ms latency. "Build" is the whole UI-thread part of a frame (build, layout and paint) as the engine reports it.

### macOS arm64 (Apple silicon), Flutter 3.50.1

| Scenario | Result | Budget (§14.1) |
| --- | --- | --- |
| Fling through 5,000 messages (up to 7,200 px/s, 4,263 frames) | build p50 0.43 ms, p95 2.25 ms, max 8.9 ms; no blank frame | p95 ≤ 8 ms, none over 32 ms ✅ |
| Open a cached chat (network 5 s away) | first frame already shows the messages at the bottom; build median 6.8 ms, max 8.1 ms | same frame, ≤ 16 ms ✅ |
| Jump across 1,000,000 messages, target on the server (20 jumps) | median 570 ms, max 576 ms (150 ms of it is the request); no blank frame | ≤ 700 ms ✅ |
| Jump, target in memory (20 jumps) | median 420 ms, max 428 ms (the animation) | ≤ 450 ms ✅ |
| 50 incoming messages/s for 30 s at the bottom (1,500 messages) | build p95 2.7 ms, max 3.9 ms; 0 frames over 16 ms; still at the bottom | no dropped frames ✅ |
| 200 reaction updates/s on visible messages for 15 s (3,001 updates) | build p95 1.8 ms, max 5.5 ms; 0 frames over 16 ms | no dropped frames ✅ |
| Memory after scrolling 100,000 messages | 1,000 messages held at 2,000 and at 100,000; 80 in the window, 10 rows built; process 199 MB → 218 MB (+9.5%) | flat ±10% ✅ |

### Android 15 emulator (API 35, arm64, on the same Mac), Flutter 3.50.1

An emulator renders without a real GPU: whole frames take about 18 ms here because of rasterization, so only the UI-thread numbers say something about the package. A physical phone was not available.

| Scenario | Result | Budget (§14.1) |
| --- | --- | --- |
| Fling through 5,000 messages (3,184 frames) | build p50 0.52 ms, p95 1.43 ms, max 4.3 ms; no blank frame | p95 ≤ 8 ms, none over 32 ms ✅ |
| Open a cached chat | first frame shows the messages; build median 1.4 ms, max 2.7 ms | same frame, ≤ 16 ms ✅ |
| Jump, target on the server (20 jumps) | median 602 ms, max 604 ms; no blank frame | ≤ 700 ms ✅ |
| Jump, target in memory (20 jumps) | median 453 ms, max 454 ms | ≤ 450 ms: 4 ms over, inside the 10% tolerance ⚠️ |
| 50 incoming messages/s for 30 s | build p95 1.2 ms, max 3.7 ms; 0 builds over 16 ms | no dropped frames ✅ (UI thread) |
| 200 reaction updates/s for 15 s | build p95 0.6 ms, max 2.0 ms; 0 builds over 16 ms | no dropped frames ✅ (UI thread) |
| Memory after scrolling 100,000 messages | 1,000 messages held throughout; process 223 MB → 242 MB (+8.5%) | flat ±10% ✅ |

The in-memory jump is an animation of fixed length (about 420 ms) plus the frames around it; on a 60 Hz emulator that lands a few milliseconds over the 450 ms budget.

### Drift cache — Dart VM, macOS arm64, SQLite file

`dart run benchmark/drift_benchmark.dart` in `packages/steady_chat_list_drift`.

| Operation | Median | Budget |
| --- | --- | --- |
| Read a page of 40 messages | 0.5 ms | ≤ 10 ms ✅ |
| Read a whole cached chat (600 messages, what `hydrate` does) | 0.9 ms | |
| Write a page of 40 with its segments | 1.3 ms | |

In Chrome (IndexedDB storage, the example app) reading a cached chat of a few hundred messages before the first frame took 24 ms warm and 148 ms on the first read after the page load, which includes starting the SQLite worker.

### Not measured

- A physical mid-range Android phone and an iPhone: none was available. The emulator numbers above are the closest.
- Chrome frame times. The example was exercised in Chrome (release build) for correctness: paging, jumps, search, the cache and restoring the position after a reload; its frame times were not recorded.
- There is no CI yet; the command above is what a CI job would run, and it fails when a budget is exceeded by more than 10%.
