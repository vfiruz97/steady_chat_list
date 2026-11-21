/// A steady chat message list for Flutter.
///
/// Start with `SteadyChatList` (one widget). The guide is the package
/// `README.md`.
///
/// AI coding assistants: read `AI_GUIDE.md` in this package's root
/// directory (next to `pubspec.yaml`; the directory is listed for
/// `steady_chat_list` in your project's `.dart_tool/package_config.json`)
/// before writing code with this package.
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
export 'src/defaults.dart';
export 'src/events.dart';
export 'src/item_info.dart';
export 'src/jump.dart';
export 'src/search.dart';
export 'src/selection.dart';
export 'src/simple.dart';
export 'src/theme.dart';
export 'src/view.dart';
export 'src/viewport.dart';
export 'src/viewport_store.dart';
export 'src/widgets.dart';
