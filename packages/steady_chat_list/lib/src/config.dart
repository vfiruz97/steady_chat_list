import 'package:flutter/foundation.dart';

/// Tunable numbers of a message list. The defaults are the values measured
/// in Telegram (SPEC §2, §9).
///
/// ```dart
/// const MessageListConfig(pageSize: 30, windowSize: 60);
/// ```
@immutable
class MessageListConfig {
  /// Creates a configuration.
  const MessageListConfig({
    this.pageSize = 40,
    this.firstOpenPageSize = 20,
    this.windowSize = 80,
    this.preloadExtent = 1500,
    this.cacheExtent = 800,
    this.stickToBottomThreshold = 24,
    this.scrollDownButtonThreshold = 1.0,
    this.unreadDividerTopInset = 10,
    this.persistDebounce = const Duration(milliseconds: 800),
    this.readDebounce = const Duration(milliseconds: 300),
    this.readDwell = const Duration(milliseconds: 100),
    this.groupingGap = const Duration(minutes: 5),
    this.restoreIslandsAfterRestart = false,
    this.snapshotLoadBudget = const Duration(milliseconds: 50),
  });

  /// Messages per page.
  final int pageSize;

  /// Messages in the first page of a list that isn't cached.
  final int firstOpenPageSize;

  /// Maximum number of built messages.
  final int windowSize;

  /// Load more when the viewport is this close (px) to a window edge.
  final double preloadExtent;

  /// Pixels built outside the viewport on each side.
  final double cacheExtent;

  /// The list counts as "at bottom" within this distance (px).
  final double stickToBottomThreshold;

  /// The scroll-down button shows when the bottom is farther away than this
  /// many viewport heights.
  final double scrollDownButtonThreshold;

  /// Distance (px) from the viewport top to the unread divider on open.
  final double unreadDividerTopInset;

  /// Quiet time after the last scroll before the position is saved.
  final Duration persistDebounce;

  /// Minimum time between two read receipts.
  final Duration readDebounce;

  /// How long a message must stay visible to count as read.
  final Duration readDwell;

  /// Messages of one sender further apart than this start a new group.
  final Duration groupingGap;

  /// Whether a persisted position outside the live segment is restored
  /// after a restart (Telegram: no).
  final bool restoreIslandsAfterRestart;

  /// How long `loadSnapshot` may take before it is ignored.
  final Duration snapshotLoadBudget;
}
