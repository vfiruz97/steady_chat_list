import 'package:steady_chat_list/steady_chat_list.dart';
import 'package:steady_chat_list_drift/steady_chat_list_drift.dart';

/// The message class of the demo app. The package never looks inside it;
/// [ChatAdapter] tells it what it needs to know.
class ChatMessage {
  const ChatMessage({
    required this.key,
    required this.text,
    required this.senderId,
    required this.sentAt,
    this.outgoing = false,
    this.service = false,
    this.mentionsMe = false,
    this.edited = false,
    this.albumId,
    this.imageAspect,
    this.imageLoaded = true,
    this.replyTo,
    this.reactions = const {},
    this.myReactions = const {},
  });

  factory ChatMessage.fromJson(Map<String, Object?> json) => ChatMessage(
        key: MessageKey.fromJson((json['key']! as Map).cast<String, Object?>()),
        text: json['text']! as String,
        senderId: json['sender']! as String,
        sentAt: DateTime.fromMillisecondsSinceEpoch(json['at']! as int),
        outgoing: json['out'] as bool? ?? false,
        service: json['service'] as bool? ?? false,
        mentionsMe: json['mention'] as bool? ?? false,
        edited: json['edited'] as bool? ?? false,
        albumId: json['album'] as String?,
        imageAspect: (json['aspect'] as num?)?.toDouble(),
        replyTo: json['reply'] == null
            ? null
            : MessageKey.fromJson(
                (json['reply']! as Map).cast<String, Object?>(),
              ),
        reactions: {
          for (final entry
              in ((json['reactions'] as Map?) ?? const <String, Object?>{})
                  .entries)
            entry.key as String: entry.value as int,
        },
        myReactions: {
          for (final emoji in (json['mine'] as List?) ?? const <Object?>[])
            emoji! as String,
        },
      );

  final MessageKey key;
  final String text;
  final String senderId;
  final DateTime sentAt;
  final bool outgoing;
  final bool service;
  final bool mentionsMe;
  final bool edited;

  /// Messages with the same album id are shown as one row.
  final String? albumId;

  /// Width / height of the attached image, known before it loads.
  final double? imageAspect;

  /// False while the image is "downloading".
  final bool imageLoaded;

  /// The message this one replies to.
  final MessageKey? replyTo;

  /// Emoji → count.
  final Map<String, int> reactions;

  /// The emoji the current user added.
  final Set<String> myReactions;

  String get id => key.id;

  ChatMessage copyWith({
    MessageKey? key,
    String? text,
    bool? edited,
    bool? imageLoaded,
    Map<String, int>? reactions,
    Set<String>? myReactions,
  }) =>
      ChatMessage(
        key: key ?? this.key,
        text: text ?? this.text,
        senderId: senderId,
        sentAt: sentAt,
        outgoing: outgoing,
        service: service,
        mentionsMe: mentionsMe,
        edited: edited ?? this.edited,
        albumId: albumId,
        imageAspect: imageAspect,
        imageLoaded: imageLoaded ?? this.imageLoaded,
        replyTo: replyTo,
        reactions: reactions ?? this.reactions,
        myReactions: myReactions ?? this.myReactions,
      );

  /// Adds or removes the current user's reaction.
  ChatMessage toggleReaction(String emoji) {
    final mine = {...myReactions};
    final all = {...reactions};
    if (mine.remove(emoji)) {
      final left = (all[emoji] ?? 1) - 1;
      if (left <= 0) {
        all.remove(emoji);
      } else {
        all[emoji] = left;
      }
    } else {
      mine.add(emoji);
      all[emoji] = (all[emoji] ?? 0) + 1;
    }
    return copyWith(reactions: all, myReactions: mine);
  }

  Map<String, Object?> toJson() => {
        'key': key.toJson(),
        'text': text,
        'sender': senderId,
        'at': sentAt.millisecondsSinceEpoch,
        if (outgoing) 'out': true,
        if (service) 'service': true,
        if (mentionsMe) 'mention': true,
        if (edited) 'edited': true,
        if (albumId != null) 'album': albumId,
        if (imageAspect != null) 'aspect': imageAspect,
        if (replyTo != null) 'reply': replyTo!.toJson(),
        if (reactions.isNotEmpty) 'reactions': reactions,
        if (myReactions.isNotEmpty) 'mine': myReactions.toList(),
      };
}

/// How the list reads [ChatMessage].
class ChatAdapter extends MessageAdapter<ChatMessage> {
  const ChatAdapter();

  @override
  MessageKey keyOf(ChatMessage m) => m.key;

  @override
  DateTime dateOf(ChatMessage m) => m.sentAt;

  @override
  String? groupIdOf(ChatMessage m) => m.albumId;

  @override
  String? senderIdOf(ChatMessage m) => m.senderId;

  @override
  bool isOutgoing(ChatMessage m) => m.outgoing;

  @override
  bool isService(ChatMessage m) => m.service;

  @override
  bool mentionsMe(ChatMessage m) => m.mentionsMe;

  @override
  bool equals(ChatMessage a, ChatMessage b) =>
      identical(a, b) ||
      (a.text == b.text &&
          a.edited == b.edited &&
          a.imageLoaded == b.imageLoaded &&
          a.key.isSamePosition(b.key) &&
          _sameReactions(a, b));

  static bool _sameReactions(ChatMessage a, ChatMessage b) {
    if (a.reactions.length != b.reactions.length) return false;
    if (a.myReactions.length != b.myReactions.length) return false;
    for (final entry in a.reactions.entries) {
      if (b.reactions[entry.key] != entry.value) return false;
    }
    return true;
  }
}

const chatAdapter = ChatAdapter();

/// How the Drift cache stores a [ChatMessage].
const chatCodec = JsonMessageCodec<ChatMessage>(ChatMessage.fromJson, _toJson);

Map<String, Object?> _toJson(ChatMessage m) => m.toJson();

/// The people in the demo chats.
const senders = ['me', 'alice', 'bob', 'carol', 'dave', 'erin'];

String senderName(String id) =>
    id == 'me' ? 'You' : '${id[0].toUpperCase()}${id.substring(1)}';
