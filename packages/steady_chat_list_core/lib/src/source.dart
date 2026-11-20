import 'package:meta/meta.dart';

import 'list_event.dart';
import 'message_key.dart';
import 'models.dart';
import 'paging.dart';

/// The app's backend, seen by the list. Works over REST, WebSocket, GraphQL,
/// Firebase, Supabase, MTProto, XMPP, Matrix…
///
/// ```dart
/// class MyBackendSource implements MessageSource<ChatMessage> {
///   @override
///   Future<PageResult<ChatMessage>> fetch(PageRequest request) async {
///     final rows = await api.history(request.list.chatId,
///         direction: request.direction.name,
///         anchor: request.anchor?.id, limit: request.limit);
///     return PageResult(items: rows);
///   }
///   @override
///   Stream<ListEvent<ChatMessage>> events(ListId list) => socket.eventsOf(list);
///   @override
///   Future<void> markRead(ListId list, MessageKey upTo) =>
///       api.markRead(list.chatId, upTo.id);
/// }
/// ```
abstract interface class MessageSource<M> {
  /// Loads one page. Throwing marks the page as failed (the list shows a
  /// retry edge, it never clears).
  Future<PageResult<M>> fetch(PageRequest request);

  /// Live changes of [list]. May be `Stream.empty()` when the app pushes
  /// changes imperatively.
  Stream<ListEvent<M>> events(ListId list);

  /// Reports that everything up to [upTo] was read.
  Future<void> markRead(ListId list, MessageKey upTo);
}

/// Optional backend search, used by the search navigator.
///
/// ```dart
/// class MySearchSource implements MessageSearchSource {
///   @override
///   Future<SearchPage> search(ListId list, String query,
///       {String? cursor, int limit = 50}) async {
///     final r = await api.search(list.chatId, query, cursor, limit);
///     return SearchPage(keys: r.keys, totalCount: r.total, nextCursor: r.next);
///   }
/// }
/// ```
abstract interface class MessageSearchSource {
  /// Returns one page of results, newest first. Pass the previous page's
  /// [SearchPage.nextCursor] as [cursor] to continue.
  Future<SearchPage> search(
    ListId list,
    String query, {
    String? cursor,
    int limit = 50,
  });
}

/// One page of search results.
///
/// ```dart
/// const SearchPage(keys: [], totalCount: 0);
/// ```
@immutable
final class SearchPage {
  /// Creates a page of results.
  const SearchPage({required this.keys, this.totalCount, this.nextCursor});

  /// Matching keys, newest first.
  final List<MessageKey> keys;

  /// Total number of results, when the server knows it.
  final int? totalCount;

  /// Cursor of the next page; null when this is the last page.
  final String? nextCursor;
}
