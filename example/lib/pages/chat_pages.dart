import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import '../data/fake_chat_server.dart';
import '../data/models.dart';
import '../demo.dart';
import '../widgets/bubble.dart';
import '../widgets/chat_pane.dart';
import '../widgets/panels.dart';

typedef ChatController = MessageListController<ChatMessage>;

Widget _bar(BuildContext context, List<Widget> children) => Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: SizedBox(
          width: double.infinity,
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
        ),
      ),
    );

Widget _hint(BuildContext context, String text) => Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );

/// A chat with a panel next to it; under 1000 px the panel opens as a
/// sheet from a button.
class WithPanel extends StatelessWidget {
  const WithPanel({
    super.key,
    required this.child,
    required this.panel,
    required this.label,
    this.width = 340,
  });

  final Widget child;
  final Widget panel;
  final String label;
  final double width;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 1000 - 320) {
            return Row(
              children: [
                Expanded(child: child),
                const VerticalDivider(width: 1),
                SizedBox(width: width, child: Material(child: panel)),
              ],
            );
          }
          return Stack(
            children: [
              Positioned.fill(child: child),
              Positioned(
                left: 12,
                bottom: 72,
                child: FloatingActionButton.extended(
                  heroTag: label,
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (context) => SizedBox(height: 420, child: panel),
                  ),
                  icon: const Icon(Icons.tune),
                  label: Text(label),
                ),
              ),
            ],
          );
        },
      );
}

// ------------------------------------------------------------ 10 million

class BigChannelPage extends StatefulWidget {
  const BigChannelPage({super.key});

  @override
  State<BigChannelPage> createState() => _BigChannelPageState();
}

class _BigChannelPageState extends State<BigChannelPage> {
  ChatController? _chat;
  bool _overlay = false;
  String _last = '';
  final TextEditingController _number = TextEditingController();

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _go(
      Future<JumpResult> Function(ChatController chat) jump) async {
    final chat = _chat;
    if (chat == null) return;
    final watch = Stopwatch()..start();
    final result = await jump(chat);
    if (!mounted) return;
    setState(
      () => _last = '${result.outcome.name} in '
          '${watch.elapsedMilliseconds} ms',
    );
  }

  @override
  Widget build(BuildContext context) {
    final server = DemoScope.of(context).server;
    return ChatPane(
      chat: bigChannel,
      composer: false,
      debugOverlay: _overlay,
      onController: (chat) => setState(() => _chat = chat),
      header: _bar(context, [
        FilledButton.tonal(
          onPressed: () => _go((c) => c.jumpTo(server.keyOfNumber(1))),
          child: const Text('First message'),
        ),
        FilledButton.tonal(
          onPressed: () => _go((c) => c.jumpTo(server.keyOfNumber(5000000))),
          child: const Text('#5,000,000'),
        ),
        SizedBox(
          width: 150,
          child: TextField(
            controller: _number,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: 'Message number',
            ),
            onSubmitted: (text) {
              final n = int.tryParse(text);
              if (n == null || n < 1) return;
              unawaited(_go((c) => c.jumpTo(server.keyOfNumber(n))));
            },
          ),
        ),
        FilledButton.tonal(
          onPressed: () async {
            final day = await showDatePicker(
              context: context,
              initialDate: DateTime(2030),
              firstDate: DateTime(2020),
              lastDate: DateTime(2039),
            );
            if (day != null) unawaited(_go((c) => c.jumpToDate(day)));
          },
          child: const Text('Jump to a date'),
        ),
        FilledButton.tonal(
          onPressed: () => _go((c) => c.jumpToBottom()),
          child: const Text('Newest'),
        ),
        FilterChip(
          label: const Text('Debug overlay'),
          selected: _overlay,
          onSelected: (on) => setState(() => _overlay = on),
        ),
        if (_last.isNotEmpty) _hint(context, 'Last jump: $_last'),
      ]),
    );
  }
}

// ------------------------------------------------------------------ group

class GroupPage extends StatelessWidget {
  const GroupPage({super.key});

  @override
  Widget build(BuildContext context) => ChatPane(
        chat: groupChat,
        pinnedBar: true,
        header: _bar(context, [
          _hint(
            context,
            'Long-press: select (shift-click a second one for a range) · '
            'swipe a message left: reply · tap a reply quote: jump and '
            'come back with the down button · tap a reaction · tap the '
            'pinned bar · tap a day chip · @ button: next mention',
          ),
        ]),
      );
}

// ----------------------------------------------------------------- search

class SearchDemoPage extends StatelessWidget {
  const SearchDemoPage({super.key});

  @override
  Widget build(BuildContext context) => ChatPane(
        chat: bigChannel,
        list: const ListId('big', 'search'),
        composer: false,
        search: true,
        header: _bar(context, [
          _hint(
            context,
            'Try "invoice", "meet" or "b". Enter or ▲ goes to the next '
            'older result, anywhere in ten million messages. Results load '
            'page by page; closing the search keeps you where you are.',
          ),
        ]),
      );
}

// ------------------------------------------------------------------ chaos

class ChaosPage extends StatefulWidget {
  const ChaosPage({super.key});

  @override
  State<ChaosPage> createState() => _ChaosPageState();
}

class _ChaosPageState extends State<ChaosPage> {
  final ValueNotifier<ChatController?> _chat = ValueNotifier(null);
  FakeChatServer? _server;

  @override
  void dispose() {
    // Leave the server calm for the other pages.
    _server
      ?..incomingPerSecond.value = 0
      ..reactionsPerSecond.value = 0
      ..failurePercent.value = 0
      ..latencyMs.value = 150
      ..reconnect()
      ..applyRates();
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = _server = DemoScope.of(context).server;
    return WithPanel(
      label: 'Server',
      panel: ServerPanel(server: server, controller: _chat),
      child: Stack(
        children: [
          Positioned.fill(
            child: ChatPane(
              chat: friendChat,
              onController: (chat) => _chat.value = chat,
              header: _bar(context, [
                _hint(
                  context,
                  'Scroll up a little, then make things happen. What you '
                  'are reading must not move by a pixel.',
                ),
              ]),
            ),
          ),
          const Positioned(top: 48, right: 12, child: PerfHud()),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ split

class SplitPage extends StatefulWidget {
  const SplitPage({super.key});

  @override
  State<SplitPage> createState() => _SplitPageState();
}

class _SplitPageState extends State<SplitPage> {
  DemoChat _open = groupChat;
  bool _twin = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 190,
          child: Material(
            color: scheme.surfaceContainerLow,
            child: ListView(
              children: [
                for (final chat in demoChats)
                  ListTile(
                    selected: chat.id == _open.id,
                    leading: CircleAvatar(child: Text(chat.title[0])),
                    title: Text(chat.title),
                    subtitle: Text('${thousands(chat.count)} messages'),
                    onTap: () => setState(() => _open = chat),
                  ),
                const Divider(),
                SwitchListTile(
                  dense: true,
                  title: const Text('Second view of the same chat'),
                  value: _twin,
                  onChanged: (on) => setState(() => _twin = on),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: _hint(
                    context,
                    'One controller is switched between chats; each chat '
                    'comes back at its own position. The second view has '
                    'its own scroll position but shares the messages: send '
                    'or delete in one and watch the other.',
                  ),
                ),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        // No key: the same pane (and controller) shows whichever chat is
        // selected, through `controller.switchTo`.
        Expanded(child: ChatPane(chat: _open)),
        if (_twin) ...[
          const VerticalDivider(width: 1),
          Expanded(child: ChatPane(chat: _open, composer: false)),
        ],
      ],
    );
  }
}

// ----------------------------------------------------------------- events

class EventsPage extends StatefulWidget {
  const EventsPage({super.key});

  @override
  State<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> {
  ChatController? _chat;
  bool _overlay = true;

  @override
  Widget build(BuildContext context) {
    final chat = _chat;
    return WithPanel(
      label: 'Events',
      panel: chat == null
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: OutlinedButton(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: chat.debugDescribe()),
                    ),
                    child: const Text('Copy debugDescribe()'),
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: EventLog(controller: chat)),
              ],
            ),
      child: ChatPane(
        chat: savedChat,
        debugOverlay: _overlay,
        onController: (chat) => setState(() => _chat = chat),
        header: _bar(context, [
          FilterChip(
            label: const Text('Debug overlay'),
            selected: _overlay,
            onSelected: (on) => setState(() => _overlay = on),
          ),
          _hint(
            context,
            'Everything the list does is reported on controller.events. '
            'In debug builds (flutter run) the overlay draws the anchor '
            'line and the state of the window.',
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ theme

class ThemePage extends StatefulWidget {
  const ThemePage({super.key});

  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  bool _rtl = false;
  bool _custom = true;
  int _palette = 1;

  static const _palettes = [
    ('Default', null),
    ('Forest', Color(0xFF2E7D32)),
    ('Sunset', Color(0xFFE65100)),
  ];

  @override
  Widget build(BuildContext context) {
    final demo = DemoScope.of(context);
    final accent = _palettes[_palette].$2;
    final base = MessageListTheme.of(context);
    final theme = accent == null
        ? base
        : base.copyWith(
            badgeColor: accent,
            dividerTextColor: accent,
            dividerColor: accent.withAlpha(30),
            highlightColor: accent.withAlpha(70),
            chipColor: accent.withAlpha(200),
          );
    return Column(
      children: [
        _bar(context, [
          FilterChip(
            label: const Text('Right to left'),
            selected: _rtl,
            onSelected: (on) => setState(() => _rtl = on),
          ),
          for (var i = 0; i < _palettes.length; i++)
            ChoiceChip(
              label: Text(_palettes[i].$1),
              selected: _palette == i,
              onSelected: (_) => setState(() => _palette = i),
            ),
          FilterChip(
            label: const Text('Custom builders'),
            selected: _custom,
            onSelected: (on) => setState(() => _custom = on),
          ),
        ]),
        Expanded(
          child: Directionality(
            textDirection: _rtl ? TextDirection.rtl : TextDirection.ltr,
            child: MessageListThemeScope(
              theme: theme,
              // `SteadyChatList.source`: a backend and one widget, no hub
              // or controller to manage.
              child: SteadyChatList<ChatMessage>.source(
                source: demo.server,
                adapter: chatAdapter,
                list: groupChat.list,
                itemBuilder: (context, m, info) =>
                    MessageBubble(message: m, info: info, showSender: true),
                dayHeaderBuilder: (context, day, onTap) =>
                    DayHeader(day: day, onTap: onTap),
                floatingDayBuilder: (context, day, onTap) =>
                    DayHeader(day: day, onTap: onTap),
                unreadDividerBuilder: !_custom
                    ? null
                    : (context) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              const Expanded(child: Divider(indent: 16)),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                child: Text(
                                  '★ new for you ★',
                                  style: TextStyle(
                                    color: theme.dividerTextColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const Expanded(child: Divider(endIndent: 16)),
                            ],
                          ),
                        ),
                scrollDownButtonBuilder: !_custom
                    ? null
                    : (context, unread, onTap) => FloatingActionButton.small(
                          heroTag: 'theme-down',
                          onPressed: onTap,
                          backgroundColor: theme.badgeColor,
                          foregroundColor: theme.badgeTextColor,
                          child: unread > 0
                              ? Text(formatUnreadCount(unread))
                              : const Icon(Icons.arrow_downward),
                        ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ cache

enum _CacheKind { none, memory, drift }

class CachePage extends StatefulWidget {
  const CachePage({super.key});

  @override
  State<CachePage> createState() => _CachePageState();
}

class _CachePageState extends State<CachePage> {
  static const _pref = 'demo.cache';
  late Demo _demo;
  MessageListHub<ChatMessage>? _hub;
  _CacheKind _kind = _CacheKind.drift;
  int _run = 0;
  String _status = '';
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _demo = DemoScope.of(context);
    final saved = _demo.preferences.getString(_pref);
    _kind = _CacheKind.values.firstWhere(
      (kind) => kind.name == saved,
      orElse: () => _CacheKind.drift,
    );
    unawaited(_restart());
  }

  @override
  void dispose() {
    _demo.server.reconnect(); // back online for the other pages
    _hub?.dispose();
    super.dispose();
  }

  MessageCache<ChatMessage>? get _cache => switch (_kind) {
        _CacheKind.none => null,
        _CacheKind.memory => _demo.memoryCache,
        _CacheKind.drift => _demo.driftCache,
      };

  /// What an app does at start: create the hub, read the chat from the
  /// cache, then show it. The first frame is already the cached chat.
  Future<void> _restart() async {
    final old = _hub;
    final requests = _demo.server.requestCount.value;
    final watch = Stopwatch()..start();
    final hub = _demo.newHub(cache: _cache);
    String status;
    try {
      await hub.hydrate(friendChat.list);
      status = _cache == null
          ? 'No cache: the chat is loaded from the server.'
          : 'Read from the cache in ${watch.elapsedMilliseconds} ms, '
              '${_demo.server.requestCount.value - requests} server '
              'requests before the first frame.';
    } on Object catch (error) {
      status = 'Cache unavailable: $error';
    }
    if (!mounted) {
      hub.dispose();
      return;
    }
    setState(() {
      _hub = hub;
      _run++;
      _status = status;
    });
    // The old screen is gone after this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final hub = _hub;
    return Column(
      children: [
        _bar(context, [
          SegmentedButton<_CacheKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _CacheKind.none, label: Text('No cache')),
              ButtonSegment(value: _CacheKind.memory, label: Text('In memory')),
              ButtonSegment(
                value: _CacheKind.drift,
                label: Text('Drift (SQLite)'),
              ),
            ],
            selected: {_kind},
            onSelectionChanged: (selection) {
              _kind = selection.first;
              unawaited(_demo.preferences.setString(_pref, _kind.name));
              unawaited(_restart());
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _demo.server.online,
            builder: (context, online, _) => FilterChip(
              avatar: Icon(online ? Icons.wifi : Icons.wifi_off, size: 18),
              label: Text(online ? 'Online' : 'Offline'),
              selected: !online,
              onSelected: (offline) => offline
                  ? _demo.server.disconnect()
                  : _demo.server.reconnect(),
            ),
          ),
          FilledButton.tonal(
            onPressed: _restart,
            child: const Text('Restart the app (new hub)'),
          ),
          OutlinedButton(
            onPressed: () async {
              await _cache?.clear();
              await _restart();
            },
            child: const Text('Clear the cache'),
          ),
          _hint(
            context,
            '$_status\nLoad some history, go offline, restart: with a '
            'cache the chat opens at once at the same position, without '
            'one it shows an error. The Drift cache also survives a '
            'browser reload.',
          ),
        ]),
        Expanded(
          child: hub == null
              ? const Center(child: SteadySpinner())
              : ChatPane(
                  key: ValueKey(_run),
                  chat: friendChat,
                  hub: hub,
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- restore

class RestorePage extends StatefulWidget {
  const RestorePage({super.key});

  @override
  State<RestorePage> createState() => _RestorePageState();
}

class _RestorePageState extends State<RestorePage> {
  static const _list = ListId('big', 'restore');
  StreamSubscription<MessageListEvent>? _events;
  String _saved = 'Scroll somewhere; the position is saved when you stop.';
  int _run = 0;

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  void _watch(ChatController chat) {
    unawaited(_events?.cancel());
    _events = chat.events.listen((event) {
      if (event is! SnapshotSaved || !mounted) return;
      final visible = chat.visibleItems;
      if (visible.isEmpty) return;
      final time = TimeOfDay.now().format(context);
      setState(
        () => _saved = 'Saved at $time (${event.reason.name}): top message '
            '#${visible.first.key.id}',
      );
    });
  }

  @override
  Widget build(BuildContext context) => ChatPane(
        key: ValueKey(_run),
        chat: bigChannel,
        list: _list,
        composer: false,
        onController: _watch,
        header: _bar(context, [
          const Icon(Icons.refresh, size: 18),
          _hint(
            context,
            'Scroll anywhere in these ten million messages, then reload the '
            'browser tab (or quit and start the app). You come back to this '
            'page, at the same message, at the same pixel.',
          ),
          Chip(label: Text(_saved)),
          OutlinedButton(
            // The same thing a reload does, without leaving the page.
            onPressed: () => setState(() => _run++),
            child: const Text('Close and reopen the chat'),
          ),
        ]),
      );
}
