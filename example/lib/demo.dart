import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:steady_chat_list_drift/steady_chat_list_drift.dart';

import 'data/fake_chat_server.dart';
import 'data/models.dart';

/// What every demo page shares: the simulated server, the hub (one per
/// app, passed down, never global) and the place positions are saved.
class Demo {
  Demo({required this.preferences})
      : server = FakeChatServer(),
        viewportStore = SharedPreferencesViewportStore(preferences) {
    hub = newHub();
  }

  final SharedPreferences preferences;
  final FakeChatServer server;

  /// Scroll positions go to `shared_preferences` (local storage on the
  /// web), so a browser reload reopens every chat where it was.
  final SharedPreferencesViewportStore viewportStore;

  late MessageListHub<ChatMessage> hub;

  /// A cache that lives as long as the app runs.
  late final InMemoryMessageCache<ChatMessage> memoryCache =
      InMemoryMessageCache<ChatMessage>(adapter: chatAdapter);

  /// A cache in SQLite: a file on devices, IndexedDB/OPFS in the browser
  /// (`web/sqlite3.wasm` and `web/drift_worker.js`). It survives restarts
  /// and browser reloads.
  late final DriftMessageCache<ChatMessage> driftCache =
      DriftMessageCache<ChatMessage>(
    SteadyCacheDatabase(
      driftDatabase(
        name: 'steady_chat_list_example',
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.js'),
        ),
      ),
    ),
    adapter: chatAdapter,
    codec: chatCodec,
  );

  MessageListHub<ChatMessage> newHub({MessageCache<ChatMessage>? cache}) =>
      MessageListHub<ChatMessage>(
        source: server,
        adapter: chatAdapter,
        viewportStore: viewportStore,
        cache: cache,
        onError: (error, stackTrace) => debugPrint('hub: $error'),
      );
}

class DemoScope extends InheritedWidget {
  const DemoScope({super.key, required this.demo, required super.child});

  final Demo demo;

  static Demo of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DemoScope>()!.demo;

  @override
  bool updateShouldNotify(DemoScope oldWidget) => demo != oldWidget.demo;
}

/// One entry of the left menu.
class DemoPage {
  const DemoPage({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });

  final String id;
  final String title;

  /// What the page demonstrates, shown under the title.
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;
}
