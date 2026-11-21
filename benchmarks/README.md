# Benchmarks

A small host app for integration and performance tests. Results are in [RESULTS.md](RESULTS.md).

```sh
# the anchor stress test on a device, emulator or browser
flutter test integration_test/anchor_stress_test.dart -d <device>
```

The performance benchmarks (fling, open, jumps, message and reaction storms, memory) are added in milestone 8.
