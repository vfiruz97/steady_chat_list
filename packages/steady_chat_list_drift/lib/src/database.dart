import 'package:drift/drift.dart';

/// The SQLite database of the message cache. It has no generated code: the
/// schema is plain SQL, so it works with every drift 2.x version.
///
/// Create it from any drift executor:
///
/// ```dart
/// // Flutter (all platforms, including the web), with drift_flutter:
/// final db = SteadyCacheDatabase(driftDatabase(name: 'chat_cache'));
/// // Dart VM / tests:
/// final db = SteadyCacheDatabase(NativeDatabase.memory());
/// ```
class SteadyCacheDatabase extends GeneratedDatabase {
  /// Opens the cache database on [executor].
  SteadyCacheDatabase(super.executor);

  /// The schema version this code writes.
  static const int currentSchemaVersion = 1;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) => _rebuild(),
        // Version 1 is the first one; later versions add their steps here.
        // A cache can always be rebuilt from the server, so a layout this
        // code doesn't know is dropped instead of migrated.
        onUpgrade: (migrator, from, to) => _rebuild(),
      );

  /// Creates the schema from scratch, removing whatever tables an older or
  /// damaged file still has.
  Future<void> _rebuild() async {
    for (final table in tableNames) {
      await customStatement('DROP TABLE IF EXISTS $table');
    }
    for (final statement in schemaV1) {
      await customStatement(statement);
    }
  }

  /// Every table of the cache.
  static const List<String> tableNames = [
    'messages',
    'segments',
    'read_state',
    'snapshots',
    'lists_meta',
  ];

  /// The statements that create schema version 1.
  static const List<String> schemaV1 = [
    '''
CREATE TABLE messages (
  list_key TEXT NOT NULL,
  id TEXT NOT NULL,
  ord INTEGER NOT NULL,
  local_seq INTEGER NOT NULL DEFAULT 0,
  date_ms INTEGER NOT NULL,
  group_id TEXT,
  sender_id TEXT,
  is_outgoing INTEGER NOT NULL DEFAULT 0,
  mentions_me INTEGER NOT NULL DEFAULT 0,
  payload BLOB NOT NULL,
  PRIMARY KEY (list_key, id)
)''',
    'CREATE INDEX messages_order ON messages (list_key, ord, local_seq, id)',
    'CREATE INDEX messages_date ON messages (list_key, date_ms)',
    '''
CREATE TABLE segments (
  list_key TEXT NOT NULL,
  first_ord INTEGER NOT NULL,
  first_seq INTEGER NOT NULL,
  first_id TEXT NOT NULL,
  last_ord INTEGER NOT NULL,
  last_seq INTEGER NOT NULL,
  last_id TEXT NOT NULL,
  reached_oldest INTEGER NOT NULL,
  reached_newest INTEGER NOT NULL
)''',
    'CREATE INDEX segments_list ON segments (list_key)',
    'CREATE TABLE read_state (list_key TEXT PRIMARY KEY, json TEXT NOT NULL)',
    '''
CREATE TABLE snapshots (
  list_key TEXT PRIMARY KEY,
  json TEXT NOT NULL,
  saved_at INTEGER NOT NULL
)''',
    '''
CREATE TABLE lists_meta (
  list_key TEXT PRIMARY KEY,
  last_opened_at INTEGER NOT NULL
)''',
  ];
}
