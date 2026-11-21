// SPEC §20 milestone 3: random inserts, deletes and resizes above, inside
// and below the viewport every frame for 10 s. The anchor must never move
// more than 1 px.
import 'package:flutter_test/flutter_test.dart';

import 'support/stress.dart';

void main() {
  for (final seed in [1, 2, 3]) {
    testWidgets('10 s of random changes, rows above the center (seed $seed)',
        (tester) async {
      final worst = await runAnchorStress(
        tester,
        belowCenter: false,
        frames: 600,
        seed: seed,
      );
      // ignore: avoid_print
      print('largest anchor movement: $worst px');
    });

    testWidgets('10 s of random changes, rows below the center (seed $seed)',
        (tester) async {
      final worst = await runAnchorStress(
        tester,
        belowCenter: true,
        frames: 600,
        seed: seed,
      );
      // ignore: avoid_print
      print('largest anchor movement: $worst px');
    });
  }
}
