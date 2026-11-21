import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import '../data/fake_chat_server.dart';
import '../data/models.dart';
import '../demo.dart';
import 'bubble.dart';

/// A complete chat screen built from the package: the list, the floating
/// buttons, a pinned bar, search navigation, selection, a composer with
/// optimistic sending, reactions with a burst effect and swipe to reply.
/// Most demo pages are this widget with different switches.
class ChatPane extends StatefulWidget {
  const ChatPane({
    super.key,
    required this.chat,
    this.hub,
    this.list,
    this.target = const OpenTarget.auto(),
    this.config = const MessageListConfig(),
    this.composer = true,
    this.pinnedBar = false,
    this.search = false,
    this.debugOverlay = false,
    this.onController,
    this.header,
  });

  final DemoChat chat;

  /// The hub to use; the shared demo hub when null.
  final MessageListHub<ChatMessage>? hub;

  /// The list to show; the chat itself when null (a thread uses another).
  final ListId? list;
  final OpenTarget target;
  final MessageListConfig config;
  final bool composer;
  final bool pinnedBar;
  final bool search;
  final bool debugOverlay;
  final void Function(MessageListController<ChatMessage> controller)?
      onController;
  final Widget? header;

  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  late Demo _demo;
  late MessageListController<ChatMessage> _controller;
  MessageSearchNavigator<ChatMessage>? _search;
  final TextEditingController _input = TextEditingController();
  final TextEditingController _query = TextEditingController();
  final List<_Burst> _bursts = [];
  ChatMessage? _replyingTo;
  bool _showResults = false;
  bool _created = false;
  int _sent = 0;

  ListId get _list => widget.list ?? widget.chat.list;
  FakeChatServer get _server => _demo.server;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_created) return;
    _created = true;
    _demo = DemoScope.of(context);
    _controller = MessageListController<ChatMessage>(
      hub: widget.hub ?? _demo.hub,
      list: _list,
      config: widget.config,
    )..open(target: widget.target);
    _server.activate(
      _list,
      () => [for (final item in _controller.visibleItems) item.key],
    );
    if (widget.search) {
      _search = _controller.search(_server)..addListener(_rebuild);
    }
    // After the frame: the owner may want to rebuild with the controller.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onController?.call(_controller);
    });
  }

  @override
  void didUpdateWidget(ChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.list ?? oldWidget.chat.list;
    if (before == _list) return;
    // Another chat in the same pane: one controller, switched. The old
    // chat's position is saved, the new one opens where it was left.
    _server.deactivate(before);
    unawaited(_controller.switchTo(_list, target: widget.target));
    _server.activate(
      _list,
      () => [for (final item in _controller.visibleItems) item.key],
    );
    setState(() => _replyingTo = null);
  }

  @override
  void dispose() {
    _server.deactivate(_list);
    _search?.removeListener(_rebuild);
    _controller.dispose();
    _input.dispose();
    _query.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------- actions

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final reply = _replyingTo;
    setState(() => _replyingTo = null);
    final id = 'local-${DateTime.now().microsecondsSinceEpoch}-${_sent++}';
    ChatMessage? pending;
    // The message appears at once; the server confirms (or fails) later.
    await _controller.insertLocal(
      id: id,
      build: (key) => pending = ChatMessage(
        key: key,
        text: text,
        senderId: 'me',
        sentAt: DateTime.now(),
        outgoing: true,
        replyTo: reply?.key,
      ),
    );
    if (pending != null) _server.send(_list, id, pending!);
  }

  void _react(ChatMessage message, String emoji) {
    _server.update(_list, message.toggleReaction(emoji));
    // The burst is placed with the geometry API: rectOf gives the item's
    // rectangle in global coordinates.
    final rect = _controller.rectOf(message.key);
    final box = context.findRenderObject() as RenderBox?;
    if (rect == null || box == null) return;
    final burst = _Burst(emoji, box.globalToLocal(rect.center));
    setState(() => _bursts.add(burst));
    Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _bursts.remove(burst));
    });
  }

  void _tap(ChatMessage message, MessageItemInfo info) {
    final selection = _controller.selection;
    if (!selection.active) return;
    // Shift-click selects the range (desktop and web).
    if (HardwareKeyboard.instance.isShiftPressed) {
      selection.extendTo(info.key);
    } else {
      selection.toggle(message.id);
    }
  }

  Future<void> _pickDay(DateTime day) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: day,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365 * 20)),
    );
    if (picked != null) unawaited(_controller.jumpToDate(picked));
  }

  void _deleteSelected() {
    final ids = _controller.selection.selectedIds.toList();
    final keys = [
      for (final id in ids) MessageKey(order: int.tryParse(id) ?? 0, id: id),
    ];
    // A batch delete: the rows animate out together, with one correction.
    _controller.remove(ids);
    _server.remoteDelete(_list, keys);
  }

  // ----------------------------------------------------------------- build

  Widget _item(
      BuildContext context, ChatMessage message, MessageItemInfo info) {
    final reply = message.replyTo;
    final replied = reply == null ? null : _controller.messageOf(reply);
    final bubble = MessageBubble(
      message: message,
      info: info,
      showSender: widget.chat.group,
      replyPreview: replied?.text,
      onReplyTap: reply == null
          ? null
          : () => _controller.jumpTo(
                reply,
                options: const JumpOptions(reason: JumpReason.reply),
              ),
      onReact: (emoji) => _react(message, emoji),
      onTap: () => _tap(message, info),
      onLongPress: () => _controller.selection.toggle(message.id),
    );
    if (message.service || info.selectionActive) return bubble;
    return SwipeToReply(
      onTriggered: () => setState(() => _replyingTo = message),
      background: (context, progress) => FadeTransition(
        opacity: progress,
        child: const Padding(
          padding: EdgeInsets.only(right: 16),
          child: Icon(Icons.reply),
        ),
      ),
      child: bubble,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = MessageListView<ChatMessage>(
      controller: _controller,
      debugOverlay: widget.debugOverlay,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemBuilder: _item,
      groupBuilder: (context, messages, info) =>
          AlbumBubble(messages: messages, info: info),
      dayHeaderBuilder: (context, day, onTap) =>
          DayHeader(day: day, onTap: onTap),
      floatingDayBuilder: (context, day, onTap) =>
          DayHeader(day: day, onTap: onTap),
      onDayTap: _pickDay,
      historyStartBuilder: (context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            'This is the beginning of "${widget.chat.title}"',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      ),
      footerBuilder: (context) => ValueListenableBuilder<Set<String>>(
        valueListenable: _controller.typingUserIds,
        builder: (context, typing, _) => typing.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '${typing.map(senderName).join(', ')} is typing…',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
      ),
    );
    return ColoredBox(
      color: scheme.surface,
      child: Column(
        children: [
          if (widget.header != null) widget.header!,
          if (widget.search) _searchBar(scheme),
          if (widget.pinnedBar) _pinnedBar(scheme),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: list),
                // Mention, reaction and scroll-down buttons with badges.
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: MessageListButtons<ChatMessage>(
                    controller: _controller,
                  ),
                ),
                for (final burst in _bursts)
                  Positioned(
                    left: burst.at.dx - 24,
                    top: burst.at.dy - 24,
                    child: _BurstEffect(emoji: burst.emoji),
                  ),
                if (_showResults && _search != null) _resultsList(scheme),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: _controller.selection,
            builder: (context, _) => _controller.selection.active
                ? _selectionBar(scheme)
                : widget.composer
                    ? _composer(scheme)
                    : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _pinnedBar(ColorScheme scheme) => ValueListenableBuilder<MessageKey?>(
        valueListenable: _controller.currentPinned,
        builder: (context, pinned, _) {
          if (pinned == null) return const SizedBox.shrink();
          final message =
              _controller.messageOf(pinned) ?? _server.messageAt(_list, pinned);
          return Material(
            color: scheme.surfaceContainer,
            child: InkWell(
              onTap: () {
                // Tapping the bar goes to the shown message; the bar then
                // shows the pinned message before it.
                unawaited(_controller.jumpToPinned(pinned, barHeight: 8));
              },
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    Icon(Icons.push_pin, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Pinned: ${message?.text ?? pinned.id}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _searchBar(ColorScheme scheme) {
    final search = _search!;
    final index = search.index;
    final total = search.total ?? search.loaded;
    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _query,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: 'Search, e.g. ${words.take(4).join(', ')}…',
                ),
                onChanged: (text) {
                  // Debounced by the navigator; a new query cancels the
                  // previous one.
                  unawaited(search.setQuery(text));
                },
                // Not onSubmitted: the field keeps the focus, so Enter
                // again goes to the next result.
                onEditingComplete: search.next,
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<SearchStatus>(
              valueListenable: search.status,
              builder: (context, status, _) => SizedBox(
                width: 132,
                child: Text(
                  switch (status) {
                    SearchStatus.idle => '',
                    SearchStatus.searching => 'Searching…',
                    SearchStatus.empty => 'No results',
                    SearchStatus.error => 'Error',
                    SearchStatus.ready => index == null
                        ? '${thousands(total)} found'
                        : '${thousands(index + 1)} of ${thousands(total)}',
                  },
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            ValueListenableBuilder<JumpState?>(
              valueListenable: _controller.jumpInProgress,
              builder: (context, jump, _) => SizedBox.square(
                dimension: 20,
                child:
                    (jump?.isLoading ?? false) ? const SteadySpinner() : null,
              ),
            ),
            IconButton(
              tooltip: 'Older result',
              onPressed: search.hasNext ? search.next : null,
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: 'Newer result',
              onPressed: search.hasPrevious ? search.previous : null,
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
            IconButton(
              tooltip: 'Results list',
              onPressed: () => setState(() => _showResults = !_showResults),
              icon: const Icon(Icons.list),
            ),
            IconButton(
              tooltip: 'Close search (keeps the position)',
              onPressed: () {
                _query.clear();
                search.close();
                setState(() => _showResults = false);
              },
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultsList(ColorScheme scheme) {
    final search = _search!;
    final results = search.results;
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      width: 280,
      child: Material(
        elevation: 4,
        color: scheme.surfaceContainerHigh,
        child: ListView.builder(
          itemCount: results.length,
          itemBuilder: (context, i) {
            final message = _server.messageAt(_list, results[i]);
            return ListTile(
              dense: true,
              selected: i == search.index,
              title: Text(
                message?.text ?? results[i].id,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('#${results[i].id}'),
              onTap: () => search.goTo(i),
            );
          },
        ),
      ),
    );
  }

  Widget _selectionBar(ColorScheme scheme) {
    final selection = _controller.selection;
    return Material(
      color: scheme.surfaceContainer,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel',
              onPressed: selection.clear,
              icon: const Icon(Icons.close),
            ),
            Expanded(child: Text('${selection.count} selected')),
            TextButton(
              onPressed: selection.selectAllLoaded,
              child: const Text('Select all loaded'),
            ),
            IconButton(
              tooltip: 'Delete selected',
              onPressed: selection.count == 0 ? null : _deleteSelected,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer(ColorScheme scheme) => Material(
        color: scheme.surfaceContainer,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyingTo != null)
              ListTile(
                dense: true,
                leading: const Icon(Icons.reply),
                title: Text(
                  _replyingTo!.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _replyingTo = null),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        hintText: 'Message',
                      ),
                      textInputAction: TextInputAction.send,
                      onEditingComplete: _send,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Send',
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

/// 1248 → "1,248".
String thousands(int n) {
  final digits = '$n';
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

class _Burst {
  _Burst(this.emoji, this.at);

  final String emoji;
  final Offset at;
}

/// An emoji that pops and fades where a reaction was tapped.
class _BurstEffect extends StatefulWidget {
  const _BurstEffect({required this.emoji});

  final String emoji;

  @override
  State<_BurstEffect> createState() => _BurstEffectState();
}

class _BurstEffectState extends State<_BurstEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..forward();

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: FadeTransition(
          opacity: ReverseAnimation(
            CurvedAnimation(parent: _pop, curve: const Interval(0.5, 1)),
          ),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.6, end: 2.4).animate(
              CurvedAnimation(parent: _pop, curve: Curves.easeOut),
            ),
            child: SizedBox.square(
              dimension: 48,
              child: Center(
                child: Text(widget.emoji, style: const TextStyle(fontSize: 28)),
              ),
            ),
          ),
        ),
      );
}
