# Example

The complete demo app (twelve demos, a simulated server with a 10,000,000-message chat, offline cache, search, jumps) is in the repository: <https://github.com/vfiruz97/steady_chat_list/tree/main/example>.

The smallest chat:

```dart
import 'package:flutter/widgets.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

class Message {
  const Message(this.id, this.text, this.sentAt, {this.mine = false});

  final String id;
  final String text;
  final DateTime sentAt;
  final bool mine;
}

final adapter = MessageAdapter<Message>.from(
  key: (m) => MessageKey(order: m.sentAt.microsecondsSinceEpoch, id: m.id),
  date: (m) => m.sentAt,
  isOutgoing: (m) => m.mine,
);

class Chat extends StatelessWidget {
  const Chat({super.key, required this.messages});

  final List<Message> messages;

  @override
  Widget build(BuildContext context) => SteadyChatList<Message>.list(
        messages: messages,
        adapter: adapter,
        itemBuilder: (context, message, info) => Align(
          alignment:
              message.mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(message.text),
          ),
        ),
      );
}
```
