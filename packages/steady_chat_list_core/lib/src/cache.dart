import 'dart:async';

import 'package:meta/meta.dart';

import 'list_event.dart';
import 'message_key.dart';
import 'models.dart';
import 'paging.dart';

/// What a cache knows about one list: enough to open it at once, offline.
///
/// ```dart
/// final cached = await cache.load(const ListId('chat-1'));
/// print('${cached?.messages.length} messages, ${cached?.segments}');
/// ```
@immutable
final class CachedList<M> {
  /// Creates a cached list.
  const CachedList({
    required this.messages,
    required this.segments,
    this.readState,
    this.snapshot,
  });

  /// The cached messages (any order). Only messages inside [segments] are
  /// meaningful.
  final List<M> messages;

  /// The runs of [messages] the server proved contiguous.
  final List<Segment> segments;

  /// Read markers and unread counters, if they were saved.
  final ReadState? readState;

  /// The saved scroll position, if any.
  final ViewportSnapshot? snapshot;
}

/// What a cache keeps (§8.3).
///
/// ```dart
/// await cache.evict(const EvictionPolicy(keepNewestPerList: 200));
/// ```
@immutable
final class EvictionPolicy {
  /// Creates a policy.
  const EvictionPolicy({
    this.keepNewestPerList = 500,
    this.dropListsUnopenedFor = const Duration(days: 30),
    this.maxMessages = 50000,
  });

  /// Per list: the newest this many messages of the live segment are kept,
  /// plus the messages around the saved position.
  final int keepNewestPerList;

  /// Lists that were not opened for this long are dropped completely.
  final Duration dropListsUnopenedFor;

  /// Upper bound for all lists together; the least recently opened lists
  /// are dropped first.
  final int maxMessages;
}

/// Someone else (another browser tab, another isolate) changed the cache.
///
/// ```dart
/// cache.watch().listen((change) => print('changed: ${change.list}'));
/// ```
@immutable
final class CacheChange {
  /// Creates a change; a null [list] means "any list".
  const CacheChange([this.list]);

  /// The list that changed, when known.
  final ListId? list;
}

/// A persistent copy of the newest part of each list, so chats open at
/// once and work offline (§8.2). The hub writes to it and reads it once
/// per list; apps normally just pass an implementation to the hub.
///
/// ```dart
/// final hub = MessageListHub<ChatMessage>(
///   source: source,
///   adapter: adapter,
///   cache: InMemoryMessageCache<ChatMessage>(adapter: adapter),
/// );
/// ```
abstract interface class MessageCache<M> {
  /// Everything cached for [list] (at most [limit] messages, preferring the
  /// newest ones and the ones around the saved position), or null.
  Future<CachedList<M>?> load(ListId list, {int limit = 600});

  /// Stores a page. [segments] are the list's segments after the page was
  /// applied in memory; they replace the stored ones.
  Future<void> applyPage(
    PageRequest request,
    PageResult<M> result, {
    required List<Segment> segments,
  });

  /// Stores a batch of events. [segments] holds the segments of every list
  /// the events touched, after they were applied in memory.
  Future<void> applyEvents(
    List<ListEvent<M>> events, {
    required Map<ListId, List<Segment>> segments,
  });

  /// Stores the scroll position of [list]. The latest call wins.
  Future<void> saveSnapshot(ListId list, ViewportSnapshot snapshot);

  /// Drops what [policy] no longer keeps.
  Future<void> evict(EvictionPolicy policy);

  /// Drops [list], or everything.
  Future<void> clear([ListId? list]);

  /// Changes made by someone else (web multi-tab). May be empty.
  Stream<CacheChange> watch();
}

/// A [MessageCache] in memory: it survives controllers and hubs, not the
/// process. Useful as a session cache and in tests; `DriftMessageCache`
/// (package `steady_chat_list_drift`) is the persistent one.
///
/// ```dart
/// final cache = InMemoryMessageCache<ChatMessage>(adapter: adapter);
/// ```
final class InMemoryMessageCache<M> implements MessageCache<M> {
  /// Creates an empty cache.
  InMemoryMessageCache({required this.adapter, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// Reads keys from the app's message class.
  final MessageAdapter<M> adapter;

  final DateTime Function() _clock;
  final Map<ListId, _CachedData<M>> _lists = {};

  _CachedData<M> _data(ListId list) =>
      _lists[list] ??= _CachedData<M>(_clock());

  /// Number of cached messages of [list].
  int count(ListId list) => _lists[list]?.messages.length ?? 0;

  @override
  Future<CachedList<M>?> load(ListId list, {int limit = 600}) async {
    final data = _lists[list];
    if (data == null) return null;
    data.openedAt = _clock();
    final keys = data.messages.keys.toList()..sort();
    final from = keys.length > limit ? keys.length - limit : 0;
    final wanted = <MessageKey>{...keys.sublist(from)};
    final snapshot = data.snapshot;
    if (snapshot != null) {
      final range = snapshot.range;
      wanted.addAll(keys.where(range.contains));
    }
    return CachedList<M>(
      messages: [for (final key in wanted) data.messages[key] as M],
      segments: List<Segment>.of(data.segments),
      readState: data.readState,
      snapshot: snapshot,
    );
  }

  @override
  Future<void> applyPage(
    PageRequest request,
    PageResult<M> result, {
    required List<Segment> segments,
  }) async {
    final data = _data(request.list);
    for (final message in result.items) {
      data.put(adapter.keyOf(message), message);
    }
    data.segments = List<Segment>.of(segments);
    final read = result.readState;
    if (read != null) data.readState = read;
  }

  @override
  Future<void> applyEvents(
    List<ListEvent<M>> events, {
    required Map<ListId, List<Segment>> segments,
  }) async {
    for (final event in events) {
      final data = _data(event.list);
      switch (event) {
        case MessagesAdded<M>(:final items) || MessagesUpdated<M>(:final items):
          for (final message in items) {
            data.put(adapter.keyOf(message), message);
          }
        case MessagesDeleted<M>(:final ids):
          ids.forEach(data.removeId);
        case LocalAcked<M>(:final localId, :final serverMessage):
          data.removeId(localId);
          data.put(adapter.keyOf(serverMessage), serverMessage);
        case ReadStateChanged<M>(:final state):
          data.readState = state;
        case HistoryCleared<M>(:final upTo):
          data.messages.removeWhere((key, _) => key <= upTo);
        case LocalFailed<M>() || PinnedChanged<M>() || TypingChanged<M>():
          break; // not persisted
      }
    }
    segments.forEach((list, value) {
      _data(list).segments = List<Segment>.of(value);
    });
  }

  @override
  Future<void> saveSnapshot(ListId list, ViewportSnapshot snapshot) async {
    _data(list).snapshot = snapshot;
  }

  @override
  Future<void> evict(EvictionPolicy policy) async {
    final now = _clock();
    _lists.removeWhere(
      (_, data) => now.difference(data.openedAt) > policy.dropListsUnopenedFor,
    );
    for (final data in _lists.values) {
      final keys = data.messages.keys.toList()..sort();
      if (keys.length <= policy.keepNewestPerList) continue;
      final keep = <MessageKey>{
        ...keys.sublist(keys.length - policy.keepNewestPerList),
      };
      final range = data.snapshot?.range;
      if (range != null) keep.addAll(keys.where(range.contains));
      final removed = [
        for (final key in keys)
          if (!keep.contains(key)) key,
      ];
      removed.forEach(data.messages.remove);
      data.segments =
          clampSegments(data.segments, kept: keep, removed: removed);
    }
    // The global cap: least recently opened lists go first.
    var total = _lists.values.fold<int>(0, (n, d) => n + d.messages.length);
    final byAge = _lists.entries.toList()
      ..sort((a, b) => a.value.openedAt.compareTo(b.value.openedAt));
    for (final entry in byAge) {
      if (total <= policy.maxMessages) break;
      total -= entry.value.messages.length;
      _lists.remove(entry.key);
    }
  }

  @override
  Future<void> clear([ListId? list]) async {
    if (list == null) {
      _lists.clear();
    } else {
      _lists.remove(list);
    }
  }

  @override
  Stream<CacheChange> watch() => const Stream<CacheChange>.empty();
}

final class _CachedData<M> {
  _CachedData(this.openedAt);

  final Map<MessageKey, M> messages = {};
  List<Segment> segments = const [];
  ReadState? readState;
  ViewportSnapshot? snapshot;
  DateTime openedAt;

  void put(MessageKey key, M message) {
    // Keys are equal by id: a re-keyed message replaces its old entry.
    messages
      ..remove(key)
      ..[key] = message;
  }

  void removeId(String id) => messages.remove(MessageKey(order: 0, id: id));
}

/// Recomputes [segments] after a cache dropped messages: only runs of
/// [kept] keys with no [removed] key between them are still proven
/// contiguous, so a segment with a hole becomes several segments. A run
/// keeps `reachedOldest` / `reachedNewest` only if it still has that end.
///
/// ```dart
/// final next = clampSegments(segments, kept: stillStored, removed: dropped);
/// ```
List<Segment> clampSegments(
  List<Segment> segments, {
  required Iterable<MessageKey> kept,
  required Iterable<MessageKey> removed,
}) {
  // true = kept, false = removed, in key order.
  final all = <(MessageKey, bool)>[
    for (final key in kept) (key, true),
    for (final key in removed) (key, false),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <Segment>[];
  for (final segment in segments) {
    MessageKey? first;
    MessageKey? last;
    void close() {
      final from = first;
      final to = last;
      first = null;
      last = null;
      if (from == null || to == null) return;
      out.add(
        Segment(
          first: from,
          last: to,
          reachedOldest:
              segment.reachedOldest && from.isSamePosition(segment.first),
          reachedNewest:
              segment.reachedNewest && to.isSamePosition(segment.last),
        ),
      );
    }

    for (final (key, isKept) in all) {
      if (!segment.contains(key)) continue;
      if (isKept) {
        first ??= key;
        last = key;
      } else {
        close(); // a hole: what follows is a new run
      }
    }
    close();
  }
  return out;
}
