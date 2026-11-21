import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

import 'config.dart';
import 'events.dart';
import 'viewport.dart';

/// Runs [callback] once, at the start of the next frame.
///
/// ```dart
/// MessageListController(hub: hub, list: list,
///     scheduler: (callback) => scheduleMicrotask(callback)); // headless
/// ```
typedef FrameScheduler = void Function(VoidCallback callback);

void _nextFrame(VoidCallback callback) {
  SchedulerBinding.instance.scheduleFrameCallback((_) => callback());
}

/// Drives one message list: decides where it opens, which messages are
/// built (the window), pages in both directions, tracks the bottom and what
/// was read, and saves the position.
///
/// A controller is a cheap view on a [MessageListHub]; several controllers
/// can show the same list.
///
/// ```dart
/// final controller = MessageListController<ChatMessage>(
///   hub: hub,
///   list: ListId(chat.id),
///   callbacks: MessageListCallbacks(
///     onReadUpTo: (list, key) => api.markRead(list.chatId, key.id),
///   ),
/// )..open();
/// ```
class MessageListController<M> extends ChangeNotifier {
  /// Creates a controller for [list]. Call [open] to load it.
  ///
  /// [scheduler] replaces the frame callback used to batch store changes
  /// (one window update per frame); pass one to run without a Flutter
  /// binding.
  MessageListController({
    required this.hub,
    required ListId list,
    this.config = const MessageListConfig(),
    this.callbacks = const MessageListCallbacks(),
    this.policies = const MessageListPolicies(),
    FrameScheduler? scheduler,
  })  : _list = list,
        _schedule = scheduler ?? _nextFrame,
        _windowPolicy = policies.window ??
            WindowPolicy(
              pageSize: config.pageSize,
              firstOpenPageSize: config.firstOpenPageSize,
              windowSize: config.windowSize,
              preloadExtent: config.preloadExtent,
            ),
        _window = ValueNotifier(MessageWindow(list: list, keys: const []));

  /// The shared data owner.
  final MessageListHub<M> hub;

  /// Tunable numbers.
  final MessageListConfig config;

  /// App hooks.
  final MessageListCallbacks<M> callbacks;

  /// Replaceable decisions.
  final MessageListPolicies<M> policies;

  final FrameScheduler _schedule;
  final WindowPolicy _windowPolicy;

  ListId _list;
  ListStore<M>? _store; // attached store of [_list]
  ListStore<M>? _shownStore; // store the published window belongs to
  bool _disposed = false;
  int _generation = 0;
  CancellationToken _token = CancellationToken();

  // Window.
  List<MessageKey> _keys = const [];
  MessageKey? _dividerKey;
  WindowPlacement? _placement;
  int _placementSerial = 0;
  bool _endsAtNewest = false;
  ViewportMetrics? _metrics;
  final ValueNotifier<MessageWindow> _window;

  // Store changes, batched per frame.
  List<StoreDelta> _pending = [];
  bool _flushScheduled = false;
  MessageKey? _liveLastSeen;

  // Edges.
  final Map<ListEdge, bool> _edgeBusy = {};
  final Map<ListEdge, Object> _edgeError = {};

  // Reading.
  final Map<String, Timer> _dwell = {};
  MessageKey? _highestRead;
  MessageKey? _sentRead;
  MessageKey? _announcedRead;
  Timer? _readTimer;
  bool _readInFlight = false;
  int _readAttempt = 0;
  final List<MessageKey> _arrived = []; // unread, newer than the server count
  bool _foreground = true;

  // Persistence.
  Timer? _persistTimer;

  // Events.
  final StreamController<MessageListEvent> _events =
      StreamController<MessageListEvent>.broadcast();
  final List<MessageListEvent> _queue = [];
  bool _dispatchScheduled = false;

  final ValueNotifier<ListPhase> _phase = ValueNotifier(ListPhase.loading);
  final ValueNotifier<bool> _isAtBottom = ValueNotifier(false);
  final ValueNotifier<bool> _showScrollDown = ValueNotifier(false);
  final ValueNotifier<int> _unreadCount = ValueNotifier(0);
  final ValueNotifier<MessageKey?> _highestVisible = ValueNotifier(null);
  final ValueNotifier<EdgeState> _olderEdge = ValueNotifier(const EdgeIdle());
  final ValueNotifier<EdgeState> _newerEdge = ValueNotifier(const EdgeIdle());

  // ------------------------------------------------------ observable state

  /// The list this controller shows.
  ListId get list => _list;

  /// Open/jump counter. Async results of older generations are dropped.
  int get generation => _generation;

  /// The messages the view must build and where to put them.
  ValueListenable<MessageWindow> get window => _window;

  /// Loading, ready, empty or error.
  ValueListenable<ListPhase> get phase => _phase;

  /// Whether the newest message is at the bottom of the viewport.
  ValueListenable<bool> get isAtBottom => _isAtBottom;

  /// Whether a scroll-to-bottom button should be visible.
  ValueListenable<bool> get showScrollDownButton => _showScrollDown;

  /// Unread incoming messages: the server count, plus messages that arrived
  /// since, minus what was read here but isn't confirmed yet.
  ValueListenable<int> get unreadCount => _unreadCount;

  /// The newest message the user has read in this visit. Only increases.
  ValueListenable<MessageKey?> get highestVisibleKey => _highestVisible;

  /// Loading state of the older (top) end of the window.
  ValueListenable<EdgeState> get olderEdge => _olderEdge;

  /// Loading state of the newer (bottom) end of the window.
  ValueListenable<EdgeState> get newerEdge => _newerEdge;

  /// Everything this controller reports (§13.2). Broadcast.
  Stream<MessageListEvent> get events => _events.stream;

  /// The message with the id of [key] in the list that is on screen.
  ///
  /// ```dart
  /// final message = controller.messageOf(window.keys.first);
  /// ```
  M? messageOf(MessageKey key) => _shownStore?.messageOf(key.id);

  // ------------------------------------------------------------- lifecycle

  /// Loads the list and decides where it opens (§10.1): the position saved
  /// in this session → the persisted position → the first unread → the
  /// bottom. Everything that is in memory is resolved synchronously, so the
  /// first frame is already correct.
  ///
  /// The future completes when the first window is shown. An open that was
  /// superseded by a newer open or switch completes with
  /// [OpenResolution.bottom] without touching the list.
  ///
  /// ```dart
  /// final how = await controller.open();
  /// ```
  Future<OpenResolution> open({
    OpenTarget target = const OpenTarget.auto(),
  }) =>
      _open(target);

  /// Shows another list with this controller. The current list stays on
  /// screen until the new one has its first window, and its position is
  /// saved.
  ///
  /// ```dart
  /// await controller.switchTo(ListId(otherChat.id));
  /// ```
  Future<OpenResolution> switchTo(
    ListId list, {
    OpenTarget target = const OpenTarget.auto(),
  }) {
    if (_disposed) return Future.value(OpenResolution.bottom);
    if (list != _list) {
      _saveNow(SaveReason.chatSwitch);
      _detach();
      _list = list;
    }
    return _open(target);
  }

  /// Saves the current position now (session memory and persistence).
  ///
  /// ```dart
  /// await controller.saveSnapshot();
  /// ```
  Future<void> saveSnapshot({SaveReason reason = SaveReason.explicit}) async {
    _saveNow(reason);
  }

  /// Tells the controller whether the app is in the foreground. Nothing is
  /// marked as read in the background. The built-in view calls this.
  void setForeground({required bool foreground}) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    final metrics = _metrics;
    if (foreground && metrics != null) _trackRead(metrics);
  }

  /// Retries a failed page at [edge].
  ///
  /// ```dart
  /// onTap: () => controller.retry(ListEdge.older),
  /// ```
  Future<void> retry(ListEdge edge) async {
    if (_disposed || _edgeError.remove(edge) == null) return;
    _updateEdges();
    await _extend(edge);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _saveNow(SaveReason.dispose);
    _disposed = true;
    _token.cancel();
    _detach();
    _queue.clear();
    unawaited(_events.close());
    for (final notifier in <ChangeNotifier>[
      _window,
      _phase,
      _isAtBottom,
      _showScrollDown,
      _unreadCount,
      _highestVisible,
      _olderEdge,
      _newerEdge,
    ]) {
      notifier.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------- imperative API (§13.5)

  /// Applies a backend event, as if it came from `MessageSource.events`.
  ///
  /// ```dart
  /// controller.apply(MessagesDeleted<ChatMessage>(controller.list, ['41']));
  /// ```
  void apply(ListEvent<M> event) => hub.apply(event);

  /// Adds or updates messages.
  ///
  /// ```dart
  /// controller.upsert([message]);
  /// ```
  void upsert(List<M> messages) => hub.apply(MessagesAdded<M>(_list, messages));

  /// Changes one message in place. Does nothing when [id] isn't loaded.
  ///
  /// ```dart
  /// controller.patch('41', (m) => m.copyWith(liked: true));
  /// ```
  void patch(String id, M Function(M current) update) {
    final store = _store;
    final key = store?.keyOf(id);
    if (store == null || key == null) return;
    final current = store.messageOf(id) as M;
    hub.apply(MessagesUpdated<M>(_list, [update(current)]));
  }

  /// Deletes messages by id.
  ///
  /// ```dart
  /// controller.remove(['41', '42']);
  /// ```
  void remove(List<String> ids) => hub.apply(MessagesDeleted<M>(_list, ids));

  /// Replaces the read markers and unread counters.
  ///
  /// ```dart
  /// controller.setReadState(ReadState(lastReadInbox: key, unreadCount: 3));
  /// ```
  void setReadState(ReadState state) =>
      hub.apply(ReadStateChanged<M>(_list, state));

  // ------------------------------------------------------------- viewport

  /// Reports what is on screen. The built-in view calls this after every
  /// layout and scroll; tests and custom views can call it too.
  ///
  /// Must not be called during build or layout (call it after the frame).
  void reportViewport(ViewportMetrics metrics) {
    if (_disposed || _keys.isEmpty) return;
    _metrics = metrics;
    _updateBottomState();
    _trackRead(metrics);
    _persistTimer?.cancel();
    _persistTimer = Timer(
      config.persistDebounce,
      () => _saveNow(SaveReason.scrollIdle),
    );
    _maybePage();
  }

  // ----------------------------------------------------------------- open

  bool _stale(int generation) => _disposed || generation != _generation;

  int _newGeneration() {
    _token.cancel();
    _token = CancellationToken();
    _edgeBusy.clear();
    _edgeError.clear();
    return ++_generation;
  }

  void _attach() {
    if (_store != null) return;
    final store = hub.attach(_list);
    _store = store;
    store.addListener(_onDelta);
    // A new visit: reading starts over.
    _highestRead = null;
    _sentRead = null;
    _announcedRead = null;
    _arrived.clear();
    _highestVisible.value = null;
  }

  void _detach() {
    final store = _store;
    if (store == null) return;
    store.removeListener(_onDelta);
    hub.detach(_list, owner: this);
    _store = null;
    _pending = [];
    _persistTimer?.cancel();
    _readTimer?.cancel();
    _readTimer = null;
    for (final timer in _dwell.values) {
      timer.cancel();
    }
    _dwell.clear();
  }

  Future<OpenResolution> _open(OpenTarget target) async {
    if (_disposed) return OpenResolution.bottom;
    final generation = _newGeneration();
    _attach();
    final store = _store!;
    final session = store.snapshot;
    ViewportSnapshot? persisted;
    if (target is OpenAuto && session == null) {
      final loading = _loadPersisted();
      if (loading is Future<ViewportSnapshot?>) {
        _showLoadingIfBlank();
        persisted = await loading;
        if (_stale(generation)) return OpenResolution.bottom;
      } else {
        persisted = loading;
      }
    }
    return _carryOut(generation, target, session, persisted);
  }

  FutureOr<ViewportSnapshot?> _loadPersisted() {
    ViewportSnapshot? failed(Object error, StackTrace stackTrace) {
      _diagnose(CallbackError('loadSnapshot', error, stackTrace));
      return null;
    }

    try {
      final load = callbacks.loadSnapshot;
      final result =
          load != null ? load(_list) : hub.viewportStore?.load(_list);
      if (result is Future<ViewportSnapshot?>) {
        return result
            .timeout(config.snapshotLoadBudget, onTimeout: () => null)
            .then<ViewportSnapshot?>((value) => value, onError: failed);
      }
      return result;
    } catch (error, stackTrace) {
      return failed(error, stackTrace);
    }
  }

  /// Runs the open plan. Synchronous until the first fetch is needed.
  Future<OpenResolution> _carryOut(
    int generation,
    OpenTarget target,
    ViewportSnapshot? session,
    ViewportSnapshot? persisted,
  ) async {
    final store = _store!;
    var plan = policies.open.decide(
      OpenContext(
        target: target,
        readState: store.readState,
        sessionSnapshot: session,
        persistedSnapshot: persisted,
        restoreIslandsAfterRestart: config.restoreIslandsAfterRestart,
      ),
    );
    OpenPlan withoutSnapshots() => policies.open.decide(
          OpenContext(target: target, readState: store.readState),
        );
    final half = _windowPolicy.windowSize ~/ 2;
    List<MessageKey> around(MessageKey key) => store.keysAround(
          key,
          before: half,
          after: _windowPolicy.windowSize - half - 1,
        );

    var triedUnread = false;
    var fetchedLatest = false;
    for (var step = 0; step < 6; step++) {
      switch (plan) {
        case OpenPlanRestore(:final snapshot, :final resolution):
          var anchor = _restorable(store, snapshot);
          if (anchor == null && resolution == OpenResolution.snapshot) {
            // Not in memory (no cache, or evicted): load around the anchor.
            _showLoadingIfBlank();
            await _fetchQuietly(
              generation,
              PageDirection.around,
              snapshot.anchorKey,
              _windowPolicy.pageSize,
            );
            if (_stale(generation)) return resolution;
            anchor = _restorable(store, snapshot);
          }
          if (anchor == null) {
            plan = withoutSnapshots();
            continue;
          }
          final exact = anchor.id == snapshot.anchorKey.id;
          _dividerKey = null;
          _show(
            store,
            around(anchor),
            PlaceAnchor(anchor, exact ? snapshot.anchorOffset : 0),
          );
          _opened(resolution);
          unawaited(_refresh(generation, latest: false));
          return resolution;

        case OpenPlanUnread():
          triedUnread = true;
          var divider = _trustedDivider(store);
          final read = store.readState.lastReadInbox;
          if (divider == null && read != null) {
            _showLoadingIfBlank();
            await _fetchQuietly(
              generation,
              PageDirection.around,
              read,
              _windowPolicy.pageSize,
            );
            if (_stale(generation)) return OpenResolution.firstUnread;
            divider = _trustedDivider(store);
          }
          if (divider == null) {
            plan = const OpenPlanBottom();
            continue;
          }
          _dividerKey = divider;
          _show(
            store,
            around(divider),
            PlaceUnread(divider, config.unreadDividerTopInset),
          );
          _opened(OpenResolution.firstUnread);
          unawaited(_refresh(generation, latest: false));
          return OpenResolution.firstUnread;

        case OpenPlanBottom():
          if (store.liveSegment == null && !store.isKnownEmpty) {
            _showLoadingIfBlank();
            final loaded = await _fetchQuietly(
              generation,
              PageDirection.latest,
              null,
              _windowPolicy.firstOpenPageSize,
            );
            if (_stale(generation)) return OpenResolution.bottom;
            if (!loaded) {
              if (!identical(_shownStore, store) || _keys.isEmpty) {
                _phase.value = ListPhase.error;
              }
              return OpenResolution.bottom;
            }
            fetchedLatest = true;
            // The first page may bring the read state with it.
            if (!triedUnread &&
                target is! OpenAtBottom &&
                store.readState.unreadCount > 0) {
              plan = const OpenPlanUnread();
              continue;
            }
          }
          _dividerKey = null;
          _showBottom(store);
          _opened(OpenResolution.bottom);
          if (!fetchedLatest) unawaited(_refresh(generation, latest: true));
          return OpenResolution.bottom;

        case OpenPlanMessage(:final key):
          MessageKey? locate() {
            final exact = store.keyOf(key.id);
            if (exact != null && store.segmentOf(exact) != null) return exact;
            if (store.segmentOf(key) == null) return null;
            return store.nearestExisting(key, ScanDirection.newer);
          }
          var at = locate();
          if (at == null) {
            _showLoadingIfBlank();
            await _fetchQuietly(
              generation,
              PageDirection.around,
              key,
              _windowPolicy.pageSize,
            );
            if (_stale(generation)) return OpenResolution.target;
            at = locate();
          }
          if (at == null) {
            plan = const OpenPlanBottom();
            continue;
          }
          _dividerKey = null;
          _show(store, around(at), PlaceAnchor(at, 0));
          _opened(OpenResolution.target);
          unawaited(_refresh(generation, latest: false));
          return OpenResolution.target;
      }
    }
    return OpenResolution.bottom;
  }

  /// The key a snapshot can be restored at: its anchor, else another key
  /// that was visible, else the nearest key when the anchor was deleted.
  MessageKey? _restorable(ListStore<M> store, ViewportSnapshot snapshot) {
    for (final key in [snapshot.anchorKey, ...snapshot.visibleKeys]) {
      final current = store.keyOf(key.id);
      if (current != null && store.segmentOf(current) != null) return current;
    }
    if (store.segmentOf(snapshot.anchorKey) == null) return null;
    return store.nearestExisting(snapshot.anchorKey, ScanDirection.newer);
  }

  /// The divider key, when the data around the read marker is loaded (so
  /// the first loaded unread message really is the first unread one).
  MessageKey? _trustedDivider(ListStore<M> store) {
    final policy = policies.unreadDivider ?? UnreadDividerPolicy<M>();
    final divider = policy.dividerBefore(store);
    if (divider == null) return null;
    final segment = store.segmentOf(divider);
    if (segment == null) return null;
    final read = store.readState.lastReadInbox;
    if (read == null) return segment.reachedOldest ? divider : null;
    return segment.contains(read) ? divider : null;
  }

  void _opened(OpenResolution resolution) {
    _liveLastSeen = _store?.liveSegment?.last;
    _recomputeUnread();
    _emit(ListOpened(_list, resolution));
  }

  /// Background refresh after an open: catches up with what was missed
  /// while the list was not subscribed. Never moves the viewport.
  Future<void> _refresh(int generation, {required bool latest}) async {
    final store = _store;
    if (store == null || _keys.isEmpty && !latest) return;
    final wasAtNewest = _endsAtNewest;
    if (latest) {
      await _fetchQuietly(
        generation,
        PageDirection.latest,
        null,
        _windowPolicy.firstOpenPageSize,
      );
    } else {
      final segment = store.segmentOf(_keys.last);
      if (segment == null) return;
      await _fetchQuietly(
        generation,
        PageDirection.newer,
        segment.last,
        _windowPolicy.pageSize,
      );
    }
    if (_stale(generation)) return;
    // More than a page was missed: the old data is an island now. A list
    // that was showing the newest messages moves to the real newest ones.
    final live = store.liveSegment;
    if (latest &&
        wasAtNewest &&
        live != null &&
        _keys.isNotEmpty &&
        !store.isContiguous(_keys.last, live.last)) {
      _showBottom(store);
    }
  }

  // --------------------------------------------------------------- window

  void _showLoadingIfBlank() {
    // Content of the previous list stays on screen while switching.
    if (_keys.isEmpty || _phase.value == ListPhase.error) {
      _phase.value = ListPhase.loading;
    }
  }

  void _showBottom(ListStore<M> store) {
    final live = store.liveSegment;
    _show(
      store,
      live == null
          ? const []
          : [
              ...store.keysBefore(live.last, _windowPolicy.windowSize - 1),
              live.last,
            ],
      const PlaceBottom(),
    );
  }

  void _show(
    ListStore<M> store,
    List<MessageKey> keys,
    WindowPlacement placement,
  ) {
    _shownStore = store;
    _keys = keys;
    _placement = placement;
    _placementSerial++;
    _metrics = null;
    _publish();
  }

  void _publish() {
    final store = _shownStore!;
    final keys = _keys;
    final live = store.liveSegment;
    _endsAtNewest =
        keys.isNotEmpty && live != null && keys.last.isSamePosition(live.last);
    final divider = _dividerKey;
    _window.value = MessageWindow(
      list: store.id,
      keys: List<MessageKey>.unmodifiable(keys),
      unreadDividerBefore:
          divider != null && keys.contains(divider) ? divider : null,
      placement: _placement,
      placementSerial: _placementSerial,
      generation: _generation,
    );
    if (keys.isNotEmpty) {
      _phase.value = ListPhase.ready;
    } else if (store.isKnownEmpty) {
      _phase.value = ListPhase.empty;
    }
    hub.protect(
      store.id,
      this,
      keys.isEmpty ? null : KeyRange(keys.first, keys.last),
    );
    _emit(
      WindowChanged(
        store.id,
        keys.isEmpty ? null : keys.first,
        keys.isEmpty ? null : keys.last,
        keys.length,
      ),
    );
    _updateEdges();
    _updateBottomState();
  }

  void _updateEdges() {
    EdgeState stateOf(ListEdge edge) {
      final store = _shownStore;
      if (store == null || _keys.isEmpty) return const EdgeIdle();
      if (_edgeBusy[edge] ?? false) return const EdgeLoading();
      final error = _edgeError[edge];
      if (error != null) return EdgeError(error);
      final older = edge == ListEdge.older;
      final key = older ? _keys.first : _keys.last;
      final segment = store.segmentOf(key);
      if (segment == null) return const EdgeIdle();
      final atEnd = older
          ? segment.reachedOldest && key.isSamePosition(segment.first)
          : segment.reachedNewest && key.isSamePosition(segment.last);
      return atEnd ? const EdgeEnd() : const EdgeIdle();
    }

    void set(ValueNotifier<EdgeState> notifier, EdgeState next) {
      final current = notifier.value;
      if (current.runtimeType == next.runtimeType &&
          (current is! EdgeError ||
              identical(current.error, (next as EdgeError).error))) {
        return;
      }
      notifier.value = next;
    }

    set(_olderEdge, stateOf(ListEdge.older));
    set(_newerEdge, stateOf(ListEdge.newer));
  }

  void _updateBottomState() {
    final metrics = _metrics;
    final bool atBottom;
    final bool showButton;
    if (_keys.isEmpty) {
      atBottom = false;
      showButton = false;
    } else if (metrics == null) {
      atBottom = _endsAtNewest && _placement is PlaceBottom;
      showButton = !_endsAtNewest;
    } else {
      atBottom = _endsAtNewest &&
          metrics.extentAfter <= config.stickToBottomThreshold &&
          (_isAtBottom.value ||
              policies.bottomStick
                  .shouldStick(userDragging: metrics.userDragging));
      showButton = !_endsAtNewest ||
          metrics.extentAfter >
              config.scrollDownButtonThreshold * metrics.viewport.height;
    }
    if (_isAtBottom.value != atBottom) {
      _isAtBottom.value = atBottom;
      _emit(AtBottomChanged(_shownStore!.id, atBottom: atBottom));
    }
    _showScrollDown.value = showButton;
  }

  // -------------------------------------------------------- store changes

  void _onDelta(StoreDelta delta) {
    if (_disposed) return;
    _pending.add(delta);
    if (_flushScheduled) return;
    _flushScheduled = true;
    _schedule(_flush);
  }

  /// One window update for everything that changed since the last frame.
  void _flush() {
    _flushScheduled = false;
    if (_disposed) return;
    final deltas = _pending;
    _pending = [];
    final store = _store;
    if (store == null || !identical(store, _shownStore) || deltas.isEmpty) {
      return; // still showing the previous list, or nothing shown yet
    }
    final previousNewest = _liveLastSeen;
    final replaced = <String, MessageKey>{};
    final incoming = <MessageKey>[];
    final local = <MessageKey>[];
    final paged = <MessageKey>[];
    final updated = <MessageKey>[];
    final deleted = <MessageKey>[];
    final cleared = <MessageKey>[];
    var readChanged = false;
    for (final delta in deltas) {
      for (final key in delta.inserted) {
        if (key.isLocal) {
          local.add(key);
        } else if (previousNewest != null && key > previousNewest) {
          incoming.add(key);
          final message = store.messageOf(key.id);
          if (message != null &&
              !hub.adapter.isOutgoing(message) &&
              !hub.adapter.isService(message)) {
            _arrived.add(key);
          }
        } else {
          paged.add(key);
        }
      }
      updated.addAll(delta.updated);
      (delta.historyCleared ? cleared : deleted).addAll(delta.removed);
      for (final replacement in delta.replaced) {
        replaced[replacement.oldKey.id] = replacement.newKey;
        _emit(KeyReplaced(_list, replacement.oldKey, replacement.newKey));
      }
      readChanged = readChanged || delta.readStateChanged;
    }
    // The server's counter is the truth again.
    if (readChanged) _arrived.clear();
    if (paged.isNotEmpty) {
      _emit(MessageInserted(_list, paged, InsertCause.page));
    }
    if (incoming.isNotEmpty) {
      _emit(MessageInserted(_list, incoming, InsertCause.incoming));
    }
    if (local.isNotEmpty) {
      _emit(MessageInserted(_list, local, InsertCause.local));
    }
    if (updated.isNotEmpty) _emit(MessageUpdated(_list, updated));
    if (deleted.isNotEmpty) {
      _emit(MessageRemoved(_list, deleted, RemoveCause.deleted));
    }
    if (cleared.isNotEmpty) {
      _emit(MessageRemoved(_list, cleared, RemoveCause.historyCleared));
    }
    _liveLastSeen = store.liveSegment?.last;
    _recomputeWindow(store, replaced);
    _recomputeUnread();
    _maybePage();
  }

  void _recomputeWindow(ListStore<M> store, Map<String, MessageKey> replaced) {
    if (_keys.isEmpty) {
      if (store.liveSegment != null) {
        _showBottom(store); // the first message of an empty list
      } else if (store.isKnownEmpty) {
        _phase.value = ListPhase.empty;
      }
      return;
    }
    MessageKey? locate(MessageKey key, ScanDirection inward) {
      final current = store.keyOf(key.id);
      if (current != null) return current;
      final successor = replaced[key.id];
      if (successor != null) return store.keyOf(successor.id);
      return store.nearestExisting(key, inward);
    }

    final first = locate(_keys.first, ScanDirection.newer);
    var last = locate(_keys.last, ScanDirection.older);
    if (first == null ||
        last == null ||
        first > last ||
        !store.isContiguous(first, last)) {
      // Everything that was built is gone.
      _dividerKey = null;
      if (store.liveSegment != null || store.isKnownEmpty) {
        _showBottom(store);
      } else {
        _keys = const [];
        _publish();
        unawaited(_open(const OpenTarget.bottom()));
      }
      return;
    }
    final size = _windowPolicy.windowSize;
    final atBottom = _isAtBottom.value;
    var keys = store.keysBetween(first, last).toList();
    final live = store.liveSegment;
    var followed = false;
    if (_endsAtNewest && live != null && live.last > last) {
      // The window ended at the newest message: follow the new ones.
      // Pinned to the bottom, always; scrolled up, only while there is room
      // (the view must not move, and the window must not grow past size).
      final room = atBottom ? size : size - keys.length;
      if (room > 0) {
        keys.addAll(store.keysAfter(last, room));
        last = keys.last;
        followed = true;
      }
      if (atBottom && !last.isSamePosition(live.last)) {
        keys = [...store.keysBefore(live.last, size - 1), live.last];
      }
    }
    if (keys.length > size) {
      final metrics = _metrics;
      final dropOldest = atBottom ||
          followed ||
          (metrics != null && metrics.extentBefore > metrics.extentAfter);
      keys =
          dropOldest ? keys.sublist(keys.length - size) : keys.sublist(0, size);
    }
    _moveDividerIfGone(store);
    if (_sameKeys(keys, _keys)) {
      _updateEdges();
      return;
    }
    _keys = keys;
    _publish();
  }

  void _moveDividerIfGone(ListStore<M> store) {
    final divider = _dividerKey;
    if (divider == null || store.contains(divider.id)) return;
    // The first unread message was deleted: the divider moves to the next
    // unread one (§10.7).
    var next = store.nearestExisting(divider, ScanDirection.newer);
    while (next != null) {
      final message = store.messageOf(next.id) as M;
      if (!next.isLocal &&
          !hub.adapter.isOutgoing(message) &&
          !hub.adapter.isService(message)) {
        break;
      }
      final after = store.keysAfter(next, 1);
      next = after.isEmpty ? null : after.first;
    }
    _dividerKey = next;
  }

  // --------------------------------------------------------------- paging

  void _maybePage() {
    final metrics = _metrics;
    if (_disposed || metrics == null || _keys.isEmpty) return;
    if (!identical(_store, _shownStore)) return;
    final before = metrics.extentBefore;
    final after = metrics.extentAfter;
    final average = (before + metrics.viewport.height + after) / _keys.length;
    final full =
        _keys.length + _windowPolicy.pageSize > _windowPolicy.windowSize;
    if (_windowPolicy.shouldExtend(
      distanceToEdge: before,
      distanceToOtherEdge: after,
      averageItemExtent: average,
      windowIsFull: full,
    )) {
      unawaited(_extend(ListEdge.older));
    } else if (_windowPolicy.shouldExtend(
      distanceToEdge: after,
      distanceToOtherEdge: before,
      averageItemExtent: average,
      windowIsFull: full,
    )) {
      unawaited(_extend(ListEdge.newer));
    }
  }

  /// Grows the window toward [edge]: from the store when it has more keys
  /// of the segment, else with one page from the source.
  Future<void> _extend(ListEdge edge) async {
    final store = _store;
    if (store == null || !identical(store, _shownStore) || _keys.isEmpty) {
      return;
    }
    final older = edge == ListEdge.older;
    if (_growFromStore(store, older: older)) return;
    final segment = store.segmentOf(older ? _keys.first : _keys.last);
    if (segment == null) return;
    if (older ? segment.reachedOldest : segment.reachedNewest) {
      _updateEdges();
      return;
    }
    if ((_edgeBusy[edge] ?? false) || _edgeError.containsKey(edge)) return;

    final generation = _generation;
    final anchor = older ? segment.first : segment.last;
    _edgeBusy[edge] = true;
    _updateEdges();
    Object? failure;
    try {
      await _fetch(
        generation,
        PageRequest(
          list: _list,
          direction: older ? PageDirection.older : PageDirection.newer,
          anchor: anchor,
          limit: _windowPolicy.pageSize,
          generation: generation,
          cancel: _token,
        ),
      );
    } on _Superseded {
      return;
    } catch (error) {
      failure = error;
    }
    if (_stale(generation)) return;
    _edgeBusy[edge] = false;
    if (failure == null) {
      final now = store.segmentOf(anchor);
      final progressed = now == null ||
          (older
              ? now.reachedOldest || now.first < anchor
              : now.reachedNewest || now.last > anchor);
      if (!progressed) {
        failure = StateError('The ${edge.name} page returned no usable keys');
      }
    }
    if (failure != null) {
      _edgeError[edge] = failure;
      _updateEdges();
      return;
    }
    if (!_growFromStore(store, older: older)) _updateEdges();
  }

  bool _growFromStore(ListStore<M> store, {required bool older}) {
    final page = _windowPolicy.pageSize;
    final size = _windowPolicy.windowSize;
    final more = older
        ? store.keysBefore(_keys.first, page)
        : store.keysAfter(_keys.last, page);
    if (more.isEmpty) return false;
    var keys = older ? [...more, ..._keys] : [..._keys, ...more];
    if (keys.length > size) {
      // Unmount from the far side, but never something that is on screen.
      final visible = _metrics?.items ?? const <VisibleItem>[];
      if (older) {
        var end = size;
        if (visible.isNotEmpty) {
          final index = keys.indexOf(visible.last.key) + 1;
          if (index > end) end = index;
        }
        keys = keys.sublist(0, end);
      } else {
        var start = keys.length - size;
        if (visible.isNotEmpty) {
          final index = keys.indexOf(visible.first.key);
          if (index >= 0 && index < start) start = index;
        }
        keys = keys.sublist(start);
      }
    }
    _keys = keys;
    _publish();
    hub.trim(store.id);
    return true;
  }

  /// One page with retries (§13.3 `RetryPolicy`). Throws [_Superseded] when
  /// the generation changed, else the last error.
  Future<PageOutcome<M>> _fetch(int generation, PageRequest request) async {
    for (var attempt = 0;; attempt++) {
      _emit(PageRequested(request.list, request));
      try {
        final outcome = await hub.fetch(request);
        if (_stale(generation) || !outcome.applied) throw const _Superseded();
        _emit(
          PageLoaded(
            request.list,
            request,
            outcome.result,
            outcome.origin,
            outcome.duration,
          ),
        );
        return outcome;
      } on _Superseded {
        rethrow;
      } catch (error, stackTrace) {
        if (_stale(generation)) throw const _Superseded();
        _emit(PageFailed(request.list, request, error, stackTrace));
        final delay = policies.retry.delayFor(attempt);
        if (delay == null) rethrow;
        await Future<void>.delayed(delay);
        if (_stale(generation)) throw const _Superseded();
      }
    }
  }

  /// A fetch whose failure is not shown at an edge. Returns whether a page
  /// was applied.
  Future<bool> _fetchQuietly(
    int generation,
    PageDirection direction,
    MessageKey? anchor,
    int limit,
  ) async {
    try {
      await _fetch(
        generation,
        PageRequest(
          list: _list,
          direction: direction,
          anchor: anchor,
          limit: limit,
          generation: generation,
          cancel: _token,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------- reading

  void _trackRead(ViewportMetrics metrics) {
    final store = _shownStore;
    if (store == null || !identical(store, _store)) return;
    final height = metrics.viewport.height;
    final eligible = <String>{};
    final immediate = <MessageKey>[];
    for (final item in metrics.items) {
      final key = item.key;
      final highest = _highestRead;
      if (key.isLocal || (highest != null && key <= highest)) continue;
      final message = store.messageOf(key.id);
      if (message == null || hub.adapter.isOutgoing(message)) continue;
      final coverage =
          height <= 0 ? 0.0 : item.rect.height * item.visibleFraction / height;
      if (!policies.read.isRead(
        visibleFraction: item.visibleFraction,
        viewportCoverage: coverage,
      )) {
        continue;
      }
      eligible.add(key.id);
      if (config.readDwell == Duration.zero) {
        immediate.add(key);
      } else {
        _dwell[key.id] ??= Timer(config.readDwell, () {
          _dwell.remove(key.id);
          final current = _store?.keyOf(key.id);
          if (current != null) _advanceRead(current);
        });
      }
    }
    _dwell.removeWhere((id, timer) {
      if (eligible.contains(id)) return false;
      timer.cancel();
      return true;
    });
    immediate.forEach(_advanceRead);
  }

  void _advanceRead(MessageKey key) {
    if (_disposed || !_foreground) return;
    final highest = _highestRead;
    if (highest != null && key <= highest) return;
    _highestRead = key;
    _highestVisible.value = key;
    _recomputeUnread();
    final confirmed = _store?.readState.lastReadInbox;
    if (confirmed != null && key <= confirmed) return;
    _readTimer ??= Timer(config.readDebounce, _sendRead);
  }

  Future<void> _sendRead() async {
    _readTimer = null;
    final key = _highestRead;
    final store = _store;
    if (_disposed || store == null || key == null || _readInFlight) return;
    final sent = _sentRead;
    if (sent != null && key <= sent) return;
    final list = _list;
    _readInFlight = true;
    try {
      // Announce a key once, even when the receipt is retried.
      final announced = _announcedRead;
      if (announced == null || key > announced) {
        _announcedRead = key;
        _emit(ReadUpTo(list, key));
      }
      await hub.markRead(list, key);
      _sentRead = key;
      _readAttempt = 0;
    } catch (_) {
      final delay = policies.retry.delayFor(_readAttempt++);
      if (delay == null) {
        _readAttempt = 0; // give up on this key until the user reads more
        _sentRead = key;
      } else if (!_disposed && identical(store, _store)) {
        _readTimer = Timer(delay, _sendRead);
      }
    } finally {
      _readInFlight = false;
    }
    if (_disposed || !identical(store, _store)) return;
    final highest = _highestRead;
    if (_readTimer == null && highest != null && highest > key) {
      _readTimer = Timer(config.readDebounce, _sendRead);
    }
  }

  void _recomputeUnread() {
    final store = _store;
    if (store == null) return;
    final state = store.readState;
    final confirmed = state.lastReadInbox;
    final highest = _highestRead;
    // Messages the server counted as unread and that were read here.
    var readHere = 0;
    bool counted(MessageKey key) {
      if (key.isLocal || _arrived.contains(key)) return false;
      final message = store.messageOf(key.id) as M;
      return !hub.adapter.isOutgoing(message) &&
          !hub.adapter.isService(message);
    }

    if (highest != null && state.unreadCount > 0) {
      if (confirmed != null) {
        if (highest > confirmed) {
          for (final key in store.keysBetween(confirmed, highest)) {
            if (key > confirmed && counted(key)) readHere++;
          }
        }
      } else {
        // No read marker: the unread ones are the newest incoming messages.
        final newest = store.newestKey;
        var remaining = state.unreadCount;
        final candidates = newest == null
            ? const <MessageKey>[]
            : [...store.keysBefore(newest, remaining * 2 + 20), newest];
        for (final key in candidates.reversed) {
          if (remaining == 0) break;
          if (!counted(key)) continue;
          remaining--;
          if (key <= highest) readHere++;
        }
      }
    }
    var count = state.unreadCount - readHere;
    if (count < 0) count = 0;
    // Plus what arrived since and wasn't read yet.
    for (final key in _arrived) {
      if (highest == null || key > highest) count++;
    }
    final next = count < 0 ? 0 : count;
    if (_unreadCount.value == next) return;
    _unreadCount.value = next;
    _emit(UnreadChanged(_list, next));
  }

  // ---------------------------------------------------------- persistence

  void _saveNow(SaveReason reason) {
    _persistTimer?.cancel();
    _persistTimer = null;
    final store = _shownStore;
    final metrics = _metrics;
    if (_disposed || store == null || metrics == null) return;
    if (metrics.items.isEmpty || !identical(store, _store)) return;
    final top = metrics.viewport.top;
    final anchor = policies.anchor.pick([
      for (final item in metrics.items)
        AnchorCandidate(
          key: item.key,
          top: item.rect.top - top,
          height: item.rect.height,
        ),
    ]);
    if (anchor == null) return;
    final snapshot = ViewportSnapshot(
      anchorKey: anchor.key,
      anchorOffset: anchor.top,
      offsetFromBottom: metrics.viewport.height + metrics.extentAfter,
      visibleKeys: [for (final item in metrics.items) item.key],
      connectedToNewest: store.segmentOf(anchor.key)?.reachedNewest ?? false,
      viewportWidth: metrics.viewport.width,
      savedAt: hub.now(),
    );
    store.snapshot = snapshot;
    final list = store.id;
    final save = callbacks.saveSnapshot;
    _guard('saveSnapshot', () {
      if (save != null) return save(list, snapshot, reason);
      return hub.viewportStore?.save(list, snapshot);
    });
    _emit(SnapshotSaved(list, snapshot, reason));
  }

  // --------------------------------------------------------------- events

  void _emit(MessageListEvent event) {
    if (_disposed) return;
    _queue.add(event);
    if (_dispatchScheduled) return;
    _dispatchScheduled = true;
    // Never during build or layout: a microtask runs after the frame.
    scheduleMicrotask(_dispatch);
  }

  void _dispatch() {
    _dispatchScheduled = false;
    if (_disposed) return;
    final events = List<MessageListEvent>.of(_queue);
    _queue.clear();
    for (final event in events) {
      if (_disposed) return;
      _events.add(event);
      _deliver(event);
    }
  }

  void _deliver(MessageListEvent event) {
    final c = callbacks;
    switch (event) {
      case ListOpened(:final list, :final resolution):
        final f = c.onOpened;
        if (f != null) _guard('onOpened', () => f(list, resolution));
      case PageRequested(:final list, :final request):
        final f = c.onPageRequested;
        if (f != null) _guard('onPageRequested', () => f(list, request));
      case PageLoaded(
          :final list,
          :final request,
          :final result,
          :final origin,
          :final duration
        ):
        final f = c.onPageLoaded;
        if (f != null) {
          _guard(
            'onPageLoaded',
            () => f(list, request, result as PageResult<M>, origin, duration),
          );
        }
      case PageFailed(
          :final list,
          :final request,
          :final error,
          :final stackTrace
        ):
        final f = c.onPageError;
        if (f != null) {
          _guard('onPageError', () => f(list, request, error, stackTrace));
        }
      case ReadUpTo(:final list, :final key):
        final f = c.onReadUpTo;
        if (f != null) _guard('onReadUpTo', () => f(list, key));
      case UnreadChanged(:final list, :final count):
        final f = c.onUnreadChanged;
        if (f != null) _guard('onUnreadChanged', () => f(list, count));
      case AtBottomChanged(:final list, :final atBottom):
        final f = c.onAtBottomChanged;
        if (f != null) _guard('onAtBottomChanged', () => f(list, atBottom));
      case DiagnosticReported(:final diagnostic):
        final f = c.onDiagnostic;
        if (f != null) {
          try {
            f(diagnostic);
          } catch (_) {
            // A failing diagnostics hook has nowhere left to report to.
          }
        }
      case WindowChanged() ||
            MessageInserted() ||
            MessageUpdated() ||
            MessageRemoved() ||
            KeyReplaced() ||
            SnapshotSaved():
        break; // stream only (saveSnapshot is called when saving)
    }
  }

  /// Runs an app callback; a throw or a failed future becomes a diagnostic.
  void _guard(String name, FutureOr<void> Function() call) {
    try {
      final result = call();
      if (result is Future<void>) {
        unawaited(
          result.then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) =>
                _diagnose(CallbackError(name, error, stackTrace)),
          ),
        );
      }
    } catch (error, stackTrace) {
      _diagnose(CallbackError(name, error, stackTrace));
    }
  }

  void _diagnose(MessageListDiagnostic diagnostic) =>
      _emit(DiagnosticReported(_list, diagnostic));
}

bool _sameKeys(List<MessageKey> a, List<MessageKey> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id || !a[i].isSamePosition(b[i])) return false;
  }
  return true;
}

/// A fetch whose controller moved on (new open, switch or dispose).
final class _Superseded implements Exception {
  const _Superseded();
}
