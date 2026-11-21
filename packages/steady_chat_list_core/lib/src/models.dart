import 'package:meta/meta.dart';

import 'message_key.dart';

/// Identity of one message sequence: a chat, a thread, a topic or a comment
/// section.
///
/// ```dart
/// const chat = ListId('chat-1');
/// const thread = ListId('chat-1', 'thread-9');
/// assert(thread.storageKey == 'chat-1/thread-9');
/// ```
@immutable
final class ListId {
  /// Creates a list id for [chatId] and an optional [threadId].
  const ListId(this.chatId, [this.threadId]);

  /// The chat this list belongs to.
  final String chatId;

  /// The thread, topic or comment section inside the chat, if any.
  final String? threadId;

  /// Key used by caches and viewport stores.
  String get storageKey => threadId == null ? chatId : '$chatId/$threadId';

  @override
  bool operator ==(Object other) =>
      other is ListId && other.chatId == chatId && other.threadId == threadId;

  @override
  int get hashCode => Object.hash(chatId, threadId);

  @override
  String toString() => 'ListId($storageKey)';
}

/// How the package reads the app's message class. Only [keyOf] and [dateOf]
/// are required.
///
/// ```dart
/// class ChatMessageAdapter extends MessageAdapter<ChatMessage> {
///   const ChatMessageAdapter();
///   @override
///   MessageKey keyOf(ChatMessage m) => MessageKey(order: m.id, id: '${m.id}');
///   @override
///   DateTime dateOf(ChatMessage m) => m.sentAt;
///   @override
///   String? senderIdOf(ChatMessage m) => m.authorId;
/// }
/// ```
abstract class MessageAdapter<M> {
  /// Const constructor for subclasses.
  const MessageAdapter();

  /// An adapter made of functions, for when a subclass is too much.
  ///
  /// ```dart
  /// final adapter = MessageAdapter<ChatMessage>.from(
  ///   key: (m) => MessageKey(order: m.sentAt.microsecondsSinceEpoch, id: m.id),
  ///   date: (m) => m.sentAt,
  ///   isOutgoing: (m) => m.authorId == myId,
  /// );
  /// ```
  const factory MessageAdapter.from({
    required MessageKey Function(M message) key,
    required DateTime Function(M message) date,
    String? Function(M message)? groupId,
    String? Function(M message)? senderId,
    bool Function(M message)? isOutgoing,
    bool Function(M message)? isService,
    bool Function(M message)? mentionsMe,
    bool Function(M a, M b)? equals,
  }) = _FunctionAdapter<M>;

  /// The sortable identity of [m].
  MessageKey keyOf(M m);

  /// When [m] was sent. Used for day grouping and jump-to-date only, never
  /// for sorting.
  DateTime dateOf(M m);

  /// Album id: messages with the same group id form one row.
  String? groupIdOf(M m) => null;

  /// Sender id, used for sender grouping.
  String? senderIdOf(M m) => null;

  /// Whether the current user sent [m]. Outgoing messages are never unread.
  bool isOutgoing(M m) => false;

  /// Whether [m] is a service row ("Alice joined"). Service rows break
  /// sender groups and are never the first unread message.
  bool isService(M m) => false;

  /// Whether [m] mentions the current user. Drives mention navigation when
  /// the server doesn't list unread mentions.
  bool mentionsMe(M m) => false;

  /// Whether [a] and [b] render the same. An item rebuilds only when this
  /// returns false.
  bool equals(M a, M b) => a == b;
}

final class _FunctionAdapter<M> extends MessageAdapter<M> {
  const _FunctionAdapter({
    required MessageKey Function(M message) key,
    required DateTime Function(M message) date,
    String? Function(M message)? groupId,
    String? Function(M message)? senderId,
    bool Function(M message)? isOutgoing,
    bool Function(M message)? isService,
    bool Function(M message)? mentionsMe,
    bool Function(M a, M b)? equals,
  })  : _key = key,
        _date = date,
        _groupId = groupId,
        _senderId = senderId,
        _isOutgoing = isOutgoing,
        _isService = isService,
        _mentionsMe = mentionsMe,
        _equals = equals;

  final MessageKey Function(M message) _key;
  final DateTime Function(M message) _date;
  final String? Function(M message)? _groupId;
  final String? Function(M message)? _senderId;
  final bool Function(M message)? _isOutgoing;
  final bool Function(M message)? _isService;
  final bool Function(M message)? _mentionsMe;
  final bool Function(M a, M b)? _equals;

  @override
  MessageKey keyOf(M m) => _key(m);

  @override
  DateTime dateOf(M m) => _date(m);

  @override
  String? groupIdOf(M m) => _groupId?.call(m);

  @override
  String? senderIdOf(M m) => _senderId?.call(m);

  @override
  bool isOutgoing(M m) => _isOutgoing?.call(m) ?? false;

  @override
  bool isService(M m) => _isService?.call(m) ?? false;

  @override
  bool mentionsMe(M m) => _mentionsMe?.call(m) ?? false;

  @override
  bool equals(M a, M b) => _equals?.call(a, b) ?? a == b;
}

/// Read markers and unread counters of a list.
///
/// ```dart
/// const state = ReadState(
///   lastReadInbox: MessageKey(order: 120, id: '120'),
///   unreadCount: 18,
/// );
/// ```
@immutable
final class ReadState {
  /// Creates a read state. Everything defaults to "nothing unread".
  const ReadState({
    this.lastReadInbox,
    this.lastReadOutbox,
    this.unreadCount = 0,
    this.unreadMentions = const [],
    this.unreadReactions = const [],
  });

  /// Reads a state written by [toJson].
  ///
  /// ```dart
  /// final state = ReadState.fromJson(const ReadState(unreadCount: 3).toJson());
  /// ```
  factory ReadState.fromJson(Map<String, Object?> json) => ReadState(
        lastReadInbox: _key(json['in']),
        lastReadOutbox: _key(json['out']),
        unreadCount: (json['n'] as num?)?.toInt() ?? 0,
        unreadMentions: _keys(json['m']),
        unreadReactions: _keys(json['r']),
      );

  /// Nothing read, nothing unread.
  static const ReadState empty = ReadState();

  /// Last incoming message read by the current user.
  final MessageKey? lastReadInbox;

  /// Last outgoing message read by the peer (for checkmarks).
  final MessageKey? lastReadOutbox;

  /// Number of unread incoming messages.
  final int unreadCount;

  /// Keys of unread messages that mention the current user.
  final List<MessageKey> unreadMentions;

  /// Keys of own messages with unread reactions.
  final List<MessageKey> unreadReactions;

  /// A copy with the given fields replaced.
  ///
  /// ```dart
  /// final next = ReadState.empty.copyWith(unreadCount: 2);
  /// ```
  ReadState copyWith({
    MessageKey? lastReadInbox,
    MessageKey? lastReadOutbox,
    int? unreadCount,
    List<MessageKey>? unreadMentions,
    List<MessageKey>? unreadReactions,
  }) =>
      ReadState(
        lastReadInbox: lastReadInbox ?? this.lastReadInbox,
        lastReadOutbox: lastReadOutbox ?? this.lastReadOutbox,
        unreadCount: unreadCount ?? this.unreadCount,
        unreadMentions: unreadMentions ?? this.unreadMentions,
        unreadReactions: unreadReactions ?? this.unreadReactions,
      );

  /// The same state with [unreadMentions] and [unreadReactions] sorted
  /// oldest first. Returns `this` when they already are.
  ReadState normalized() {
    if (_isSorted(unreadMentions) && _isSorted(unreadReactions)) return this;
    return ReadState(
      lastReadInbox: lastReadInbox,
      lastReadOutbox: lastReadOutbox,
      unreadCount: unreadCount,
      unreadMentions: [...unreadMentions]..sort(),
      unreadReactions: [...unreadReactions]..sort(),
    );
  }

  /// A JSON-safe map, read back by [ReadState.fromJson].
  Map<String, Object?> toJson() => {
        if (lastReadInbox != null) 'in': lastReadInbox!.toJson(),
        if (lastReadOutbox != null) 'out': lastReadOutbox!.toJson(),
        'n': unreadCount,
        if (unreadMentions.isNotEmpty)
          'm': [for (final k in unreadMentions) k.toJson()],
        if (unreadReactions.isNotEmpty)
          'r': [for (final k in unreadReactions) k.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is ReadState &&
      _samePosition(other.lastReadInbox, lastReadInbox) &&
      _samePosition(other.lastReadOutbox, lastReadOutbox) &&
      other.unreadCount == unreadCount &&
      _sameKeys(other.unreadMentions, unreadMentions) &&
      _sameKeys(other.unreadReactions, unreadReactions);

  @override
  int get hashCode => Object.hash(
        lastReadInbox,
        lastReadOutbox,
        unreadCount,
        unreadMentions.length,
        unreadReactions.length,
      );

  @override
  String toString() => 'ReadState(inbox: $lastReadInbox, '
      'outbox: $lastReadOutbox, unread: $unreadCount, '
      'mentions: ${unreadMentions.length}, '
      'reactions: ${unreadReactions.length})';
}

/// A sorted run of keys proven contiguous by server responses.
///
/// ```dart
/// const segment = Segment(
///   first: MessageKey(order: 1, id: '1'),
///   last: MessageKey(order: 40, id: '40'),
///   reachedNewest: true,
/// );
/// assert(segment.isLive);
/// ```
@immutable
final class Segment {
  /// Creates a segment covering [first]..[last] (inclusive).
  const Segment({
    required this.first,
    required this.last,
    this.reachedOldest = false,
    this.reachedNewest = false,
  });

  /// Oldest key of the run.
  final MessageKey first;

  /// Newest key of the run.
  final MessageKey last;

  /// Whether [first] is the oldest message of the list.
  final bool reachedOldest;

  /// Whether [last] is the newest message of the list.
  final bool reachedNewest;

  /// Whether this is the live segment (it holds the newest message).
  bool get isLive => reachedNewest;

  /// The key range of this segment.
  KeyRange get range => KeyRange(first, last);

  /// Whether [key] sorts inside this segment.
  bool contains(MessageKey key) => key >= first && key <= last;

  /// A copy with the given fields replaced.
  ///
  /// ```dart
  /// final grown = segment.copyWith(last: newerKey);
  /// ```
  Segment copyWith({
    MessageKey? first,
    MessageKey? last,
    bool? reachedOldest,
    bool? reachedNewest,
  }) =>
      Segment(
        first: first ?? this.first,
        last: last ?? this.last,
        reachedOldest: reachedOldest ?? this.reachedOldest,
        reachedNewest: reachedNewest ?? this.reachedNewest,
      );

  @override
  bool operator ==(Object other) =>
      other is Segment &&
      other.first.isSamePosition(first) &&
      other.last.isSamePosition(last) &&
      other.reachedOldest == reachedOldest &&
      other.reachedNewest == reachedNewest;

  @override
  int get hashCode => Object.hash(first, last, reachedOldest, reachedNewest);

  @override
  String toString() => 'Segment(${reachedOldest ? '|' : '…'}'
      '${first.order}..${last.order}${last.isLocal ? '+${last.localSeq}' : ''}'
      '${reachedNewest ? '|' : '…'})';
}

/// Saved position of a list.
///
/// ```dart
/// final snapshot = ViewportSnapshot(
///   anchorKey: key,
///   anchorOffset: 12,
///   offsetFromBottom: 1600,
///   visibleKeys: [key],
///   connectedToNewest: true,
///   viewportWidth: 390,
///   savedAt: DateTime.now(),
/// );
/// prefs.setString('pos', jsonEncode(snapshot.toJson()));
/// ```
@immutable
final class ViewportSnapshot {
  /// Creates a snapshot.
  const ViewportSnapshot({
    required this.anchorKey,
    required this.anchorOffset,
    required this.offsetFromBottom,
    required this.visibleKeys,
    required this.connectedToNewest,
    required this.viewportWidth,
    required this.savedAt,
  });

  /// Reads a snapshot written by [toJson].
  ///
  /// ```dart
  /// final snapshot = ViewportSnapshot.fromJson(
  ///   jsonDecode(text) as Map<String, Object?>,
  /// );
  /// ```
  factory ViewportSnapshot.fromJson(Map<String, Object?> json) =>
      ViewportSnapshot(
        anchorKey: _key(json['a'])!,
        anchorOffset: (json['ao']! as num).toDouble(),
        offsetFromBottom: (json['fb']! as num).toDouble(),
        visibleKeys: _keys(json['v']),
        connectedToNewest: json['c']! as bool,
        viewportWidth: (json['w']! as num).toDouble(),
        savedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['t']! as num).toInt(),
          isUtc: true,
        ),
      );

  /// The item that pins the position.
  final MessageKey anchorKey;

  /// Pixels from the viewport top to the anchor's top.
  final double anchorOffset;

  /// `scrollExtent − pixels`: a fallback when the anchor is gone.
  final double offsetFromBottom;

  /// Keys that were visible, oldest first.
  final List<MessageKey> visibleKeys;

  /// Whether the window was in the live segment.
  final bool connectedToNewest;

  /// Viewport width at save time, to detect layout changes.
  final double viewportWidth;

  /// When the snapshot was taken.
  final DateTime savedAt;

  /// The key range the snapshot needs in memory to restore: the visible
  /// keys plus the anchor.
  KeyRange get range {
    var lo = anchorKey;
    var hi = anchorKey;
    for (final k in visibleKeys) {
      if (k < lo) lo = k;
      if (k > hi) hi = k;
    }
    return KeyRange(lo, hi);
  }

  /// A JSON-safe map, read back by [ViewportSnapshot.fromJson].
  Map<String, Object?> toJson() => {
        'a': anchorKey.toJson(),
        'ao': anchorOffset,
        'fb': offsetFromBottom,
        'v': [for (final k in visibleKeys) k.toJson()],
        'c': connectedToNewest,
        'w': viewportWidth,
        't': savedAt.millisecondsSinceEpoch,
      };

  @override
  String toString() => 'ViewportSnapshot($anchorKey @ $anchorOffset px, '
      'fromBottom: $offsetFromBottom, live: $connectedToNewest)';
}

MessageKey? _key(Object? json) => json == null
    ? null
    : MessageKey.fromJson((json as Map).cast<String, Object?>());

List<MessageKey> _keys(Object? json) =>
    json == null ? const [] : [for (final k in json as List<Object?>) _key(k)!];

bool _samePosition(MessageKey? a, MessageKey? b) =>
    a == null ? b == null : b != null && a.isSamePosition(b);

bool _sameKeys(List<MessageKey> a, List<MessageKey> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!a[i].isSamePosition(b[i])) return false;
  }
  return true;
}

bool _isSorted(List<MessageKey> keys) {
  for (var i = 1; i < keys.length; i++) {
    if (keys[i - 1] > keys[i]) return false;
  }
  return true;
}
