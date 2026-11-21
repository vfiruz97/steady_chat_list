import 'package:meta/meta.dart';

import 'message_key.dart';

/// Where a jump target ends up in the viewport (§10.4).
///
/// ```dart
/// controller.jumpTo(key, options: const JumpOptions(
///   alignment: JumpAlignment.top(inset: 48), // below a pinned bar
/// ));
/// ```
@immutable
sealed class JumpAlignment {
  const JumpAlignment();

  /// Centered below [topInset]; top-aligned when the item is taller than
  /// the space. An item that is already fully visible is not moved.
  const factory JumpAlignment.centerIfFits({double topInset}) = AlignCenter;

  /// The item's top [inset] px below the viewport top.
  const factory JumpAlignment.top({double inset}) = AlignTop;

  /// The item's bottom [inset] px above the viewport bottom.
  const factory JumpAlignment.bottom({double inset}) = AlignBottom;

  /// The free space is split by [fraction]: 0 = top, 0.5 = center,
  /// 1 = bottom.
  const factory JumpAlignment.fraction(double fraction) = AlignFraction;

  /// Scroll only as far as needed to make the item fully visible.
  const factory JumpAlignment.minimal() = AlignMinimal;

  /// The scroll offset that puts an item at this alignment.
  ///
  /// [itemOffset] is the scroll offset at which the item's top is at the
  /// viewport top, [itemExtent] its height, [viewport] the viewport height
  /// and [current] the current scroll offset.
  ///
  /// ```dart
  /// final target = const JumpAlignment.top()
  ///     .resolve(itemOffset: 1200, itemExtent: 80, viewport: 600, current: 0);
  /// ```
  double resolve({
    required double itemOffset,
    required double itemExtent,
    required double viewport,
    required double current,
  });

  /// Whether an item that is fully visible stays where it is.
  bool get keepsVisibleItem => false;
}

/// [JumpAlignment.centerIfFits].
final class AlignCenter extends JumpAlignment {
  /// Creates the alignment.
  const AlignCenter({this.topInset = 0});

  /// Space kept free at the top (a pinned bar, a search bar).
  final double topInset;

  @override
  bool get keepsVisibleItem => true;

  @override
  double resolve({
    required double itemOffset,
    required double itemExtent,
    required double viewport,
    required double current,
  }) {
    final free = viewport - topInset - itemExtent;
    return itemOffset - topInset - (free > 0 ? free / 2 : 0);
  }
}

/// [JumpAlignment.top].
final class AlignTop extends JumpAlignment {
  /// Creates the alignment.
  const AlignTop({this.inset = 0});

  /// Distance from the viewport top to the item's top.
  final double inset;

  @override
  double resolve({
    required double itemOffset,
    required double itemExtent,
    required double viewport,
    required double current,
  }) =>
      itemOffset - inset;
}

/// [JumpAlignment.bottom].
final class AlignBottom extends JumpAlignment {
  /// Creates the alignment.
  const AlignBottom({this.inset = 0});

  /// Distance from the item's bottom to the viewport bottom.
  final double inset;

  @override
  double resolve({
    required double itemOffset,
    required double itemExtent,
    required double viewport,
    required double current,
  }) =>
      itemOffset + itemExtent - viewport + inset;
}

/// [JumpAlignment.fraction].
final class AlignFraction extends JumpAlignment {
  /// Creates the alignment.
  const AlignFraction(this.fraction);

  /// 0 = top, 0.5 = center, 1 = bottom.
  final double fraction;

  @override
  double resolve({
    required double itemOffset,
    required double itemExtent,
    required double viewport,
    required double current,
  }) =>
      itemOffset - fraction * (viewport - itemExtent);
}

/// [JumpAlignment.minimal].
final class AlignMinimal extends JumpAlignment {
  /// Creates the alignment.
  const AlignMinimal();

  @override
  bool get keepsVisibleItem => true;

  @override
  double resolve({
    required double itemOffset,
    required double itemExtent,
    required double viewport,
    required double current,
  }) {
    if (itemOffset < current || itemExtent > viewport) return itemOffset;
    final bottom = itemOffset + itemExtent - viewport;
    return bottom > current ? bottom : current;
  }
}

/// Why a jump happened. Sent with every jump event and to the item that
/// is highlighted.
///
/// ```dart
/// if (info.highlightReason == JumpReason.search) highlightMatches();
/// ```
enum JumpReason {
  /// `jumpTo` without a reason.
  programmatic,

  /// A search result.
  search,

  /// A tapped reply preview.
  reply,

  /// A pinned message.
  pinned,

  /// The next unread mention.
  mention,

  /// The next unread reaction.
  reaction,

  /// A day.
  date,

  /// A link to a message.
  deepLink,

  /// The scroll-to-bottom button.
  bottom,

  /// The open chat was selected again.
  reselect,
}

/// How a jump ended.
///
/// ```dart
/// if (result.outcome == JumpOutcome.arrivedNearest) toast('Message deleted');
/// ```
enum JumpOutcome {
  /// The target is on screen at the requested alignment.
  arrived,

  /// The target no longer exists; the nearest message is shown instead.
  arrivedNearest,

  /// The target was already fully visible; nothing scrolled.
  alreadyVisible,

  /// A newer jump, a user scroll, a chat switch or dispose interrupted it.
  cancelled,

  /// The page with the target could not be loaded.
  failed,
}

/// The result of a jump.
///
/// ```dart
/// final result = await controller.jumpTo(key);
/// print('${result.outcome} in ${result.took.inMilliseconds} ms');
/// ```
@immutable
final class JumpResult {
  /// Creates a result.
  const JumpResult({
    required this.outcome,
    required this.took,
    this.landedOn,
    this.fetchedPages = 0,
    this.error,
  });

  /// How it ended.
  final JumpOutcome outcome;

  /// The message that is shown (the target, or the nearest one).
  final MessageKey? landedOn;

  /// Pages loaded from the source for this jump (0 or 1).
  final int fetchedPages;

  /// From the call to the end of the scroll.
  final Duration took;

  /// What went wrong, for [JumpOutcome.failed].
  final Object? error;

  /// Whether a message is on screen as a result.
  bool get succeeded =>
      outcome == JumpOutcome.arrived ||
      outcome == JumpOutcome.arrivedNearest ||
      outcome == JumpOutcome.alreadyVisible;

  @override
  String toString() => 'JumpResult(${outcome.name}, landedOn: $landedOn, '
      'fetched: $fetchedPages, took: ${took.inMilliseconds} ms)';
}
