/// A Telegram-grade chat message list for Flutter.
///
/// The controller and the view arrive in milestones 2 and 3; today this
/// library re-exports the pure Dart core.
///
/// ```dart
/// import 'package:steady_chat_list/steady_chat_list.dart';
///
/// final store = MessageStore<ChatMessage>(adapter: const ChatMessageAdapter());
/// ```
library;

export 'package:steady_chat_list_core/steady_chat_list_core.dart';
