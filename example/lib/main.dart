import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'demo.dart';
import 'pages/chat_pages.dart';
import 'pages/simple_pages.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  runApp(ExampleApp(demo: Demo(preferences: preferences)));
}

/// Every demo of the left menu: a title, what it shows, and the page.
final List<DemoPage> demoPages = [
  DemoPage(
    id: 'simple-list',
    title: 'Simple list',
    subtitle: 'SteadyChatList.list: hand it a List and call setState. '
        'Adds, inserts, edits and removals never move what you read.',
    icon: Icons.list_alt,
    builder: (context) => const SimpleListPage(),
  ),
  DemoPage(
    id: 'stream',
    title: 'Stream of snapshots',
    subtitle: 'SteadyChatList.stream: Firestore-style query snapshots. '
        'The list diffs each snapshot and stays put while rows arrive.',
    icon: Icons.stream,
    builder: (context) => const StreamPage(),
  ),
  DemoPage(
    id: 'ai',
    title: 'AI streaming reply',
    subtitle: 'A message that grows word by word: followed at the bottom, '
        'ignored when you scroll up to read.',
    icon: Icons.auto_awesome,
    builder: (context) => const AiPage(),
  ),
  DemoPage(
    id: 'big',
    title: '10,000,000 messages',
    subtitle: 'Paging in both directions with a window of 80 rows. Jump to '
        'any message number or date in one request, with media and albums.',
    icon: Icons.all_inclusive,
    builder: (context) => const BigChannelPage(),
  ),
  DemoPage(
    id: 'group',
    title: 'Group chat, all features',
    subtitle: 'Optimistic sending, replies with jump-back, reactions, '
        'mentions, pinned bar, selection, swipe to reply, day chips, '
        'unread divider, typing footer.',
    icon: Icons.forum,
    builder: (context) => const GroupPage(),
  ),
  DemoPage(
    id: 'search',
    title: 'Search navigation',
    subtitle: '"3 of 250,000": step through server search results with '
        'highlighting, a results list and paged loading.',
    icon: Icons.search,
    builder: (context) => const SearchDemoPage(),
  ),
  DemoPage(
    id: 'chaos',
    title: 'Server chaos & performance',
    subtitle: 'Latency, failures, 50 messages/s, reaction storms, remote '
        'deletes and edits, lost connection. Frame times on screen.',
    icon: Icons.bolt,
    builder: (context) => const ChaosPage(),
  ),
  DemoPage(
    id: 'cache',
    title: 'Offline cache',
    subtitle: 'In-memory or Drift (SQLite, also in the browser): chats '
        'open instantly and offline after a restart.',
    icon: Icons.storage,
    builder: (context) => const CachePage(),
  ),
  DemoPage(
    id: 'restore',
    title: 'Reload restores position',
    subtitle: 'Reload the browser tab or restart the app: every chat '
        'reopens at the same message and pixel.',
    icon: Icons.restore,
    builder: (context) => const RestorePage(),
  ),
  DemoPage(
    id: 'split',
    title: 'Split view & shared hub',
    subtitle: 'One controller switched between chats, each with its own '
        'position; two views of one chat stay in sync.',
    icon: Icons.vertical_split,
    builder: (context) => const SplitPage(),
  ),
  DemoPage(
    id: 'events',
    title: 'Events & debug overlay',
    subtitle: 'The controller.events stream live, the anchor line, and '
        'debugDescribe() for bug reports.',
    icon: Icons.bug_report,
    builder: (context) => const EventsPage(),
  ),
  DemoPage(
    id: 'theme',
    title: 'Theming, RTL, custom builders',
    subtitle: 'SteadyChatList.source with MessageListTheme, right-to-left '
        'layout, a custom unread divider and scroll-down button.',
    icon: Icons.palette,
    builder: (context) => const ThemePage(),
  ),
];

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key, required this.demo});

  final Demo demo;

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  static const _pagePref = 'demo.page';
  static const _darkPref = 'demo.dark';

  late DemoPage _page;
  late bool _dark;

  @override
  void initState() {
    super.initState();
    final preferences = widget.demo.preferences;
    // The open page is remembered too, so a reload returns to it.
    final saved = preferences.getString(_pagePref);
    _page = demoPages.firstWhere(
      (page) => page.id == saved,
      orElse: () => demoPages.first,
    );
    _dark = preferences.getBool(_darkPref) ?? false;
  }

  void _select(DemoPage page) {
    setState(() => _page = page);
    widget.demo.preferences.setString(_pagePref, page.id);
  }

  void _setDark(bool dark) {
    setState(() => _dark = dark);
    widget.demo.preferences.setBool(_darkPref, dark);
  }

  @override
  Widget build(BuildContext context) => DemoScope(
        demo: widget.demo,
        child: MaterialApp(
          title: 'steady_chat_list',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFF3390EC),
            brightness: _dark ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MessageListThemeScope(
            theme: _dark
                ? const MessageListTheme.dark()
                : const MessageListTheme(),
            child: child!,
          ),
          home: _Shell(
            page: _page,
            dark: _dark,
            onSelect: _select,
            onDark: _setDark,
          ),
        ),
      );
}

class _Shell extends StatelessWidget {
  const _Shell({
    required this.page,
    required this.dark,
    required this.onSelect,
    required this.onDark,
  });

  final DemoPage page;
  final bool dark;
  final ValueChanged<DemoPage> onSelect;
  final ValueChanged<bool> onDark;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final body = KeyedSubtree(
      key: ValueKey(page.id),
      child: Builder(builder: page.builder),
    );
    if (!wide) {
      return Scaffold(
        appBar: AppBar(
          title: Text(page.title),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(40),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                page.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        drawer: Drawer(
          child: SafeArea(
            child: _Menu(
              page: page,
              dark: dark,
              onDark: onDark,
              onSelect: (selected) {
                Navigator.of(context).pop();
                onSelect(selected);
              },
            ),
          ),
        ),
        body: SafeArea(child: body),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: 320,
              child: _Menu(
                page: page,
                dark: dark,
                onDark: onDark,
                onSelect: onSelect,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          page.title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          page.subtitle,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The left menu: one tile per demo, with what it demonstrates below the
/// title.
class _Menu extends StatelessWidget {
  const _Menu({
    required this.page,
    required this.dark,
    required this.onSelect,
    required this.onDark,
  });

  final DemoPage page;
  final bool dark;
  final ValueChanged<DemoPage> onSelect;
  final ValueChanged<bool> onDark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          ListTile(
            title: const Text(
              'steady_chat_list',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: const Text('A message list that never jumps'),
            trailing: IconButton(
              tooltip: dark ? 'Light theme' : 'Dark theme',
              onPressed: () => onDark(!dark),
              icon: Icon(dark ? Icons.light_mode : Icons.dark_mode),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (final entry in demoPages)
                  ListTile(
                    selected: entry.id == page.id,
                    selectedTileColor: scheme.secondaryContainer,
                    leading: Icon(entry.icon),
                    title: Text(entry.title),
                    subtitle: Text(
                      entry.subtitle,
                      style: const TextStyle(fontSize: 12),
                    ),
                    isThreeLine: true,
                    onTap: () => onSelect(entry),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
