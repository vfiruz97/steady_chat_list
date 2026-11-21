import 'dart:async';

import 'package:meta/meta.dart';

import 'message_key.dart';
import 'models.dart';

/// Which part of the history a [PageRequest] asks for.
///
/// ```dart
/// if (request.direction == PageDirection.latest) return api.newest(request.limit);
/// ```
enum PageDirection {
  /// Messages strictly older than the anchor.
  older,

  /// Messages strictly newer than the anchor.
  newer,

  /// About half older and half newer than the anchor, plus the anchor.
  around,

  /// The newest messages of the list.
  latest,
}

/// Tells a data source that a request is no longer needed.
///
/// ```dart
/// final dioToken = CancelToken();
/// request.cancel.whenCancelled.then((_) => dioToken.cancel());
/// ```
final class CancellationToken {
  final Completer<void> _completer = Completer<void>();

  /// Whether [cancel] was called.
  bool get isCancelled => _completer.isCompleted;

  /// Completes when [cancel] is called. Never completes with an error.
  Future<void> get whenCancelled => _completer.future;

  /// Marks the request as cancelled. Safe to call more than once.
  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// One page request sent to a `MessageSource`.
///
/// ```dart
/// final request = PageRequest(
///   list: const ListId('chat-1'),
///   direction: PageDirection.older,
///   anchor: oldestLoadedKey,
///   limit: 40,
/// );
/// ```
@immutable
final class PageRequest {
  /// Creates a request. [anchor] may be null only for
  /// [PageDirection.latest], or for [PageDirection.around] with an
  /// [anchorDate].
  PageRequest({
    required this.list,
    required this.direction,
    required this.limit,
    this.anchor,
    this.anchorDate,
    this.cursor,
    this.generation = 0,
    CancellationToken? cancel,
  }) : cancel = cancel ?? CancellationToken();

  /// The list to read.
  final ListId list;

  /// Which part of the history is wanted.
  final PageDirection direction;

  /// The key the page is relative to.
  final MessageKey? anchor;

  /// Set for jump-to-date when no key is known: the page should be around
  /// the first message on or after this moment.
  final DateTime? anchorDate;

  /// The opaque token a previous page returned for this edge
  /// ([PageResult.olderCursor] / [PageResult.newerCursor]), when the list
  /// still has it. Backends that page by key can ignore it.
  final String? cursor;

  /// Maximum number of messages. For [PageDirection.around]: about half
  /// older and half newer.
  final int limit;

  /// Open/jump counter of the requesting controller. Results from older
  /// generations are dropped.
  final int generation;

  /// Cancelled when the result is no longer needed. The app should abort
  /// the network call.
  final CancellationToken cancel;

  @override
  String toString() => 'PageRequest(${list.storageKey}, ${direction.name}, '
      'anchor: ${anchor ?? anchorDate}, limit: $limit, gen: $generation)';
}

/// One page of messages returned by a `MessageSource`.
///
/// ```dart
/// return PageResult(items: rows.map(ChatMessage.fromJson).toList(),
///     reachedOldest: rows.length < request.limit);
/// ```
@immutable
final class PageResult<M> {
  /// Creates a result. [items] may be in any order.
  const PageResult({
    required this.items,
    this.reachedOldest = false,
    this.reachedNewest = false,
    this.readState,
    this.olderCursor,
    this.newerCursor,
  });

  /// The messages, in any order.
  final List<M> items;

  /// Whether the page includes the oldest message of the list.
  final bool reachedOldest;

  /// Whether the page includes the newest message of the list.
  final bool reachedNewest;

  /// Optional read state sent along with the page.
  final ReadState? readState;

  /// For backends that page with tokens: the token to load the page before
  /// the oldest message of this page. It comes back as
  /// [PageRequest.cursor].
  final String? olderCursor;

  /// The token to load the page after the newest message of this page.
  final String? newerCursor;
}
