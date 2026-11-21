import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

import 'controller.dart';

/// What a search is doing.
///
/// ```dart
/// if (search.status.value == SearchStatus.empty) const Text('No results');
/// ```
enum SearchStatus {
  /// No query.
  idle,

  /// Waiting for results.
  searching,

  /// Results are loaded.
  ready,

  /// The query has no results.
  empty,

  /// The search failed.
  error,
}

/// Steps through search results in a list: "3 of 1,248" with up and down
/// arrows (§10.5). Created by `MessageListController.search`.
///
/// Results are ordered newest first; [next] goes to an older result and
/// loads more result pages when needed. Each step is a jump with
/// `JumpReason.search`, so the target is centered, flashed, and the query
/// reaches the items as `MessageItemInfo.highlightQuery`.
///
/// ```dart
/// final search = controller.search(MySearchSource(api));
/// await search.setQuery('invoice');
/// await search.next();                       // the newest hit
/// Text('${search.index! + 1} of ${search.total ?? search.loaded}');
/// search.close();                            // leaves the list where it is
/// ```
class MessageSearchNavigator<M> extends ChangeNotifier {
  /// Creates a navigator. Use `MessageListController.search` instead.
  MessageSearchNavigator({
    required MessageListController<M> controller,
    required MessageSearchSource source,
    void Function(MessageSearchNavigator<M> navigator)? onDispose,
    this.pageSize = 50,
  })  : _controller = controller,
        _source = source,
        _onDispose = onDispose;

  final MessageListController<M> _controller;
  final MessageSearchSource _source;
  final void Function(MessageSearchNavigator<M> navigator)? _onDispose;

  /// Results per request.
  final int pageSize;

  final ValueNotifier<SearchStatus> _status = ValueNotifier(SearchStatus.idle);
  List<MessageKey> _results = const [];
  String _query = '';
  String? _cursor;
  int? _total;
  int? _index;
  int _serial = 0;
  Timer? _debounce;
  Completer<void>? _pending;
  Future<void>? _more;
  Object? _error;
  bool _disposed = false;

  /// Idle, searching, ready, empty or error.
  ValueListenable<SearchStatus> get status => _status;

  /// The current query (trimmed).
  String get query => _query;

  /// Total number of results, when the server knows it.
  int? get total => _total;

  /// Number of results loaded so far.
  int get loaded => _results.length;

  /// Position of the current result, 0 = newest; null before the first
  /// step.
  int? get index => _index;

  /// The current result.
  MessageKey? get current {
    final i = _index;
    return i == null || i >= _results.length ? null : _results[i];
  }

  /// The loaded results, newest first (for a results list).
  List<MessageKey> get results => List<MessageKey>.unmodifiable(_results);

  /// Why the last search failed.
  Object? get error => _error;

  /// Whether there is an older result to go to.
  bool get hasNext {
    final i = _index;
    return _results.isNotEmpty &&
        (i == null || i < _results.length - 1 || _cursor != null);
  }

  /// Whether there is a newer result to go to.
  bool get hasPrevious => (_index ?? 0) > 0;

  /// Searches for [query] after a short pause in typing (300 ms by
  /// default). A newer query cancels this one. The future completes when
  /// the results of this query arrived (or it was replaced).
  ///
  /// ```dart
  /// onChanged: search.setQuery,
  /// ```
  Future<void> setQuery(String query) {
    if (_disposed) return Future.value();
    final text = query.trim();
    final serial = ++_serial;
    _debounce?.cancel();
    _finishPending();
    _query = text;
    _results = const [];
    _cursor = null;
    _total = null;
    _index = null;
    _error = null;
    _more = null;
    if (text.isEmpty) {
      _status.value = SearchStatus.idle;
      _controller.clearHighlightQuery();
      notifyListeners();
      return Future.value();
    }
    _status.value = SearchStatus.searching;
    notifyListeners();
    final pending = _pending = Completer<void>();
    _debounce = Timer(
      _controller.config.searchDebounce,
      () => unawaited(_run(serial)),
    );
    return pending.future;
  }

  void _finishPending() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<void> _run(int serial) async {
    try {
      final page =
          await _source.search(_controller.list, _query, limit: pageSize);
      if (_disposed || serial != _serial) return;
      _results = List<MessageKey>.of(page.keys);
      _cursor = page.nextCursor;
      _total = page.totalCount;
      _status.value =
          _results.isEmpty ? SearchStatus.empty : SearchStatus.ready;
    } catch (error) {
      if (_disposed || serial != _serial) return;
      _error = error;
      _status.value = SearchStatus.error;
    }
    notifyListeners();
    _finishPending();
  }

  /// Loads the next page of results (single flight).
  Future<void> _loadMore() {
    final cursor = _cursor;
    if (cursor == null) return Future.value();
    final running = _more;
    if (running != null) return running;
    final serial = _serial;
    final future = () async {
      try {
        final page = await _source.search(
          _controller.list,
          _query,
          cursor: cursor,
          limit: pageSize,
        );
        if (_disposed || serial != _serial) return;
        _results = [..._results, ...page.keys];
        _cursor = page.nextCursor;
        _total = page.totalCount ?? _total;
        notifyListeners();
      } catch (error) {
        if (_disposed || serial != _serial) return;
        _error = error; // the loaded results stay usable
        notifyListeners();
      } finally {
        if (serial == _serial) _more = null;
      }
    }();
    return _more = future;
  }

  /// Goes to the next older result (the newest one on the first call).
  ///
  /// ```dart
  /// IconButton(icon: const Icon(Icons.keyboard_arrow_up),
  ///     onPressed: search.hasNext ? search.next : null);
  /// ```
  Future<JumpResult> next() => goTo((_index ?? -1) + 1);

  /// Goes to the next newer result.
  Future<JumpResult> previous() => goTo((_index ?? 0) - 1);

  /// Goes to result number [index] (0 = newest). Fast repeated calls are
  /// fine: only the last jump arrives, the earlier ones are cancelled.
  ///
  /// ```dart
  /// onTap: () => search.goTo(row), // from a results list
  /// ```
  Future<JumpResult> goTo(int index) async {
    JumpResult none(String why) => JumpResult(
          outcome: JumpOutcome.failed,
          took: Duration.zero,
          error: StateError(why),
        );
    if (_disposed || index < 0) return none('No such search result');
    final serial = _serial;
    if (index >= _results.length) {
      await _loadMore();
      if (_disposed || serial != _serial) return none('The query changed');
      if (index >= _results.length) return none('No such search result');
    }
    _index = index;
    notifyListeners();
    if (index >= _results.length - 5 && _cursor != null) {
      unawaited(_loadMore());
    }
    final result = await _controller.jumpTo(
      _results[index],
      options: _controller.config.jump.copyWith(
        reason: JumpReason.search,
        highlightQuery: _query,
      ),
    );
    if (result.succeeded && !_disposed && serial == _serial) {
      // Warm the neighbours, so the next press is instant.
      for (final neighbour in [index + 1, index - 1]) {
        if (neighbour >= 0 && neighbour < _results.length) {
          unawaited(_controller.prefetchAround(_results[neighbour]));
        }
      }
    }
    return result;
  }

  /// Ends the search: clears the results and the highlighted term. The
  /// list stays where it is.
  void close() {
    if (_disposed) return;
    unawaited(setQuery(''));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _serial++;
    _debounce?.cancel();
    _finishPending();
    _status.dispose();
    _onDispose?.call(this);
    super.dispose();
  }
}
