import 'package:flutter/widgets.dart';

/// Returns the scroll offset a placement wants, given the scroll range and
/// the viewport height after the content was laid out.
///
/// ```dart
/// position.placeWith((min, max, viewport) => max); // the bottom
/// ```
typedef PlacementResolver = double Function(
  double min,
  double max,
  double viewport,
);

/// What an [AnchoredScrollPosition] needs to know about the content. The
/// message list view implements it.
///
/// ```dart
/// class _MyListState extends State<MyList> implements AnchoredScrollHost {
///   // measure the laid-out items and answer the position's questions
/// }
/// ```
abstract interface class AnchoredScrollHost {
  /// The real scroll bounds for [viewportDimension], or null to keep what
  /// the viewport computed. Content shorter than the viewport reports
  /// `min == max` so that it sits at the bottom.
  ({double min, double max})? contentBounds(double viewportDimension);

  /// Whether the content ends at the newest message (bottom pinning only
  /// applies there).
  bool get endsAtNewest;

  /// The list counts as "at bottom" within this distance.
  double get stickThreshold;

  /// Whether a list that is at the bottom stays pinned there.
  bool shouldStick({required bool userDragging});

  /// How far the anchor item moved (in scroll offset) since the last
  /// accepted layout, because content before it was inserted, removed or
  /// resized. The host takes the new position as its baseline.
  double takeAnchorDelta();

  /// The viewport corrected the offset by [correction] on its own (a sliver
  /// asked for it): the anchor is expected to have moved by the same amount.
  void shiftAnchor(double correction);

  /// Whether a jump animation owns the position: the anchor is then left
  /// alone and the jump retargets instead.
  bool get isJumping;

  /// A layout was accepted at the position's current pixels. [corrected]
  /// is how far the offset was moved to keep the anchor still.
  void didLayout(AnchoredScrollPosition position, {required double corrected});
}

/// A scroll position that never lets content move under the reader's eyes
/// (§11.2).
///
/// After every layout of the viewport it asks its [host] where the anchor
/// item is now. If content before the anchor changed size, the offset is
/// corrected in the same layout pass, before anything is painted. It also:
///
/// * applies a pending placement (open, restore) before the first paint;
/// * keeps the list pinned to the bottom when it was at the bottom
///   (new messages, keyboard, footer);
/// * makes content shorter than the viewport sit at the bottom.
///
/// ```dart
/// class MyController extends ScrollController {
///   MyController(this.host) : super(keepScrollOffset: false);
///   final AnchoredScrollHost host;
///   @override
///   ScrollPosition createScrollPosition(ScrollPhysics physics,
///           ScrollContext context, ScrollPosition? oldPosition) =>
///       AnchoredScrollPosition(
///           physics: physics, context: context, host: host);
/// }
/// ```
class AnchoredScrollPosition extends ScrollPositionWithSingleContext {
  /// Creates a position for [host].
  AnchoredScrollPosition({
    required super.physics,
    required super.context,
    required this.host,
    super.oldPosition,
    super.debugLabel,
  }) : super(initialPixels: 0, keepScrollOffset: false);

  /// Measures the content.
  final AnchoredScrollHost host;

  static const double _epsilon = 0.01;
  static const int _maxPasses = 8;

  ({PlacementResolver resolve, bool bottom})? _pending;
  bool _pinned = false;
  double _bottomGap = 0;
  bool _ownCorrection = false;
  int _passes = 0;
  double _corrected = 0;

  /// Whether the list is pinned to the bottom: it was at the bottom and
  /// will follow content that grows below.
  bool get isPinned => _pinned;

  /// Whether a finger is dragging the list.
  bool get isDragging => activity is DragScrollActivity;

  /// Whether a placement is waiting for the next layout.
  bool get hasPendingPlacement => _pending != null;

  /// Puts the content where [resolve] says, before the next paint.
  /// [resolve] runs after the content was laid out (possibly several times
  /// in one frame, until the offset is stable). [guess] is the offset for
  /// the first pass; [bottom] marks a placement at the end of the content.
  void placeWith(
    PlacementResolver resolve, {
    double? guess,
    bool bottom = false,
  }) {
    if (activity is! IdleScrollActivity) goIdle();
    _pending = (resolve: resolve, bottom: bottom);
    _pinned = bottom;
    _bottomGap = 0;
    correctPixels(
      guess ?? (bottom && hasViewportDimension ? -viewportDimension : 0),
    );
  }

  @override
  bool applyViewportDimension(double viewportDimension) {
    final pending = _pending;
    if (pending != null && pending.bottom && !hasViewportDimension) {
      // A first guess; exact after the slivers are laid out.
      correctPixels(-viewportDimension);
    }
    return super.applyViewportDimension(viewportDimension);
  }

  @override
  double setPixels(double newPixels) {
    final overscroll = super.setPixels(newPixels);
    _updatePinned();
    return overscroll;
  }

  @override
  void forcePixels(double value) {
    super.forcePixels(value); // jumpTo
    _updatePinned();
  }

  @override
  void correctBy(double correction) {
    super.correctBy(correction);
    if (!_ownCorrection) host.shiftAnchor(correction);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final bounds = host.contentBounds(viewportDimension);
    final lo = bounds?.min ?? minScrollExtent;
    final hi = bounds?.max ?? maxScrollExtent;

    final pending = _pending;
    double? target;
    if (pending != null) {
      target = pending.resolve(lo, hi, viewportDimension);
    } else if (_pinned && host.shouldStick(userDragging: isDragging)) {
      // Pinning wins over the anchor: keep the distance to the bottom
      // (zero when exactly at the bottom) while content or the viewport
      // changes size. An overscroll (iOS bounce) is left to the physics
      // unless nothing is moving.
      final gap =
          _bottomGap < 0 && activity is IdleScrollActivity ? 0.0 : _bottomGap;
      target = hi - gap;
    } else if (!host.isJumping) {
      final delta = host.takeAnchorDelta();
      if (delta.abs() > _epsilon) target = pixels + delta;
    }

    if (target != null &&
        (target - pixels).abs() > _epsilon &&
        _passes < _maxPasses) {
      _passes++;
      if (pending != null) {
        correctPixels(target);
      } else {
        _corrected += target - pixels;
        _ownCorrection = true;
        correctBy(target - pixels);
        _ownCorrection = false;
      }
      return false; // lay out again at the corrected offset, same frame
    }

    _pending = null;
    if (!super.applyContentDimensions(lo, hi)) return false;
    _passes = 0;
    _updatePinned();
    final corrected = _corrected;
    _corrected = 0;
    host.didLayout(this, corrected: corrected);
    return true;
  }

  void _updatePinned() {
    if (!hasContentDimensions || !hasPixels) return;
    _bottomGap = maxScrollExtent - pixels;
    _pinned = host.endsAtNewest && _bottomGap <= host.stickThreshold;
  }
}
