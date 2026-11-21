import 'dart:async';
import 'dart:collection';

import 'list_event.dart';
import 'message_key.dart';
import 'models.dart';
import 'paging.dart';
import 'source.dart';

/// Called when the user has read a list up to a key.
///
/// ```dart
/// onMarkRead: (list, key) => db.markRead(list.chatId, key.id),
/// ```
typedef MarkReadCallback = FutureOr<void> Function(
    ListId list, MessageKey upTo);

/// A [MessageSource] for apps that simply have the messages: no backend
/// code, no paging to implement. Fill it and change it; every list that
/// shows it follows.
///
/// Good for local-only chats, AI assistant chats, small conversations and
/// tests. All messages of a list are kept in memory; for huge histories
/// implement [MessageSource] with real paging instead.
///
/// ```dart
/// final source = ListMessageSource<ChatMessage>(adapter: adapter);
/// source.setAll(chat, loadedMessages);       // everything at once
/// source.upsert(chat, [newMessage]);         // a message arrived or changed
/// source.remove(chat, ['41']);               // a message was deleted
/// ```
final class ListMessageSource<M> implements MessageSource<M> {
  /// Creates a source, optionally filled with [initial] messages per list.
  ListMessageSource({
    required this.adapter,
    Map<ListId, Iterable<M>> initial = const {},
    this.onMarkRead,
  }) {
    initial.forEach(setAll);
  }

  /// Reads keys and dates from the app's message class.
  final MessageAdapter<M> adapter;

  /// Called (debounced by the list) when the user has read up to a key.
  final MarkReadCallback? onMarkRead;

  final Map<ListId, _ListData<M>> _lists = {};
  bool _disposed = false;

  _ListData<M> _data(ListId list) => _lists[list] ??= _ListData<M>();

  /// The messages of [list], oldest first.
  ///
  /// ```dart
  /// final count = source.messages(chat).length;
  /// ```
  List<M> messages(ListId list) =>
      _lists[list]?.byKey.values.toList(growable: false) ?? <M>[];

  /// The read state sent along with pages of [list], if one was set.
  ReadState? readStateOf(ListId list) => _lists[list]?.readState;

  /// Replaces every message of [list]. Lists on screen get the difference:
  /// what was added, changed and removed.
  ///
  /// ```dart
  /// source.setAll(chat, await db.allMessages(chat.chatId));
  /// ```
  void setAll(ListId list, Iterable<M> messages) {
    final data = _data(list);
    final next = SplayTreeMap<MessageKey, M>();
    final nextKeys = <String, MessageKey>{};
    for (final message in messages) {
      final key = adapter.keyOf(message);
      final previous = nextKeys[key.id];
      if (previous != null) next.remove(previous); // the last one wins
      next[key] = message;
      nextKeys[key.id] = key;
    }
    final removed = <String>[
      for (final id in data.keyById.keys)
        if (!nextKeys.containsKey(id)) id,
    ];
    final added = <M>[];
    final updated = <M>[];
    for (final entry in next.entries) {
      final oldKey = data.keyById[entry.key.id];
      if (oldKey == null) {
        added.add(entry.value);
      } else if (!oldKey.isSamePosition(entry.key) ||
          !adapter.equals(data.byKey[oldKey] as M, entry.value)) {
        updated.add(entry.value);
      }
    }
    data
      ..byKey = next
      ..keyById = nextKeys;
    if (removed.isNotEmpty) data.emit(MessagesDeleted<M>(list, removed));
    if (updated.isNotEmpty) data.emit(MessagesUpdated<M>(list, updated));
    if (added.isNotEmpty) data.emit(MessagesAdded<M>(list, added));
  }

  /// Adds new messages and replaces the ones whose id is already there.
  ///
  /// ```dart
  /// source.upsert(chat, [message.copyWith(text: edited)]);
  /// ```
  void upsert(ListId list, Iterable<M> messages) {
    final data = _data(list);
    final added = <M>[];
    final updated = <M>[];
    for (final message in messages) {
      final key = adapter.keyOf(message);
      final oldKey = data.keyById[key.id];
      if (oldKey == null) {
        added.add(message);
      } else {
        final changed = !oldKey.isSamePosition(key) ||
            !adapter.equals(data.byKey[oldKey] as M, message);
        data.byKey.remove(oldKey);
        if (changed) updated.add(message);
      }
      data.byKey[key] = message;
      data.keyById[key.id] = key;
    }
    if (updated.isNotEmpty) data.emit(MessagesUpdated<M>(list, updated));
    if (added.isNotEmpty) data.emit(MessagesAdded<M>(list, added));
  }

  /// Removes the messages with [ids].
  ///
  /// ```dart
  /// source.remove(chat, [message.id]);
  /// ```
  void remove(ListId list, Iterable<String> ids) {
    final data = _data(list);
    final removed = <String>[];
    for (final id in ids) {
      final key = data.keyById.remove(id);
      if (key == null) continue;
      data.byKey.remove(key);
      removed.add(id);
    }
    if (removed.isNotEmpty) data.emit(MessagesDeleted<M>(list, removed));
  }

  /// Removes every message of [list].
  ///
  /// ```dart
  /// source.clear(chat);
  /// ```
  void clear(ListId list) => setAll(list, const []);

  /// Sets the read markers and unread counters of [list].
  ///
  /// ```dart
  /// source.setReadState(chat, ReadState(lastReadInbox: key, unreadCount: 3));
  /// ```
  void setReadState(ListId list, ReadState state) {
    final data = _data(list)..readState = state;
    data.emit(ReadStateChanged<M>(list, state));
  }

  /// Sends [event] to the lists showing [list], for what the methods above
  /// don't cover (typing, pinned messages, local message acks).
  ///
  /// ```dart
  /// source.emit(TypingChanged<ChatMessage>(chat, {'alice'}));
  /// ```
  void emit(ListEvent<M> event) => _data(event.list).emit(event);

  /// Reports an error to the listeners of [list].
  void addError(ListId list, Object error, [StackTrace? stackTrace]) {
    final data = _data(list);
    if (!data.events.isClosed) data.events.addError(error, stackTrace);
  }

  /// The page for [request], computed right away. [fetch] returns the same.
  ///
  /// ```dart
  /// final newest = source.page(PageRequest(
  ///     list: chat, direction: PageDirection.latest, limit: 80));
  /// ```
  PageResult<M> page(PageRequest request) {
    final data = _data(request.list);
    final byKey = data.byKey;
    List<M> older(MessageKey? from, int limit) {
      final out = <M>[];
      var key = from == null ? byKey.lastKey() : byKey.lastKeyBefore(from);
      while (key != null && out.length < limit) {
        out.add(byKey[key] as M);
        key = byKey.lastKeyBefore(key);
      }
      return out;
    }

    List<M> newer(MessageKey from, int limit) {
      final out = <M>[];
      var key = byKey.firstKeyAfter(from);
      while (key != null && out.length < limit) {
        out.add(byKey[key] as M);
        key = byKey.firstKeyAfter(key);
      }
      return out;
    }

    bool isOldest(List<M> items) =>
        items.isEmpty ||
        adapter.keyOf(items.last).isSamePosition(byKey.firstKey()!);
    bool isNewest(List<M> items) =>
        items.isEmpty ||
        adapter.keyOf(items.last).isSamePosition(byKey.lastKey()!);

    switch (request.direction) {
      case PageDirection.latest:
        final items = older(null, request.limit);
        return PageResult<M>(
          items: items,
          reachedOldest: isOldest(items),
          reachedNewest: true,
          readState: data.readState,
        );
      case PageDirection.older:
        final items = older(request.anchor, request.limit);
        return PageResult<M>(
          items: items,
          reachedOldest: byKey.isEmpty || isOldest(items),
          readState: data.readState,
        );
      case PageDirection.newer:
        final items = newer(request.anchor!, request.limit);
        return PageResult<M>(
          items: items,
          reachedNewest: byKey.isEmpty || isNewest(items),
          readState: data.readState,
        );
      case PageDirection.around:
        var anchor = request.anchor;
        final date = request.anchorDate;
        if (anchor == null && date != null) {
          // The first message at or after the date, else the newest one.
          for (final entry in byKey.entries) {
            if (!adapter.dateOf(entry.value).isBefore(date)) {
              anchor = entry.key;
              break;
            }
          }
          anchor ??= byKey.lastKey();
        }
        if (anchor == null) return PageResult<M>(items: const []);
        final half = request.limit ~/ 2;
        final before = older(anchor, half);
        final after = newer(anchor, half);
        final stored = data.keyById[anchor.id];
        return PageResult<M>(
          items: [
            ...before,
            if (stored != null) byKey[stored] as M,
            ...after,
          ],
          reachedOldest: isOldest(before) &&
              (before.isNotEmpty || byKey.lastKeyBefore(anchor) == null),
          reachedNewest: isNewest(after) &&
              (after.isNotEmpty || byKey.firstKeyAfter(anchor) == null),
          readState: data.readState,
        );
    }
  }

  @override
  Future<PageResult<M>> fetch(PageRequest request) =>
      Future<PageResult<M>>.value(page(request));

  @override
  Stream<ListEvent<M>> events(ListId list) => _data(list).events.stream;

  @override
  Future<void> markRead(ListId list, MessageKey upTo) async {
    await onMarkRead?.call(list, upTo);
  }

  /// Closes the event streams. The source can't be used afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final data in _lists.values) {
      unawaited(data.events.close());
    }
  }
}

final class _ListData<M> {
  SplayTreeMap<MessageKey, M> byKey = SplayTreeMap<MessageKey, M>();
  Map<String, MessageKey> keyById = <String, MessageKey>{};
  ReadState? readState;
  final StreamController<ListEvent<M>> events =
      StreamController<ListEvent<M>>.broadcast();

  void emit(ListEvent<M> event) {
    if (!events.isClosed) events.add(event);
  }
}

/// A [MessageSource] over a stream of complete lists: every event of the
/// stream is all the messages of the conversation, and the lists on screen
/// get the difference.
///
/// This is how reactive stores deliver data: a Drift `watch()` query, a
/// Firestore `snapshots()` query, a Supabase realtime query, a `BehaviorSubject`.
/// The stream is listened to while a list is shown (and 30 s after).
///
/// ```dart
/// final source = StreamMessageSource<ChatMessage>(
///   adapter: adapter,
///   snapshots: (list) => db.watchMessages(list.chatId),
/// );
/// ```
final class StreamMessageSource<M> implements MessageSource<M> {
  /// Creates a source that listens to [snapshots] per list.
  StreamMessageSource({
    required MessageAdapter<M> adapter,
    required this.snapshots,
    MarkReadCallback? onMarkRead,
  }) : _inner = ListMessageSource<M>(adapter: adapter, onMarkRead: onMarkRead);

  /// Returns the stream of complete message lists of a conversation.
  final Stream<List<M>> Function(ListId list) snapshots;

  final ListMessageSource<M> _inner;
  final Map<ListId, _Feed<M>> _feeds = {};
  bool _disposed = false;

  /// The messages of [list] from its latest snapshot, oldest first.
  List<M> messages(ListId list) => _inner.messages(list);

  /// Sets the read markers and unread counters of [list].
  void setReadState(ListId list, ReadState state) =>
      _inner.setReadState(list, state);

  /// Sends [event] to the lists showing [list] (typing, pinned, acks).
  void emit(ListEvent<M> event) => _inner.emit(event);

  _Feed<M> _listen(ListId list) {
    final existing = _feeds[list];
    if (existing != null) return existing;
    final feed = _Feed<M>();
    _feeds[list] = feed;
    void failed(Object error, StackTrace stackTrace) {
      if (!feed.first.isCompleted) {
        // Nothing arrived yet: the pending fetch fails and can be retried.
        _feeds.remove(list);
        unawaited(feed.subscription?.cancel());
        feed.first.completeError(error, stackTrace);
      } else {
        _inner.addError(list, error, stackTrace);
      }
    }

    try {
      feed.subscription = snapshots(list).listen(
        (messages) {
          _inner.setAll(list, messages);
          if (!feed.first.isCompleted) feed.first.complete();
        },
        onError: failed,
      );
    } catch (error, stackTrace) {
      failed(error, stackTrace);
    }
    // A failed first snapshot is reported through fetch.
    unawaited(feed.first.future.then((_) {}, onError: (Object _) {}));
    return feed;
  }

  void _release(ListId list) {
    final feed = _feeds.remove(list);
    unawaited(feed?.subscription?.cancel());
  }

  @override
  Future<PageResult<M>> fetch(PageRequest request) async {
    await _listen(request.list).first.future;
    return _inner.page(request);
  }

  @override
  Stream<ListEvent<M>> events(ListId list) {
    late final StreamController<ListEvent<M>> controller;
    StreamSubscription<ListEvent<M>>? forward;
    controller = StreamController<ListEvent<M>>(
      onListen: () {
        forward = _inner.events(list).listen(
              controller.add,
              onError: controller.addError,
            );
        if (!_disposed) _listen(list);
      },
      onCancel: () {
        _release(list);
        return forward?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> markRead(ListId list, MessageKey upTo) =>
      _inner.markRead(list, upTo);

  /// Stops listening to every stream.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final list in _feeds.keys.toList()) {
      _release(list);
    }
    _inner.dispose();
  }
}

final class _Feed<M> {
  final Completer<void> first = Completer<void>();
  StreamSubscription<List<M>>? subscription;
}
