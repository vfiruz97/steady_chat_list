/// Pure Dart core of `steady_chat_list`: message keys, the segmented message
/// store, paging and event models. No Flutter imports.
///
/// ```dart
/// import 'package:steady_chat_list_core/steady_chat_list_core.dart';
///
/// final store = MessageStore<ChatMessage>(adapter: const ChatMessageAdapter());
/// ```
library;

export 'src/hub.dart';
export 'src/list_event.dart';
export 'src/list_store.dart';
export 'src/message_key.dart';
export 'src/message_store.dart';
export 'src/models.dart';
export 'src/paging.dart';
export 'src/policies.dart';
export 'src/simple_sources.dart';
export 'src/source.dart';
export 'src/store_delta.dart';
