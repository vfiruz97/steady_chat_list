import 'package:flutter/widgets.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

import 'events.dart';

/// Delivery state of a message, for checkmarks and retry buttons.
///
/// ```dart
/// if (info.sendState == SendState.failed) const Icon(Icons.error);
/// ```
enum SendState {
  /// Not an outgoing message.
  none,

  /// A pending local message.
  sending,

  /// Confirmed by the server.
  sent,

  /// Sending failed; the app may retry or remove it.
  failed,
}

/// What the list knows about one item when it is built.
///
/// ```dart
/// itemBuilder: (context, message, info) => MessageBubble(
///   message,
///   showAvatar: info.isLastInGroup,
///   showName: info.isFirstInGroup,
/// ),
/// ```
@immutable
class MessageItemInfo {
  /// Creates the info. The view does this.
  const MessageItemInfo({
    required this.key,
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
    this.isFirstInDay = false,
    this.isFirstUnread = false,
    this.isJustAdded = false,
    this.isLocal = false,
    this.sendState = SendState.none,
    this.isRead = false,
    this.highlight,
    this.highlightQuery,
    this.highlightReason,
    this.indexInWindow = 0,
  });

  /// The message (for an album: its first message).
  final MessageKey key;

  /// Whether this is the first message of a sender group.
  final bool isFirstInGroup;

  /// Whether this is the last message of a sender group.
  final bool isLastInGroup;

  /// Whether this is the first message of its day.
  final bool isFirstInDay;

  /// Whether the unread divider is shown before this message.
  final bool isFirstUnread;

  /// Whether the message just arrived or was just sent (it is playing the
  /// appear animation).
  final bool isJustAdded;

  /// Whether this is a pending local message.
  final bool isLocal;

  /// Delivery state.
  final SendState sendState;

  /// Whether the peer has read this outgoing message.
  final bool isRead;

  /// Goes from 1 to 0 after a jump landed on this message; null otherwise.
  /// Draw the flash with it (see `JumpHighlightBackground`).
  final Animation<double>? highlight;

  /// The search term to mark in the text, while search navigation is on.
  final String? highlightQuery;

  /// Why the jump that flashes this message happened.
  final JumpReason? highlightReason;

  /// Position in the window (debug only).
  final int indexInWindow;

  /// A copy with another delivery state.
  MessageItemInfo withSendState(SendState state, {required bool isLocal}) =>
      MessageItemInfo(
        key: key,
        isFirstInGroup: isFirstInGroup,
        isLastInGroup: isLastInGroup,
        isFirstInDay: isFirstInDay,
        isFirstUnread: isFirstUnread,
        isJustAdded: isJustAdded,
        isLocal: isLocal,
        sendState: state,
        isRead: isRead,
        highlight: highlight,
        highlightQuery: highlightQuery,
        highlightReason: highlightReason,
        indexInWindow: indexInWindow,
      );

  @override
  bool operator ==(Object other) =>
      other is MessageItemInfo &&
      other.key.id == key.id &&
      other.key.isSamePosition(key) &&
      other.isFirstInGroup == isFirstInGroup &&
      other.isLastInGroup == isLastInGroup &&
      other.isFirstInDay == isFirstInDay &&
      other.isFirstUnread == isFirstUnread &&
      other.isJustAdded == isJustAdded &&
      other.isLocal == isLocal &&
      other.sendState == sendState &&
      other.isRead == isRead &&
      identical(other.highlight, highlight) &&
      other.highlightQuery == highlightQuery &&
      other.highlightReason == highlightReason;

  @override
  int get hashCode => Object.hash(
        key,
        isFirstInGroup,
        isLastInGroup,
        isFirstInDay,
        isFirstUnread,
        isLocal,
        sendState,
        isRead,
        highlightQuery,
        highlightReason,
      );
}

/// Builds one message.
///
/// ```dart
/// Widget build(BuildContext context, ChatMessage m, MessageItemInfo info) =>
///     MessageBubble(m, grouped: !info.isFirstInGroup);
/// ```
typedef MessageItemBuilder<M> = Widget Function(
  BuildContext context,
  M message,
  MessageItemInfo info,
);

/// Builds one album: several messages with the same group id in one row.
///
/// ```dart
/// groupBuilder: (context, photos, info) => PhotoGrid(photos),
/// ```
typedef MessageGroupBuilder<M> = Widget Function(
  BuildContext context,
  List<M> messages,
  MessageItemInfo info,
);

/// Builds the inline header at the start of a day.
///
/// ```dart
/// dayHeaderBuilder: (context, day, onTap) =>
///     GestureDetector(onTap: onTap, child: Text('$day')),
/// ```
typedef DayHeaderBuilder = Widget Function(
  BuildContext context,
  DateTime day,
  VoidCallback onTap,
);

/// Builds the row shown at one end of the window: a spinner while a page
/// loads, an error with a retry button, or nothing.
///
/// ```dart
/// edgeBuilder: (context, edge, state, retry) => switch (state) {
///   EdgeLoading() => const Spinner(),
///   EdgeError() => TextButton(onPressed: retry, child: const Text('Retry')),
///   _ => const SizedBox.shrink(),
/// },
/// ```
typedef EdgeBuilder = Widget Function(
  BuildContext context,
  ListEdge edge,
  EdgeState state,
  VoidCallback retry,
);

/// Builds the animation of a row that appears or is removed. [animation]
/// runs from 0 to 1 while the row animates; when nothing animates it is
/// constant, and the builder must still return the same widget structure
/// around [child] (so the item keeps its state).
///
/// ```dart
/// appearTransitionBuilder: (context, animation, child, info) =>
///     SizeTransition(sizeFactor: animation, child: child),
/// ```
typedef ItemTransitionBuilder = Widget Function(
  BuildContext context,
  Animation<double> animation,
  Widget child,
  MessageItemInfo info,
);
