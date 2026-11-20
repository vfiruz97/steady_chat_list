import 'package:meta/meta.dart';

import 'message_key.dart';
import 'models.dart';

/// A change pushed by the backend (or by the app) for one list.
///
/// ```dart
/// socket.onMessage((json) => controller.add(
///   MessagesAdded(ListId(json['chat']), [ChatMessage.fromJson(json)]),
/// ));
/// ```
@immutable
sealed class ListEvent<M> {
  const ListEvent(this.list);

  /// The list this event belongs to.
  final ListId list;
}

/// New messages arrived.
///
/// ```dart
/// MessagesAdded(list, [message]);
/// ```
final class MessagesAdded<M> extends ListEvent<M> {
  /// Creates the event.
  const MessagesAdded(super.list, this.items);

  /// The new messages, in any order.
  final List<M> items;
}

/// Existing messages changed (edit, reactions, status, view counter).
///
/// ```dart
/// MessagesUpdated(list, [edited]);
/// ```
final class MessagesUpdated<M> extends ListEvent<M> {
  /// Creates the event.
  const MessagesUpdated(super.list, this.items);

  /// The new versions, matched by id.
  final List<M> items;
}

/// Messages were deleted.
///
/// ```dart
/// MessagesDeleted<ChatMessage>(list, ['41', '42']);
/// ```
final class MessagesDeleted<M> extends ListEvent<M> {
  /// Creates the event.
  const MessagesDeleted(super.list, this.ids);

  /// Ids of the deleted messages.
  final List<String> ids;
}

/// The server accepted a pending local message.
///
/// ```dart
/// LocalAcked(list, 'client-1', serverMessage);
/// ```
final class LocalAcked<M> extends ListEvent<M> {
  /// Creates the event.
  const LocalAcked(super.list, this.localId, this.serverMessage);

  /// Client id the message was inserted with.
  final String localId;

  /// The confirmed message with its server key.
  final M serverMessage;
}

/// Sending a pending local message failed.
///
/// ```dart
/// LocalFailed<ChatMessage>(list, 'client-1', error);
/// ```
final class LocalFailed<M> extends ListEvent<M> {
  /// Creates the event.
  const LocalFailed(super.list, this.localId, this.error);

  /// Client id the message was inserted with.
  final String localId;

  /// What went wrong.
  final Object error;
}

/// Read markers or unread counters changed.
///
/// ```dart
/// ReadStateChanged<ChatMessage>(list, const ReadState(unreadCount: 0));
/// ```
final class ReadStateChanged<M> extends ListEvent<M> {
  /// Creates the event.
  const ReadStateChanged(super.list, this.state);

  /// The new read state (replaces the old one).
  final ReadState state;
}

/// The set of pinned messages changed.
///
/// ```dart
/// PinnedChanged<ChatMessage>(list, [pinnedKey]);
/// ```
final class PinnedChanged<M> extends ListEvent<M> {
  /// Creates the event.
  const PinnedChanged(super.list, this.keys);

  /// All pinned keys (replaces the old set).
  final List<MessageKey> keys;
}

/// History was cleared up to (and including) a key.
///
/// ```dart
/// HistoryCleared<ChatMessage>(list, newestClearedKey);
/// ```
final class HistoryCleared<M> extends ListEvent<M> {
  /// Creates the event.
  const HistoryCleared(super.list, this.upTo);

  /// Every message with a key ≤ this one is gone.
  final MessageKey upTo;
}

/// The set of users typing in the list changed.
///
/// ```dart
/// TypingChanged<ChatMessage>(list, {'alice'});
/// ```
final class TypingChanged<M> extends ListEvent<M> {
  /// Creates the event.
  const TypingChanged(super.list, this.userIds);

  /// Ids of the users typing right now.
  final Set<String> userIds;
}
