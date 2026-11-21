import 'package:flutter/foundation.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

/// Which messages are selected (§10.11). Owned by a controller
/// (`controller.selection`); the app draws the checkmarks from
/// `MessageItemInfo.isSelected` and `selectionActive`.
///
/// Selected ids survive paging and window trims. Deleted messages leave
/// the selection by themselves.
///
/// ```dart
/// onLongPress: () => controller.selection.toggle(message.id),
/// onTap: () => selection.active
///     ? (shiftPressed ? selection.extendTo(info.key) : selection.toggle(id))
///     : openMessage(),
/// // delete: controller.remove(selection.selectedIds.toList());
/// ```
class SelectionController extends ChangeNotifier {
  /// Creates a selection over the keys the given functions provide. A
  /// controller creates its own.
  SelectionController({
    required Iterable<MessageKey> Function(MessageKey from, MessageKey to)
        keysBetween,
    required Iterable<MessageKey> Function() loadedKeys,
    required bool Function(MessageKey key) isSelectable,
    required MessageKey? Function(String id) keyOf,
  })  : _keysBetween = keysBetween,
        _loadedKeys = loadedKeys,
        _isSelectable = isSelectable,
        _keyOf = keyOf;

  final Iterable<MessageKey> Function(MessageKey from, MessageKey to)
      _keysBetween;
  final Iterable<MessageKey> Function() _loadedKeys;
  final bool Function(MessageKey key) _isSelectable;
  final MessageKey? Function(String id) _keyOf;

  final Set<String> _ids = <String>{};
  bool _started = false;
  MessageKey? _last; // where a shift-click range starts
  MessageKey? _dragStart;
  Set<String> _dragBase = const {};

  /// Whether selection mode is on: something is selected, or [start] was
  /// called.
  bool get active => _started || _ids.isNotEmpty;

  /// Ids of the selected messages.
  Set<String> get selectedIds => Set<String>.unmodifiable(_ids);

  /// Number of selected messages.
  int get count => _ids.length;

  /// Whether the message with [id] is selected.
  bool isSelected(String id) => _ids.contains(id);

  /// Whether [key] can be selected (`SelectionPolicy`; by default
  /// everything except service messages).
  bool isSelectable(MessageKey key) => _isSelectable(key);

  /// Turns selection mode on without selecting anything.
  void start() {
    if (_started) return;
    _started = true;
    notifyListeners();
  }

  /// Selects or deselects one message (tap in selection mode, long-press).
  void toggle(String id) {
    final key = _keyOf(id);
    if (_ids.remove(id)) {
      _last = key ?? _last;
      notifyListeners();
    } else if (key != null && _isSelectable(key)) {
      _ids.add(id);
      _last = key;
      notifyListeners();
    }
  }

  /// Selects everything loaded between [from] and [to] (in any order).
  void selectRange(MessageKey from, MessageKey to) {
    if (_addRange(from, to)) notifyListeners();
    _last = to;
  }

  /// Shift-click: selects from the message toggled last up to [key].
  void extendTo(MessageKey key) => selectRange(_last ?? key, key);

  /// Selects every loaded message.
  void selectAllLoaded() {
    var changed = false;
    for (final key in _loadedKeys()) {
      if (_isSelectable(key) && _ids.add(key.id)) changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Drag-to-select: call with the message the drag started on and the one
  /// under the finger now. The range between them is selected on top of
  /// what was selected before the drag; moving back shrinks it again.
  void dragSelect(MessageKey start, MessageKey current) {
    if (_dragStart?.id != start.id) {
      _dragStart = start;
      _dragBase = Set<String>.of(_ids);
    }
    final before = Set<String>.of(_ids);
    _ids
      ..clear()
      ..addAll(_dragBase);
    _addRange(start, current);
    _last = current;
    if (before.length != _ids.length || !before.containsAll(_ids)) {
      notifyListeners();
    }
  }

  /// Ends a drag-to-select gesture.
  void endDrag() {
    _dragStart = null;
    _dragBase = const {};
  }

  /// Deselects everything and leaves selection mode.
  void clear() {
    if (!active) return;
    _ids.clear();
    _started = false;
    _last = null;
    endDrag();
    notifyListeners();
  }

  /// Forgets messages that no longer exist. The controller calls this when
  /// messages are deleted; selection mode ends when nothing is left.
  void forget(Iterable<String> ids) {
    var changed = false;
    for (final id in ids) {
      if (_ids.remove(id)) changed = true;
    }
    if (!changed) return;
    if (_ids.isEmpty) {
      _started = false;
      _last = null;
    }
    notifyListeners();
  }

  bool _addRange(MessageKey a, MessageKey b) {
    final from = a <= b ? a : b;
    final to = a <= b ? b : a;
    var changed = false;
    for (final key in _keysBetween(from, to)) {
      if (_isSelectable(key) && _ids.add(key.id)) changed = true;
    }
    return changed;
  }
}
