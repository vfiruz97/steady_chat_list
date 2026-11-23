import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

import 'anchored_scroll_position.dart';
import 'controller.dart';
import 'defaults.dart';
import 'events.dart';
import 'item_info.dart';
import 'jump.dart';
import 'viewport.dart';
import 'widgets.dart';

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
    this.appearTransitionBuilder,
    this.removeTransitionBuilder,
    this.scrollDownButtonBuilder,
    this.floatingDayBuilder,
    this.keyboardShortcuts = true,
    this.debugOverlay = false,
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

  /// Animates a message that just arrived or was just sent; the animation
  /// goes 0 → 1. Default: a fade-in.
  final ItemTransitionBuilder? appearTransitionBuilder;

  /// Animates a deleted message out; the animation goes 0 → 1. Default:
  /// fade out, shrink to 30% and slide toward the sender's side.
  final ItemTransitionBuilder? removeTransitionBuilder;

  /// Builds a scroll-to-bottom button that floats over the bottom end
  /// corner while the newest message is more than a screen away. It gets
  /// the unread count and what to do on tap. No button without it; see
  /// also `MessageListButtons` for placing the buttons yourself.
  ///
  /// ```dart
  /// scrollDownButtonBuilder: (context, unread, onTap) =>
  ///     ScrollDownButton(unread: unread, onTap: onTap),
  /// ```
  final Widget Function(BuildContext context, int unread, VoidCallback onTap)?
      scrollDownButtonBuilder;

  /// Builds a chip with the day of the topmost message that floats at the
  /// top while the list scrolls and fades out a second after it stops.
  ///
  /// ```dart
  /// floatingDayBuilder: (context, day, onTap) =>
  ///     DayHeader(day: day, onTap: onTap),
  /// ```
  final DayHeaderBuilder? floatingDayBuilder;

  /// Whether the list reacts to PageUp, PageDown, Home, End and the arrow
  /// keys on desktop and web (after it was clicked). The list takes the
  /// keyboard focus on every click, so turn this off inside a
  /// `SelectionArea` or on a page that manages focus itself.
  final bool keyboardShortcuts;

  /// Draws the anchor line and the controller's state over the list
  /// (debug builds only): window, segments, edges, pending fetches,
  /// generation and the last anchor correction (§16).
  final bool debugOverlay;

  @override
  State<MessageListView<M>> createState() => _MessageListViewState<M>();
}

class _MessageListViewState<M> extends State<MessageListView<M>>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin
    implements AnchoredScrollHost, MessageListViewport {
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
  final _RebuildFilter _upperFilter = _RebuildFilter();
  final _RebuildFilter _lowerFilter = _RebuildFilter();

  // Placement.
  int _serial = -1;
  int _epoch = 0;
  MessageKey? _split; // rows starting at or after this key are below
  bool _splitInclusive = true;
  ({PlacementResolver resolve, double? guess, bool bottom})? _initialPlacement;
  Map<String, String> _rowOfKey = const {};

  // Debug overlay (§16).
  final ValueNotifier<int> _debugTick = ValueNotifier(0);
  double _lastCorrection = 0;
  double? _debugAnchorY;

  // Keyboard and the floating day chip.
  final FocusNode _focus =
      FocusNode(debugLabel: 'steady_chat_list', skipTraversal: true);
  final ValueNotifier<bool> _scrolling = ValueNotifier(false);

  // Jumps and the flash on their target.
  _Jump? _jump;
  late final AnimationController _flash;
  CurvedAnimation? _flashCurve;
  Animation<double>? _flashAnimation;
  HighlightState? _flashState;

  // Anchors captured at the last accepted layout: (row id, scroll offset).
  List<(String, double)> _anchors = const [];
  _Frame? _frame;
  bool _reportScheduled = false;

  MessageListController<M> get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // Created here, not lazily: a ticker must not be created in dispose.
    _flash = AnimationController(vsync: this);
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
    _finishJump(_jump, arrived: false);
    _flashCurve?.dispose();
    _flash.dispose();
    _focus.dispose();
    _scrolling.dispose();
    _debugTick.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _listen(MessageListController<M> controller) {
    controller.window.addListener(_windowChanged);
    controller.phase.addListener(_rebuild);
    controller.lastReadOutbox.addListener(_windowChanged);
    controller.highlightQuery.addListener(_windowChanged);
    controller.highlighted.addListener(_highlightChanged);
    controller.selection.addListener(_windowChanged);
    controller.attachViewport(this);
  }

  void _unlisten(MessageListController<M> controller) {
    controller.window.removeListener(_windowChanged);
    controller.phase.removeListener(_rebuild);
    controller.lastReadOutbox.removeListener(_windowChanged);
    controller.highlightQuery.removeListener(_windowChanged);
    controller.highlighted.removeListener(_highlightChanged);
    controller.selection.removeListener(_windowChanged);
    controller.detachViewport(this);
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
      final ({PlacementResolver resolve, double? guess, bool bottom}) place;
      switch (placement) {
        case PlaceAnchor(:final key, :final offset):
          _split = key;
          _splitInclusive = true;
          place = (
            resolve: (min, max, viewport) => (-offset).clamp(min, max),
            guess: -offset,
            bottom: false,
          );
        case PlaceUnread(:final key, :final topInset):
          _split = key;
          _splitInclusive = true;
          place = (
            resolve: (min, max, viewport) => (-topInset).clamp(min, max),
            guess: -topInset,
            bottom: false,
          );
        case PlaceBottom(:final scroll):
          // Everything is above the center; what arrives later goes below.
          _split = window.keys.last;
          _splitInclusive = false;
          final lead = scroll == null ? 0.0 : scroll.maxAnimatedDistance;
          place = (
            // A jump to the bottom starts up to one viewport above it.
            resolve: (min, max, viewport) =>
                (max - viewport * lead).clamp(min, max),
            guess: null,
            bottom: lead == 0,
          );
        case PlaceJump(
            :final key,
            :final alignment,
            :final fromNewer,
            :final scroll
          ):
          _split = key;
          _splitInclusive = true;
          place = (
            // Up to one viewport before the target, on the side the list
            // comes from; the jump animates the rest.
            resolve: (min, max, viewport) {
              final target =
                  _alignedOffset(key, alignment, viewport, 0).clamp(min, max);
              final lead = viewport * scroll.maxAnimatedDistance;
              return (fromNewer ? target + lead : target - lead)
                  .clamp(min, max);
            },
            guess: 0,
            bottom: false,
          );
      }
      if (_scroll.hasClients) {
        _scroll.anchored.placeWith(
          place.resolve,
          guess: place.guess,
          bottom: place.bottom,
        );
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
    final query = controller.highlightQuery.value;
    final flash = _flashState;
    final rowOfKey = <String, String>{};
    final selection = controller.selection;

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
      final flashed = flash != null && rowKeys.contains(flash.key);
      final removing = window.removing.isNotEmpty &&
          rowKeys.every((key) => window.removing.contains(key.id));
      final justAdded = window.justAdded.isNotEmpty &&
          rowKeys.any((key) => window.justAdded.contains(key.id));
      final row = _Row(
        id: rowKeys.length > 1 && group != null
            ? 'album:$group'
            : controller.stableIdOf(first),
        keys: rowKeys,
        day: firstInDay ? day : null,
        divider: rowKeys.contains(window.unreadDividerBefore),
        flash: flashed ? flash.serial : null,
        removing: removing,
        justAdded: justAdded,
        outgoing: adapter.isOutgoing(firstMessage),
        // The header leaves with the row when no other row of its day is
        // left to carry it.
        headerLeaves: removing &&
            firstInDay &&
            (after == null || grouping.dayOf(adapter, after) != day),
        info: MessageItemInfo(
          key: first,
          isFirstInGroup: before == null ||
              !grouping.sameGroup(adapter, before, firstMessage, gap),
          isLastInGroup: after == null ||
              !grouping.sameGroup(adapter, lastMessage, after, gap),
          isFirstInDay: firstInDay,
          isFirstUnread: rowKeys.contains(window.unreadDividerBefore),
          isJustAdded: justAdded,
          isLocal: first.isLocal,
          sendState: current,
          isRead: current == SendState.sent && outbox != null && last <= outbox,
          highlight: flashed ? _flashAnimation : null,
          highlightQuery: query,
          highlightReason: flashed ? flash.reason : null,
          isSelected: selection.count > 0 &&
              rowKeys.any((key) => selection.isSelected(key.id)),
          selectionActive: selection.active,
          indexInWindow: i,
        ),
      );
      rows.add(row);
      for (final key in rowKeys) {
        rowOfKey[key.id] = row.id;
      }
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
    _rowOfKey = rowOfKey;
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
      _RebuildFilter filter,
    ) =>
        SliverChildBuilderDelegate(
          (context, i) => filter.skips(i) ? null : _rowWidget(rows[i]),
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
          filter: _upperFilter,
          delegate: delegate(_upper, _upperIndex, _upperFilter),
        ),
        _SteadySliverList(
          key: centerKey,
          filter: _lowerFilter,
          delegate: delegate(_lower, _lowerIndex, _lowerFilter),
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
    Widget list = scrollView;
    if (!widget.scrollbar) {
      list = ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: list,
      );
    }
    final dayChip = widget.floatingDayBuilder;
    if (dayChip != null) {
      list = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollStartNotification) {
            _scrolling.value = true;
          } else if (notification is ScrollEndNotification) {
            _scrolling.value = false;
          }
          return false;
        },
        child: list,
      );
    }
    if (widget.keyboardShortcuts && _hasKeyboard) {
      list = Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _focus.requestFocus(),
          child: list,
        ),
      );
    }
    final button = widget.scrollDownButtonBuilder;
    final debug = kDebugMode && widget.debugOverlay;
    if (button == null && dayChip == null && !debug) return list;
    return Stack(
      children: [
        Positioned.fill(child: list),
        if (dayChip != null)
          Positioned(
            top: padding.top,
            left: 0,
            right: 0,
            child: _FloatingDay(
              day: controller.topVisibleDay,
              scrolling: _scrolling,
              builder: dayChip,
              onTap: _dayTapped,
            ),
          ),
        if (debug)
          Positioned.fill(
            child: IgnorePointer(
              child: ListenableBuilder(
                listenable: _debugTick,
                builder: (context, _) => _DebugOverlay(
                  text: '${controller.debugDescribe()}\n'
                      'last anchor correction: '
                      '${_lastCorrection.toStringAsFixed(2)} px',
                  anchorY: _debugAnchorY,
                ),
              ),
            ),
          ),
        if (button != null)
          PositionedDirectional(
            end: 12,
            bottom: 12 + padding.bottom,
            child: VisibleWhen<bool>(
              value: controller.showScrollDownButton,
              shown: (show) => show,
              builder: (context, _) => ValueListenableBuilder<int>(
                valueListenable: controller.unreadCount,
                builder: (context, unread, _) =>
                    button(context, unread, controller.jumpToBottom),
              ),
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------- keyboard

  static bool get _hasKeyboard =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  /// PageUp / PageDown, Home / End and the arrow keys (§11.6).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_scroll.hasClients) {
      return KeyEventResult.ignored;
    }
    final position = _scroll.anchored;
    void by(double delta, {bool animated = false}) {
      final target = (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (animated) {
        position.animateTo(
          target,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        );
      } else {
        position.jumpTo(target);
      }
    }

    final page = position.viewportDimension * 0.85;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      by(-40);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      by(40);
    } else if (key == LogicalKeyboardKey.pageUp) {
      by(-page, animated: true);
    } else if (key == LogicalKeyboardKey.pageDown) {
      by(page, animated: true);
    } else if (key == LogicalKeyboardKey.end) {
      _controller.jumpToBottom();
    } else if (key == LogicalKeyboardKey.home) {
      final keyboard = HardwareKeyboard.instance;
      if (keyboard.isControlPressed || keyboard.isMetaPressed) {
        // The very first message of the list.
        _controller.jumpToDate(DateTime(1970));
      } else {
        // The oldest loaded message.
        final keys = _controller.window.value.keys;
        if (keys.isNotEmpty) {
          _controller.jumpTo(
            keys.first,
            options: const JumpOptions(
              alignment: JumpAlignment.top(),
              highlight: JumpHighlight.none(),
            ),
          );
        }
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ----------------------------------------------------- AnchoredScrollHost

  ({PlacementResolver resolve, double? guess, bool bottom})?
      takeInitialPlacement() {
    final placement = _initialPlacement;
    _initialPlacement = null;
    return placement;
  }

  RenderViewport? get _viewport {
    final object = _viewportKey.currentContext?.findRenderObject();
    return object is RenderViewport ? object : null;
  }

  void _dayTapped(DateTime day) {
    widget.onDayTap?.call(day);
    _controller.notifyDayTap(day);
  }

  // ------------------------------------------------- highlight and jumps

  void _highlightChanged() {
    if (!mounted) return;
    final state = _controller.highlighted.value;
    if (state == null) {
      _flashState = null;
    } else if (state.serial != _flashState?.serial) {
      _flashState = state;
      _flashCurve?.dispose();
      _flash
        ..stop()
        ..value = 0
        ..duration = state.highlight.duration;
      final curve = _flashCurve =
          CurvedAnimation(parent: _flash, curve: state.highlight.curve);
      _flashAnimation = ReverseAnimation(curve); // 1 → 0
      final delay = state.highlight.delay;
      if (delay == Duration.zero) {
        _flash.forward();
      } else {
        Future<void>.delayed(delay, () {
          if (mounted && _flashState?.serial == state.serial) _flash.forward();
        });
      }
    }
    setState(_adoptWindow);
  }

  _RenderRow? _rowOf(MessageKey key) {
    final row = _registry[_rowOfKey[key.id] ?? key.id];
    return row != null && row.attached ? row : null;
  }

  /// The scroll offset that puts [key] at [alignment]. Before the row is
  /// laid out it counts as the first row below the center with no height.
  double _alignedOffset(
    MessageKey key,
    JumpAlignment alignment,
    double viewport,
    double current,
  ) {
    final row = _rowOf(key);
    final port = _viewport;
    final top = row == null || port == null ? null : _topOf(row, port);
    return alignment.resolve(
      itemOffset: top ?? 0,
      itemExtent: top == null ? 0 : row!.height,
      viewport: viewport,
      current: current,
    );
  }

  @override
  bool isBuilt(MessageKey key) {
    final row = _rowOf(key);
    final port = _viewport;
    return row != null && port != null && _topOf(row, port) != null;
  }

  @override
  Rect? rectOf(MessageKey key) {
    final row = _rowOf(key);
    if (row == null || !row.hasSize) return null;
    return row.localToGlobal(Offset.zero) & row.size;
  }

  @override
  Future<bool> scrollToItem(
    MessageKey key,
    JumpAlignment alignment,
    JumpScroll scroll,
  ) =>
      _beginJump(_Jump(key, alignment, scroll));

  @override
  Future<bool> scrollToBottom(JumpScroll scroll) =>
      _beginJump(_Jump(null, const JumpAlignment.bottom(), scroll));

  @override
  bool get isJumping => _jump != null;

  Future<bool> _beginJump(_Jump jump) {
    _finishJump(_jump, arrived: false);
    _jump = jump;
    if (_scroll.hasClients &&
        !_scroll.anchored.hasPendingPlacement &&
        (jump.key == null || isBuilt(jump.key!))) {
      _startJump(jump);
    } else {
      // The window with the target is laid out in the coming frame.
      SchedulerBinding.instance.scheduleFrame();
    }
    return jump.done.future;
  }

  double? _jumpTarget(_Jump jump, AnchoredScrollPosition position) {
    final key = jump.key;
    if (key == null) return position.maxScrollExtent;
    if (!isBuilt(key)) return null;
    return _alignedOffset(
      key,
      jump.alignment,
      position.viewportDimension,
      position.pixels,
    ).clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  void _startJump(_Jump jump) {
    if (!identical(_jump, jump) || !_scroll.hasClients) return;
    final position = _scroll.anchored;
    final target = _jumpTarget(jump, position);
    if (target == null) {
      _finishJump(jump, arrived: false);
      return;
    }
    final scroll = jump.scroll;
    final distance = (target - position.pixels).abs();
    if (scroll.isInstant || distance < 0.5) {
      if (distance >= 0.01) position.jumpTo(target);
      _finishJump(jump, arrived: true);
      return;
    }
    // Never animate through more than the allowed distance.
    final lead = scroll.maxAnimatedDistance * position.viewportDimension;
    if (distance > lead) {
      position.jumpTo(position.pixels > target ? target + lead : target - lead);
    }
    jump
      ..target = target
      ..clock.start();
    _animateJump(jump, scroll.duration);
  }

  void _animateJump(_Jump jump, Duration duration) {
    final position = _scroll.anchored;
    final run = ++jump.run;
    position
        .animateTo(jump.target!, duration: duration, curve: jump.scroll.curve)
        .then((_) {
      if (!identical(_jump, jump) || jump.run != run || !mounted) return;
      // Interrupted (a drag, another scroll) when it is not at the target.
      _finishJump(
        jump,
        arrived: (_scroll.anchored.pixels - jump.target!).abs() < 1,
      );
    });
  }

  /// After a layout: start a jump that waited for its window, or aim a
  /// running one at where its target is now (media loaded, rows changed).
  void _updateJump() {
    final jump = _jump;
    if (jump == null || !_scroll.hasClients) return;
    final position = _scroll.anchored;
    if (position.hasPendingPlacement) return;
    final current = jump.target;
    if (current == null) {
      _startJump(jump);
      return;
    }
    final target = _jumpTarget(jump, position);
    if (target == null || (target - current).abs() <= 0.5) return;
    jump.target = target;
    final left = jump.scroll.duration - jump.clock.elapsed;
    _animateJump(
      jump,
      left < const Duration(milliseconds: 80)
          ? const Duration(milliseconds: 80)
          : left,
    );
  }

  void _finishJump(_Jump? jump, {required bool arrived}) {
    if (jump == null) return;
    if (identical(_jump, jump)) _jump = null;
    if (!jump.done.isCompleted) jump.done.complete(arrived);
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
          isRemoving: row.row.removing,
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
      _lastCorrection = corrected;
      _controller.reportDiagnostic(AnchorCorrected(corrected));
    }
    if (kDebugMode && widget.debugOverlay) {
      _debugAnchorY = _anchors.isEmpty ? null : _anchors.first.$2 - pixels;
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
    if (kDebugMode && mounted && widget.debugOverlay) _debugTick.value++;
    if (mounted) _updateJump();
    final frame = _frame;
    final viewport = _viewport;
    if (!mounted || frame == null || viewport == null || !viewport.attached) {
      return;
    }
    final origin = viewport.localToGlobal(Offset.zero);
    final width = viewport.size.width;
    // How far the window reaches beyond the viewport, from the number of
    // its messages there and the average height of the visible ones.
    double? windowBefore;
    double? windowAfter;
    if (frame.rows.isNotEmpty) {
      final keys = _controller.window.value.keys;
      final (firstKeys, firstTop, _) = frame.rows.first;
      final (lastKeys, lastTop, lastHeight) = frame.rows.last;
      final first = keys.indexOf(firstKeys.first);
      final last = keys.indexOf(lastKeys.last);
      if (first >= 0 && last >= first) {
        var visibleHeight = 0.0;
        for (final (_, _, height) in frame.rows) {
          visibleHeight += height;
        }
        final average = visibleHeight / (last - first + 1);
        final hiddenAbove = firstTop < 0 ? -firstTop : 0.0;
        final below = lastTop + lastHeight - frame.height;
        windowBefore = first * average + hiddenAbove;
        windowAfter =
            (keys.length - 1 - last) * average + (below > 0 ? below : 0.0);
      }
    }
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
        windowExtentBefore: windowBefore,
        windowExtentAfter: windowAfter,
      ),
    );
  }
}

/// A jump the view is carrying out.
final class _Jump {
  _Jump(this.key, this.alignment, this.scroll);

  /// The target; null for the end of the content.
  final MessageKey? key;
  final JumpAlignment alignment;
  final JumpScroll scroll;
  final Completer<bool> done = Completer<bool>();

  /// Where the animation is heading; null until it started.
  double? target;
  final Stopwatch clock = Stopwatch();
  int run = 0;
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
    this.flash,
    this.removing = false,
    this.justAdded = false,
    this.outgoing = false,
    this.headerLeaves = false,
  });

  final String id;
  final List<MessageKey> keys;
  final MessageItemInfo info;
  final DateTime? day;
  final bool divider;

  /// Serial of the flash on this row, if it is the jump target.
  final int? flash;

  /// Every message of the row was deleted; it is animating out.
  final bool removing;

  /// The row plays the appear animation.
  final bool justAdded;

  /// The row's (first) message was sent by the user.
  final bool outgoing;

  /// The day header animates out with the row.
  final bool headerLeaves;

  @override
  bool operator ==(Object other) {
    if (other is! _Row ||
        other.id != id ||
        other.day != day ||
        other.divider != divider ||
        other.flash != flash ||
        other.removing != removing ||
        other.justAdded != justAdded ||
        other.headerLeaves != headerLeaves ||
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

class _RowWidgetState<M> extends State<_RowWidget<M>>
    with TickerProviderStateMixin {
  List<Listenable> _sources = const [];
  AnimationController? _appear;
  AnimationController? _remove;
  Animation<double> _removeContent = kAlwaysDismissedAnimation;
  Animation<double> _removeSize = kAlwaysCompleteAnimation;

  @override
  void initState() {
    super.initState();
    _subscribe();
    final config = widget.host._controller.config;
    if (widget.row.justAdded) {
      _appear =
          AnimationController(vsync: this, duration: config.appearDuration)
            ..forward();
    }
    _startRemoveIfNeeded();
  }

  @override
  void didUpdateWidget(_RowWidget<M> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _unsubscribe();
    _subscribe();
    _startRemoveIfNeeded();
  }

  @override
  void dispose() {
    _unsubscribe();
    _appear?.dispose();
    _remove?.dispose();
    super.dispose();
  }

  void _startRemoveIfNeeded() {
    if (!widget.row.removing || _remove != null) return;
    final config = widget.host._controller.config;
    final collapse = config.collapseRemovedRows;
    final remove = _remove = AnimationController(
      vsync: this,
      // With a collapsing row the second half closes the gap.
      duration: collapse ? config.removeDuration * 2 : config.removeDuration,
    )..forward();
    _removeContent = CurvedAnimation(
      parent: remove,
      curve: collapse
          ? const Interval(0, 0.5, curve: Curves.easeIn)
          : Curves.easeIn,
    );
    if (collapse) {
      _removeSize = ReverseAnimation(
        CurvedAnimation(parent: remove, curve: const Interval(0.5, 1)),
      );
    }
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
    final controller = host._controller;
    final collapse = controller.config.collapseRemovedRows;
    final messages = <M>[];
    for (final key in row.keys) {
      final message = controller.messageOf(key);
      if (message != null) messages.add(message);
    }
    // The delivery state can change without the window changing.
    var info = row.info;
    final state = controller.sendStateOf(row.keys.first);
    if (state != info.sendState) {
      info = info.withSendState(state,
          isLocal: state == SendState.sending || state == SendState.failed);
    }
    Widget child;
    if (messages.isEmpty) {
      child = const SizedBox.shrink();
    } else if (messages.length == 1) {
      child = view.itemBuilder(context, messages.first, info);
    } else if (view.groupBuilder != null) {
      child = view.groupBuilder!(context, messages, info);
    } else {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final message in messages)
            view.itemBuilder(context, message, info),
        ],
      );
    }

    // The same wrappers are always there (with constant animations when
    // nothing moves), so starting an animation never rebuilds the item.
    final removing = _removeContent;
    Widget animate(Widget content) {
      final appear = view.appearTransitionBuilder ?? _defaultAppear;
      final remove = view.removeTransitionBuilder ?? _defaultRemove;
      return remove(
        context,
        removing,
        appear(context, _appear ?? kAlwaysCompleteAnimation, content, info),
        info,
      );
    }

    final day = row.day;
    final header = day == null ? null : view.dayHeaderBuilder;
    if (!row.headerLeaves) child = animate(child);
    if (header != null || row.divider) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) header(context, day!, () => host._dayTapped(day)),
          if (row.divider)
            view.unreadDividerBuilder?.call(context) ?? const UnreadDivider(),
          child,
        ],
      );
    }
    if (row.headerLeaves) child = animate(child);
    if (collapse) {
      // The gap closes from the bottom; the row stays top-aligned.
      final size = _removeSize;
      child = AnimatedBuilder(
        animation: size,
        builder: (context, child) => ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: size.value,
            child: child,
          ),
        ),
        child: child,
      );
    }
    final padding = view.padding;
    if (padding.left != 0 || padding.right != 0) {
      child = Padding(
        padding: EdgeInsets.only(left: padding.left, right: padding.right),
        child: child,
      );
    }
    return _RowBoundary(
      row: row,
      registry: host._registry,
      // Screen readers go through the messages oldest to newest.
      child: Semantics(
        sortKey: OrdinalSortKey(row.keys.first.order.toDouble()),
        child: IgnorePointer(ignoring: row.removing, child: child),
      ),
    );
  }

  Widget _defaultAppear(
    BuildContext context,
    Animation<double> animation,
    Widget child,
    MessageItemInfo info,
  ) =>
      FadeTransition(opacity: animation, child: child);

  /// The default delete: fade to 0, shrink to 0.3 and slide toward the
  /// sender's side (mirrored in right-to-left layouts).
  Widget _defaultRemove(
    BuildContext context,
    Animation<double> animation,
    Widget child,
    MessageItemInfo info,
  ) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final toRight = widget.row.outgoing != rtl;
    return FadeTransition(
      opacity: ReverseAnimation(animation),
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = animation.value;
          return Transform(
            alignment: toRight ? Alignment.centerRight : Alignment.centerLeft,
            transform: Matrix4.diagonal3Values(1 - 0.7 * t, 1 - 0.7 * t, 1)
              ..setTranslationRaw((toRight ? 48.0 : -48.0) * t, 0, 0),
            child: child,
          );
        },
        child: child,
      ),
    );
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

/// The debug overlay: a line where the anchor's top is and the state text.
class _DebugOverlay extends StatelessWidget {
  const _DebugOverlay({required this.text, required this.anchorY});

  final String text;
  final double? anchorY;

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          if (anchorY != null)
            Positioned(
              top: anchorY,
              left: 0,
              right: 0,
              child: const ColoredBox(
                color: Color(0xFFFF3B30),
                child: SizedBox(height: 1),
              ),
            ),
          Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: DecoratedBox(
                decoration: const BoxDecoration(color: Color(0xCC000000)),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Color(0xFF7CFC00),
                      fontSize: 10,
                      height: 1.3,
                      fontFamily: 'monospace',
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
}

/// The day chip that floats at the top while the list scrolls.
class _FloatingDay extends StatefulWidget {
  const _FloatingDay({
    required this.day,
    required this.scrolling,
    required this.builder,
    required this.onTap,
  });

  final ValueListenable<DateTime?> day;
  final ValueListenable<bool> scrolling;
  final DayHeaderBuilder builder;
  final void Function(DateTime day) onTap;

  @override
  State<_FloatingDay> createState() => _FloatingDayState();
}

class _FloatingDayState extends State<_FloatingDay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _show;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _show = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    widget.scrolling.addListener(_scrollingChanged);
  }

  @override
  void dispose() {
    widget.scrolling.removeListener(_scrollingChanged);
    _hide?.cancel();
    _show.dispose();
    super.dispose();
  }

  void _scrollingChanged() {
    _hide?.cancel();
    if (widget.scrolling.value) {
      _show.forward();
    } else {
      // It stays for a second after the list stopped.
      _hide = Timer(const Duration(seconds: 1), _show.reverse);
    }
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _show,
        child: ValueListenableBuilder<DateTime?>(
          valueListenable: widget.day,
          builder: (context, day, _) => day == null
              ? const SizedBox.shrink()
              : widget.builder(context, day, () => widget.onTap(day)),
        ),
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
      position.placeWith(
        placement.resolve,
        guess: placement.guess,
        bottom: placement.bottom,
      );
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
  const _SteadySliverList({
    super.key,
    required super.delegate,
    required this.filter,
  });

  /// Shared with the delegate's builder; see [_SteadySliverElement].
  final _RebuildFilter filter;

  @override
  SliverMultiBoxAdaptorElement createElement() =>
      _SteadySliverElement(this, replaceMovedChildren: true);
}

/// Lets the sliver's element tell the delegate which indices it may build
/// during a rebuild.
class _RebuildFilter {
  int? _last;

  /// Whether [index] lies beyond the rows that exist. Such a row is left
  /// to layout, which builds it only if the viewport reaches it. A missing
  /// row before or between existing ones is built at once: layout would
  /// not look for it.
  bool skips(int index) {
    final last = _last;
    return last != null && index > last;
  }
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
    // When the window shifts, the rows that stay move to other indices, and
    // the framework would at once build a new row at every index they left:
    // dozens of rows far from the viewport, built in one frame and dropped
    // by the next layout. Nothing is built here beyond the last row that
    // exists; layout builds what the viewport really needs there.
    final sliver = widget as _SteadySliverList;
    int? last;
    visitChildren((child) {
      final key = child.widget.key;
      final index = key == null
          ? child.slot as int?
          : sliver.delegate.findIndexByKey(key);
      if (index != null && (last == null || index > last!)) last = index;
    });
    sliver.filter._last = last;
    try {
      super.performRebuild();
    } finally {
      sliver.filter._last = null;
    }
    // A row that was skipped changed nothing in the render tree; layout
    // has to run to look for it.
    list.markNeedsLayout();
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
