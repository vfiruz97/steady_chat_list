/// Drift (SQLite) message cache for `steady_chat_list`.
///
/// ```dart
/// import 'package:steady_chat_list_drift/steady_chat_list_drift.dart';
///
/// final cache = DriftMessageCache<ChatMessage>(
///   SteadyCacheDatabase(driftDatabase(name: 'chat_cache')),
///   adapter: adapter,
///   codec: JsonMessageCodec(ChatMessage.fromJson, (m) => m.toJson()),
/// );
/// ```
library;

export 'src/codec.dart';
export 'src/database.dart';
export 'src/drift_message_cache.dart';
