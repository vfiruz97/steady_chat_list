import 'package:meta/meta.dart';

import 'message_key.dart';
import 'models.dart';

/// A message whose key changed: a local message was acknowledged, or its
/// `order` changed.
///
/// ```dart
/// for (final r in delta.replaced) {
///   print('${r.oldKey.id} is now ${r.newKey.id}');
/// }
/// ```
@immutable
final class KeyReplacement {
  /// Creates a replacement record.
  const KeyReplacement(this.oldKey, this.newKey);

  /// The key before the change.
  final MessageKey oldKey;

  /// The key after the change.
  final MessageKey newKey;

  @override
  String toString() => 'KeyReplacement($oldKey → $newKey)';
}

/// What one store operation changed. Empty when the operation was a no-op
/// (the same page or event applied twice).
///
/// ```dart
/// final delta = store.applyPage(request, result);
/// if (delta.inserted.isNotEmpty) rebuildWindow();
/// ```
@immutable
final class StoreDelta {
  /// Creates a delta. Usually only the store does.
  const StoreDelta({
    required this.list,
    this.inserted = const [],
    this.updated = const [],
    this.removed = const [],
    this.removedMessages = const [],
    this.evicted = const [],
    this.replaced = const [],
    this.segmentsChanged = false,
    this.readStateChanged = false,
    this.pinnedChanged = false,
    this.typingChanged = false,
    this.historyCleared = false,
  });

  /// The list that changed.
  final ListId list;

  /// Keys of new messages.
  final List<MessageKey> inserted;

  /// Keys whose message content or send state changed in place.
  final List<MessageKey> updated;

  /// Keys deleted or cleared.
  final List<MessageKey> removed;

  /// The messages of [removed], in the same order (each is the app's
  /// message type). They are no longer in the store; a view can keep
  /// showing them while they animate out.
  final List<Object?> removedMessages;

  /// Keys dropped from memory by eviction (they still exist on the server).
  final List<MessageKey> evicted;

  /// Messages whose key changed.
  final List<KeyReplacement> replaced;

  /// Whether segment bounds or flags changed.
  final bool segmentsChanged;

  /// Whether the read state changed.
  final bool readStateChanged;

  /// Whether the pinned keys changed.
  final bool pinnedChanged;

  /// Whether the typing users changed.
  final bool typingChanged;

  /// Whether history was cleared.
  final bool historyCleared;

  /// Whether nothing changed.
  bool get isEmpty =>
      inserted.isEmpty &&
      updated.isEmpty &&
      removed.isEmpty &&
      evicted.isEmpty &&
      replaced.isEmpty &&
      !segmentsChanged &&
      !readStateChanged &&
      !pinnedChanged &&
      !typingChanged &&
      !historyCleared;

  @override
  String toString() => 'StoreDelta(${list.storageKey}: '
      '+${inserted.length} ~${updated.length} -${removed.length} '
      'evicted ${evicted.length} replaced ${replaced.length}'
      '${segmentsChanged ? ' segments' : ''}'
      '${readStateChanged ? ' read' : ''}'
      '${pinnedChanged ? ' pinned' : ''}'
      '${typingChanged ? ' typing' : ''}'
      '${historyCleared ? ' cleared' : ''})';
}
