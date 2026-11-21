import 'package:meta/meta.dart';

import 'list_store.dart';
import 'message_key.dart';
import 'models.dart';

/// Where a list should open (§10.1).
///
/// ```dart
/// controller.open(target: const OpenTarget.message(deepLinkedKey));
/// ```
@immutable
sealed class OpenTarget {
  const OpenTarget();

  /// Saved position → first unread → bottom.
  const factory OpenTarget.auto() = OpenAuto;

  /// Always the newest messages.
  const factory OpenTarget.bottom() = OpenAtBottom;

  /// The first unread message when there is one, else the bottom.
  const factory OpenTarget.firstUnread() = OpenAtFirstUnread;

  /// A specific message (deep link).
  const factory OpenTarget.message(MessageKey key) = OpenAtMessage;
}

/// [OpenTarget.auto].
final class OpenAuto extends OpenTarget {
  /// Creates the target.
  const OpenAuto();
}

/// [OpenTarget.bottom].
final class OpenAtBottom extends OpenTarget {
  /// Creates the target.
  const OpenAtBottom();
}

/// [OpenTarget.firstUnread].
final class OpenAtFirstUnread extends OpenTarget {
  /// Creates the target.
  const OpenAtFirstUnread();
}

/// [OpenTarget.message].
final class OpenAtMessage extends OpenTarget {
  /// Creates the target.
  const OpenAtMessage(this.key);

  /// The message to open at.
  final MessageKey key;
}

/// How a list was opened.
///
/// ```dart
/// if (await controller.open() == OpenResolution.firstUnread) showHint();
/// ```
enum OpenResolution {
  /// The position from earlier in this session was restored.
  sessionRestore,

  /// A persisted position was restored (after a restart or reload).
  snapshot,

  /// Opened at the first unread message.
  firstUnread,

  /// Opened at the newest messages.
  bottom,

  /// Opened at the requested message.
  target,
}

/// What an [OpenPolicy] knows when it decides.
///
/// ```dart
/// final plan = const OpenPolicy().decide(
///   const OpenContext(target: OpenTarget.auto(), readState: ReadState.empty),
/// );
/// ```
@immutable
final class OpenContext {
  /// Creates a context.
  const OpenContext({
    required this.target,
    required this.readState,
    this.sessionSnapshot,
    this.persistedSnapshot,
    this.restoreIslandsAfterRestart = true,
  });

  /// What the app asked for.
  final OpenTarget target;

  /// Read markers known so far.
  final ReadState readState;

  /// Position saved earlier in this session, if the list is still in memory.
  final ViewportSnapshot? sessionSnapshot;

  /// Position loaded from persistent storage.
  final ViewportSnapshot? persistedSnapshot;

  /// Whether a persisted position outside the live segment may be restored.
  final bool restoreIslandsAfterRestart;
}

/// The decision of an [OpenPolicy]. The controller falls back to the next
/// rule when a plan can't be carried out (the anchor is gone, a fetch fails).
///
/// ```dart
/// final plan = policy.decide(context);
/// if (plan is OpenPlanRestore) print(plan.snapshot.anchorKey);
/// ```
@immutable
sealed class OpenPlan {
  const OpenPlan();
}

/// Restore a saved position.
final class OpenPlanRestore extends OpenPlan {
  /// Creates the plan.
  const OpenPlanRestore(this.snapshot, this.resolution);

  /// The position to restore.
  final ViewportSnapshot snapshot;

  /// [OpenResolution.sessionRestore] or [OpenResolution.snapshot].
  final OpenResolution resolution;
}

/// Open at the first unread message, with the unread divider near the top.
final class OpenPlanUnread extends OpenPlan {
  /// Creates the plan.
  const OpenPlanUnread();
}

/// Open at the newest messages.
final class OpenPlanBottom extends OpenPlan {
  /// Creates the plan.
  const OpenPlanBottom();
}

/// Open at a specific message.
final class OpenPlanMessage extends OpenPlan {
  /// Creates the plan.
  const OpenPlanMessage(this.key);

  /// The message to open at.
  final MessageKey key;
}

/// Decides where a list opens. Default: session position → persisted
/// position (if it was connected to the newest message) → first unread →
/// bottom (§10.1).
///
/// ```dart
/// class AlwaysBottom extends OpenPolicy {
///   const AlwaysBottom();
///   @override
///   OpenPlan decide(OpenContext context) => const OpenPlanBottom();
/// }
/// ```
class OpenPolicy {
  /// Creates the default policy.
  const OpenPolicy();

  /// Returns the plan for [context].
  OpenPlan decide(OpenContext context) {
    switch (context.target) {
      case OpenAtMessage(:final key):
        return OpenPlanMessage(key);
      case OpenAtBottom():
        return const OpenPlanBottom();
      case OpenAtFirstUnread():
        break;
      case OpenAuto():
        final session = context.sessionSnapshot;
        if (session != null) {
          return OpenPlanRestore(session, OpenResolution.sessionRestore);
        }
        final saved = context.persistedSnapshot;
        if (saved != null &&
            (saved.connectedToNewest || context.restoreIslandsAfterRestart)) {
          return OpenPlanRestore(saved, OpenResolution.snapshot);
        }
    }
    return context.readState.unreadCount > 0
        ? const OpenPlanUnread()
        : const OpenPlanBottom();
  }
}

/// Decides what counts as read. Default: fully visible, or covering at
/// least half of the viewport when taller than it (§10.8). The dwell time
/// and the foreground check are applied by the controller.
///
/// ```dart
/// class ReadWhenHalfVisible extends ReadPolicy {
///   const ReadWhenHalfVisible();
///   @override
///   bool isRead({required double visibleFraction,
///           required double viewportCoverage}) =>
///       visibleFraction >= 0.5;
/// }
/// ```
class ReadPolicy {
  /// Creates the default policy.
  const ReadPolicy();

  /// Whether an item counts as read. [visibleFraction] is the visible part
  /// of the item (0–1); [viewportCoverage] is the part of the viewport it
  /// covers (0–1).
  bool isRead({
    required double visibleFraction,
    required double viewportCoverage,
  }) =>
      visibleFraction >= 0.999 || viewportCoverage >= 0.5;
}

/// A visible item an [AnchorPolicy] can choose.
///
/// ```dart
/// const AnchorCandidate(key: key, top: -12, height: 64);
/// ```
@immutable
final class AnchorCandidate {
  /// Creates a candidate.
  const AnchorCandidate({
    required this.key,
    required this.top,
    required this.height,
    this.isRemoving = false,
  });

  /// The item.
  final MessageKey key;

  /// Pixels from the viewport top to the item's top (negative when the item
  /// starts above the viewport).
  final double top;

  /// The item's height.
  final double height;

  /// Whether the item is animating out.
  final bool isRemoving;
}

/// Decides which item keeps the screen still during changes. Default: the
/// first visible item that is not being removed (§11.2).
///
/// ```dart
/// final anchor = const AnchorPolicy().pick(candidates);
/// ```
class AnchorPolicy {
  /// Creates the default policy.
  const AnchorPolicy();

  /// Picks the anchor among [visible] (ordered top to bottom).
  AnchorCandidate? pick(List<AnchorCandidate> visible) {
    for (final candidate in visible) {
      if (!candidate.isRemoving && candidate.top + candidate.height > 0) {
        return candidate;
      }
    }
    return visible.isEmpty ? null : visible.first;
  }
}

/// Decides sender groups and day groups. Default: same sender, same local
/// day, at most `gap` apart; service messages break groups (§13.3).
///
/// ```dart
/// class NoGrouping<M> extends GroupingPolicy<M> {
///   const NoGrouping();
///   @override
///   bool sameGroup(MessageAdapter<M> adapter, M a, M b, Duration gap) => false;
/// }
/// ```
class GroupingPolicy<M> {
  /// Creates the default policy.
  const GroupingPolicy();

  /// The calendar day [message] belongs to (local midnight).
  DateTime dayOf(MessageAdapter<M> adapter, M message) {
    final local = adapter.dateOf(message).toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// Whether [older] and [newer] (neighbours) belong to one sender group.
  bool sameGroup(MessageAdapter<M> adapter, M older, M newer, Duration gap) {
    if (adapter.isService(older) || adapter.isService(newer)) return false;
    final sender = adapter.senderIdOf(older);
    if (sender == null || sender != adapter.senderIdOf(newer)) return false;
    if (adapter.isOutgoing(older) != adapter.isOutgoing(newer)) return false;
    if (dayOf(adapter, older) != dayOf(adapter, newer)) return false;
    return adapter.dateOf(newer).difference(adapter.dateOf(older)).abs() <= gap;
  }
}

/// Decides where the "Unread messages" divider goes. Default: before the
/// first unread incoming, non-service message (§10.8).
///
/// ```dart
/// class NoDivider<M> extends UnreadDividerPolicy<M> {
///   const NoDivider();
///   @override
///   MessageKey? dividerBefore(ListStore<M> store) => null;
/// }
/// ```
class UnreadDividerPolicy<M> {
  /// Creates the default policy.
  const UnreadDividerPolicy();

  /// The key the divider is shown before, or null for no divider.
  MessageKey? dividerBefore(ListStore<M> store) => store.firstUnread();
}

/// Decides retry delays for failed pages and read receipts. Default: 0.5,
/// 1, 2 and 4 s, then the error state (§13.3).
///
/// ```dart
/// const RetryPolicy(delays: [Duration(seconds: 1), Duration(seconds: 5)]);
/// ```
class RetryPolicy {
  /// Creates a policy that retries after each of [delays], then gives up.
  const RetryPolicy({
    this.delays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
  });

  /// Never retries.
  const RetryPolicy.none() : delays = const [];

  /// Delay before each retry.
  final List<Duration> delays;

  /// The delay before retry number [attempt] (0 = first retry), or null to
  /// stop retrying.
  Duration? delayFor(int attempt) =>
      attempt < delays.length ? delays[attempt] : null;
}

/// Decides page sizes, the window size and when to load more. Defaults
/// follow Telegram: 40 / 20 / 80 / 1500 px (§10.2).
///
/// ```dart
/// const WindowPolicy(pageSize: 30, windowSize: 60);
/// ```
class WindowPolicy {
  /// Creates a policy.
  const WindowPolicy({
    this.pageSize = 40,
    this.firstOpenPageSize = 20,
    this.windowSize = 80,
    this.preloadExtent = 1500,
  })  : assert(pageSize > 0),
        assert(firstOpenPageSize > 0),
        assert(windowSize >= pageSize),
        assert(preloadExtent >= 0);

  /// Messages per page.
  final int pageSize;

  /// Messages in the first page of a list that isn't cached.
  final int firstOpenPageSize;

  /// Maximum number of built messages.
  final int windowSize;

  /// Load more when the viewport is this close (px) to a window edge.
  final double preloadExtent;

  /// Whether the window should grow toward an edge that is
  /// [distanceToEdge] px away from the viewport.
  ///
  /// When growing would unmount items on the other side ([windowIsFull]),
  /// the trigger distance is reduced so the two edges can't trigger each
  /// other in a loop: after adding one page, the far side must still be
  /// farther away than the trigger.
  bool shouldExtend({
    required double distanceToEdge,
    required double distanceToOtherEdge,
    required double averageItemExtent,
    required bool windowIsFull,
  }) {
    if (!windowIsFull) return distanceToEdge <= preloadExtent;
    // Loading a page here unmounts a page over there. With trigger t, the
    // far side ends up at least (scrollable - t - page) away, which must
    // stay above t: t < (scrollable - page) / 2.
    final pageExtent = averageItemExtent * pageSize;
    final scrollable = distanceToEdge + distanceToOtherEdge;
    final limit = (scrollable - pageExtent) / 2;
    if (limit <= 0) {
      // The window barely covers the viewport (tiny items or a huge
      // viewport): only load at the very edge. Raise `windowSize`.
      return distanceToEdge <= 0 && distanceToOtherEdge > 0;
    }
    return distanceToEdge < limit && distanceToEdge <= preloadExtent;
  }
}

/// Decides whether the list stays pinned to the bottom. Default: stick
/// unless the user is dragging (§10.3).
///
/// ```dart
/// class AlwaysStick extends BottomStickPolicy {
///   const AlwaysStick();
///   @override
///   bool shouldStick({required bool userDragging}) => true;
/// }
/// ```
class BottomStickPolicy {
  /// Creates the default policy.
  const BottomStickPolicy();

  /// Whether a list that is at the bottom should stay there.
  bool shouldStick({required bool userDragging}) => !userDragging;
}

/// Decides which items can be selected. Default: all except service
/// messages (§10.11).
///
/// ```dart
/// class OnlyMine<M> extends SelectionPolicy<M> {
///   const OnlyMine();
///   @override
///   bool isSelectable(MessageAdapter<M> adapter, M message) =>
///       adapter.isOutgoing(message);
/// }
/// ```
class SelectionPolicy<M> {
  /// Creates the default policy.
  const SelectionPolicy();

  /// Whether [message] can be selected.
  bool isSelectable(MessageAdapter<M> adapter, M message) =>
      !adapter.isService(message);
}

/// Decides which pinned message the pinned bar shows. Default: the newest
/// pinned message at or before the anchor (§10.10).
///
/// ```dart
/// final shown = const PinnedPolicy<ChatMessage>().currentPinned(store, anchor);
/// ```
class PinnedPolicy<M> {
  /// Creates the default policy.
  const PinnedPolicy();

  /// The pinned key to show while [anchor] is at the top of the viewport.
  MessageKey? currentPinned(ListStore<M> store, MessageKey anchor) =>
      store.pinnedAtOrBefore(anchor);
}

/// Every replaceable decision of a list. A null generic policy means "use
/// the default".
///
/// ```dart
/// MessageListPolicies<ChatMessage>(
///   retry: const RetryPolicy.none(),
///   grouping: const NoGrouping(),
/// );
/// ```
@immutable
final class MessageListPolicies<M> {
  /// Creates a set of policies; everything defaults to Telegram behavior.
  const MessageListPolicies({
    this.open = const OpenPolicy(),
    this.read = const ReadPolicy(),
    this.anchor = const AnchorPolicy(),
    this.retry = const RetryPolicy(),
    this.bottomStick = const BottomStickPolicy(),
    this.window,
    this.grouping,
    this.unreadDivider,
    this.selection,
    this.pinned,
  });

  /// Where to open.
  final OpenPolicy open;

  /// What counts as read.
  final ReadPolicy read;

  /// Which item keeps the screen still.
  final AnchorPolicy anchor;

  /// Page and read-receipt retry delays.
  final RetryPolicy retry;

  /// Whether to stay pinned to the bottom.
  final BottomStickPolicy bottomStick;

  /// Page sizes, window size and preload. Null: built from the config.
  final WindowPolicy? window;

  /// Sender and day groups. Null: [GroupingPolicy].
  final GroupingPolicy<M>? grouping;

  /// Where the unread divider goes. Null: [UnreadDividerPolicy].
  final UnreadDividerPolicy<M>? unreadDivider;

  /// Selectable items. Null: [SelectionPolicy].
  final SelectionPolicy<M>? selection;

  /// Current pinned message. Null: [PinnedPolicy].
  final PinnedPolicy<M>? pinned;
}
