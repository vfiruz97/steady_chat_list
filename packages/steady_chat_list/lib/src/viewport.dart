import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

import 'jump.dart';

/// One item on screen.
///
/// ```dart
/// for (final item in metrics.items) {
///   if (item.visibleFraction == 1) print('${item.key.id} fully visible');
/// }
/// ```
@immutable
final class VisibleItem {
  /// Creates a visible item.
  const VisibleItem({
    required this.key,
    required this.rect,
    required this.visibleFraction,
  });

  /// The message.
  final MessageKey key;

  /// The item's rectangle in global coordinates.
  final Rect rect;

  /// The visible part of the item's height, 0–1.
  final double visibleFraction;
}

/// The messages on screen, from the first to the last.
///
/// ```dart
/// onVisibleRangeChanged: (list, range) => overlay.reposition(),
/// ```
@immutable
final class VisibleRange {
  /// Creates a range.
  const VisibleRange(
      {required this.first, required this.last, required this.count});

  /// The topmost visible message.
  final MessageKey first;

  /// The bottommost visible message.
  final MessageKey last;

  /// Number of visible messages.
  final int count;

  @override
  bool operator ==(Object other) =>
      other is VisibleRange &&
      other.first.id == first.id &&
      other.last.id == last.id &&
      other.count == count;

  @override
  int get hashCode => Object.hash(first, last, count);

  @override
  String toString() => 'VisibleRange(${first.id}..${last.id}, $count)';
}

/// What the view reports to the controller after a layout or a scroll.
///
/// The built-in view sends these. Tests and custom views can send them with
/// `MessageListController.reportViewport`.
///
/// ```dart
/// controller.reportViewport(ViewportMetrics(
///   viewport: const Rect.fromLTWH(0, 0, 400, 600),
///   items: visible, extentBefore: 1200, extentAfter: 0));
/// ```
@immutable
final class ViewportMetrics {
  /// Creates a report.
  const ViewportMetrics({
    required this.viewport,
    required this.items,
    required this.extentBefore,
    required this.extentAfter,
    this.userDragging = false,
  });

  /// The list's viewport in global coordinates.
  final Rect viewport;

  /// Items intersecting the viewport, top to bottom.
  final List<VisibleItem> items;

  /// Built content (px) above the viewport top.
  final double extentBefore;

  /// Built content (px) below the viewport bottom.
  final double extentAfter;

  /// Whether a finger is dragging the list.
  final bool userDragging;
}

/// Where the view must put the window before it paints (§11.4).
///
/// ```dart
/// switch (window.placement) {
///   case PlaceAnchor(:final key, :final offset): ...
///   case PlaceBottom(): ...
///   case PlaceUnread(:final key, :final topInset): ...
///   case PlaceJump(:final key, :final alignment): ...
///   case null: // keep the current position
/// }
/// ```
@immutable
sealed class WindowPlacement {
  const WindowPlacement();
}

/// Put the top of [key] at [offset] px below the viewport top.
final class PlaceAnchor extends WindowPlacement {
  /// Creates the placement.
  const PlaceAnchor(this.key, this.offset);

  /// The anchor item.
  final MessageKey key;

  /// Pixels from the viewport top to the anchor's top.
  final double offset;
}

/// Show the end of the window, pinned to the bottom. With [scroll] the view
/// starts up to one viewport above and animates down (a jump to the bottom).
final class PlaceBottom extends WindowPlacement {
  /// Creates the placement.
  const PlaceBottom({this.scroll});

  /// How to arrive; null puts the list there before the first paint.
  final JumpScroll? scroll;
}

/// A jump into a new window: start up to one viewport away from where
/// [key] will be at [alignment], on the side the list comes from, then
/// animate the rest (§10.4).
final class PlaceJump extends WindowPlacement {
  /// Creates the placement.
  const PlaceJump(
    this.key,
    this.alignment, {
    required this.fromNewer,
    required this.scroll,
  });

  /// The jump target.
  final MessageKey key;

  /// Where the target ends up.
  final JumpAlignment alignment;

  /// Whether the list comes from newer messages (it then travels upward).
  final bool fromNewer;

  /// How it moves.
  final JumpScroll scroll;
}

/// Put the unread divider (shown before [key]) at [topInset] px below the
/// viewport top; if the content below it is shorter than the viewport,
/// align to the bottom instead.
final class PlaceUnread extends WindowPlacement {
  /// Creates the placement.
  const PlaceUnread(this.key, this.topInset);

  /// The first unread message.
  final MessageKey key;

  /// Pixels from the viewport top to the divider.
  final double topInset;
}

/// The messages the view must build, and where to put them.
///
/// ```dart
/// controller.window.addListener(() {
///   final w = controller.window.value;
///   print('${w.keys.length} items, placement ${w.placement}');
/// });
/// ```
@immutable
final class MessageWindow {
  /// Creates a window.
  const MessageWindow({
    required this.list,
    required this.keys,
    this.unreadDividerBefore,
    this.removing = const {},
    this.justAdded = const {},
    this.placement,
    this.placementSerial = 0,
    this.generation = 0,
  });

  /// The list the keys belong to.
  final ListId list;

  /// Keys to build, oldest first. At most `windowSize`.
  final List<MessageKey> keys;

  /// The key the unread divider is shown before, if any.
  final MessageKey? unreadDividerBefore;

  /// Ids of deleted messages that are still in [keys] while they animate
  /// out.
  final Set<String> removing;

  /// Ids of messages that just arrived or were just sent (they play the
  /// appear animation).
  final Set<String> justAdded;

  /// Where to put the window. Applied once per [placementSerial]; otherwise
  /// the view keeps its position.
  final WindowPlacement? placement;

  /// Changes whenever [placement] must be applied again.
  final int placementSerial;

  /// Open/jump counter of the controller.
  final int generation;
}
