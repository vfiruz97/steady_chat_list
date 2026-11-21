import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:test/test.dart';

import 'support.dart';

double at(JumpAlignment alignment, {double extent = 100, double current = 0}) =>
    alignment.resolve(
      itemOffset: 2000,
      itemExtent: extent,
      viewport: 600,
      current: current,
    );

void main() {
  test('top, bottom and fraction', () {
    expect(at(const JumpAlignment.top()), 2000);
    expect(at(const JumpAlignment.top(inset: 48)), 1952);
    expect(at(const JumpAlignment.bottom()), 1500);
    expect(at(const JumpAlignment.bottom(inset: 20)), 1520);
    expect(at(const JumpAlignment.fraction(0)), 2000);
    expect(at(const JumpAlignment.fraction(0.5)), 1750);
    expect(at(const JumpAlignment.fraction(1)), 1500);
    expect(const JumpAlignment.top().keepsVisibleItem, isFalse);
  });

  test('centerIfFits centers, or top-aligns a tall item', () {
    expect(at(const JumpAlignment.centerIfFits()), 1750);
    expect(at(const JumpAlignment.centerIfFits(topInset: 100)), 1700);
    expect(at(const JumpAlignment.centerIfFits(), extent: 900), 2000);
    expect(
      at(const JumpAlignment.centerIfFits(topInset: 40), extent: 900),
      1960,
    );
    expect(const JumpAlignment.centerIfFits().keepsVisibleItem, isTrue);
  });

  test('minimal scrolls only as far as needed', () {
    const minimal = JumpAlignment.minimal();
    expect(at(minimal, current: 2500), 2000, reason: 'above: to the top');
    expect(at(minimal, current: 0), 1500, reason: 'below: to the bottom');
    expect(at(minimal, current: 1700), 1700, reason: 'visible: stays');
    expect(at(minimal, extent: 900, current: 0), 2000, reason: 'tall: top');
    expect(minimal.keepsVisibleItem, isTrue);
  });

  test('JumpResult', () {
    final arrived = JumpResult(
      outcome: JumpOutcome.arrived,
      took: const Duration(milliseconds: 420),
      landedOn: k(7),
      fetchedPages: 1,
    );
    expect(arrived.succeeded, isTrue);
    expect('$arrived', contains('arrived'));
    expect('$arrived', contains('420 ms'));
    for (final outcome in JumpOutcome.values) {
      expect(
        JumpResult(outcome: outcome, took: Duration.zero).succeeded,
        outcome != JumpOutcome.cancelled && outcome != JumpOutcome.failed,
      );
    }
    expect(JumpReason.values, hasLength(10));
  });
}
