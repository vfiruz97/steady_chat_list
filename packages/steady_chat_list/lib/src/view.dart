import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

import 'anchored_scroll_position.dart';
import 'controller.dart';
import 'defaults.dart';
import 'events.dart';
import 'item_info.dart';
import 'viewport.dart';

/// The message list: a center-keyed scroll view over the controller's
/// window that never moves content under the reader's eyes (§11).
///
/// The app draws the messages; the list decides which are built, where they
/// are placed, and keeps them still while pages load, messages arrive,
/// media resizes or the keyboard opens.
///
/// ```dart
/// MessageListView<ChatMessage>(
///   controller: controller,
///   itemBuilder: (context, message, info) =>
///       MessageBubble(message, grouped: !info.isFirstInGroup),
///   footerBuilder: (context) => TypingIndicator(chat.id),
/// );
/// ```
class MessageListView<M> extends StatefulWidget {
  /// Creates a message list for [controller].
  const MessageListView({
    super.key,
    required this.controller,
    required this.itemBuilder,
    this.groupBuilder,
    this.dayHeaderBuilder,
    this.unreadDividerBuilder,
    this.edgeBuilder,
    this.historyStartBuilder,
    this.footerBuilder,
    this.emptyBuilder,
    this.loadingBuilder,
    this.errorBuilder,
    this.onDayTap,
    this.padding = EdgeInsets.zero,
    this.physics,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.onDrag,
    this.scrollbar = true,
  });

  /// Decides what is shown.
  final MessageListController<M> controller;

  /// Builds one message.
  final MessageItemBuilder<M> itemBuilder;

  /// Builds an album (messages with the same group id). Without it the
  /// messages of an album are stacked with [itemBuilder].
  final MessageGroupBuilder<M>? groupBuilder;

  /// Builds the header at the start of each day. No header without it.
  final DayHeaderBuilder? dayHeaderBuilder;

  /// Builds the "Unread messages" divider.
  final WidgetBuilder? unreadDividerBuilder;

  /// Builds the row at each end of the window. Default: a spinner while a
  /// page loads, a tap-to-retry line when it failed.
  final EdgeBuilder? edgeBuilder;

  /// Shown above the oldest message of the list (chat intro).
  final WidgetBuilder? historyStartBuilder;

  /// Shown below the newest message (typing indicator). Its height may
  /// change; a list at the bottom stays pinned.
  final WidgetBuilder? footerBuilder;

  /// Shown when the list has no messages. Default: [DefaultEmptyState].
  final WidgetBuilder? emptyBuilder;

  /// Shown while the first page loads. Default: [DefaultLoadingState].
  final WidgetBuilder? loadingBuilder;

  /// Shown when the first page failed. Default: [DefaultErrorState], which
  /// calls `controller.open()` on tap.
  final WidgetBuilder? errorBuilder;

  /// Called when a day header is tapped.
  final void Function(DateTime day)? onDayTap;

  /// Space around the content. The vertical part scrolls with it.
  final EdgeInsets padding;

  /// Scroll physics; the platform default when null.
  final ScrollPhysics? physics;

  /// When scrolling dismisses the keyboard.
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// Whether desktop and web show a scrollbar.
  final bool scrollbar;

  @override
  State<MessageListView<M>> createState() => _MessageListViewState<M>();
}

class _MessageListViewState<M> extends State<MessageListView<M>>
    with WidgetsBindingObserver
    implements AnchoredScrollHost {
  final GlobalKey _viewportKey = GlobalKey(debugLabel: 'steady viewport');
  final Map<String, _RenderRow> _registry = {};
  late final _AnchoredScrollController _scroll =
      _AnchoredScrollController(this);

  // Rows of the current window, split around the center of the viewport.
  List<_Row> _upper = const []; // older than the split; index 0 = newest
  List<_Row> _lower = const []; // the split and newer; index 0 = oldest
  Map<String, int> _upperIndex = const {};
  Map<String, int> _lowerIndex = const {};
  final Map<String, (_Row, int, Widget)> _built = {};
  int _widgetEpoch = 0;

  // Placement.
  int _serial = -1;
  int _epoch = 0;
  MessageKey? _split; // rows starting at or after this key are below
  bool _splitInclusive = true;
  ({bool bottom, double offset})? _initialPlacement;

  // Anchors captured at the last accepted layout: (row id, scroll offset).
  List<(String, double)> _anchors = const [];
  _Frame? _frame;
  bool _reportScheduled = false;

  MessageListController<M> get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen(_controller);
    _adoptWindow();
  }

  @override
  void didUpdateWidget(MessageListView<M> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _widgetEpoch++; // builders may close over new state: rebuild built rows
    if (!identical(oldWidget.controller, _controller)) {
      _unlisten(oldWidget.controller);
      _listen(_controller);
      _serial = -1;
      _adoptWindow();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unlisten(_controller);
    _scroll.dispose();
    super.dispose();
  }

  void _listen(MessageListController<M> controller) {
    controller.window.addListener(_windowChanged);
    controller.phase.addListener(_rebuild);
    controller.lastReadOutbox.addListener(_windowChanged);
  }

  void _unlisten(MessageListController<M> controller) {
    controller.window.removeListener(_windowChanged);
    controller.phase.removeListener(_rebuild);
    controller.lastReadOutbox.removeListener(_windowChanged);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _windowChanged() {
    if (!mounted) return;
    setState(_adoptWindow);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    _controller.setForeground(foreground: foreground);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Also covers the web: hiding or closing the tab reports `hidden`.
      _controller.saveSnapshot(reason: SaveReason.appPaused);
    }
  }

  // ------------------------------------------------------------------ rows

  void _adoptWindow() {
    final window = _controller.window.value;
    final placement = window.placement;
    final placed = window.placementSerial != _serial &&
        placement != null &&
        window.keys.isNotEmpty;
    if (placed) {
      _serial = window.placementSerial;
      _epoch++; // fresh slivers: no stale layout offsets survive a placement
      _anchors = const [];
      final ({bool bottom, double offset}) place;
      switch (placement) {
        case PlaceAnchor(:final key, :final offset):
          _split = key;
          _splitInclusive = true;
          place = (bottom: false, offset: offset);
        case PlaceUnread(:final key, :final topInset):
          _split = key;
          _splitInclusive = true;
          place = (bottom: false, offset: topInset);
        case PlaceBottom():
          // Everything is above the center; what arrives later goes below.
          _split = window.keys.last;
          _splitInclusive = false;
          place = (bottom: true, offset: 0);
      }
      if (_scroll.hasClients) {
        _scroll.anchored.place(bottom: place.bottom, offset: place.offset);
      } else {
        _initialPlacement = place;
      }
    }
    _buildRows(window, placed: placed);
  }

  void _buildRows(MessageWindow window, {required bool placed}) {
    final controller = _controller;
    final adapter = controller.hub.adapter;
    final grouping = controller.policies.grouping ?? GroupingPolicy<M>();
    final gap = controller.config.groupingGap;
    final outbox = controller.lastReadOutbox.value;
    final keys = window.keys;

    // Albums: neighbours with the same group id share a row.
    final groups = <List<MessageKey>>[];
    String? openGroup;
    for (final key in keys) {
      final message = controller.messageOf(key);
      final group = message == null ? null : adapter.groupIdOf(message);
      if (group != null && group == openGroup) {
        groups.last.add(key);
      } else {
        groups.add([key]);
      }
      openGroup = group;
    }

    final rows = <_Row>[];
    for (var i = 0; i < groups.length; i++) {
      final rowKeys = groups[i];
      final first = rowKeys.first;
      final last = rowKeys.last;
      final firstMessage = controller.messageOf(first);
      final lastMessage = controller.messageOf(last);
      if (firstMessage == null || lastMessage == null) continue;
      final beforeKey =
          i > 0 ? groups[i - 1].last : controller.keyBefore(first);
      final afterKey = i < groups.length - 1
          ? groups[i + 1].first
          : controller.keyAfter(last);
      final before = beforeKey == null ? null : controller.messageOf(beforeKey);
      final after = afterKey == null ? null : controller.messageOf(afterKey);
      final day = grouping.dayOf(adapter, firstMessage);
      final firstInDay =
          before == null || grouping.dayOf(adapter, before) != day;
      final current = controller.sendStateOf(first);
      final group = adapter.groupIdOf(firstMessage);
      final row = _Row(
        id: rowKeys.length > 1 && group != null ? 'album:$group' : first.id,
        keys: rowKeys,
        day: firstInDay ? day : null,
        divider: rowKeys.contains(window.unreadDividerBefore),
        info: MessageItemInfo(
          key: first,
          isFirstInGroup: before == null ||
              !grouping.sameGroup(adapter, before, firstMessage, gap),
          isLastInGroup: after == null ||
              !grouping.sameGroup(adapter, lastMessage, after, gap),
          isFirstInDay: firstInDay,
          isFirstUnread: rowKeys.contains(window.unreadDividerBefore),
          isLocal: first.isLocal,
          sendState: current,
          isRead: current == SendState.sent && outbox != null && last <= outbox,
          indexInWindow: i,
        ),
      );
      rows.add(row);
    }

    if (!placed) {
      // When one side of the center has no surviving row, the center moves
      // to the edge of the other side. No row changes its list, and what
      // comes back on the emptied side (a page re-added after a trim) grows
      // away from the center instead of squeezing in before built rows.
      var lastAbove = -1;
      var firstBelow = -1;
      for (var i = 0; i < rows.length; i++) {
        if (_upperIndex.containsKey(rows[i].id)) lastAbove = i;
        if (firstBelow < 0 && _lowerIndex.containsKey(rows[i].id)) {
          firstBelow = i;
        }
      }
      if (lastAbove >= 0 && firstBelow < 0) {
        _split = rows[lastAbove].keys.first;
        _splitInclusive = false;
      } else if (firstBelow >= 0 && lastAbove < 0) {
        _split = rows[firstBelow].keys.first;
        _splitInclusive = true;
      }
    }
    final split = _split;
    final upper = <_Row>[];
    final lower = <_Row>[];
    for (final row in rows) {
      final first = row.keys.first;
      final below =
          split == null || (_splitInclusive ? first >= split : first > split);
      (below ? lower : upper).add(row);
    }
    _upper = upper.reversed.toList(growable: false);
    _lower = lower;
    _upperIndex = {for (var i = 0; i < _upper.length; i++) _upper[i].id: i};
    _lowerIndex = {for (var i = 0; i < _lower.length; i++) _lower[i].id: i};
    _built.removeWhere(
      (id, _) => !_upperIndex.containsKey(id) && !_lowerIndex.containsKey(id),
    );
  }

  /// The widget of a row. The same instance is returned while nothing about
  /// the row changed, so a window update rebuilds only new or changed rows.
  Widget _rowWidget(_Row row) {
    final cached = _built[row.id];
    if (cached != null && cached.$1 == row && cached.$2 == _widgetEpoch) {
      return cached.$3;
    }
    final built =
        _RowWidget<M>(key: ValueKey<String>(row.id), row: row, host: this);
    _built[row.id] = (row, _widgetEpoch, built);
    return built;
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_upper.isEmpty && _lower.isEmpty) {
      return switch (controller.phase.value) {
        ListPhase.loading ||
        ListPhase.ready =>
          widget.loadingBuilder?.call(context) ?? const DefaultLoadingState(),
        ListPhase.empty =>
          widget.emptyBuilder?.call(context) ?? const DefaultEmptyState(),
        ListPhase.error => widget.errorBuilder?.call(context) ??
            DefaultErrorState(onRetry: controller.open),
      };
    }
    final centerKey = ValueKey<int>(_epoch);
    final padding = widget.padding;
    SliverChildBuilderDelegate delegate(
      List<_Row> rows,
      Map<String, int> index,
    ) =>
        SliverChildBuilderDelegate(
          (context, i) => _rowWidget(rows[i]),
          childCount: rows.length,
          findChildIndexCallback: (key) =>
              key is ValueKey<String> ? index[key.value] : null,
          // The row is its own repaint boundary and registers its render
          // object; nothing may be wrapped around it.
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: false,
          addSemanticIndexes: false,
        );

    final scrollView = _AnchoredScrollView(
      controller: _scroll,
      viewportKey: _viewportKey,
      center: centerKey,
      physics: widget.physics,
      cacheExtent: controller.config.cacheExtent,
      keyboardDismissBehavior: widget.keyboardDismissBehavior,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: padding.top),
            child: _EdgeRow(
              edge: ListEdge.older,
              state: controller.olderEdge,
              builder: widget.edgeBuilder,
              endBuilder: widget.historyStartBuilder,
              retry: () => controller.retry(ListEdge.older),
            ),
          ),
        ),
        _SteadySliverList(
          key: ValueKey<String>('upper$_epoch'),
          delegate: delegate(_upper, _upperIndex),
        ),
        _SteadySliverList(
          key: centerKey,
          delegate: delegate(_lower, _lowerIndex),
        ),
        SliverToBoxAdapter(
          child: _EdgeRow(
            edge: ListEdge.newer,
            state: controller.newerEdge,
            builder: widget.edgeBuilder,
            retry: () => controller.retry(ListEdge.newer),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(bottom: padding.bottom),
            child: widget.footerBuilder == null
                ? null
                : Builder(builder: widget.footerBuilder!),
          ),
        ),
      ],
    );
    if (widget.scrollbar) return scrollView;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: scrollView,
    );
  }

  // ----------------------------------------------------- AnchoredScrollHost

  ({bool bottom, double offset})? takeInitialPlacement() {
    final placement = _initialPlacement;
    _initialPlacement = null;
    return placement;
  }

  RenderViewport? get _viewport {
    final object = _viewportKey.currentContext?.findRenderObject();
    return object is RenderViewport ? object : null;
  }

  @override
  bool get endsAtNewest => _controller.windowEndsAtNewest;

  @override
  double get stickThreshold => _controller.config.stickToBottomThreshold;

  @override
  bool shouldStick({required bool userDragging}) =>
      _controller.policies.bottomStick.shouldStick(userDragging: userDragging);

  @override
  ({double min, double max})? contentBounds(double viewportDimension) {
    final viewport = _viewport;
    if (viewport == null) return null;
    var upper = 0.0;
    var lower = 0.0;
    var below = false;
    for (var sliver = viewport.firstChild;
        sliver != null;
        sliver = viewport.childAfter(sliver)) {
      if (identical(sliver, viewport.center)) below = true;
      final extent = sliver.geometry?.scrollExtent ?? 0;
      if (below) {
        lower += extent;
      } else {
        upper += extent;
      }
    }
    final max = lower - viewportDimension;
    final min = -upper;
    // Content shorter than the viewport sits at the bottom.
    return (min: max < min ? max : min, max: max);
  }

  /// The scroll offset at which the top of [row] is at the viewport top.
  double? _topOf(_RenderRow row, RenderViewport viewport) {
    final data = row.parentData;
    if (data is! SliverMultiBoxAdaptorParentData) return null;
    final offset = data.layoutOffset;
    if (offset == null || data.keptAlive) return null;
    return identical(row.parent, viewport.center)
        ? offset
        : -(offset + row.height);
  }

  @override
  double takeAnchorDelta() {
    final viewport = _viewport;
    if (viewport == null) return 0;
    for (final (id, recorded) in _anchors) {
      final row = _registry[id];
      if (row == null || !row.attached) continue;
      final top = _topOf(row, viewport);
      if (top == null) continue;
      final delta = top - recorded;
      if (delta != 0) shiftAnchor(delta);
      return delta;
    }
    return 0;
  }

  @override
  void shiftAnchor(double correction) {
    if (_anchors.isEmpty || correction == 0) return;
    _anchors = [for (final (id, top) in _anchors) (id, top + correction)];
  }

  @override
  void didLayout(AnchoredScrollPosition position, {required double corrected}) {
    final viewport = _viewport;
    if (viewport == null) return;
    final pixels = position.pixels;
    final height = position.viewportDimension;

    // Built rows, top to bottom.
    final rows = <(_RenderRow, double)>[];
    void collect(RenderSliver? sliver, {required bool reverse}) {
      if (sliver is! RenderSliverList) return;
      final start = rows.length;
      for (var child = sliver.firstChild;
          child != null;
          child = sliver.childAfter(child)) {
        if (child is! _RenderRow) continue;
        final top = _topOf(child, viewport);
        if (top != null) rows.add((child, top));
      }
      if (reverse) {
        final part = rows.sublist(start).reversed.toList();
        rows.replaceRange(start, rows.length, part);
      }
    }

    final center = viewport.center;
    collect(center == null ? null : viewport.childBefore(center),
        reverse: true);
    collect(center, reverse: false);

    final visible = <(_RenderRow, double)>[
      for (final (row, top) in rows)
        if (top < pixels + height && top + row.height > pixels) (row, top),
    ];
    final picked = _controller.policies.anchor.pick([
      for (final (row, top) in visible)
        AnchorCandidate(
          key: row.row.keys.first,
          top: top - pixels,
          height: row.height,
        ),
    ]);
    // The picked row first, then the rows after it as fallbacks.
    final from = picked == null
        ? 0
        : visible.indexWhere((v) => v.$1.row.keys.first == picked.key);
    _anchors = [
      for (final (row, top) in visible.skip(from < 0 ? 0 : from).take(4))
        (row.row.id, top),
    ];

    _frame = _Frame(
      pixels: pixels,
      height: height,
      min: position.minScrollExtent,
      max: position.maxScrollExtent,
      dragging: position.isDragging,
      rows: [
        for (final (row, top) in visible)
          (row.row.keys, top - pixels, row.height),
      ],
    );
    if (kDebugMode && corrected.abs() > 0.01) {
      _controller.reportDiagnostic(AnchorCorrected(corrected));
    }
    if (!_reportScheduled) {
      _reportScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) => _report());
    }
  }

  /// Tells the controller what is on screen, after the frame (never during
  /// layout).
  void _report() {
    _reportScheduled = false;
    final frame = _frame;
    final viewport = _viewport;
    if (!mounted || frame == null || viewport == null || !viewport.attached) {
      return;
    }
    final origin = viewport.localToGlobal(Offset.zero);
    final width = viewport.size.width;
    _controller.reportViewport(
      ViewportMetrics(
        viewport: origin & viewport.size,
        items: [
          for (final (keys, top, height) in frame.rows)
            for (final key in keys)
              VisibleItem(
                key: key,
                rect: Rect.fromLTWH(origin.dx, origin.dy + top, width, height),
                visibleFraction: height <= 0
                    ? 0
                    : ((top + height < frame.height
                                ? top + height
                                : frame.height) -
                            (top > 0 ? top : 0)) /
                        height,
              ),
        ],
        extentBefore: frame.pixels - frame.min,
        extentAfter:
            frame.max - frame.pixels < 0 ? 0 : frame.max - frame.pixels,
        userDragging: frame.dragging,
      ),
    );
  }
}

/// What was on screen at the last accepted layout.
final class _Frame {
  const _Frame({
    required this.pixels,
    required this.height,
    required this.min,
    required this.max,
    required this.dragging,
    required this.rows,
  });

  final double pixels;
  final double height;
  final double min;
  final double max;
  final bool dragging;

  /// Visible rows: keys, top relative to the viewport, height.
  final List<(List<MessageKey>, double, double)> rows;
}

/// One child of the list: a message or an album, with the day header and
/// the unread divider that belong above it.
@immutable
final class _Row {
  const _Row({
    required this.id,
    required this.keys,
    required this.info,
    required this.day,
    required this.divider,
  });

  final String id;
  final List<MessageKey> keys;
  final MessageItemInfo info;
  final DateTime? day;
  final bool divider;

  @override
  bool operator ==(Object other) {
    if (other is! _Row ||
        other.id != id ||
        other.day != day ||
        other.divider != divider ||
        other.info != info ||
        other.keys.length != keys.length) {
      return false;
    }
    for (var i = 0; i < keys.length; i++) {
      if (other.keys[i].id != keys[i].id) return false;
    }
    return true;
  }

  @override
  int get hashCode => id.hashCode; // coverage:ignore-line
}

class _RowWidget<M> extends StatefulWidget {
  const _RowWidget({super.key, required this.row, required this.host});

  final _Row row;
  final _MessageListViewState<M> host;

  @override
  State<_RowWidget<M>> createState() => _RowWidgetState<M>();
}

class _RowWidgetState<M> extends State<_RowWidget<M>> {
  List<Listenable> _sources = const [];

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(_RowWidget<M> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _unsubscribe();
    _subscribe();
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _subscribe() {
    final controller = widget.host._controller;
    _sources = [
      for (final key in widget.row.keys) controller.listenableFor(key.id),
    ];
    for (final source in _sources) {
      source.addListener(_changed);
    }
  }

  void _unsubscribe() {
    for (final source in _sources) {
      source.removeListener(_changed);
    }
    _sources = const [];
  }

  void _changed() {
    if (mounted) setState(() {}); // this row only (§14 rule 1)
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final view = host.widget;
    final row = widget.row;
    final messages = <M>[];
    for (final key in row.keys) {
      final message = host._controller.messageOf(key);
      if (message != null) messages.add(message);
    }
    Widget child;
    if (messages.isEmpty) {
      child = const SizedBox.shrink();
    } else if (messages.length == 1) {
      child = view.itemBuilder(context, messages.first, row.info);
    } else if (view.groupBuilder != null) {
      child = view.groupBuilder!(context, messages, row.info);
    } else {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final message in messages)
            view.itemBuilder(context, message, row.info),
        ],
      );
    }
    final day = row.day;
    final header = day == null ? null : view.dayHeaderBuilder;
    if (header != null || row.divider) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            header(context, day!, () => view.onDayTap?.call(day)),
          if (row.divider)
            view.unreadDividerBuilder?.call(context) ??
                const _DefaultUnreadDivider(),
          child,
        ],
      );
    }
    final padding = view.padding;
    if (padding.left != 0 || padding.right != 0) {
      child = Padding(
        padding: EdgeInsets.only(left: padding.left, right: padding.right),
        child: child,
      );
    }
    return _RowBoundary(row: row, registry: host._registry, child: child);
  }
}

/// Marks the root of a row: a repaint boundary whose render object is
/// registered by id (anchors, geometry) without a `GlobalKey` per item.
class _RowBoundary extends SingleChildRenderObjectWidget {
  const _RowBoundary({
    required this.row,
    required this.registry,
    required super.child,
  });

  final _Row row;
  final Map<String, _RenderRow> registry;

  @override
  _RenderRow createRenderObject(BuildContext context) =>
      _RenderRow(row, registry);

  @override
  void updateRenderObject(BuildContext context, _RenderRow renderObject) {
    renderObject.row = row;
  }
}

class _RenderRow extends RenderProxyBox {
  _RenderRow(this.row, this._registry);

  final Map<String, _RenderRow> _registry;

  /// The row this render object shows. Its id never changes: the element
  /// is keyed by it.
  _Row row;

  /// The height at the last layout. Recorded here because the viewport
  /// reads it while it lays out, when only the parent may read `size`.
  double height = 0;

  @override
  bool get isRepaintBoundary => true;

  @override
  void performLayout() {
    super.performLayout();
    height = size.height;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _registry[row.id] = this;
  }

  @override
  void detach() {
    _unregister();
    super.detach();
  }

  void _unregister() {
    if (identical(_registry[row.id], this)) _registry.remove(row.id);
  }
}

class _EdgeRow extends StatelessWidget {
  const _EdgeRow({
    required this.edge,
    required this.state,
    required this.builder,
    required this.retry,
    this.endBuilder,
  });

  final ListEdge edge;
  final ValueListenable<EdgeState> state;
  final EdgeBuilder? builder;
  final WidgetBuilder? endBuilder;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EdgeState>(
        valueListenable: state,
        builder: (context, value, _) {
          final end = endBuilder;
          if (value is EdgeEnd && end != null) return end(context);
          final custom = builder;
          if (custom != null) return custom(context, edge, value, retry);
          return switch (value) {
            EdgeLoading() => const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(child: SteadySpinner()),
              ),
            EdgeError() => DefaultErrorState(
                onRetry: retry,
                text: "Couldn't load more. Tap to retry.",
                expand: false,
              ),
            EdgeIdle() || EdgeEnd() => const SizedBox.shrink(),
          };
        },
      );
}

class _DefaultUnreadDivider extends StatelessWidget {
  const _DefaultUnreadDivider();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Center(child: Text('Unread messages')),
      );
}

class _AnchoredScrollController extends ScrollController {
  _AnchoredScrollController(this._host) : super(keepScrollOffset: false);

  final _MessageListViewState<Object?> _host;

  AnchoredScrollPosition get anchored => position as AnchoredScrollPosition;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    final position = AnchoredScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      host: _host,
      debugLabel: 'steady_chat_list',
    );
    final placement = _host.takeInitialPlacement();
    if (placement != null) {
      position.place(bottom: placement.bottom, offset: placement.offset);
    }
    return position;
  }
}

/// A `SliverList` whose built children keep their layout offsets when their
/// indices change.
///
/// A stock `SliverList` ties layout offsets to indices: when rows are added
/// or removed before the built children (a window trim, a page added on the
/// center side), a moved child takes the offset of whatever was at its new
/// index, or loses its offset and is destroyed with its `State`. Here every
/// surviving child keeps its own offset, so the built rows stay where they
/// are; the list then reflows from its first built child as usual, and any
/// gap left at index 0 is closed by the sliver's own scroll offset
/// correction when the viewport gets there.
class _SteadySliverList extends SliverList {
  const _SteadySliverList({super.key, required super.delegate});

  @override
  SliverMultiBoxAdaptorElement createElement() =>
      _SteadySliverElement(this, replaceMovedChildren: true);
}

class _SteadySliverElement extends SliverMultiBoxAdaptorElement {
  _SteadySliverElement(super.widget, {super.replaceMovedChildren});

  @override
  void performRebuild() {
    final list = renderObject;
    final offsets = <RenderBox, double>{};
    for (var child = list.firstChild;
        child != null;
        child = list.childAfter(child)) {
      final offset =
          (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset;
      if (offset != null) offsets[child] = offset;
    }
    super.performRebuild();
    for (var child = list.firstChild;
        child != null;
        child = list.childAfter(child)) {
      final offset = offsets[child];
      if (offset != null) {
        (child.parentData! as SliverMultiBoxAdaptorParentData).layoutOffset =
            offset;
      }
    }
  }
}

/// A `CustomScrollView` whose viewport can be found by key (to read the
/// extents of its slivers).
class _AnchoredScrollView extends CustomScrollView {
  const _AnchoredScrollView({
    required ScrollController super.controller,
    required this.viewportKey,
    required Key super.center,
    required super.slivers,
    super.physics,
    // `scrollCacheExtent` replaces this in Flutter 3.41+, but the package
    // supports Flutter 3.24.
    // ignore: deprecated_member_use
    super.cacheExtent,
    super.keyboardDismissBehavior,
  });

  final GlobalKey viewportKey;

  @override
  Widget buildViewport(
    BuildContext context,
    ViewportOffset offset,
    AxisDirection axisDirection,
    List<Widget> slivers,
  ) =>
      Viewport(
        key: viewportKey,
        axisDirection: axisDirection,
        offset: offset,
        slivers: slivers,
        // ignore: deprecated_member_use
        cacheExtent: cacheExtent,
        center: center,
        clipBehavior: clipBehavior,
      );
}
