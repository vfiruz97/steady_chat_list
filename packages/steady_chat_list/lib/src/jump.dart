import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

/// How a jump moves.
///
/// ```dart
/// const JumpScroll.animated(duration: Duration(milliseconds: 250));
/// ```
@immutable
class JumpScroll {
  /// Animates the last part of the way. A target farther away than
  /// [maxAnimatedDistance] viewport heights is first brought that close
  /// without animation, so a jump never scrolls through a long history.
  const JumpScroll.animated({
    this.duration = const Duration(milliseconds: 400),
    this.curve = Curves.easeOutCubic,
    this.maxAnimatedDistance = 1.0,
  });

  /// Goes to the target at once.
  const JumpScroll.instant()
      : duration = Duration.zero,
        curve = Curves.linear,
        maxAnimatedDistance = 0;

  /// Length of the animation; zero for an instant jump.
  final Duration duration;

  /// Easing of the animation.
  final Curve curve;

  /// How many viewport heights are animated at most.
  final double maxAnimatedDistance;

  /// Whether nothing is animated.
  bool get isInstant => duration == Duration.zero;
}

/// How the target is flashed after a jump. The item draws it, using
/// `MessageItemInfo.highlight`.
///
/// ```dart
/// const JumpHighlight(duration: Duration(milliseconds: 600));
/// ```
@immutable
class JumpHighlight {
  /// Flashes the target: `info.highlight` goes from 1 to 0.
  const JumpHighlight({
    this.duration = const Duration(milliseconds: 1000),
    this.delay = Duration.zero,
    this.curve = Curves.easeOut,
  });

  /// No flash.
  const JumpHighlight.none()
      : duration = Duration.zero,
        delay = Duration.zero,
        curve = Curves.linear;

  /// How long the flash takes to fade.
  final Duration duration;

  /// Time at full strength before it fades.
  final Duration delay;

  /// Easing of the fade.
  final Curve curve;

  /// Whether there is a flash at all.
  bool get isEnabled => duration > Duration.zero;
}

/// Where a jump lands, how it moves and how it looks (§10.4).
///
/// ```dart
/// controller.jumpTo(reply.targetKey, options: const JumpOptions(
///   reason: JumpReason.reply,
///   alignment: JumpAlignment.top(inset: 56),
/// ));
/// ```
@immutable
class JumpOptions {
  /// Creates jump options.
  const JumpOptions({
    this.alignment = const JumpAlignment.centerIfFits(),
    this.scroll = const JumpScroll.animated(),
    this.highlight = const JumpHighlight(),
    this.highlightQuery,
    this.reason = JumpReason.programmatic,
  });

  /// Where the target ends up.
  final JumpAlignment alignment;

  /// How the list moves there.
  final JumpScroll scroll;

  /// How the target is flashed on arrival.
  final JumpHighlight highlight;

  /// A search term for the items to mark (`MessageItemInfo.highlightQuery`).
  /// It stays set until `controller.clearHighlightQuery()`.
  final String? highlightQuery;

  /// Why the jump happens.
  final JumpReason reason;

  /// A copy with the given fields replaced.
  JumpOptions copyWith({
    JumpAlignment? alignment,
    JumpScroll? scroll,
    JumpHighlight? highlight,
    String? highlightQuery,
    JumpReason? reason,
  }) =>
      JumpOptions(
        alignment: alignment ?? this.alignment,
        scroll: scroll ?? this.scroll,
        highlight: highlight ?? this.highlight,
        highlightQuery: highlightQuery ?? this.highlightQuery,
        reason: reason ?? this.reason,
      );
}

/// What happens when the user selects the chat that is already open.
///
/// ```dart
/// const MessageListConfig(reselectBehavior: ReselectBehavior.none);
/// ```
enum ReselectBehavior {
  /// Jump to the newest message (Telegram).
  jumpToBottom,

  /// Scroll to the oldest loaded message.
  scrollToTopOfWindow,

  /// Nothing.
  none,
}

/// A jump that is running, for spinners on the scroll-down button or the
/// search arrows.
///
/// ```dart
/// final busy = controller.jumpInProgress.value?.isLoading ?? false;
/// ```
@immutable
final class JumpState {
  /// Creates a state.
  const JumpState({required this.reason, this.target, this.isLoading = false});

  /// The target; null for a jump to the bottom or to a date.
  final MessageKey? target;

  /// Why the jump happens.
  final JumpReason reason;

  /// Whether the page with the target is loading (and has been for longer
  /// than `loadingIndicatorDelay`).
  final bool isLoading;
}

/// The item that is flashed after a jump.
///
/// ```dart
/// final flashing = controller.highlighted.value?.key;
/// ```
@immutable
final class HighlightState {
  /// Creates a state.
  const HighlightState({
    required this.key,
    required this.reason,
    required this.highlight,
    required this.serial,
  });

  /// The flashed message.
  final MessageKey key;

  /// Why the jump happened.
  final JumpReason reason;

  /// Timing of the flash.
  final JumpHighlight highlight;

  /// Changes with every flash, also for the same message.
  final int serial;
}

/// A step of a jump, reported through `onJump` and `controller.events`.
///
/// ```dart
/// onJump: (list, event) => analytics.log('jump', event.toMap()),
/// ```
@immutable
sealed class JumpEvent {
  const JumpEvent(this.reason, this.target);

  /// Why the jump happens.
  final JumpReason reason;

  /// The target; null for a jump to the bottom or to a date.
  final MessageKey? target;

  /// The name of the step.
  String get phase;

  /// A flat map for analytics.
  Map<String, Object?> toMap() => {
        'phase': phase,
        'reason': reason.name,
        if (target != null) 'target': target!.id,
      };

  @override
  String toString() => 'JumpEvent(${toMap()})';
}

/// The jump was requested.
final class JumpStarted extends JumpEvent {
  /// Creates the event.
  const JumpStarted(super.reason, super.target);

  @override
  String get phase => 'started';
}

/// The page with the target is taking longer than `loadingIndicatorDelay`.
final class JumpLoading extends JumpEvent {
  /// Creates the event.
  const JumpLoading(super.reason, super.target);

  @override
  String get phase => 'loading';
}

/// The list started moving to the target.
final class JumpScrolling extends JumpEvent {
  /// Creates the event.
  const JumpScrolling(super.reason, super.target);

  @override
  String get phase => 'scrolling';
}

/// The target (or the nearest message) is on screen.
final class JumpArrived extends JumpEvent {
  /// Creates the event.
  const JumpArrived(super.reason, super.target, this.result, this.rect);

  /// The result `jumpTo` returns.
  final JumpResult result;

  /// The item's rectangle in global coordinates, when a view is attached.
  final Rect? rect;

  @override
  String get phase => 'arrived';

  @override
  Map<String, Object?> toMap() => {
        ...super.toMap(),
        'outcome': result.outcome.name,
        'tookMs': result.took.inMilliseconds,
        'fetchedPages': result.fetchedPages,
        if (result.landedOn != null) 'landedOn': result.landedOn!.id,
      };
}

/// The flash on the target faded out.
final class JumpHighlightEnded extends JumpEvent {
  /// Creates the event.
  const JumpHighlightEnded(super.reason, super.target);

  @override
  String get phase => 'highlightEnded';
}

/// The jump was interrupted.
final class JumpCancelled extends JumpEvent {
  /// Creates the event.
  const JumpCancelled(super.reason, super.target);

  @override
  String get phase => 'cancelled';
}

/// The page with the target could not be loaded.
final class JumpFailed extends JumpEvent {
  /// Creates the event.
  const JumpFailed(super.reason, super.target, this.error);

  /// What went wrong.
  final Object error;

  @override
  String get phase => 'failed';

  @override
  Map<String, Object?> toMap() => {...super.toMap(), 'error': '$error'};
}

/// What a controller asks of the view that shows its window: move to an
/// item and measure items. `MessageListView` implements it.
///
/// ```dart
/// controller.attachViewport(myCustomView); // a custom view or a test
/// ```
abstract interface class MessageListViewport {
  /// Whether the item of [key] is laid out right now.
  bool isBuilt(MessageKey key);

  /// The item's rectangle in global coordinates, or null when not built.
  Rect? rectOf(MessageKey key);

  /// Moves [key] to [alignment]. Completes with true on arrival and false
  /// when the user or another scroll interrupted it. After a window with a
  /// jump placement was published, it waits for that window to be laid out.
  Future<bool> scrollToItem(
    MessageKey key,
    JumpAlignment alignment,
    JumpScroll scroll,
  );

  /// Moves to the end of the content. Completes like [scrollToItem].
  Future<bool> scrollToBottom(JumpScroll scroll);
}
