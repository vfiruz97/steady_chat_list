import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

import 'jump.dart';

/// What the list as a whole is doing.
///
/// ```dart
/// ValueListenableBuilder(
///   valueListenable: controller.phase,
///   builder: (_, phase, __) =>
///       phase == ListPhase.loading ? const Spinner() : list,
/// );
/// ```
enum ListPhase {
  /// Nothing to show yet; the first page is loading.
  loading,

  /// Messages are shown.
  ready,

  /// The list has no messages.
  empty,

  /// The first page failed and nothing is cached. Call `open()` to retry.
  error,
}

/// One end of the window.
///
/// ```dart
/// controller.retry(ListEdge.older);
/// ```
enum ListEdge {
  /// Toward older messages (top).
  older,

  /// Toward newer messages (bottom).
  newer,
}

/// The loading state of one end of the window.
///
/// ```dart
/// switch (controller.olderEdge.value) {
///   case EdgeIdle(): ...
///   case EdgeLoading(): return const Spinner();
///   case EdgeError(:final error): return RetryRow(error);
///   case EdgeEnd(): return const ChatIntro();
/// }
/// ```
@immutable
sealed class EdgeState {
  const EdgeState();
}

/// More messages may exist; nothing is loading.
final class EdgeIdle extends EdgeState {
  /// Creates the state.
  const EdgeIdle();
}

/// A page is loading.
final class EdgeLoading extends EdgeState {
  /// Creates the state.
  const EdgeLoading();
}

/// A page failed after all retries. Call `controller.retry(edge)`.
final class EdgeError extends EdgeState {
  /// Creates the state.
  const EdgeError(this.error);

  /// What went wrong.
  final Object error;
}

/// The window ends at the oldest (or newest) message of the list.
final class EdgeEnd extends EdgeState {
  /// Creates the state.
  const EdgeEnd();
}

/// Why a position was saved.
///
/// ```dart
/// saveSnapshot: (list, snapshot, reason) {
///   if (reason != SaveReason.scrollIdle) db.flush();
/// }
/// ```
enum SaveReason {
  /// The list stopped scrolling.
  scrollIdle,

  /// The controller switched to another list.
  chatSwitch,

  /// The controller was disposed.
  dispose,

  /// The app went to the background.
  appPaused,

  /// The web page is being hidden or closed.
  pageHide,

  /// `saveSnapshot()` was called by the app.
  explicit,
}

/// Why messages appeared in the store.
///
/// ```dart
/// if (event.cause == InsertCause.incoming) playSound();
/// ```
enum InsertCause {
  /// Loaded as part of a page.
  page,

  /// A new message, newer than everything known.
  incoming,

  /// A pending local message.
  local,
}

/// Why messages left the store.
///
/// ```dart
/// if (event.cause == RemoveCause.deleted) showUndo();
/// ```
enum RemoveCause {
  /// Deleted (locally or remotely).
  deleted,

  /// History was cleared.
  historyCleared,
}

/// A problem or internal detail worth logging.
///
/// ```dart
/// onDiagnostic: (d) {
///   if (d is CallbackError) crashlytics.record(d.error, d.stackTrace);
/// }
/// ```
@immutable
sealed class MessageListDiagnostic {
  const MessageListDiagnostic();
}

/// An app callback threw. The list keeps working.
final class CallbackError extends MessageListDiagnostic {
  /// Creates the diagnostic.
  const CallbackError(this.callback, this.error, this.stackTrace);

  /// Name of the callback that threw (for example `onReadUpTo`).
  final String callback;

  /// What it threw.
  final Object error;

  /// Where it threw.
  final StackTrace stackTrace;

  @override
  String toString() => 'CallbackError($callback: $error)';
}

/// The view moved the scroll offset to keep the anchor still (debug builds
/// only).
final class AnchorCorrected extends MessageListDiagnostic {
  /// Creates the diagnostic.
  const AnchorCorrected(this.pixels);

  /// How far the offset was moved.
  final double pixels;

  @override
  String toString() => 'AnchorCorrected($pixels px)';
}

/// Everything a controller reports, as one stream (§13.2). Each event that
/// has a callback in [MessageListCallbacks] carries the same information.
///
/// ```dart
/// controller.events.listen((event) {
///   switch (event) {
///     case UnreadChanged(:final count): badge.value = count;
///     case WindowChanged(:final count): debugPrint('$count built');
///     default:
///   }
/// });
/// ```
@immutable
sealed class MessageListEvent {
  const MessageListEvent(this.list);

  /// The list the event belongs to.
  final ListId list;
}

/// The list opened. Callback: `onOpened`.
final class ListOpened extends MessageListEvent {
  /// Creates the event.
  const ListOpened(super.list, this.resolution);

  /// How it was opened.
  final OpenResolution resolution;
}

/// A page request was sent. Callback: `onPageRequested`.
final class PageRequested extends MessageListEvent {
  /// Creates the event.
  const PageRequested(super.list, this.request);

  /// The request.
  final PageRequest request;
}

/// A page arrived and was applied. Callback: `onPageLoaded`.
final class PageLoaded extends MessageListEvent {
  /// Creates the event.
  const PageLoaded(
    super.list,
    this.request,
    this.result,
    this.origin,
    this.duration,
  );

  /// The request.
  final PageRequest request;

  /// The result (a `PageResult<M>`).
  final PageResult<Object?> result;

  /// Cache or remote.
  final PageOrigin origin;

  /// How long the fetch took.
  final Duration duration;
}

/// A page request failed (it may be retried). Callback: `onPageError`.
final class PageFailed extends MessageListEvent {
  /// Creates the event.
  const PageFailed(super.list, this.request, this.error, this.stackTrace);

  /// The request.
  final PageRequest request;

  /// What went wrong.
  final Object error;

  /// Where it went wrong.
  final StackTrace stackTrace;
}

/// The user read up to a key; a read receipt is being sent. Keys strictly
/// increase. Callback: `onReadUpTo`.
final class ReadUpTo extends MessageListEvent {
  /// Creates the event.
  const ReadUpTo(super.list, this.key);

  /// The newest message read.
  final MessageKey key;
}

/// The unread counter changed. Callback: `onUnreadChanged`.
final class UnreadChanged extends MessageListEvent {
  /// Creates the event.
  const UnreadChanged(super.list, this.count);

  /// The new count.
  final int count;
}

/// The list reached or left the bottom. Callback: `onAtBottomChanged`.
final class AtBottomChanged extends MessageListEvent {
  /// Creates the event.
  const AtBottomChanged(super.list, {required this.atBottom});

  /// Whether the newest message is at the bottom of the viewport.
  final bool atBottom;
}

/// The set of built messages changed.
final class WindowChanged extends MessageListEvent {
  /// Creates the event.
  const WindowChanged(super.list, this.first, this.last, this.count);

  /// Oldest built key (null when empty).
  final MessageKey? first;

  /// Newest built key (null when empty).
  final MessageKey? last;

  /// Number of built messages.
  final int count;
}

/// Messages appeared in the store.
final class MessageInserted extends MessageListEvent {
  /// Creates the event.
  const MessageInserted(super.list, this.keys, this.cause);

  /// The new keys.
  final List<MessageKey> keys;

  /// Why they appeared.
  final InsertCause cause;
}

/// Messages changed in place (edit, reactions, send state).
final class MessageUpdated extends MessageListEvent {
  /// Creates the event.
  const MessageUpdated(super.list, this.keys);

  /// The changed keys.
  final List<MessageKey> keys;
}

/// Messages left the store.
final class MessageRemoved extends MessageListEvent {
  /// Creates the event.
  const MessageRemoved(super.list, this.keys, this.cause);

  /// The removed keys.
  final List<MessageKey> keys;

  /// Why they left.
  final RemoveCause cause;
}

/// A message changed its key (a local message was acknowledged).
final class KeyReplaced extends MessageListEvent {
  /// Creates the event.
  const KeyReplaced(super.list, this.oldKey, this.newKey);

  /// The key before.
  final MessageKey oldKey;

  /// The key after.
  final MessageKey newKey;
}

/// The position was saved. Callback: `saveSnapshot`.
final class SnapshotSaved extends MessageListEvent {
  /// Creates the event.
  const SnapshotSaved(super.list, this.snapshot, this.reason);

  /// The saved position.
  final ViewportSnapshot snapshot;

  /// Why it was saved.
  final SaveReason reason;
}

/// A step of a jump. Callback: `onJump`.
final class Jumped extends MessageListEvent {
  /// Creates the event.
  const Jumped(super.list, this.jump);

  /// The step.
  final JumpEvent jump;
}

/// The pinned message for the current scroll position changed. Callback:
/// `onCurrentPinnedChanged`.
final class CurrentPinnedChanged extends MessageListEvent {
  /// Creates the event.
  const CurrentPinnedChanged(super.list, this.key);

  /// The pinned message to show in the bar, if any.
  final MessageKey? key;
}

/// A diagnostic was reported. Callback: `onDiagnostic`.
final class DiagnosticReported extends MessageListEvent {
  /// Creates the event.
  const DiagnosticReported(super.list, this.diagnostic);

  /// The diagnostic.
  final MessageListDiagnostic diagnostic;
}

/// Hooks an app can plug into a controller (§13.1).
///
/// Callbacks are never called during build or layout. They may throw or
/// return failing futures: the error is reported as a [CallbackError]
/// diagnostic and the list keeps working.
///
/// ```dart
/// MessageListCallbacks<ChatMessage>(
///   onReadUpTo: (list, key) => api.markRead(list.chatId, key.id),
///   onUnreadChanged: (list, count) => badges.set(list.chatId, count),
/// );
/// ```
@immutable
class MessageListCallbacks<M> {
  /// Creates a set of callbacks. All are optional.
  const MessageListCallbacks({
    this.loadSnapshot,
    this.saveSnapshot,
    this.onReadUpTo,
    this.onUnreadChanged,
    this.onPageRequested,
    this.onPageLoaded,
    this.onPageError,
    this.onOpened,
    this.onAtBottomChanged,
    this.onJump,
    this.onCurrentPinnedChanged,
    this.onDiagnostic,
  });

  /// Loads the persisted position of a list. Replaces the hub's
  /// `viewportStore`. A synchronous answer restores in the first frame; a
  /// future is ignored when slower than `snapshotLoadBudget`.
  final FutureOr<ViewportSnapshot?> Function(ListId list)? loadSnapshot;

  /// Persists the position of a list. Replaces the hub's `viewportStore`.
  final FutureOr<void> Function(
    ListId list,
    ViewportSnapshot snapshot,
    SaveReason reason,
  )? saveSnapshot;

  /// The user read up to a key (debounced, strictly increasing). Called in
  /// addition to `MessageSource.markRead`.
  final FutureOr<void> Function(ListId list, MessageKey key)? onReadUpTo;

  /// The unread counter changed.
  final void Function(ListId list, int count)? onUnreadChanged;

  /// A page request was sent.
  final void Function(ListId list, PageRequest request)? onPageRequested;

  /// A page arrived and was applied.
  final void Function(
    ListId list,
    PageRequest request,
    PageResult<M> result,
    PageOrigin origin,
    Duration duration,
  )? onPageLoaded;

  /// A page request failed.
  final void Function(
    ListId list,
    PageRequest request,
    Object error,
    StackTrace stackTrace,
  )? onPageError;

  /// The list opened.
  final void Function(ListId list, OpenResolution resolution)? onOpened;

  /// The list reached or left the bottom.
  final void Function(ListId list, bool atBottom)? onAtBottomChanged;

  /// A step of a jump: started, loading, scrolling, arrived (with the
  /// item's rectangle), highlightEnded, cancelled or failed.
  final void Function(ListId list, JumpEvent event)? onJump;

  /// The pinned message for the current scroll position changed.
  final void Function(ListId list, MessageKey? key)? onCurrentPinnedChanged;

  /// A diagnostic was reported.
  final void Function(MessageListDiagnostic diagnostic)? onDiagnostic;
}
