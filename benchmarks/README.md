# Benchmarks

A small host app for integration and performance tests. Results are in [RESULTS.md](RESULTS.md).

```sh
# performance: fling, cached open, jumps, message and reaction storms, memory
flutter drive --profile -d <device> \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/performance_test.dart

# performance in Chrome: build it as a page, open it, read the BENCH lines
# in the browser console (use a release build; reload without cache after
# rebuilding)
flutter build web --release -t integration_test/performance_test.dart
(cd build/web && python3 -m http.server 8766)

# the anchor stress test on a device, emulator or browser
flutter test integration_test/anchor_stress_test.dart -d <device>

# headless micro-benchmarks
(cd ../packages/steady_chat_list_core && dart run benchmark/store_benchmark.dart)
(cd ../packages/steady_chat_list && flutter test benchmark/controller_benchmark_test.dart)
(cd ../packages/steady_chat_list_drift && dart run benchmark/drift_benchmark.dart)
```

`--dart-define=ONLY=fling` runs one scenario (`fling`, `open`, `jump`, `incoming`, `reactions`, `memory`), and `--dart-define=WINDOW=120` another window size. The fling also prints its slowest frames with the rows built in each.

The performance test prints one `BENCH` line per scenario and fails when a budget is exceeded by more than 10% (in profile and release builds; debug builds are several times slower and only report).
