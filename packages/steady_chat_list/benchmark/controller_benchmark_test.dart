// Headless timings of the controller (no widgets yet).
//
//   flutter test benchmark/controller_benchmark_test.dart
//
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import '../test/support/fake_chat_server.dart';
import '../test/support/fake_viewport.dart';

const _chat = ListId('chat');

void main() {
  test('controller timings', () {
    fakeAsync((async) {
      final server = FakeChatServer(count: 10000000);
      final hub =
          MessageListHub<Msg>(source: server, adapter: const MsgAdapter());
      void settle() {
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
      }

      MessageListController<Msg> open() => MessageListController<Msg>(
            hub: hub,
            list: _chat,
            scheduler: Timer.run,
          )..open();

      // Fill memory: page up 20 times.
      final first = open();
      final view = FakeViewport(first);
      settle();
      for (var i = 0; i < 20; i++) {
        view.scrollToTop();
        settle();
      }
      view.scrollBy(1234);
      settle();
      first.dispose();
      settle();

      // Open a cached chat at its saved position (synchronous part).
      const runs = 200;
      final watch = Stopwatch()..start();
      for (var i = 0; i < runs; i++) {
        final controller = open();
        expect(controller.window.value.keys, isNotEmpty);
        controller.dispose();
      }
      final openMicros = watch.elapsedMicroseconds / runs;
      settle();

      // 50 incoming messages in one frame, pinned to the bottom.
      final bottom = MessageListController<Msg>(
        hub: hub,
        list: const ListId('second'),
        scheduler: Timer.run,
      )..open();
      FakeViewport(bottom);
      settle();
      var total = 0;
      const frames = 100;
      for (var f = 0; f < frames; f++) {
        for (var i = 0; i < 50; i++) {
          server.incoming(const ListId('second'));
        }
        async.flushMicrotasks();
        final frame = Stopwatch()..start();
        async.elapse(Duration.zero); // the frame: one flush
        total += frame.elapsedMicroseconds;
      }
      print('open cached chat (controller part): '
          '${openMicros.toStringAsFixed(1)} µs');
      print('frame with 50 incoming messages (controller part): '
          '${(total / frames).toStringAsFixed(1)} µs');
    });
  });
}
