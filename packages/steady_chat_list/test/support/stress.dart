// ignore_for_file: unawaited_futures
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'fake_chat_server.dart';
import 'list_harness.dart';

/// The milestone 3 stress test (SPEC §20): every frame for [frames] frames
/// (10 s at 60 fps), random messages are inserted, deleted and resized
/// above, inside and below the viewport, with a random scroll now and then.
/// The first visible item must never move by more than 1 px.
///
/// Returns the largest movement seen. Runs as a widget test (VM, Chrome)
/// and as an integration test on a device.
Future<double> runAnchorStress(
  WidgetTester tester, {
  required bool belowCenter,
  int frames = 300,
  int seed = 1,
}) async {
  final random = Random(seed);
  final h = ListHarness(tester, count: 100000);
  // Opening at a message puts the rows after it below the viewport center;
  // opening at the bottom and scrolling up puts everything above it.
  h.controller.open(
    target:
        belowCenter ? OpenTarget.message(k(500000)) : const OpenTarget.bottom(),
  );
  await h.pump();
  // Away from both ends of the content: at an end the content itself can
  // become too short to keep the anchor where it is.
  for (var i = 0; i < 4; i++) {
    await h.scrollBy(belowCenter ? 300 : -700);
    await h.settle(const Duration(milliseconds: 400));
  }

  var worst = 0.0;
  var compared = 0;
  var inserted = 0;
  var deleted = 0;
  var resized = 0;
  const frame = Duration(milliseconds: 16);

  for (var f = 0; f < frames; f++) {
    final position = h.position;
    if (f % 37 == 36) {
      // A scroll: the anchor changes, nothing to compare across it.
      final room = position.maxScrollExtent - position.pixels;
      final back = position.pixels - position.minScrollExtent;
      // Deletions shrink the content, so the list drifts toward its ends;
      // steer it back to where both sides have room.
      var dy = (random.nextDouble() - 0.5) * 900;
      if (room < 2000) {
        dy = -900;
      } else if (back < 2000) {
        dy = 900;
      }
      await h.scrollBy(dy);
      await tester.pump(frame);
      continue;
    }

    // Deleting and shrinking can leave less content than the distance to an
    // end; then the physics must move the list, and no anchor can hold.
    // The same goes for a list that is still settling after such a move.
    final comparable = !position.isPinned &&
        !position.isScrollingNotifier.value &&
        position.maxScrollExtent - position.pixels > 700 &&
        position.pixels - position.minScrollExtent > 700;
    if (comparable) compared++;
    final visible = h.visible;
    expect(visible, isNotEmpty, reason: 'frame $f: nothing on screen');
    final anchor = visible.first;
    final before = h.yOf(anchor)!;
    final window = h.controller.window.value.keys;
    final aboveViewport = [
      for (final key in window)
        if (key.order < anchor) key.order,
    ];
    final belowViewport = [
      for (final key in window)
        if (key.order > visible.last) key.order,
    ];
    List<int> zone() => switch (random.nextInt(3)) {
          0 => aboveViewport,
          1 => visible.sublist(1),
          _ => belowViewport,
        };

    final operations = 1 + random.nextInt(3);
    for (var i = 0; i < operations; i++) {
      final candidates = zone();
      if (candidates.isEmpty) continue;
      final target = candidates[random.nextInt(candidates.length)];
      switch (random.nextInt(3)) {
        case 0:
          // A late message right after `target` (ids have gaps of 10).
          final order = target + 1 + random.nextInt(9);
          if (h.controller.messageOf(k(order)) != null) continue;
          h.heights['m$order'] = 20.0 + random.nextInt(140);
          h.controller.upsert([Msg(order)]);
          inserted++;
        case 1:
          h.controller.remove(['m$target']);
          deleted++;
        case 2:
          h.resize(target, 20.0 + random.nextInt(140));
          resized++;
      }
    }
    await tester.pump(frame);

    final after = h.yOf(anchor);
    expect(after, isNotNull, reason: 'frame $f: the anchor was unmounted');
    if (!comparable) continue;
    final moved = (after! - before).abs();
    if (moved > worst) worst = moved;
    expect(
      moved,
      lessThanOrEqualTo(1.0),
      reason: 'frame $f (seed $seed): the anchor moved $moved px',
    );
    expect(h.controller.window.value.keys.length, lessThanOrEqualTo(80));
  }
  expect(compared, greaterThan(frames * 0.8), reason: 'too few frames checked');
  expect(inserted, greaterThan(frames ~/ 10));
  expect(deleted, greaterThan(frames ~/ 10));
  expect(resized, greaterThan(frames ~/ 10));
  await h.dispose();
  return worst;
}
