import 'dart:async';

import 'package:meta/meta.dart';

import 'list_event.dart';
import 'list_store.dart';
import 'message_key.dart';
import 'message_store.dart';
import 'models.dart';
import 'paging.dart';
import 'source.dart';
import 'store_delta.dart';

/// Where a page came from.
///
/// ```dart
/// if (outcome.origin == PageOrigin.cache) metrics.cacheHit();
/// ```
enum PageOrigin {
  /// Answered from the local cache.
  cache,

  /// Answered by the backend.
  remote,
}

/// Persistent storage for saved positions (§10.9). [load] may answer
/// synchronously, which lets a list restore its position in the first frame.
///
/// ```dart
/// class PrefsViewportStore implements ViewportStore {
///   PrefsViewportStore(this.prefs);
///   final SharedPreferences prefs;
///   @override
///   ViewportSnapshot? load(ListId list) {
///     final text = prefs.getString('pos/${list.storageKey}');
///     return text == null ? null
///         : ViewportSnapshot.fromJson(jsonDecode(text) as Map<String, Object?>);
///   }
///   @override
///   Future<void> save(ListId list, ViewportSnapshot snapshot) => prefs
///       .setString('pos/${list.storageKey}', jsonEncode(snapshot.toJson()));
/// }
/// ```
abstract interface class ViewportStore {
  /// The saved position of [list], if any.
  FutureOr<ViewportSnapshot?> load(ListId list);

  /// Saves the position of [list]. The latest call wins.
  FutureOr<void> save(ListId list, ViewportSnapshot snapshot);
}

/// A [ViewportStore] that lives as long as the object does. Useful in tests
/// and for apps that persist positions themselves.
///
/// ```dart
/// final hub = MessageListHub(source: source, adapter: adapter,
///     viewportStore: InMemoryViewportStore());
/// ```
final class InMemoryViewportStore implements ViewportStore {
  final Map<ListId, ViewportSnapshot> _snapshots = {};

  @override
  ViewportSnapshot? load(ListId list) => _snapshots[list];

  @override
  void save(ListId list, ViewportSnapshot snapshot) =>
      _snapshots[list] = snapshot;
}

/// The result of [MessageListHub.fetch].
///
/// ```dart
/// final outcome = await hub.fetch(request);
/// if (outcome.applied) print('${outcome.delta.inserted.length} new');
/// ```
@immutable
final class PageOutcome<M> {
  /// Creates an outcome.
  const PageOutcome({
    required this.request,
    required this.result,
    required this.delta,
    required this.origin,
    required this.duration,
    required this.applied,
  });

  /// The request that was sent.
  final PageRequest request;

  /// What the source returned.
  final PageResult<M> result;

  /// What the page changed in the store (empty when not [applied]).
  final StoreDelta delta;

  /// Where the page came from.
  final PageOrigin origin;

  /// How long the fetch took.
  final Duration duration;

  /// False when every requester cancelled before the page arrived: the
  /// result was dropped.
  final bool applied;
}

/// One per app (passed in, never global). Owns the message store, the
/// subscriptions to the backend and in-flight page requests for every list
/// (§8.4). Controllers are cheap views on it: two controllers on the same
/// list share data and events.
///
/// ```dart
/// final hub = MessageListHub<ChatMessage>(
///   source: MyBackendSource(api, socket),
///   adapter: const ChatMessageAdapter(),
/// );
/// ```
final class MessageListHub<M> {
  /// Creates a hub.
  ///
  /// [merge] combines the stored and the incoming version of a message
  /// (default: the incoming one wins). [onError] receives errors of the
  /// event streams. [clock] is for tests.
  MessageListHub({
    required this.source,
    required this.adapter,
    this.viewportStore,
    int memoryLimitPerList = 1000,
    int openListsInMemory = 10,
    this.releaseDelay = const Duration(seconds: 30),
    MessageMerge<M>? merge,
    this.onError,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        store = MessageStore<M>(
          adapter: adapter,
          memoryLimitPerList: memoryLimitPerList,
          openListsInMemory: openListsInMemory,
          merge: merge,
          clock: clock,
        );

  /// The app's backend.
  final MessageSource<M> source;

  /// Reads keys, dates and flags from the app's message class.
  final MessageAdapter<M> adapter;

  /// Where positions are persisted when the app gives no callbacks.
  final ViewportStore? viewportStore;

  /// How long the event subscription of a list is kept after its last
  /// controller detached.
  final Duration releaseDelay;

  /// Receives errors of `source.events` streams.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Every list in memory.
  final MessageStore<M> store;

  final DateTime Function() _clock;
  final Map<ListId, _Attachment<M>> _attachments = {};
  final Map<String, _Flight<M>> _flights = {};
  bool _disposed = false;

  /// The current time (the injected clock in tests).
  DateTime now() => _clock();

  /// Whether [dispose] was called.
  bool get isDisposed => _disposed;

  /// Lists with at least one controller attached.
  Iterable<ListId> get attachedLists => [
        for (final entry in _attachments.entries)
          if (entry.value.count > 0) entry.key,
      ];

  /// Registers a user of [list] and returns its store. The first user
  /// subscribes to `source.events(list)`.
  ///
  /// ```dart
  /// final listStore = hub.attach(const ListId('chat-1'));
  /// ```
  ListStore<M> attach(ListId list) {
    assert(!_disposed, 'attach() on a disposed hub');
    final attachment = _attachments[list] ??= _Attachment<M>();
    attachment.count++;
    attachment.release?.cancel();
    attachment.release = null;
    final listStore = store.list(list);
    attachment.subscription ??= source.events(list).listen(
          apply,
          onError: (Object error, StackTrace stackTrace) =>
              onError?.call(error, stackTrace),
        );
    store.evictLists(keep: _attachments.keys.toSet());
    return listStore;
  }

  /// Unregisters a user of [list]. The subscription is released
  /// [releaseDelay] after the last user detached.
  void detach(ListId list, {Object? owner}) {
    final attachment = _attachments[list];
    if (attachment == null || attachment.count == 0) return;
    if (owner != null) attachment.protected.remove(owner);
    attachment.count--;
    if (attachment.count > 0 || _disposed) return;
    attachment.release = Timer(releaseDelay, () {
      unawaited(attachment.subscription?.cancel());
      _attachments.remove(list);
    });
  }

  /// Declares the key range [owner] (a controller) has on screen, so
  /// [trim] never drops it. Pass null to clear.
  void protect(ListId list, Object owner, KeyRange? range) {
    final attachment = _attachments[list];
    if (attachment == null) return;
    if (range == null) {
      attachment.protected.remove(owner);
    } else {
      attachment.protected[owner] = range;
    }
  }

  /// Trims [list] to the memory limit, keeping every protected range and
  /// the saved snapshot (§7.4).
  StoreDelta trim(ListId list) => store.evictMessages(
        list,
        protect: _attachments[list]?.protected.values ?? const <KeyRange>[],
      );

  /// Loads a page and applies it to the store.
  ///
  /// Identical requests in flight share one call to the source. The result
  /// is dropped ([PageOutcome.applied] is false) when every requester
  /// cancelled its [PageRequest.cancel] token first.
  ///
  /// ```dart
  /// final outcome = await hub.fetch(PageRequest(
  ///   list: list, direction: PageDirection.latest, limit: 20));
  /// ```
  Future<PageOutcome<M>> fetch(PageRequest request) {
    final anchor = request.anchor;
    final signature = '${request.list.storageKey}|${request.direction.name}|'
        '${anchor?.order}:${anchor?.localSeq}:${anchor?.id}|'
        '${request.anchorDate?.microsecondsSinceEpoch}|${request.limit}';
    final existing = _flights[signature];
    if (existing != null) {
      existing.join(request.cancel);
      return existing.future;
    }
    final flight = _Flight<M>()..join(request.cancel);
    _flights[signature] = flight;
    final sent = PageRequest(
      list: request.list,
      direction: request.direction,
      anchor: request.anchor,
      anchorDate: request.anchorDate,
      limit: request.limit,
      generation: request.generation,
      cancel: flight.token,
    );
    final watch = Stopwatch()..start();
    flight.future =
        Future<PageResult<M>>.sync(() => source.fetch(sent)).then((result) {
      final dropped = _disposed || flight.token.isCancelled;
      return PageOutcome<M>(
        request: sent,
        result: result,
        delta: dropped
            ? StoreDelta(list: request.list)
            : store.list(request.list).applyPage(sent, result),
        origin: PageOrigin.remote,
        duration: watch.elapsed,
        applied: !dropped,
      );
    }).whenComplete(() => _flights.remove(signature));
    return flight.future;
  }

  /// Applies an event to the store of its list. Events for lists that are
  /// not in memory are ignored: their data is fetched when they open.
  ///
  /// ```dart
  /// hub.apply(MessagesDeleted<ChatMessage>(list, ['41']));
  /// ```
  StoreDelta apply(ListEvent<M> event) {
    if (_disposed) return StoreDelta(list: event.list);
    return store.peek(event.list)?.apply(event) ?? StoreDelta(list: event.list);
  }

  /// Reports to the backend that [list] was read up to [upTo].
  Future<void> markRead(ListId list, MessageKey upTo) =>
      source.markRead(list, upTo);

  /// Cancels subscriptions and pending requests. Late results are dropped.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final attachment in _attachments.values) {
      attachment.release?.cancel();
      unawaited(attachment.subscription?.cancel());
    }
    _attachments.clear();
    for (final flight in _flights.values) {
      flight.token.cancel();
    }
  }
}

final class _Attachment<M> {
  int count = 0;
  StreamSubscription<ListEvent<M>>? subscription;
  Timer? release;
  final Map<Object, KeyRange> protected = {};
}

final class _Flight<M> {
  /// Cancelled when every requester cancelled.
  final CancellationToken token = CancellationToken();
  final List<CancellationToken> _requesters = [];
  late final Future<PageOutcome<M>> future; // set right after creation

  void join(CancellationToken requester) {
    _requesters.add(requester);
    unawaited(
      requester.whenCancelled.then((_) {
        if (_requesters.every((t) => t.isCancelled)) token.cancel();
      }),
    );
  }
}
