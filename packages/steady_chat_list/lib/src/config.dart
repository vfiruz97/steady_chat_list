import 'package:flutter/foundation.dart';

import 'jump.dart';

/// Tunable numbers of a message list. The defaults follow what Telegram's
/// apps do, which is a good starting point for most chats.
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
    this.restoreIslandsAfterRestart = true,
    this.snapshotLoadBudget = const Duration(milliseconds: 50),
    this.jump = const JumpOptions(),
    this.loadingIndicatorDelay = const Duration(milliseconds: 150),
    this.reselectBehavior = ReselectBehavior.jumpToBottom,
    this.searchDebounce = const Duration(milliseconds: 300),
    this.appearDuration = const Duration(milliseconds: 200),
    this.removeDuration = const Duration(milliseconds: 200),
    this.collapseRemovedRows = false,
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

  /// Whether a saved position deep in the history (not connected to the
  /// newest message) is restored after a restart or a browser reload.
  ///
  /// True by default: the reader comes back to the message they were
  /// reading. With false such a position is dropped and the list opens at
  /// the first unread message or at the bottom, as Telegram does.
  final bool restoreIslandsAfterRestart;

  /// How long `loadSnapshot` may take before it is ignored.
  final Duration snapshotLoadBudget;

  /// Default options of `jumpTo` and the other jumps.
  final JumpOptions jump;

  /// A jump whose page loads longer than this reports `isLoading`, so the
  /// app can show a spinner on the button that started it.
  final Duration loadingIndicatorDelay;

  /// What `reselect()` does.
  final ReselectBehavior reselectBehavior;

  /// Quiet time after typing before a search query is sent.
  final Duration searchDebounce;

  /// Length of the appear animation of new messages; zero turns it off.
  final Duration appearDuration;

  /// Length of the animation of a deleted message; zero turns it off.
  final Duration removeDuration;

  /// Whether the space of a deleted row closes with an animation (another
  /// [removeDuration]) instead of in one step.
  final bool collapseRemovedRows;
}
