import 'list_store.dart';
import 'message_key.dart';
import 'models.dart';
import 'store_delta.dart';

/// All lists an app has in memory: one [ListStore] per [ListId], kept in
/// least-recently-used order (§7, §7.4).
///
/// ```dart
/// final store = MessageStore<ChatMessage>(adapter: const ChatMessageAdapter());
/// final chat = store.list(const ListId('chat-1'));
/// chat.applyPage(request, result);
/// store.evictLists(keep: {const ListId('chat-1')});
/// ```
final class MessageStore<M> {
  /// Creates an empty store.
  MessageStore({
    required this.adapter,
    this.memoryLimitPerList = 1000,
    this.openListsInMemory = 10,
    this.tombstoneTtl = const Duration(minutes: 5),
    this.merge,
    DateTime Function()? clock,
  })  : assert(memoryLimitPerList > 0),
        assert(openListsInMemory > 0),
        _clock = clock;

  /// Reads keys, dates and flags from the app's message class.
  final MessageAdapter<M> adapter;

  /// Maximum number of messages kept per list by [evictMessages].
  final int memoryLimitPerList;

  /// Maximum number of lists kept by [evictLists].
  final int openListsInMemory;

  /// How long a deleted id keeps rejecting late pages and events.
  final Duration tombstoneTtl;

  /// Combines the stored and the incoming version of a message.
  final MessageMerge<M>? merge;

  final DateTime Function()? _clock;

  // Insertion order = least recently used first.
  final Map<ListId, ListStore<M>> _lists = <ListId, ListStore<M>>{};

  /// Ids of the lists in memory, least recently used first.
  Iterable<ListId> get lists => _lists.keys;

  /// The store of [id], created when missing. Marks it most recently used.
  ///
  /// ```dart
  /// final chat = store.list(const ListId('chat-1'));
  /// ```
  ListStore<M> list(ListId id) {
    final existing = _lists.remove(id);
    final store = existing ??
        ListStore<M>(
          id: id,
          adapter: adapter,
          tombstoneTtl: tombstoneTtl,
          clock: _clock,
          merge: merge,
        );
    _lists[id] = store;
    return store;
  }

  /// The store of [id] if it is in memory. Doesn't change the LRU order.
  ///
  /// ```dart
  /// final hasSession = store.peek(id)?.snapshot != null;
  /// ```
  ListStore<M>? peek(ListId id) => _lists[id];

  /// Trims the list [id] to [memoryLimitPerList] messages, never dropping
  /// keys inside [protect] or its saved snapshot (§7.4).
  ///
  /// ```dart
  /// store.evictMessages(id, protect: [KeyRange(windowFirst, windowLast)]);
  /// ```
  StoreDelta evictMessages(
    ListId id, {
    Iterable<KeyRange> protect = const <KeyRange>[],
  }) =>
      _lists[id]?.evict(limit: memoryLimitPerList, protect: protect) ??
      StoreDelta(list: id);

  /// Drops least recently used lists until at most [openListsInMemory]
  /// remain. Lists in [keep] (those with a controller attached) stay.
  /// Returns the dropped ids.
  ///
  /// ```dart
  /// final dropped = store.evictLists(keep: attachedLists);
  /// ```
  List<ListId> evictLists({Set<ListId> keep = const <ListId>{}}) {
    final dropped = <ListId>[];
    var excess = _lists.length - openListsInMemory;
    if (excess <= 0) return dropped;
    for (final id in _lists.keys.toList(growable: false)) {
      if (excess <= 0) break;
      if (keep.contains(id)) continue;
      _lists.remove(id);
      dropped.add(id);
      excess--;
    }
    return dropped;
  }

  /// Drops the list [id] from memory, or every list when [id] is null.
  ///
  /// ```dart
  /// store.clear(const ListId('chat-1'));
  /// ```
  void clear([ListId? id]) {
    if (id == null) {
      _lists.clear();
    } else {
      _lists.remove(id);
    }
  }
}
