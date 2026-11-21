import 'dart:async';

import 'package:flutter/material.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import '../data/fake_chat_server.dart' show words;
import '../data/models.dart';
import '../demo.dart';
import '../widgets/bubble.dart';

ChatMessage _message(int n, String text, {bool mine = false}) => ChatMessage(
      key: MessageKey(order: n, id: '$n'),
      text: text,
      senderId: mine ? 'me' : 'alice',
      sentAt: DateTime(2026, 1, 1, 9).add(Duration(minutes: n * 7)),
      outgoing: mine,
    );

Widget _bubble(BuildContext context, ChatMessage m, MessageItemInfo info) =>
    MessageBubble(message: m, info: info);

Widget _toolbar(List<Widget> children) => Material(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(spacing: 8, runSpacing: 8, children: children),
      ),
    );

/// `SteadyChatList.list`: the app owns a plain `List` and calls `setState`.
class SimpleListPage extends StatefulWidget {
  const SimpleListPage({super.key});

  @override
  State<SimpleListPage> createState() => _SimpleListPageState();
}

class _SimpleListPageState extends State<SimpleListPage> {
  List<ChatMessage> _messages = [
    for (var n = 1; n <= 60; n++)
      _message(n * 10, '${words[n % words.length]} number $n',
          mine: n % 3 == 0),
  ];
  int _next = 61;

  void _change(void Function(List<ChatMessage> list) edit) {
    final copy = [..._messages];
    edit(copy);
    // A new list each time, like any immutable state.
    setState(() => _messages = copy);
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          _toolbar([
            FilledButton.tonal(
              onPressed: () => _change((list) {
                final n = _next++;
                list.add(_message(n * 10, 'New message $n', mine: n.isEven));
              }),
              child: const Text('Add at the end'),
            ),
            FilledButton.tonal(
              onPressed: () => _change((list) {
                // Order 5, 15, 25…: lands between existing messages.
                final at = list.length ~/ 2;
                final order = list[at].key.order + 1 + _next++ % 8;
                list.add(_message(order, 'Inserted in the middle'));
              }),
              child: const Text('Insert in the middle'),
            ),
            FilledButton.tonal(
              onPressed: () => _change((list) {
                final at = list.length ~/ 3;
                list[at] = list[at].copyWith(
                  text: '${list[at].text}\nedited: one more line',
                  edited: true,
                );
              }),
              child: const Text('Edit one (grows)'),
            ),
            FilledButton.tonal(
              onPressed: _messages.length < 4
                  ? null
                  : () => _change((list) => list.removeAt(list.length ~/ 2)),
              child: const Text('Remove one'),
            ),
            FilledButton.tonal(
              onPressed: () => _change((list) {
                for (var i = 0; i < 1000; i++) {
                  final n = _next++;
                  list.add(_message(n * 10, 'Bulk message $n'));
                }
              }),
              child: const Text('Add 1,000'),
            ),
            Chip(label: Text('${_messages.length} messages')),
          ]),
          Expanded(
            child: SteadyChatList<ChatMessage>.list(
              messages: _messages,
              adapter: chatAdapter,
              list: const ListId('simple-list'),
              viewportStore: DemoScope.of(context).viewportStore,
              itemBuilder: _bubble,
            ),
          ),
        ],
      );
}

/// `SteadyChatList.stream`: a stream of whole snapshots, as Firestore,
/// Supabase or a local database query give them.
class StreamPage extends StatefulWidget {
  const StreamPage({super.key});

  @override
  State<StreamPage> createState() => _StreamPageState();
}

class _StreamPageState extends State<StreamPage> {
  final List<ChatMessage> _rows = [
    for (var n = 1; n <= 30; n++) _message(n, 'Row $n of the query'),
  ];
  late final StreamController<List<ChatMessage>> _snapshots =
      StreamController<List<ChatMessage>>.broadcast(
    onListen: _emit,
  );
  Timer? _timer;
  bool _live = true;

  @override
  void initState() {
    super.initState();
    _setLive(true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_snapshots.close());
    super.dispose();
  }

  // Every change sends the complete result again; the list works out what
  // was added, changed and removed.
  void _emit() => _snapshots.add([..._rows]);

  void _setLive(bool live) {
    _timer?.cancel();
    _live = live;
    if (live) {
      _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
        final n = _rows.last.key.order + 1;
        _rows.add(
            _message(n, 'Row $n arrived from the stream', mine: n % 4 == 0));
        _emit();
      });
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          _toolbar([
            FilterChip(
              label: const Text('Rows keep arriving'),
              selected: _live,
              onSelected: _setLive,
            ),
            FilledButton.tonal(
              onPressed: () {
                _rows.removeAt(_rows.length ~/ 2);
                _emit();
              },
              child: const Text('Delete a row'),
            ),
            FilledButton.tonal(
              onPressed: () {
                final at = _rows.length - 3;
                _rows[at] = _rows[at].copyWith(
                  text: '${_rows[at].text} (changed)',
                  edited: true,
                );
                _emit();
              },
              child: const Text('Change a row'),
            ),
          ]),
          Expanded(
            child: SteadyChatList<ChatMessage>.stream(
              stream: _snapshots.stream,
              adapter: chatAdapter,
              list: const ListId('simple-stream'),
              viewportStore: DemoScope.of(context).viewportStore,
              itemBuilder: _bubble,
            ),
          ),
        ],
      );
}

/// An assistant whose answer grows word by word.
class AiPage extends StatefulWidget {
  const AiPage({super.key});

  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> {
  List<ChatMessage> _messages = [
    _message(1, 'Ask anything. The answer is streamed word by word.'),
  ];
  final TextEditingController _input = TextEditingController();
  Timer? _stream;
  int _next = 2;

  static const _answer =
      'Here is a long answer that arrives in small pieces. While you stay at '
      'the bottom, the list follows the growing message. Scroll up while it '
      'is still writing and nothing moves under your finger: the message '
      'keeps growing below the screen and the scroll-down button appears. '
      'The same mechanism keeps the list still when an image above the '
      'screen finishes loading or when someone edits an old message. ';

  @override
  void dispose() {
    _stream?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _ask() {
    final question = _input.text.trim();
    if (question.isEmpty || _stream != null) return;
    _input.clear();
    final answerId = _next + 1;
    setState(() {
      _messages = [
        ..._messages,
        _message(_next, question, mine: true),
        _message(answerId, '…'),
      ];
      _next += 2;
    });
    final tokens = (_answer * 3).split(' ');
    var shown = 0;
    _stream = Timer.periodic(const Duration(milliseconds: 45), (timer) {
      shown++;
      final text = tokens.take(shown).join(' ');
      setState(() {
        _messages = [
          for (final m in _messages)
            if (m.key.order == answerId) m.copyWith(text: text) else m,
        ];
      });
      if (shown >= tokens.length) {
        timer.cancel();
        setState(() => _stream = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Expanded(
            child: SteadyChatList<ChatMessage>.list(
              messages: _messages,
              adapter: chatAdapter,
              list: const ListId('simple-ai'),
              itemBuilder: _bubble,
            ),
          ),
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        hintText: 'Ask something',
                      ),
                      onEditingComplete: _ask,
                    ),
                  ),
                  IconButton(
                    onPressed: _stream == null ? _ask : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}
