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

  // No transaction around the reads, and every write is one batch (one
  // request to the database): a browser tab that is frozen or closed in
  // the middle can then never leave a transaction open. With drift on the
  // web all tabs share one connection, and an open transaction would make
  // every other tab wait forever.

  @override
  Future<CachedList<M>?> load(ListId list, {int limit = 600}) async {
    final key = list.storageKey;
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
  }) {
    final key = request.list.storageKey;
    final out = <_Statement>[];
    _touch(out, key);
    for (final message in result.items) {
      _put(out, key, message);
    }
    _replaceSegments(out, key, segments);
    final read = result.readState;
    if (read != null) _saveReadState(out, key, read);
    return _write(out);
  }

  @override
  Future<void> applyEvents(
    List<ListEvent<M>> events, {
    required Map<ListId, List<Segment>> segments,
  }) {
    final out = <_Statement>[];
    for (final event in events) {
      final key = event.list.storageKey;
      _touch(out, key);
      switch (event) {
        case MessagesAdded<M>(:final items) || MessagesUpdated<M>(:final items):
          for (final message in items) {
            _put(out, key, message);
          }
        case MessagesDeleted<M>(:final ids):
          for (final id in ids) {
            _delete(out, key, id);
          }
        case LocalAcked<M>(:final localId, :final serverMessage):
          _delete(out, key, localId);
          _put(out, key, serverMessage);
        case ReadStateChanged<M>(:final state):
          _saveReadState(out, key, state);
        case HistoryCleared<M>(:final upTo):
          out.add((
            'DELETE FROM messages WHERE list_key = ? AND '
                '(ord < ? OR (ord = ? AND local_seq <= ?))',
            [key, upTo.order, upTo.order, upTo.localSeq],
          ));
        case LocalFailed<M>() || PinnedChanged<M>() || TypingChanged<M>():
          break; // not persisted
      }
    }
    for (final entry in segments.entries) {
      _replaceSegments(out, entry.key.storageKey, entry.value);
    }
    return _write(out);
  }

  @override
  Future<void> saveSnapshot(ListId list, ViewportSnapshot snapshot) {
    final out = <_Statement>[];
    _touch(out, list.storageKey);
    out.add((
      'INSERT OR REPLACE INTO snapshots (list_key, json, saved_at) '
          'VALUES (?, ?, ?)',
      [
        list.storageKey,
        jsonEncode(snapshot.toJson()),
        snapshot.savedAt.millisecondsSinceEpoch,
      ],
    ));
    return _write(out);
  }

  @override
  Future<void> evict(EvictionPolicy policy) async {
    // Read what there is, decide, then write everything in one batch.
    final out = <_Statement>[];
    final cutoff =
        _clock().subtract(policy.dropListsUnopenedFor).millisecondsSinceEpoch;
    final lists = await database
        .customSelect(
          'SELECT list_key, last_opened_at FROM lists_meta '
          'ORDER BY last_opened_at',
        )
        .get();
    final counts = <String, int>{
      for (final row in await database
          .customSelect(
            'SELECT list_key, COUNT(*) AS n FROM messages GROUP BY list_key',
          )
          .get())
        row.read<String>('list_key'): row.read<int>('n'),
    };
    final kept = <String>[]; // least recently opened first
    for (final row in lists) {
      final key = row.read<String>('list_key');
      if (row.read<int>('last_opened_at') < cutoff) {
        _dropList(out, key);
      } else {
        counts[key] = await _trimList(out, key, policy, counts[key] ?? 0);
        kept.add(key);
      }
    }
    // The global cap: least recently opened lists go first.
    var total = 0;
    for (final key in kept) {
      total += counts[key] ?? 0;
    }
    for (final key in kept) {
      if (total <= policy.maxMessages) break;
      _dropList(out, key);
      total -= counts[key] ?? 0;
    }
    await _write(out);
  }

  /// Keeps the newest messages of a list and the ones around its saved
  /// position, and recomputes the segments for what is left. Returns how
  /// many messages stay.
  Future<int> _trimList(
    List<_Statement> out,
    String key,
    EvictionPolicy policy,
    int count,
  ) async {
    if (count <= policy.keepNewestPerList) return count;
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
      _delete(out, key, gone.id);
    }
    _replaceSegments(
      out,
      key,
      clampSegments(await _segments(key), kept: kept, removed: removed),
    );
    return kept.length;
  }

  @override
  Future<void> clear([ListId? list]) {
    final out = <_Statement>[];
    if (list != null) {
      _dropList(out, list.storageKey);
    } else {
      for (final table in SteadyCacheDatabase.tableNames) {
        out.add(('DELETE FROM $table', const []));
      }
    }
    return _write(out);
  }

  void _dropList(List<_Statement> out, String key) {
    for (final table in SteadyCacheDatabase.tableNames) {
      out.add(('DELETE FROM $table WHERE list_key = ?', [key]));
    }
  }

  void _touch(List<_Statement> out, String key) => out.add((
        'INSERT OR IGNORE INTO lists_meta (list_key, last_opened_at) '
            'VALUES (?, ?)',
        [key, _clock().millisecondsSinceEpoch],
      ));

  void _put(List<_Statement> out, String key, M message) {
    final k = adapter.keyOf(message);
    out.add((
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
    ));
  }

  void _delete(List<_Statement> out, String key, String id) => out.add((
        'DELETE FROM messages WHERE list_key = ? AND id = ?',
        [key, id],
      ));

  void _saveReadState(List<_Statement> out, String key, ReadState state) =>
      out.add((
        'INSERT OR REPLACE INTO read_state (list_key, json) VALUES (?, ?)',
        [key, jsonEncode(state.toJson())],
      ));

  void _replaceSegments(
    List<_Statement> out,
    String key,
    List<Segment> segments,
  ) {
    out.add(('DELETE FROM segments WHERE list_key = ?', [key]));
    for (final segment in segments) {
      out.add((
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
      ));
    }
  }

  /// All statements of a page, an event batch or an eviction go to the
  /// database as one atomic request (§8.3), followed by a notification for
  /// the other tabs.
  ///
  /// The request carries its own BEGIN and COMMIT. A drift transaction or
  /// batch is several requests (begin, statements, commit); a browser tab
  /// that is frozen between two of them, for example when it goes into the
  /// back/forward cache, would keep the transaction open, and the other
  /// tabs, which share the connection, would wait forever.
  Future<void> _write(List<_Statement> statements) async {
    if (statements.isEmpty) return;
    final sql = <String>[];
    final indexOf = <String, int>{};
    final arguments = <ArgumentsForBatchedStatement>[];
    void add(String statement, List<Object?> values) {
      final index = indexOf[statement] ??= () {
        sql.add(statement);
        return sql.length - 1;
      }();
      arguments.add(ArgumentsForBatchedStatement(index, values));
    }

    add('BEGIN IMMEDIATE', const []);
    for (final (statement, values) in statements) {
      add(statement, values);
    }
    add('COMMIT', const []);
    await database.doWhenOpened((executor) async {
      try {
        await executor.runBatched(BatchedStatements(sql, arguments));
      } catch (_) {
        // A statement failed after BEGIN: leave no transaction behind.
        try {
          await executor.runCustom('ROLLBACK');
        } catch (_) {
          // There was none (BEGIN itself failed).
        }
        rethrow;
      }
    });
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

/// One SQL statement with its arguments.
typedef _Statement = (String sql, List<Object?> arguments);
