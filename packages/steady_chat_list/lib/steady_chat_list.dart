/// A Telegram-grade chat message list for Flutter.
///
/// ```dart
/// import 'package:steady_chat_list/steady_chat_list.dart';
///
/// final hub = MessageListHub<ChatMessage>(
///   source: MyBackendSource(api, socket),
///   adapter: const ChatMessageAdapter(),
/// );
/// final controller = MessageListController<ChatMessage>(
///   hub: hub,
///   list: ListId(chat.id),
/// )..open();
/// ```
library;

export 'package:steady_chat_list_core/steady_chat_list_core.dart';

export 'src/anchored_scroll_position.dart';
export 'src/config.dart';
export 'src/controller.dart';
export 'src/events.dart';
export 'src/item_info.dart';
export 'src/view.dart';
export 'src/viewport.dart';
