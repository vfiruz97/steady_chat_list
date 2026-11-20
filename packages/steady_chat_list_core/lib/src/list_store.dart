import 'dart:collection';

import 'list_event.dart';
import 'message_key.dart';
import 'models.dart';
import 'paging.dart';
import 'store_delta.dart';

/// Combines the stored version of a message with an incoming one.
///
/// ```dart
/// ChatMessage keepLocalDraft(ChatMessage current, ChatMessage incoming) =>
///     incoming.copyWith(draft: current.draft);
/// ```
typedef MessageMerge<M> = M Function(M current, M incoming);

/// Called after every store operation that changed something.
///
/// ```dart
/// store.addListener((delta) => print(delta));
/// ```
typedef StoreListener = void Function(StoreDelta delta);

/// A direction along the key order.
///
/// ```dart
/// final next = store.nearestExisting(deletedKey, ScanDirection.newer);
/// ```
enum ScanDirection {
  /// Toward smaller keys.
  older,

  /// Toward larger keys.
  newer,
}

/// The in-memory state of one list: messages sorted by key, the segments
/// proven contiguous by the server, read state, tombstones and pinned keys.
///
/// Every operation is idempotent and returns a [StoreDelta]; applying the
/// same page or event twice returns an empty delta. Lookups and single
/// updates are O(log n); range queries are O(log n + k).
///
/// ```dart
/// final store = ListStore<ChatMessage>(
///   id: const ListId('chat-1'),
///   adapter: const ChatMessageAdapter(),
/// );
/// store.applyPage(request, await source.fetch(request));
/// final newest = store.keysBefore(store.liveSegment!.last, 20);
/// ```
final class ListStore<M> {
  /// Creates an empty store for the list [id].
  ///
  /// [clock] is used for tombstone expiry (tests pass a fake one). [merge]
  /// combines the stored and the incoming version of a message; the default
  /// keeps the incoming one.
  ListStore({
    required this.id,
    required this.adapter,
    this.tombstoneTtl = const Duration(minutes: 5),
    DateTime Function()? clock,
    this.merge,
  }) : _clock = clock ?? DateTime.now;

  /// The list this store holds.
  final ListId id;

  /// Reads keys, dates and flags from the app's message class.
  final MessageAdapter<M> adapter;

  /// How long a deleted id keeps rejecting late pages and events.
  final Duration tombstoneTtl;

  /// Combines the stored and the incoming version of a message.
  final MessageMerge<M>? merge;

  /// Saved position from this session, restored on reopen. Its key range is
  /// protected from [evict].
  ViewportSnapshot? snapshot;

  final DateTime Function() _clock;
  final SplayTreeMap<MessageKey, M> _byKey = SplayTreeMap<MessageKey, M>();
  final Map<String, MessageKey> _keyById = <String, MessageKey>{};
  final SplayTreeMap<_Dated, bool> _byDate = SplayTreeMap<_Dated, bool>();
  final List<Segment> _segments = <Segment>[];
  final Map<String, DateTime> _tombstones = <String, DateTime>{};
  final Map<String, Object> _sendErrors = <String, Object>{};
  final List<StoreListener> _listeners = <StoreListener>[];
  ReadState _readState = ReadState.empty;
  List<MessageKey> _pinned = const <MessageKey>[];
  Set<String> _typing = const <String>{};
  MessageKey? _clearedUpTo;
  bool _knownEmpty = false;
  DateTime? _lastPurge;

  // ---------------------------------------------------------------- state

  /// Number of messages in memory.
  int get length => _byKey.length;

  /// Whether no message is in memory.
  bool get isEmpty => _byKey.isEmpty;

  /// Whether the server confirmed that the list has no messages.
  bool get isKnownEmpty => _knownEmpty;

  /// Segments, oldest first. They never overlap; only the last one can be
  /// live.
  List<Segment> get segments => UnmodifiableListView<Segment>(_segments);

  /// The segment holding the newest message of the list, if loaded.
  Segment? get liveSegment =>
      _segments.isNotEmpty && _segments.last.reachedNewest
          ? _segments.last
          : null;

  /// Current read markers and unread counters.
  ReadState get readState => _readState;

  /// Pinned keys, oldest first.
  List<MessageKey> get pinned => _pinned;

  /// Ids of the users typing right now.
  Set<String> get typingUserIds => _typing;

  /// Everything at or below this key was cleared; older data is rejected.
  MessageKey? get clearedUpTo => _clearedUpTo;

  /// The oldest key in memory.
  MessageKey? get oldestKey => _byKey.firstKey();

  /// The newest key in memory.
  MessageKey? get newestKey => _byKey.lastKey();

  /// All keys in memory, oldest first. Iterating is O(n).
  Iterable<MessageKey> get keys => _byKey.keys;

  /// Whether a message with [id] is in memory.
  bool contains(String id) => _keyById.containsKey(id);

  /// The current key of the message with [id].
  MessageKey? keyOf(String id) => _keyById[id];

  /// The message with [id], if in memory.
  M? messageOf(String id) {
    final key = _keyById[id];
    return key == null ? null : _byKey[key];
  }

  /// The message with the id of [key], if in memory.
  M? operator [](MessageKey key) => messageOf(key.id);

  /// The error of a local message whose send failed, else null.
  Object? sendErrorOf(String id) => _sendErrors[id];

  /// Whether [id] was deleted less than [tombstoneTtl] ago.
  bool isTombstoned(String id) {
    final at = _tombstones[id];
    if (at == null) return false;
    if (_clock().difference(at) > tombstoneTtl) {
      _tombstones.remove(id);
      return false;
    }
    return true;
  }

  /// Registers [listener]; it runs after every operation with a non-empty
  /// delta.
  void addListener(StoreListener listener) => _listeners.add(listener);

  /// Unregisters [listener].
  void removeListener(StoreListener listener) => _listeners.remove(listener);

  // ------------------------------------------------------------ mutations

  /// Stores a page and records the key range it proves contiguous (§7.1).
  ///
  /// ```dart
  /// final delta = store.applyPage(request, await source.fetch(request));
  /// ```
  StoreDelta applyPage(PageRequest request, PageResult<M> result) {
    assert(request.list == id, 'Page for ${request.list} applied to $id');
    return _mutate((d) {
      MessageKey? lo;
      MessageKey? hi;
      void widen(MessageKey key) {
        if (lo == null || key < lo!) lo = key;
        if (hi == null || key > hi!) hi = key;
      }

      for (final item in result.items) {
        widen(adapter.keyOf(item));
        _upsert(item, d, place: false);
      }
      final direction = request.direction;
      final anchor = request.anchor;
      if (anchor != null && direction != PageDirection.latest) widen(anchor);

      final oldest = switch (direction) {
        PageDirection.older =>
          result.reachedOldest || result.items.length < request.limit,
        PageDirection.newer => false,
        PageDirection.around || PageDirection.latest => result.reachedOldest,
      };
      final newest = switch (direction) {
        PageDirection.older => false,
        PageDirection.latest => true,
        PageDirection.newer || PageDirection.around => result.reachedNewest,
      };
      if (lo != null) {
        _prove(lo!, hi!, oldest: oldest, newest: newest, d: d);
      } else if (direction == PageDirection.latest &&
          _byKey.isEmpty &&
          !_knownEmpty) {
        _knownEmpty = true;
        d.segments = true;
      }
      final read = result.readState;
      if (read != null) _setReadState(read, d);
    });
  }

  /// Applies a backend or app event (§7.2).
  ///
  /// ```dart
  /// store.apply(MessagesDeleted<ChatMessage>(store.id, ['41']));
  /// ```
  StoreDelta apply(ListEvent<M> event) {
    assert(event.list == id, 'Event for ${event.list} applied to $id');
    return _mutate((d) {
      switch (event) {
        case MessagesAdded<M>(:final items):
          for (final item in items) {
            _upsert(item, d, place: true);
          }
        case MessagesUpdated<M>(:final items):
          for (final item in items) {
            final key = adapter.keyOf(item);
            if (_keyById.containsKey(key.id) || _segmentIndexOf(key) >= 0) {
              _upsert(item, d, place: false);
            }
          }
        case MessagesDeleted<M>(:final ids):
          for (final id in ids) {
            _delete(id, d);
          }
        case LocalAcked<M>(:final localId, :final serverMessage):
          _ack(localId, serverMessage, d);
        case LocalFailed<M>(:final localId, :final error):
          final key = _keyById[localId];
          if (key != null && _sendErrors[localId] != error) {
            _sendErrors[localId] = error;
            d.updated.add(key);
          }
        case ReadStateChanged<M>(:final state):
          _setReadState(state, d);
        case PinnedChanged<M>(:final keys):
          final sorted = [...keys]..sort();
          if (!_sameKeys(sorted, _pinned)) {
            _pinned = List<MessageKey>.unmodifiable(sorted);
            d.pinned = true;
          }
        case HistoryCleared<M>(:final upTo):
          _clearHistory(upTo, d);
        case TypingChanged<M>(:final userIds):
          if (userIds.length != _typing.length ||
              !userIds.containsAll(_typing)) {
            _typing = Set<String>.unmodifiable(userIds);
            d.typing = true;
          }
      }
    });
  }

  /// Clears the "send failed" state of a local message (before a retry).
  ///
  /// ```dart
  /// store.clearSendError('client-1');
  /// ```
  StoreDelta clearSendError(String id) => _mutate((d) {
        final key = _keyById[id];
        if (_sendErrors.remove(id) != null && key != null) d.updated.add(key);
      });

  /// The key for a new pending local message with client id [id]: it sorts
  /// right after the newest message (§10.6).
  ///
  /// ```dart
  /// final key = store.nextLocalKey('client-1');
  /// store.apply(MessagesAdded(store.id, [draft.copyWith(key: key)]));
  /// ```
  MessageKey nextLocalKey(String id) {
    final base = liveSegment?.last ?? _byKey.lastKey() ?? _clearedUpTo;
    return base == null
        ? MessageKey(order: 0, id: id, localSeq: 1)
        : MessageKey(order: base.order, id: id, localSeq: base.localSeq + 1);
  }

  /// Drops messages from memory until at most [limit] remain (§7.4).
  ///
  /// Keys inside [protect] and inside [snapshot]'s range are never dropped.
  /// Orphans go first, then islands without protected keys, then the far
  /// ends of the remaining segments. A trimmed side loses its
  /// `reachedOldest` / `reachedNewest` flag.
  ///
  /// ```dart
  /// store.evict(limit: 1000, protect: [KeyRange(windowFirst, windowLast)]);
  /// ```
  StoreDelta evict({
    required int limit,
    Iterable<KeyRange> protect = const <KeyRange>[],
  }) =>
      _mutate((d) => _evict(limit, protect, d));

  // -------------------------------------------------------------- queries

  /// The segment containing [key], or null for an orphan or unknown key.
  Segment? segmentOf(MessageKey key) {
    final i = _segmentIndexOf(_canonical(key));
    return i < 0 ? null : _segments[i];
  }

  /// Whether [a] and [b] are in the same segment, i.e. the server proved
  /// that no unknown message lies between them.
  bool isContiguous(MessageKey a, MessageKey b) {
    final i = _segmentIndexOf(_canonical(a));
    return i >= 0 && i == _segmentIndexOf(_canonical(b));
  }

  /// Up to [n] keys strictly older than [key] in its segment, oldest first.
  ///
  /// ```dart
  /// final page = store.keysBefore(windowFirst, 40);
  /// ```
  List<MessageKey> keysBefore(MessageKey key, int n) {
    final from = _canonical(key);
    final si = _segmentIndexOf(from);
    if (si < 0 || n <= 0) return const <MessageKey>[];
    final first = _segments[si].first;
    final out = <MessageKey>[];
    var k = _byKey.lastKeyBefore(from);
    while (k != null && out.length < n && k >= first) {
      out.add(k);
      k = _byKey.lastKeyBefore(k);
    }
    return out.reversed.toList();
  }

  /// Up to [n] keys strictly newer than [key] in its segment, oldest first.
  ///
  /// ```dart
  /// final page = store.keysAfter(windowLast, 40);
  /// ```
  List<MessageKey> keysAfter(MessageKey key, int n) {
    final from = _canonical(key);
    final si = _segmentIndexOf(from);
    if (si < 0 || n <= 0) return const <MessageKey>[];
    final last = _segments[si].last;
    final out = <MessageKey>[];
    var k = _byKey.firstKeyAfter(from);
    while (k != null && out.length < n && k <= last) {
      out.add(k);
      k = _byKey.firstKeyAfter(k);
    }
    return out;
  }

  /// Up to [before] older keys, [key] itself when present, and up to
  /// [after] newer keys, all in the segment of [key], oldest first.
  ///
  /// ```dart
  /// final window = store.keysAround(target, before: 20, after: 20);
  /// ```
  List<MessageKey> keysAround(
    MessageKey key, {
    required int before,
    required int after,
  }) {
    final at = _canonical(key);
    return <MessageKey>[
      ...keysBefore(at, before),
      if (_byKey.containsKey(at) && _segmentIndexOf(at) >= 0) at,
      ...keysAfter(at, after),
    ];
  }

  /// Keys in memory from [first] to [last] (inclusive), oldest first,
  /// regardless of segments. Lazy.
  ///
  /// ```dart
  /// final ids = store.keysBetween(a, b).map((k) => k.id).toSet();
  /// ```
  Iterable<MessageKey> keysBetween(MessageKey first, MessageKey last) sync* {
    var k = _byKey.containsKey(first) ? first : _byKey.firstKeyAfter(first);
    while (k != null && k <= last) {
      yield k;
      k = _byKey.firstKeyAfter(k);
    }
  }

  /// [key] itself when it is in memory, else the closest key in
  /// [direction]. Null when nothing exists on that side.
  ///
  /// ```dart
  /// final landing = store.nearestExisting(deletedTarget, ScanDirection.newer);
  /// ```
  MessageKey? nearestExisting(MessageKey key, ScanDirection direction) {
    final at = _canonical(key);
    if (_byKey.containsKey(at)) return at;
    return direction == ScanDirection.newer
        ? _byKey.firstKeyAfter(at)
        : _byKey.lastKeyBefore(at);
  }

  /// The earliest loaded message sent at or after [date]. Only looks at
  /// messages in memory.
  ///
  /// ```dart
  /// final key = store.firstOnOrAfter(DateTime(2026, 11, 13));
  /// ```
  MessageKey? firstOnOrAfter(DateTime date) =>
      _byDate.firstKeyAfter(_Dated(date.microsecondsSinceEpoch, _minKey))?.key;

  /// The oldest unread mention newer than [after] (or the oldest of all).
  ///
  /// Uses [ReadState.unreadMentions] when the server sent them, else scans
  /// loaded unread messages with [MessageAdapter.mentionsMe].
  ///
  /// ```dart
  /// final next = store.nextUnreadMention(anchorKey);
  /// ```
  MessageKey? nextUnreadMention([MessageKey? after]) {
    final listed = _readState.unreadMentions;
    if (listed.isNotEmpty) return _firstAfter(listed, after);
    if (_readState.unreadCount <= 0) return null;
    var from = _readState.lastReadInbox;
    if (after != null && (from == null || after > from)) from = after;
    var k = from == null ? _byKey.firstKey() : _byKey.firstKeyAfter(from);
    while (k != null) {
      final m = _byKey[k] as M;
      if (!adapter.isOutgoing(m) && adapter.mentionsMe(m)) return k;
      k = _byKey.firstKeyAfter(k);
    }
    return null;
  }

  /// The oldest unread reaction newer than [after] (or the oldest of all).
  ///
  /// ```dart
  /// final next = store.nextUnreadReaction(anchorKey);
  /// ```
  MessageKey? nextUnreadReaction([MessageKey? after]) =>
      _firstAfter(_readState.unreadReactions, after);

  /// The first loaded unread message: the first incoming, non-service,
  /// confirmed key after [ReadState.lastReadInbox]. Null when nothing is
  /// unread or it isn't loaded.
  ///
  /// ```dart
  /// final dividerBefore = store.firstUnread();
  /// ```
  MessageKey? firstUnread() {
    if (_readState.unreadCount <= 0) return null;
    final read = _readState.lastReadInbox;
    var k = read == null ? _byKey.firstKey() : _byKey.firstKeyAfter(read);
    while (k != null) {
      final m = _byKey[k] as M;
      if (!k.isLocal && !adapter.isOutgoing(m) && !adapter.isService(m)) {
        return _segmentIndexOf(k) >= 0 ? k : null;
      }
      k = _byKey.firstKeyAfter(k);
    }
    return null;
  }

  /// The newest pinned key at or before [key] (§10.10).
  ///
  /// ```dart
  /// final barShows = store.pinnedAtOrBefore(anchorKey);
  /// ```
  MessageKey? pinnedAtOrBefore(MessageKey key) {
    var lo = 0;
    var hi = _pinned.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_pinned[mid] <= key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == 0 ? null : _pinned[lo - 1];
  }

  /// Checks every store invariant and throws a [StateError] describing the
  /// first broken one. Always returns true, so it can be used in `assert`.
  ///
  /// ```dart
  /// assert(store.debugCheckInvariants());
  /// ```
  bool debugCheckInvariants() => _check(deep: true);

  @override
  String toString() =>
      'ListStore(${id.storageKey}, $length messages, $_segments)';

  // ------------------------------------------------------------ internals

  StoreDelta _mutate(void Function(_DeltaBuilder d) body) {
    _purgeTombstones();
    final d = _DeltaBuilder();
    body(d);
    assert(_check(deep: false));
    final delta = d.build(id);
    if (!delta.isEmpty && _listeners.isNotEmpty) {
      for (final listener in List<StoreListener>.of(_listeners)) {
        listener(delta);
      }
    }
    return delta;
  }

  MessageKey _canonical(MessageKey key) => _keyById[key.id] ?? key;

  bool _isCleared(MessageKey key) {
    final cleared = _clearedUpTo;
    return cleared != null && key <= cleared;
  }

  void _insertRaw(MessageKey key, M value) {
    _byKey[key] = value;
    _keyById[key.id] = key;
    _byDate[_Dated(adapter.dateOf(value).microsecondsSinceEpoch, key)] = true;
  }

  void _removeRaw(MessageKey key) {
    final value = _byKey.remove(key) as M;
    _keyById.remove(key.id);
    _byDate.remove(_Dated(adapter.dateOf(value).microsecondsSinceEpoch, key));
  }

  /// Inserts or updates [incoming]. Returns its key, or null when skipped.
  /// With [place], a new key is placed like a live "added" event.
  MessageKey? _upsert(M incoming, _DeltaBuilder d, {required bool place}) {
    final inKey = adapter.keyOf(incoming);
    if (isTombstoned(inKey.id)) return null;
    final oldKey = _keyById[inKey.id];
    if (oldKey == null) {
      if (_isCleared(inKey)) return null;
      _insertRaw(inKey, incoming);
      d.inserted.add(inKey);
      if (place) _placeAdded(inKey, d);
      return inKey;
    }
    final current = _byKey[oldKey] as M;
    final merge = this.merge;
    final next = merge == null ? incoming : merge(current, incoming);
    final newKey = merge == null ? inKey : adapter.keyOf(next);
    assert(newKey.id == oldKey.id, 'merge must keep the message id');
    if (oldKey.isSamePosition(newKey)) {
      if (!adapter.equals(current, next)) {
        final oldDate = adapter.dateOf(current).microsecondsSinceEpoch;
        final newDate = adapter.dateOf(next).microsecondsSinceEpoch;
        _byKey[oldKey] = next;
        if (oldDate != newDate) {
          _byDate.remove(_Dated(oldDate, oldKey));
          _byDate[_Dated(newDate, oldKey)] = true;
        }
        d.updated.add(oldKey);
      }
      return oldKey;
    }
    _rekey(oldKey, newKey, next, d);
    return newKey;
  }

  /// Moves a message from [oldKey] to [newKey] (ids may differ: local ack).
  void _rekey(MessageKey oldKey, MessageKey newKey, M value, _DeltaBuilder d) {
    final si = _segmentIndexOf(oldKey);
    _removeRaw(oldKey);
    _insertRaw(newKey, value);
    final error = _sendErrors.remove(oldKey.id);
    if (error != null && oldKey.id == newKey.id) {
      _sendErrors[newKey.id] = error;
    }
    d.replaced.add(KeyReplacement(oldKey, newKey));
    if (si >= 0) {
      final s = _segments[si];
      final inside = s.contains(newKey);
      final extendsLive = s.reachedNewest && newKey > s.last;
      if (inside || extendsLive) {
        var first = s.first;
        var last = s.last;
        if (first.isSamePosition(oldKey)) {
          first = _byKey.firstKeyAfter(oldKey)!;
        }
        if (extendsLive) {
          last = newKey;
        } else if (last.isSamePosition(oldKey)) {
          last = _byKey.lastKeyBefore(oldKey)!;
        }
        _segments[si] = s.copyWith(first: first, last: last);
        d.segments = true;
        return;
      }
      _shrinkAfterRemoval(oldKey, d);
    }
    _placeAdded(newKey, d);
  }

  /// Places a key that arrived as a live event (already in `_byKey`).
  void _placeAdded(MessageKey key, _DeltaBuilder d) {
    if (_segmentIndexOf(key) >= 0) return; // late message inside a segment
    if (_segments.isNotEmpty && key < _segments.last.last) return; // orphan
    final live = liveSegment;
    if (live != null) {
      _segments[_segments.length - 1] = live.copyWith(last: key);
    } else if (key.isLocal && !_knownEmpty) {
      return; // a pending message alone proves nothing about the newest
    } else {
      _segments.add(
        Segment(
          first: key,
          last: key,
          reachedOldest: _knownEmpty,
          reachedNewest: true,
        ),
      );
    }
    _knownEmpty = false;
    d.segments = true;
  }

  void _delete(String id, _DeltaBuilder d) {
    _tombstones[id] = _clock();
    final key = _keyById[id];
    if (key == null) return;
    _removeRaw(key);
    _sendErrors.remove(id);
    _shrinkAfterRemoval(key, d);
    d.removed.add(key);
    if (_pinned.contains(key)) {
      _pinned = List<MessageKey>.unmodifiable(_pinned.where((k) => k != key));
      d.pinned = true;
    }
    final read = _readState;
    if (read.unreadMentions.contains(key) ||
        read.unreadReactions.contains(key)) {
      _readState = ReadState(
        lastReadInbox: read.lastReadInbox,
        lastReadOutbox: read.lastReadOutbox,
        unreadCount: read.unreadCount,
        unreadMentions: [
          for (final k in read.unreadMentions)
            if (k != key) k,
        ],
        unreadReactions: [
          for (final k in read.unreadReactions)
            if (k != key) k,
        ],
      );
      d.read = true;
    }
  }

  void _ack(String localId, M server, _DeltaBuilder d) {
    final localKey = _keyById[localId];
    final serverKey = adapter.keyOf(server);
    if (localKey == null || serverKey.id == localId) {
      _upsert(server, d, place: true);
      return;
    }
    final existing = _keyById[serverKey.id];
    if (existing != null || isTombstoned(serverKey.id)) {
      // The server message arrived (or was deleted) before the ack.
      _removeRaw(localKey);
      _sendErrors.remove(localId);
      _shrinkAfterRemoval(localKey, d);
      if (existing != null) {
        d.replaced.add(KeyReplacement(localKey, existing));
        _upsert(server, d, place: true);
      } else {
        d.removed.add(localKey);
      }
      return;
    }
    _rekey(localKey, serverKey, server, d);
  }

  void _setReadState(ReadState state, _DeltaBuilder d) {
    final next = state.normalized();
    if (next != _readState) {
      _readState = next;
      d.read = true;
    }
  }

  void _clearHistory(MessageKey upTo, _DeltaBuilder d) {
    final cleared = _clearedUpTo;
    if (cleared == null || upTo > cleared) {
      _clearedUpTo = upTo;
      d.cleared = true;
    }
    final doomed = <MessageKey>[];
    var k = _byKey.firstKey();
    while (k != null && k <= upTo) {
      doomed.add(k);
      k = _byKey.firstKeyAfter(k);
    }
    for (final key in doomed) {
      _removeRaw(key);
      _sendErrors.remove(key.id);
    }
    d.removed.addAll(doomed);
    var droppedLive = false;
    while (_segments.isNotEmpty) {
      final s = _segments.first;
      if (s.last <= upTo) {
        droppedLive = droppedLive || s.reachedNewest;
        _segments.removeAt(0);
        d.segments = true;
        continue;
      }
      if (s.first <= upTo) {
        // The segment straddled the cut: nothing older than its new first
        // key exists any more.
        _segments[0] = s.copyWith(
          first: _byKey.firstKeyAfter(upTo)!,
          reachedOldest: true,
        );
        d.segments = true;
      }
      break;
    }
    if (droppedLive && _segments.isEmpty && !_knownEmpty) {
      _knownEmpty = true;
      d.segments = true;
    }
    if (doomed.isNotEmpty) d.cleared = true;
  }

  /// Fixes segment bounds after [removed] left `_byKey`.
  void _shrinkAfterRemoval(MessageKey removed, _DeltaBuilder d) {
    final i = _segmentIndexOf(removed);
    if (i < 0) return;
    final s = _segments[i];
    final wasFirst = s.first.isSamePosition(removed);
    final wasLast = s.last.isSamePosition(removed);
    if (!wasFirst && !wasLast) return;
    final first = wasFirst ? _byKey.firstKeyAfter(removed) : s.first;
    final last = wasLast ? _byKey.lastKeyBefore(removed) : s.last;
    d.segments = true;
    if (first == null || last == null || first > last) {
      _segments.removeAt(i);
      if (s.reachedOldest && s.reachedNewest && _segments.isEmpty) {
        _knownEmpty = true;
      }
      return;
    }
    _segments[i] = s.copyWith(first: first, last: last);
  }

  /// Records that the server proved [lo]..[hi] contiguous (§7.1 steps 2–4).
  void _prove(
    MessageKey lo,
    MessageKey hi, {
    required bool oldest,
    required bool newest,
    required _DeltaBuilder d,
  }) {
    // First segment whose last key is >= lo.
    var a = 0;
    var b = _segments.length;
    while (a < b) {
      final mid = (a + b) >> 1;
      if (_segments[mid].last < lo) {
        a = mid + 1;
      } else {
        b = mid;
      }
    }
    b = a;
    while (b < _segments.length && _segments[b].first <= hi) {
      final s = _segments[b];
      if (s.first < lo) lo = s.first;
      if (s.last > hi) hi = s.last;
      oldest = oldest || s.reachedOldest;
      newest = newest || s.reachedNewest;
      b++;
    }
    // Bounds are always keys that exist in memory.
    final first = _byKey.containsKey(lo) ? lo : _byKey.firstKeyAfter(lo);
    final last = _byKey.containsKey(hi) ? hi : _byKey.lastKeyBefore(hi);
    if (first == null || last == null || first > last) return;
    final merged = Segment(
      first: first,
      last: last,
      reachedOldest: oldest,
      reachedNewest: newest && b == _segments.length,
    );
    if (b - a == 1 && _segments[a] == merged) return;
    _segments.replaceRange(a, b, <Segment>[merged]);
    // Only the newest segment can hold the newest message: a segment with
    // newer data above it is stale.
    for (var i = 0; i < _segments.length - 1; i++) {
      if (_segments[i].reachedNewest) {
        _segments[i] = _segments[i].copyWith(reachedNewest: false);
      }
    }
    _knownEmpty = false;
    d.segments = true;
  }

  void _evict(int limit, Iterable<KeyRange> protect, _DeltaBuilder d) {
    final excess = _byKey.length - limit;
    if (excess <= 0) return;
    final ranges = <KeyRange>[
      ...protect,
      if (snapshot case final s?) s.range,
    ];
    final keys = _byKey.keys.toList(growable: false);
    final n = keys.length;
    final count = _segments.length;
    final segOf = List<int>.filled(n, -1);
    final segLo = List<int>.filled(count, -1);
    final segHi = List<int>.filled(count, -1);
    final hullLo = List<int>.filled(count, -1);
    final hullHi = List<int>.filled(count, -1);
    final protected = List<bool>.filled(n, false);
    var si = 0;
    for (var i = 0; i < n; i++) {
      final key = keys[i];
      while (si < count && _segments[si].last < key) {
        si++;
      }
      final inSegment = si < count && _segments[si].first <= key;
      protected[i] = ranges.any((r) => r.contains(key));
      if (!inSegment) continue;
      segOf[i] = si;
      if (segLo[si] < 0) segLo[si] = i;
      segHi[si] = i;
      if (protected[i]) {
        if (hullLo[si] < 0) hullLo[si] = i;
        hullHi[si] = i;
      }
    }
    // Higher score = dropped earlier.
    final score = List<int>.filled(n, -1);
    final candidates = <int>[];
    for (var i = 0; i < n; i++) {
      if (protected[i]) continue;
      final s = segOf[i];
      if (s < 0) {
        score[i] = _orphanScore;
      } else if (hullLo[s] >= 0) {
        if (i >= hullLo[s] && i <= hullHi[s]) continue;
        score[i] = i < hullLo[s] ? hullLo[s] - i : i - hullHi[s];
      } else {
        final fromNewest = segHi[s] - i;
        score[i] =
            _segments[s].reachedNewest ? fromNewest : _islandScore + fromNewest;
      }
      candidates.add(i);
    }
    if (candidates.isEmpty) return;
    candidates.sort((x, y) => score[y].compareTo(score[x]));
    final dropped = List<bool>.filled(n, false);
    for (final i in candidates.take(excess)) {
      dropped[i] = true;
      _removeRaw(keys[i]);
      _sendErrors.remove(keys[i].id);
      d.evicted.add(keys[i]);
    }
    final next = <Segment>[];
    for (var s = 0; s < count; s++) {
      var first = segLo[s];
      var last = segHi[s];
      while (first <= last && dropped[first]) {
        first++;
      }
      while (last >= first && dropped[last]) {
        last--;
      }
      if (first > last) continue;
      final old = _segments[s];
      next.add(
        Segment(
          first: keys[first],
          last: keys[last],
          reachedOldest: old.reachedOldest && first == segLo[s],
          reachedNewest: old.reachedNewest && last == segHi[s],
        ),
      );
    }
    if (!_sameSegments(next, _segments)) {
      _segments
        ..clear()
        ..addAll(next);
      d.segments = true;
    }
  }

  int _segmentIndexOf(MessageKey key) {
    // Last segment whose first key is <= key.
    var lo = 0;
    var hi = _segments.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_segments[mid].first <= key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final i = lo - 1;
    return i >= 0 && key <= _segments[i].last ? i : -1;
  }

  void _purgeTombstones() {
    if (_tombstones.isEmpty) return;
    final now = _clock();
    final last = _lastPurge;
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _lastPurge = now;
    _tombstones.removeWhere((_, at) => now.difference(at) > tombstoneTtl);
  }

  bool _check({required bool deep}) {
    Never fail(String what) => throw StateError('$what in $this');
    for (var i = 0; i < _segments.length; i++) {
      final s = _segments[i];
      if (s.first > s.last) fail('Segment $i is inverted');
      if (!_byKey.containsKey(s.first) || !_byKey.containsKey(s.last)) {
        fail('Segment $i has a bound that is not stored');
      }
      if (i > 0 && _segments[i - 1].last >= s.first) {
        fail('Segments ${i - 1} and $i overlap or are unsorted');
      }
      if (s.reachedNewest && i != _segments.length - 1) {
        fail('Segment $i is live but not the newest');
      }
    }
    if (_knownEmpty && _segments.isNotEmpty) fail('Known-empty with segments');
    if (_keyById.length != _byKey.length || _byDate.length != _byKey.length) {
      fail('Indexes disagree (${_byKey.length} keys, '
          '${_keyById.length} ids, ${_byDate.length} dates)');
    }
    if (!deep) return true;
    MessageKey? previous;
    for (final entry in _byKey.entries) {
      final key = entry.key;
      if (previous != null && previous >= key) fail('Keys are unsorted');
      previous = key;
      final indexed = _keyById[key.id];
      if (indexed == null || !indexed.isSamePosition(key)) {
        fail('Id index is stale for $key');
      }
      if (!adapter.keyOf(entry.value).isSamePosition(key)) {
        fail('Message stored under the wrong key $key');
      }
      if (_isCleared(key)) fail('Cleared key $key is stored');
    }
    for (var i = 1; i < _pinned.length; i++) {
      if (_pinned[i - 1] > _pinned[i]) fail('Pinned keys are unsorted');
    }
    return true;
  }
}

/// Lowest possible key at a date, used as a search probe.
const MessageKey _minKey = MessageKey(order: -9007199254740991, id: '');

const int _islandScore = 1099511627776; // 2^40, written out for the web
const int _orphanScore = 1125899906842624; // 2^50

MessageKey? _firstAfter(List<MessageKey> sorted, MessageKey? after) {
  if (sorted.isEmpty) return null;
  if (after == null) return sorted.first;
  var lo = 0;
  var hi = sorted.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sorted[mid] <= after) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo < sorted.length ? sorted[lo] : null;
}

bool _sameKeys(List<MessageKey> a, List<MessageKey> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!a[i].isSamePosition(b[i])) return false;
  }
  return true;
}

bool _sameSegments(List<Segment> a, List<Segment> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final class _Dated implements Comparable<_Dated> {
  const _Dated(this.micros, this.key);

  final int micros;
  final MessageKey key;

  @override
  int compareTo(_Dated other) => micros != other.micros
      ? micros.compareTo(other.micros)
      : key.compareTo(other.key);
}

final class _DeltaBuilder {
  final List<MessageKey> inserted = <MessageKey>[];
  final List<MessageKey> updated = <MessageKey>[];
  final List<MessageKey> removed = <MessageKey>[];
  final List<MessageKey> evicted = <MessageKey>[];
  final List<KeyReplacement> replaced = <KeyReplacement>[];
  bool segments = false;
  bool read = false;
  bool pinned = false;
  bool typing = false;
  bool cleared = false;

  StoreDelta build(ListId list) => StoreDelta(
        list: list,
        inserted: inserted,
        updated: updated,
        removed: removed,
        evicted: evicted,
        replaced: replaced,
        segmentsChanged: segments,
        readStateChanged: read,
        pinnedChanged: pinned,
        typingChanged: typing,
        historyCleared: cleared,
      );
}
