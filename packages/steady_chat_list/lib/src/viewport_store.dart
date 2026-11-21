import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

/// Keeps scroll positions in `shared_preferences` (on the web: the
/// browser's local storage), so a chat reopens where the reader left it
/// after an app restart or a page reload.
///
/// Positions are read synchronously, which lets the list restore before
/// its first frame once the messages are available.
///
/// ```dart
/// final hub = MessageListHub<ChatMessage>(
///   source: source,
///   adapter: adapter,
///   viewportStore: await SharedPreferencesViewportStore.create(),
/// );
/// ```
final class SharedPreferencesViewportStore implements ViewportStore {
  /// Creates a store over loaded [preferences].
  SharedPreferencesViewportStore(
    SharedPreferences preferences, {
    this.prefix = 'steady_chat_list.position.',
  }) : _preferences = preferences;

  final SharedPreferences _preferences;

  /// Put in front of every key (one entry per list).
  final String prefix;

  /// Loads the preferences and creates the store.
  static Future<SharedPreferencesViewportStore> create({
    String prefix = 'steady_chat_list.position.',
  }) async =>
      SharedPreferencesViewportStore(
        await SharedPreferences.getInstance(),
        prefix: prefix,
      );

  String _key(ListId list) => '$prefix${list.storageKey}';

  @override
  ViewportSnapshot? load(ListId list) {
    final text = _preferences.getString(_key(list));
    if (text == null) return null;
    try {
      return ViewportSnapshot.fromJson(
        (jsonDecode(text) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return null; // written by another version, or damaged
    }
  }

  @override
  Future<void> save(ListId list, ViewportSnapshot snapshot) =>
      _preferences.setString(_key(list), jsonEncode(snapshot.toJson()));

  /// Forgets the position of [list].
  Future<void> remove(ListId list) => _preferences.remove(_key(list));

  /// Forgets every position this store saved.
  Future<void> clear() async {
    for (final key in _preferences.getKeys().toList()) {
      if (key.startsWith(prefix)) await _preferences.remove(key);
    }
  }
}
