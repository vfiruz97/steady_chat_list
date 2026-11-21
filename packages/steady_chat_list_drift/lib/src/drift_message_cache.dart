import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

import 'codec.dart';
import 'database.dart';

/// A [MessageCache] in SQLite through drift: chats open at once after a
/// restart and work offline. On the web it uses drift's WebAssembly build,
/// and two tabs that share the database see each other's changes.
///
/// ```dart
/// final cache = DriftMessageCache<ChatMessage>(
///   SteadyCacheDatabase(driftDatabase(name: 'chat_cache')),
///   adapter: adapter,
///   codec: JsonMessageCodec(ChatMessage.fromJson, (m) => m.toJson()),
/// );
/// final hub = MessageListHub<ChatMessage>(
///     source: source, adapter: adapter, cache: cache);
/// ```
final class DriftMessageCache<M> implements MessageCache<M> {
  /// Creates a cache on [database].
  DriftMessageCache(
    this.database, {
    required this.adapter,
    required this.codec,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The SQLite database.
  final SteadyCacheDatabase database;

  /// Reads keys and dates from the app's message class.
  final MessageAdapter<M> adapter;

  /// Turns messages into bytes and back.
  final MessageCodec<M> codec;

  final DateTime Function() _clock;
  int _ownNotifications = 0;

  static const String _messages = 'messages';

  /// Closes the database.
  Future<void> close() => database.close();

  // ----------------------------------------------------------------- read

  @override
  Future<CachedList<M>?> load(ListId list, {int limit = 600}) async {
    final key = list.storageKey;
    return database.transaction(() async {
      final meta = await database.customSelect(
        'SELECT 1 FROM lists_meta WHERE list_key = ?',
        variables: [Variable<String>(key)],
      ).get();
      if (meta.isEmpty) return null;
      await database.customStatement(
        'UPDATE lists_meta SET last_opened_at = ? WHERE list_key = ?',
        [_clock().millisecondsSinceEpoch, key],
      );
      final snapshot = await _snapshot(key);
      final rows = await database.customSelect(
        'SELECT id, payload FROM messages WHERE list_key = ? '
        'ORDER BY ord DESC, local_seq DESC, id DESC LIMIT ?',
        variables: [Variable<String>(key), Variable<int>(limit)],
      ).get();
      final byId = <String, M>{
        for (final row in rows)
          row.read<String>('id'): codec.decode(row.read<Uint8List>('payload')),
      };
      if (snapshot != null) {
        // The messages around the saved position, wherever they are.
        final range = snapshot.range;
        final around = await database.customSelect(
          'SELECT id, payload FROM messages WHERE list_key = ? '
          'AND ord >= ? AND ord <= ?',
          variables: [
            Variable<String>(key),
            Variable<int>(range.first.order),
            Variable<int>(range.last.order),
          ],
        ).get();
        for (final row in around) {
          byId.putIfAbsent(
            row.read<String>('id'),
            () => codec.decode(row.read<Uint8List>('payload')),
          );
        }
      }
      final read = await database.customSelect(
        'SELECT json FROM read_state WHERE list_key = ?',
        variables: [Variable<String>(key)],
      ).getSingleOrNull();
      return CachedList<M>(
        messages: byId.values.toList(growable: false),
        segments: await _segments(key),
        readState: read == null
            ? null
            : ReadState.fromJson(_decode(read.read<String>('json'))),
        snapshot: snapshot,
      );
    });
  }

  Future<ViewportSnapshot?> _snapshot(String key) async {
    final row = await database.customSelect(
      'SELECT json FROM snapshots WHERE list_key = ?',
      variables: [Variable<String>(key)],
    ).getSingleOrNull();
    if (row == null) return null;
    try {
      return ViewportSnapshot.fromJson(_decode(row.read<String>('json')));
    } catch (_) {
      return null; // written by another version
    }
  }

  Future<List<Segment>> _segments(String key) async {
    final rows = await database.customSelect(
      'SELECT * FROM segments WHERE list_key = ? '
      'ORDER BY first_ord, first_seq, first_id',
      variables: [Variable<String>(key)],
    ).get();
    return [
      for (final row in rows)
        Segment(
          first: MessageKey(
            order: row.read<int>('first_ord'),
            localSeq: row.read<int>('first_seq'),
            id: row.read<String>('first_id'),
          ),
          last: MessageKey(
            order: row.read<int>('last_ord'),
            localSeq: row.read<int>('last_seq'),
            id: row.read<String>('last_id'),
          ),
          reachedOldest: row.read<int>('reached_oldest') != 0,
          reachedNewest: row.read<int>('reached_newest') != 0,
        ),
    ];
  }

  static Map<String, Object?> _decode(String json) =>
      (jsonDecode(json) as Map).cast<String, Object?>();

  // ---------------------------------------------------------------- write

  @override
  Future<void> applyPage(
    PageRequest request,
    PageResult<M> result, {
    required List<Segment> segments,
  }) =>
      _write(() async {
        final key = request.list.storageKey;
        await _touch(key);
        for (final message in result.items) {
          await _put(key, message);
        }
        await _replaceSegments(key, segments);
        final read = result.readState;
        if (read != null) await _saveReadState(key, read);
      });

  @override
  Future<void> applyEvents(
    List<ListEvent<M>> events, {
    required Map<ListId, List<Segment>> segments,
  }) =>
      _write(() async {
        for (final event in events) {
          final key = event.list.storageKey;
          await _touch(key);
          switch (event) {
            case MessagesAdded<M>(:final items) ||
                  MessagesUpdated<M>(:final items):
              for (final message in items) {
                await _put(key, message);
              }
            case MessagesDeleted<M>(:final ids):
              for (final id in ids) {
                await _delete(key, id);
              }
            case LocalAcked<M>(:final localId, :final serverMessage):
              await _delete(key, localId);
              await _put(key, serverMessage);
            case ReadStateChanged<M>(:final state):
              await _saveReadState(key, state);
            case HistoryCleared<M>(:final upTo):
              await database.customStatement(
                'DELETE FROM messages WHERE list_key = ? AND '
                '(ord < ? OR (ord = ? AND local_seq <= ?))',
                [key, upTo.order, upTo.order, upTo.localSeq],
              );
            case LocalFailed<M>() || PinnedChanged<M>() || TypingChanged<M>():
              break; // not persisted
          }
        }
        for (final entry in segments.entries) {
          await _replaceSegments(entry.key.storageKey, entry.value);
        }
      });

  @override
  Future<void> saveSnapshot(ListId list, ViewportSnapshot snapshot) =>
      _write(() async {
        await _touch(list.storageKey);
        await database.customStatement(
          'INSERT OR REPLACE INTO snapshots (list_key, json, saved_at) '
          'VALUES (?, ?, ?)',
          [
            list.storageKey,
            jsonEncode(snapshot.toJson()),
            snapshot.savedAt.millisecondsSinceEpoch,
          ],
        );
      });

  @override
  Future<void> evict(EvictionPolicy policy) => _write(() async {
        final cutoff = _clock()
            .subtract(policy.dropListsUnopenedFor)
            .millisecondsSinceEpoch;
        final old = await database.customSelect(
          'SELECT list_key FROM lists_meta WHERE last_opened_at < ?',
          variables: [Variable<int>(cutoff)],
        ).get();
        for (final row in old) {
          await _dropList(row.read<String>('list_key'));
        }
        final lists = await database
            .customSelect(
              'SELECT list_key FROM lists_meta ORDER BY last_opened_at',
            )
            .get();
        for (final row in lists) {
          await _trimList(row.read<String>('list_key'), policy);
        }
        // The global cap: least recently opened lists go first.
        var total = (await database
                .customSelect('SELECT COUNT(*) AS n FROM messages')
                .getSingle())
            .read<int>('n');
        for (final row in lists) {
          if (total <= policy.maxMessages) break;
          final key = row.read<String>('list_key');
          final count = await _count(key);
          await _dropList(key);
          total -= count;
        }
      });

  Future<int> _count(String key) async => (await database.customSelect(
        'SELECT COUNT(*) AS n FROM messages WHERE list_key = ?',
        variables: [Variable<String>(key)],
      ).getSingle())
          .read<int>('n');

  /// Keeps the newest messages of a list and the ones around its saved
  /// position; recomputes the segments for what is left.
  Future<void> _trimList(String key, EvictionPolicy policy) async {
    if (await _count(key) <= policy.keepNewestPerList) return;
    final rows = await database.customSelect(
      'SELECT id, ord, local_seq FROM messages WHERE list_key = ? '
      'ORDER BY ord, local_seq, id',
      variables: [Variable<String>(key)],
    ).get();
    final keys = [
      for (final row in rows)
        MessageKey(
          order: row.read<int>('ord'),
          localSeq: row.read<int>('local_seq'),
          id: row.read<String>('id'),
        ),
    ];
    final range = (await _snapshot(key))?.range;
    final newestFrom = keys.length - policy.keepNewestPerList;
    final kept = <MessageKey>[];
    final removed = <MessageKey>[];
    for (var i = 0; i < keys.length; i++) {
      final keep = i >= newestFrom || (range?.contains(keys[i]) ?? false);
      (keep ? kept : removed).add(keys[i]);
    }
    for (final gone in removed) {
      await _delete(key, gone.id);
    }
    await _replaceSegments(
      key,
      clampSegments(await _segments(key), kept: kept, removed: removed),
    );
  }

  @override
  Future<void> clear([ListId? list]) => _write(() async {
        if (list != null) {
          await _dropList(list.storageKey);
          return;
        }
        for (final table in SteadyCacheDatabase.tableNames) {
          await database.customStatement('DELETE FROM $table');
        }
      });

  Future<void> _dropList(String key) async {
    for (final table in SteadyCacheDatabase.tableNames) {
      await database
          .customStatement('DELETE FROM $table WHERE list_key = ?', [key]);
    }
  }

  Future<void> _touch(String key) => database.customStatement(
        'INSERT OR IGNORE INTO lists_meta (list_key, last_opened_at) '
        'VALUES (?, ?)',
        [key, _clock().millisecondsSinceEpoch],
      );

  Future<void> _put(String key, M message) {
    final k = adapter.keyOf(message);
    return database.customStatement(
      'INSERT OR REPLACE INTO messages (list_key, id, ord, local_seq, '
      'date_ms, group_id, sender_id, is_outgoing, mentions_me, payload) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        key,
        k.id,
        k.order,
        k.localSeq,
        adapter.dateOf(message).millisecondsSinceEpoch,
        adapter.groupIdOf(message),
        adapter.senderIdOf(message),
        if (adapter.isOutgoing(message)) 1 else 0,
        if (adapter.mentionsMe(message)) 1 else 0,
        codec.encode(message),
      ],
    );
  }

  Future<void> _delete(String key, String id) => database.customStatement(
        'DELETE FROM messages WHERE list_key = ? AND id = ?',
        [key, id],
      );

  Future<void> _saveReadState(String key, ReadState state) =>
      database.customStatement(
        'INSERT OR REPLACE INTO read_state (list_key, json) VALUES (?, ?)',
        [key, jsonEncode(state.toJson())],
      );

  Future<void> _replaceSegments(String key, List<Segment> segments) async {
    await database
        .customStatement('DELETE FROM segments WHERE list_key = ?', [key]);
    for (final segment in segments) {
      await database.customStatement(
        'INSERT INTO segments (list_key, first_ord, first_seq, first_id, '
        'last_ord, last_seq, last_id, reached_oldest, reached_newest) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          key,
          segment.first.order,
          segment.first.localSeq,
          segment.first.id,
          segment.last.order,
          segment.last.localSeq,
          segment.last.id,
          if (segment.reachedOldest) 1 else 0,
          if (segment.reachedNewest) 1 else 0,
        ],
      );
    }
  }

  /// One transaction per page or event batch (§8.3), then a notification
  /// for the other tabs.
  Future<void> _write(Future<void> Function() body) async {
    await database.transaction(body);
    _ownNotifications++;
    database.notifyUpdates({const TableUpdate(_messages)});
  }

  // ---------------------------------------------------------------- watch

  @override
  Stream<CacheChange> watch() => database
          .tableUpdates(const TableUpdateQuery.onTableName(_messages))
          .where((_) {
        // Our own writes come back once each; everything else was written
        // by another tab or isolate sharing the database.
        if (_ownNotifications > 0) {
          _ownNotifications--;
          return false;
        }
        return true;
      }).map((_) => const CacheChange());
}
