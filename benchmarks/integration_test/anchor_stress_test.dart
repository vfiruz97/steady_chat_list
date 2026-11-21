// The milestone 3 stress test on a real device or browser:
//
//   flutter test integration_test/anchor_stress_test.dart -d <device>
//
// Random inserts, deletes and resizes above, inside and below the viewport
// every frame for 10 s; the first visible item must not move more than 1 px.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../../packages/steady_chat_list/test/support/stress.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('10 s of random changes, rows above the center', (tester) async {
    final worst =
        await runAnchorStress(tester, belowCenter: false, frames: 600);
    // ignore: avoid_print
    print('largest anchor movement: $worst px');
  });

  testWidgets('10 s of random changes, rows below the center', (tester) async {
    final worst = await runAnchorStress(tester, belowCenter: true, frames: 600);
    // ignore: avoid_print
    print('largest anchor movement: $worst px');
  });
}
