// The performance benchmarks of SPEC §19, measured against the budgets of
// §14.1. Run in profile mode on a device, emulator or desktop:
//
//   flutter drive --profile -d <device> \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/performance_test.dart
//
// Every scenario prints one line; all of them are also reported to the
// driver (build/integration_response_data.json). Budgets are asserted only
// in profile and release builds: debug builds are several times slower.
//
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import '../../packages/steady_chat_list/test/support/fake_chat_server.dart';
import 'rss_stub.dart' if (dart.library.io) 'rss_io.dart';

const ListId chat = ListId('chat');

/// Budgets are 10% above §14.1, the allowed regression.
const double slack = 1.1;

final Map<String, Object?> report = {};

const _phrases = [
  'ok',
  'sounds good to me',
  'can we talk about it after the call?',
  'please have a look when you have time, there is no rush at all',
  'that is exactly what I meant, and here is some more text so that this '
      'message wraps over several lines on a phone screen and costs a real '
      'text layout',
];

/// A realistic row: a bubble with wrapped text, a time and reactions.
class _Bubble extends StatelessWidget {
  const _Bubble(this.message, this.info);

  final Msg message;
  final MessageItemInfo info;

  @override
  Widget build(BuildContext context) {
    final mine = message.order % 30 == 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(8, info.isFirstInGroup ? 6 : 2, 8, 2),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: mine ? const Color(0xFFD9FDD3) : const Color(0xFFEDEDED),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '#${message.order ~/ 10} '
                    '${_phrases[(message.order ~/ 10) % _phrases.length]}',
                    style: const TextStyle(
                      color: Color(0xFF000000),
                      fontSize: 15,
                    ),
                  ),
                  if (message.rev > 0)
                    Text(
                      '👍 ${message.rev}',
                      style: const TextStyle(
                        color: Color(0xFF333333),
                        fontSize: 13,
                      ),
                    ),
                  const Text(
                    '12:34',
                    style: TextStyle(color: Color(0xFF777777), fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Bench {
  _Bench(this.tester, {int count = 1000000, MessageCache<Msg>? cache})
      : server = FakeChatServer(count: count) {
    hub = MessageListHub<Msg>(
      source: server,
      adapter: const MsgAdapter(),
      cache: cache,
    );
    controller = MessageListController<Msg>(hub: hub, list: chat);
  }

  final WidgetTester tester;
  final FakeChatServer server;
  late final MessageListHub<Msg> hub;
  late final MessageListController<Msg> controller;
  final List<FrameTiming> _timings = [];

  Widget app() => Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: Center(
            // A phone-sized list on every platform.
            child: SizedBox(
              width: 390,
              height: 760,
              child: MessageListView<Msg>(
                controller: controller,
                itemBuilder: (context, m, info) => _Bubble(m, info),
                dayHeaderBuilder: (context, day, onTap) =>
                    DayHeader(day: day, onTap: onTap),
              ),
            ),
          ),
        ),
      );

  ScrollPosition get position =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position;

  int get rows => find.byType(_Bubble).evaluate().length;

  Future<void> wait(Duration time) async {
    final end = DateTime.now().add(time);
    while (DateTime.now().isBefore(end)) {
      await tester.pump();
    }
  }

  /// Starts collecting frame timings (after flushing older ones).
  Future<void> startFrames() async {
    await _flush();
    _timings.clear();
    SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
  }

  /// Stops collecting and returns the statistics of the frames in between.
  Future<Map<String, Object?>> stopFrames() async {
    await _flush();
    SchedulerBinding.instance.removeTimingsCallback(_timings.addAll);
    double ms(Duration d) => d.inMicroseconds / 1000;
    final builds = [for (final t in _timings) ms(t.buildDuration)]..sort();
    final totals = [
      for (final t in _timings) ms(t.buildDuration + t.rasterDuration),
    ]..sort();
    double at(List<double> sorted, double q) =>
        sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * q).round()];
    double round(double v) => (v * 100).round() / 100;
    return {
      'frames': _timings.length,
      'build_p50_ms': round(at(builds, 0.5)),
      'build_p95_ms': round(at(builds, 0.95)),
      'build_max_ms': round(at(builds, 1)),
      'frame_p95_ms': round(at(totals, 0.95)),
      'frame_max_ms': round(at(totals, 1)),
      'over_16ms': builds.where((b) => b > 16.7).length,
      'over_32ms': builds.where((b) => b > 32).length,
    };
  }

  // The engine reports timings in batches (once a second in debug, every
  // 100 ms in profile).
  Future<void> _flush() => wait(const Duration(milliseconds: 1300));

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    hub.dispose();
    await wait(const Duration(milliseconds: 100));
  }
}

void record(String name, Map<String, Object?> result) {
  report[name] = result;
  print('BENCH $name: $result');
}

/// Budgets hold for optimized builds only.
void budget(bool ok, String what) {
  if (kDebugMode) return;
  expect(ok, isTrue, reason: 'budget exceeded: $what');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  tearDownAll(() {
    report['mode'] = kDebugMode
        ? 'debug'
        : kProfileMode
            ? 'profile'
            : 'release';
    report['platform'] = kIsWeb ? 'web' : defaultTargetPlatform.name;
    binding.reportData = report;
  });

  testWidgets('fling through 5,000 messages', (tester) async {
    final b = _Bench(tester);
    unawaited(b.controller.open(target: OpenTarget.message(k(5000000))));
    await tester.pumpWidget(b.app());
    await b.wait(const Duration(seconds: 1));
    final first = b.controller.visibleItems.first.key.order;
    await b.startFrames();
    final watch = Stopwatch()..start();
    var blank = 0;
    // 30 px per frame at 60 fps = 1,800 px/s, then faster and faster up
    // to 7,200 px/s: a hard fling. Pages arrive with 150 ms latency.
    var frames = 0;
    while (first - b.controller.visibleItems.first.key.order < 5000 * 10) {
      final speed = (30 + frames ~/ 4).clamp(30, 120).toDouble();
      final position = b.position;
      position.jumpTo(
        (position.pixels - speed)
            .clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      await tester.pump();
      if (b.rows == 0) blank++;
      frames++;
      if (watch.elapsed > const Duration(minutes: 4)) break;
    }
    final result = await b.stopFrames()
      ..['seconds'] = watch.elapsed.inSeconds
      ..['blank_frames'] = blank
      ..['rows_built'] = b.rows;
    record('fling_5000', result);
    budget((result['build_p95_ms']! as double) <= 8 * slack, 'fling p95');
    budget(result['over_32ms'] == 0, 'fling: a frame over 32 ms');
    expect(blank, 0);
    await b.dispose();
  });

  testWidgets('open a cached chat: correct in the first frame', (tester) async {
    final cache = InMemoryMessageCache<Msg>(adapter: const MsgAdapter());
    // First run fills the cache.
    final warm = _Bench(tester, cache: cache);
    unawaited(warm.controller.open());
    await tester.pumpWidget(warm.app());
    await warm.wait(const Duration(seconds: 1));
    await warm.dispose();

    // The first frame of each run is by far the most expensive of its
    // frames, so the ten slowest builds of the whole scenario are the ten
    // first frames. (Timing `pumpWidget` would include the wait for vsync.)
    const runs = 10;
    final frames = <FrameTiming>[];
    await warm.wait(const Duration(milliseconds: 1300));
    SchedulerBinding.instance.addTimingsCallback(frames.addAll);
    var rowsInFirstFrame = 0;
    for (var run = 0; run < runs; run++) {
      final b = _Bench(tester, cache: cache);
      b.server.latency = const Duration(seconds: 5); // the network is slow
      await b.hub.hydrate(chat);
      unawaited(b.controller.open());
      await tester.pumpWidget(b.app()); // one frame
      rowsInFirstFrame = b.rows;
      expect(rowsInFirstFrame, greaterThan(5), reason: 'first frame is blank');
      expect(b.controller.isAtBottom.value, isTrue);
      await b.wait(const Duration(milliseconds: 150));
      await b.dispose();
    }
    await warm.wait(const Duration(milliseconds: 1300));
    SchedulerBinding.instance.removeTimingsCallback(frames.addAll);
    final builds = [
      for (final t in frames) t.buildDuration.inMicroseconds / 1000,
    ]..sort((x, y) => y.compareTo(x));
    final first = builds.take(runs).toList();
    final result = <String, Object?>{
      'first_frame_build_median_ms': first[first.length ~/ 2],
      'first_frame_build_max_ms': first.first,
      'rows_in_first_frame': rowsInFirstFrame,
    };
    record('open_cached', result);
    budget(first.first <= 16 * slack, 'open cached chat');
  });

  testWidgets('20 jumps across 1,000,000 messages', (tester) async {
    final b = _Bench(tester);
    unawaited(b.controller.open());
    await tester.pumpWidget(b.app());
    await b.wait(const Duration(seconds: 1));

    Future<double> jump(int number) async {
      var done = false;
      final watch = Stopwatch()..start();
      unawaited(b.controller.jumpTo(k(number * 10)).then((_) => done = true));
      while (!done) {
        await tester.pump();
        expect(b.rows, greaterThan(0), reason: 'blank frame during a jump');
        if (watch.elapsed > const Duration(seconds: 10)) fail('jump hangs');
      }
      return watch.elapsedMicroseconds / 1000;
    }

    final remote = <double>[];
    final cached = <double>[];
    for (var i = 0; i < 20; i++) {
      // Far targets, never seen before: one request with 150 ms latency.
      remote.add(await jump(40000 + i * 47111));
      await b.wait(const Duration(milliseconds: 200));
    }
    for (var i = 0; i < 20; i++) {
      // Targets that are still in memory.
      cached.add(await jump(40000 + (19 - i) * 47111));
      await b.wait(const Duration(milliseconds: 200));
    }
    remote.sort();
    cached.sort();
    final result = <String, Object?>{
      'remote_median_ms': remote[10].round(),
      'remote_max_ms': remote.last.round(),
      'cached_median_ms': cached[10].round(),
      'cached_max_ms': cached.last.round(),
    };
    record('jump_x20', result);
    budget(remote.last <= 700 * slack, 'remote jump');
    budget(cached.last <= 450 * slack, 'cached jump');
    await b.dispose();
  });

  testWidgets('50 incoming messages per second for 30 s at the bottom',
      (tester) async {
    final b = _Bench(tester);
    unawaited(b.controller.open());
    await tester.pumpWidget(b.app());
    await b.wait(const Duration(seconds: 1));
    await b.startFrames();
    var sent = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      b.server.incoming(chat);
      sent++;
    });
    await b.wait(const Duration(seconds: 30));
    timer.cancel();
    final result = await b.stopFrames()
      ..['messages'] = sent;
    record('incoming_50_per_s', result);
    expect(b.controller.isAtBottom.value, isTrue, reason: 'lost the bottom');
    budget(result['over_16ms'] == 0, 'incoming storm drops frames');
    await b.dispose();
  });

  testWidgets('200 reaction updates per second on visible messages',
      (tester) async {
    final b = _Bench(tester);
    unawaited(b.controller.open());
    await tester.pumpWidget(b.app());
    await b.wait(const Duration(seconds: 1));
    await b.startFrames();
    final revisions = <int, int>{};
    var sent = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final visible = b.controller.visibleItems;
      if (visible.isEmpty) return;
      final order = visible[sent % visible.length].key.order;
      final rev = revisions[order] = (revisions[order] ?? 0) + 1;
      b.server.push(MessagesUpdated<Msg>(chat, [Msg(order, rev: rev)]));
      sent++;
    });
    await b.wait(const Duration(seconds: 15));
    timer.cancel();
    final result = await b.stopFrames()
      ..['updates'] = sent;
    record('reactions_200_per_s', result);
    budget(result['over_16ms'] == 0, 'reaction storm drops frames');
    await b.dispose();
  });

  testWidgets('memory stays flat while scrolling 100,000 messages',
      (tester) async {
    final b = _Bench(tester);
    b.server.latency = const Duration(milliseconds: 1);
    unawaited(b.controller.open(target: OpenTarget.message(k(5000000))));
    await tester.pumpWidget(b.app());
    await b.wait(const Duration(seconds: 1));
    final first = b.controller.visibleItems.first.key.order;
    int scrolled() => (first - b.controller.visibleItems.first.key.order) ~/ 10;

    Future<void> scrollTo(int messages) async {
      final watch = Stopwatch()..start();
      while (scrolled() < messages) {
        final position = b.position;
        position.jumpTo(
          (position.pixels - 1500)
              .clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        await tester.pump();
        if (watch.elapsed > const Duration(minutes: 8)) break;
      }
    }

    await scrollTo(2000);
    final rssAt2k = currentRss();
    final storeAt2k = b.hub.store.peek(chat)!.length;
    await scrollTo(100000);
    final rssAt100k = currentRss();
    final store = b.hub.store.peek(chat)!;
    final result = <String, Object?>{
      'scrolled': scrolled(),
      'messages_in_memory_at_2k': storeAt2k,
      'messages_in_memory_at_100k': store.length,
      'window': b.controller.window.value.keys.length,
      'rows_built': b.rows,
      if (rssAt2k != null) 'rss_mb_at_2k': rssAt2k ~/ (1024 * 1024),
      if (rssAt100k != null) 'rss_mb_at_100k': rssAt100k ~/ (1024 * 1024),
    };
    record('memory_100k', result);
    // The data the package holds is bounded, whatever the distance.
    expect(store.length, lessThanOrEqualTo(storeAt2k * 1.1 + 100));
    expect(b.controller.window.value.keys.length, lessThanOrEqualTo(80));
    if (rssAt2k != null && rssAt100k != null) {
      budget(rssAt100k <= rssAt2k * 1.1 * slack, 'memory grows');
    }
    await b.dispose();
  });
}
