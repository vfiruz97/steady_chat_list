import 'package:meta/meta.dart';

/// Sortable identity of a message.
///
/// * Integer server ids: use the id as [order].
/// * String ids (UUID, Firestore): use the server time in microseconds as
///   [order] and the string as [id].
/// * Pending local messages share the [order] of the newest confirmed message
///   and get [localSeq] 1, 2, … so they sort right after it.
///
/// Sorting uses [compareTo] (`order`, then `localSeq`, then `id`).
/// Equality and [hashCode] use [id] only, so identity survives the
/// local → server re-key. Use [isSamePosition] to compare sort positions.
///
/// ```dart
/// const a = MessageKey(order: 41, id: '41');
/// const b = MessageKey(order: 42, id: '42');
/// assert(a < b);
/// const pending = MessageKey(order: 42, id: 'client-1', localSeq: 1);
/// assert(pending > b && pending.isLocal);
/// ```
@immutable
final class MessageKey implements Comparable<MessageKey> {
  /// Creates a key. [localSeq] is 0 for confirmed messages.
  const MessageKey({required this.order, required this.id, this.localSeq = 0});

  /// Reads a key written by [toJson].
  ///
  /// ```dart
  /// final key = MessageKey.fromJson(const MessageKey(order: 1, id: 'a').toJson());
  /// ```
  factory MessageKey.fromJson(Map<String, Object?> json) => MessageKey(
        order: (json['o']! as num).toInt(),
        id: json['i']! as String,
        localSeq: (json['l'] as num?)?.toInt() ?? 0,
      );

  /// Primary sort value (server id or server time in microseconds).
  final int order;

  /// Stable identity: the server id, or the client id of a pending message.
  final String id;

  /// 0 for confirmed messages; 1, 2, … for pending local messages placed
  /// after [order].
  final int localSeq;

  /// Whether this key belongs to a pending local message.
  bool get isLocal => localSeq > 0;

  /// Whether [other] sorts at exactly the same position.
  ///
  /// `==` only compares [id]; this also compares [order] and [localSeq].
  ///
  /// ```dart
  /// const before = MessageKey(order: 7, id: 'x', localSeq: 1);
  /// const after = MessageKey(order: 9, id: 'x');
  /// assert(before == after && !before.isSamePosition(after));
  /// ```
  bool isSamePosition(MessageKey other) => compareTo(other) == 0;

  @override
  int compareTo(MessageKey other) => order != other.order
      ? order.compareTo(other.order)
      : localSeq != other.localSeq
          ? localSeq.compareTo(other.localSeq)
          : id.compareTo(other.id);

  /// Whether this key sorts before [other].
  bool operator <(MessageKey other) => compareTo(other) < 0;

  /// Whether this key sorts before [other] or at the same position.
  bool operator <=(MessageKey other) => compareTo(other) <= 0;

  /// Whether this key sorts after [other].
  bool operator >(MessageKey other) => compareTo(other) > 0;

  /// Whether this key sorts after [other] or at the same position.
  bool operator >=(MessageKey other) => compareTo(other) >= 0;

  /// A JSON-safe map, read back by [MessageKey.fromJson].
  Map<String, Object?> toJson() => {
        'o': order,
        'i': id,
        if (localSeq != 0) 'l': localSeq,
      };

  @override
  bool operator ==(Object other) => other is MessageKey && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      isLocal ? 'MessageKey($order+$localSeq, $id)' : 'MessageKey($order, $id)';
}

/// An inclusive range of keys, used to protect windows from eviction.
///
/// ```dart
/// const range = KeyRange(
///   MessageKey(order: 10, id: '10'),
///   MessageKey(order: 20, id: '20'),
/// );
/// assert(range.contains(const MessageKey(order: 15, id: '15')));
/// ```
@immutable
final class KeyRange {
  /// Creates the range [first]..[last] (inclusive).
  const KeyRange(this.first, this.last);

  /// Oldest key of the range.
  final MessageKey first;

  /// Newest key of the range.
  final MessageKey last;

  /// Whether [key] sorts inside the range.
  bool contains(MessageKey key) => key >= first && key <= last;

  @override
  String toString() => 'KeyRange($first..$last)';
}
