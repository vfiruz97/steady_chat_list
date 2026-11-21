import 'dart:async';
import 'dart:ui' show Rect;

import 'package:steady_chat_list/steady_chat_list.dart';

/// A headless stand-in for the view: lays the window out as a column of
/// boxes, applies placements, keeps the first visible item still when the
/// window changes (as the real view must), and reports metrics after the
/// "frame" (a microtask).
class FakeViewport<M> {
  FakeViewport(
    this.controller, {
    this.height = 600,
    this.width = 400,
    this.itemHeight = 50,
    this.dividerHeight = 30,
  }) : _window = controller.window.value {
    controller.window.addListener(_windowChanged);
    _windowChanged();
  }

  final MessageListController<M> controller;
  double height;
  final double width;
  final double itemHeight;
  final double dividerHeight;

  /// Height overrides by message id.
  final Map<String, double> heights = {};

  /// Content offset at the viewport top.
  double top = 0;

  /// Whether a finger is down.
  bool dragging = false;

  int layouts = 0;

  MessageWindow _window;
  int _serial = -1;
  final Map<String, double> _y = {};
  double _content = 0;
  double? _dividerY;
  bool _reportScheduled = false;

  List<MessageKey> get keys => _window.keys;

  double get _pad => _content < height ? height - _content : 0;
  double get _maxTop => _content > height ? _content - height : 0;

  /// The y of [key]'s top edge in the viewport, or null when not built.
  double? yOf(MessageKey key) {
    final y = _y[key.id];
    return y == null ? null : y - top + _pad;
  }

  /// The y of the unread divider in the viewport.
  double? get dividerY => _dividerY == null ? null : _dividerY! - top + _pad;

  /// Distance from the viewport bottom to the end of the content.
  double get extentAfter => _maxTop - top;

  /// Orders of the items intersecting the viewport.
  List<int> get visibleOrders =>
      [for (final item in _visible()) item.key.order];

  void scrollBy(double dy) {
    top = (top + dy).clamp(0, _maxTop);
    _scheduleReport();
  }

  void scrollToTop() => scrollBy(-top);

  void scrollToBottom() => scrollBy(_maxTop - top);

  void dispose() => controller.window.removeListener(_windowChanged);

  void _layout() {
    layouts++;
    _y.clear();
    _dividerY = null;
    var y = 0.0;
    for (final key in _window.keys) {
      if (key == _window.unreadDividerBefore) {
        _dividerY = y;
        y += dividerHeight;
      }
      _y[key.id] = y;
      y += heights[key.id] ?? itemHeight;
    }
    _content = y;
  }

  void _windowChanged() {
    final previous = _visible();
    final anchor = previous.isEmpty ? null : previous.first;
    final pinned = controller.isAtBottom.value && !dragging;
    _window = controller.window.value;
    _layout();
    final placement = _window.placement;
    if (_window.placementSerial != _serial && placement != null) {
      _serial = _window.placementSerial;
      switch (placement) {
        case PlaceAnchor(:final key, :final offset):
          top = (_y[key.id] ?? 0) - offset;
        case PlaceBottom():
          top = _maxTop;
        case PlaceUnread(:final key, :final topInset):
          top = (_dividerY ?? _y[key.id] ?? 0) - topInset;
      }
    } else if (pinned) {
      top = _maxTop;
    } else if (anchor != null && _y.containsKey(anchor.key.id)) {
      top = _y[anchor.key.id]! - anchor.rect.top;
    }
    top = top.clamp(0, _maxTop);
    _scheduleReport();
  }

  List<VisibleItem> _visible() {
    final items = <VisibleItem>[];
    for (final key in _window.keys) {
      final y = yOf(key);
      if (y == null) continue;
      final h = heights[key.id] ?? itemHeight;
      if (y >= height || y + h <= 0) continue;
      final shown = (y + h < height ? y + h : height) - (y > 0 ? y : 0);
      items.add(
        VisibleItem(
          key: key,
          rect: Rect.fromLTWH(0, y, width, h),
          visibleFraction: shown / h,
        ),
      );
    }
    return items;
  }

  void _scheduleReport() {
    if (_reportScheduled) return;
    _reportScheduled = true;
    scheduleMicrotask(() {
      _reportScheduled = false;
      controller.reportViewport(
        ViewportMetrics(
          viewport: Rect.fromLTWH(0, 0, width, height),
          items: _visible(),
          extentBefore: top,
          extentAfter: extentAfter,
          userDragging: dragging,
        ),
      );
    });
  }
}
