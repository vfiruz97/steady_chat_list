// A chat held in memory, read through the hub: no Flutter needed.
//
//   dart run example/example.dart
//
// ignore_for_file: avoid_print
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

final class ChatMessage {
  const ChatMessage(this.id, this.text, this.sentAt);
  final String id;
  final String text;
  final DateTime sentAt;
}

Future<void> main() async {
  // 1. Tell the list how to read your message class.
  final adapter = MessageAdapter<ChatMessage>.from(
    key: (m) => MessageKey(order: m.sentAt.microsecondsSinceEpoch, id: m.id),
    date: (m) => m.sentAt,
  );

  // 2. A source that simply has the messages. With a backend, implement
  //    MessageSource and answer page requests instead.
  const chat = ListId('chat-1');
  final start = DateTime.utc(2025, 1, 1, 9);
  final source = ListMessageSource<ChatMessage>(adapter: adapter);
  source.setAll(chat, [
    for (var i = 0; i < 200; i++)
      ChatMessage('$i', 'Message $i', start.add(Duration(minutes: i))),
  ]);

  // 3. One hub per app. It owns the store of every open list.
  final hub = MessageListHub<ChatMessage>(source: source, adapter: adapter);
  final store = hub.attach(chat);

  // 4. Load the newest page.
  await hub.fetch(
    PageRequest(
      list: chat,
      direction: PageDirection.latest,
      limit: 40,
    ),
  );
  print('loaded ${store.length} messages');
  print('live segment: ${store.liveSegment}');

  // 5. A new message arrives; the store follows the source.
  source.upsert(chat, [
    ChatMessage('200', 'Hello', start.add(const Duration(minutes: 200))),
  ]);
  await Future<void>.delayed(Duration.zero);
  print('after a new message: ${store.length} messages');

  hub.dispose();
}
