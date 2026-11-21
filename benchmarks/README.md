# Benchmarks

A small host app for integration and performance tests. Results are in [RESULTS.md](RESULTS.md).

```sh
# performance: fling, cached open, jumps, message and reaction storms, memory
flutter drive --profile -d <device> \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/performance_test.dart

# the anchor stress test on a device, emulator or browser
flutter test integration_test/anchor_stress_test.dart -d <device>

# headless micro-benchmarks
(cd ../packages/steady_chat_list_core && dart run benchmark/store_benchmark.dart)
(cd ../packages/steady_chat_list && flutter test benchmark/controller_benchmark_test.dart)
(cd ../packages/steady_chat_list_drift && dart run benchmark/drift_benchmark.dart)
```

The performance test prints one `BENCH` line per scenario and fails when a budget is exceeded by more than 10% (in profile and release builds; debug builds are several times slower and only report).
