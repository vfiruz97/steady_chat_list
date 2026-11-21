import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';

import 'config.dart';
import 'controller.dart';
import 'events.dart';
import 'item_info.dart';
import 'view.dart';
import 'widgets.dart';

/// The whole message list in one widget: it creates the hub and the
/// controller, opens the list and disposes everything.
///
/// Pick the constructor that matches where the messages are:
///
/// * [SteadyChatList.list] — the app has them in a `List` (local chats, AI
///   assistants, small conversations). Rebuild with a new list, or the same
///   list changed, and the view follows.
/// * [SteadyChatList.stream] — a reactive query delivers the complete list
///   (Drift `watch()`, Firestore `snapshots()`, Supabase realtime).
/// * [SteadyChatList.source] — a paged backend ([MessageSource]) for
///   histories of any size.
///
/// ```dart
/// SteadyChatList<ChatMessage>.list(
///   messages: messages,
///   adapter: MessageAdapter.from(
///     key: (m) => MessageKey(order: m.sentAt.microsecondsSinceEpoch, id: m.id),
///     date: (m) => m.sentAt,
///     isOutgoing: (m) => m.authorId == myId,
///   ),
///   itemBuilder: (context, message, info) => MessageBubble(message),
/// );
/// ```
///
/// Use [onController] to scroll, jump or read state from outside. Apps that
/// show the same chat twice, switch chats without rebuilding or share a
/// cache create a [MessageListHub] and [MessageListController] themselves
/// and use [MessageListView].
class SteadyChatList<M> extends StatefulWidget {
  const SteadyChatList._({
    super.key,
    this.messages,
    this.stream,
    this.source,
    this.readState,
    required this.adapter,
    required this.itemBuilder,
    this.list = const ListId('chat'),
    this.onMarkRead,
    this.onController,
    this.config = const MessageListConfig(),
    this.callbacks,
    this.policies,
    this.viewportStore,
    this.groupBuilder,
    this.dayHeaderBuilder,
    this.unreadDividerBuilder,
    this.edgeBuilder,
    this.historyStartBuilder,
    this.footerBuilder,
    this.emptyBuilder,
    this.loadingBuilder,
    this.errorBuilder,
    this.onDayTap,
    this.padding = EdgeInsets.zero,
    this.physics,
    this.keyboardDismissBehavior = ScrollViewKeyboardDismissBehavior.onDrag,
    this.scrollbar = true,
    this.scrollDownButton = true,
    this.scrollDownButtonBuilder,
    this.floatingDayBuilder,
  });

  /// A list over [messages] the app already has (any order).
  ///
  /// The first frame already shows the newest messages. Rebuild the widget
  /// after adding, changing or removing messages; only what changed is
  /// updated, and nothing on screen moves.
  const SteadyChatList.list({
    Key? key,
    required List<M> messages,
    required MessageAdapter<M> adapter,
    required MessageItemBuilder<M> itemBuilder,
    ListId list = const ListId('chat'),
    ReadState? readState,
    MarkReadCallback? onMarkRead,
    void Function(MessageListController<M> controller)? onController,
    MessageListConfig config = const MessageListConfig(),
    MessageListCallbacks<M>? callbacks,
    MessageListPolicies<M>? policies,
    ViewportStore? viewportStore,
    MessageGroupBuilder<M>? groupBuilder,
    DayHeaderBuilder? dayHeaderBuilder,
    WidgetBuilder? unreadDividerBuilder,
    EdgeBuilder? edgeBuilder,
    WidgetBuilder? historyStartBuilder,
    WidgetBuilder? footerBuilder,
    WidgetBuilder? emptyBuilder,
    WidgetBuilder? loadingBuilder,
    WidgetBuilder? errorBuilder,
    void Function(DateTime day)? onDayTap,
    EdgeInsets padding = EdgeInsets.zero,
    ScrollPhysics? physics,
    ScrollViewKeyboardDismissBehavior keyboardDismissBehavior =
        ScrollViewKeyboardDismissBehavior.onDrag,
    bool scrollbar = true,
    bool scrollDownButton = true,
    Widget Function(BuildContext context, int unread, VoidCallback onTap)?
        scrollDownButtonBuilder,
    DayHeaderBuilder? floatingDayBuilder,
  }) : this._(
          key: key,
          messages: messages,
          readState: readState,
          adapter: adapter,
          itemBuilder: itemBuilder,
          list: list,
          onMarkRead: onMarkRead,
          onController: onController,
          config: config,
          callbacks: callbacks,
          policies: policies,
          viewportStore: viewportStore,
          groupBuilder: groupBuilder,
          dayHeaderBuilder: dayHeaderBuilder,
          unreadDividerBuilder: unreadDividerBuilder,
          edgeBuilder: edgeBuilder,
          historyStartBuilder: historyStartBuilder,
          footerBuilder: footerBuilder,
          emptyBuilder: emptyBuilder,
          loadingBuilder: loadingBuilder,
          errorBuilder: errorBuilder,
          onDayTap: onDayTap,
          padding: padding,
          physics: physics,
          keyboardDismissBehavior: keyboardDismissBehavior,
          scrollbar: scrollbar,
          scrollDownButton: scrollDownButton,
          scrollDownButtonBuilder: scrollDownButtonBuilder,
          floatingDayBuilder: floatingDayBuilder,
        );

  /// A list over a [stream] whose every event is the complete conversation.
  ///
  /// ```dart
  /// SteadyChatList<ChatMessage>.stream(
  ///   stream: db.watchMessages(chatId),
  ///   adapter: adapter,
  ///   itemBuilder: (context, message, info) => MessageBubble(message),
  /// );
  /// ```
  const SteadyChatList.stream({
    Key? key,
    required Stream<List<M>> stream,
    required MessageAdapter<M> adapter,
    required MessageItemBuilder<M> itemBuilder,
    ListId list = const ListId('chat'),
    MarkReadCallback? onMarkRead,
    void Function(MessageListController<M> controller)? onController,
    MessageListConfig config = const MessageListConfig(),
    MessageListCallbacks<M>? callbacks,
    MessageListPolicies<M>? policies,
    ViewportStore? viewportStore,
    MessageGroupBuilder<M>? groupBuilder,
    DayHeaderBuilder? dayHeaderBuilder,
    WidgetBuilder? unreadDividerBuilder,
    EdgeBuilder? edgeBuilder,
    WidgetBuilder? historyStartBuilder,
    WidgetBuilder? footerBuilder,
    WidgetBuilder? emptyBuilder,
    WidgetBuilder? loadingBuilder,
    WidgetBuilder? errorBuilder,
    void Function(DateTime day)? onDayTap,
    EdgeInsets padding = EdgeInsets.zero,
    ScrollPhysics? physics,
    ScrollViewKeyboardDismissBehavior keyboardDismissBehavior =
        ScrollViewKeyboardDismissBehavior.onDrag,
    bool scrollbar = true,
    bool scrollDownButton = true,
    Widget Function(BuildContext context, int unread, VoidCallback onTap)?
        scrollDownButtonBuilder,
    DayHeaderBuilder? floatingDayBuilder,
  }) : this._(
          key: key,
          stream: stream,
          adapter: adapter,
          itemBuilder: itemBuilder,
          list: list,
          onMarkRead: onMarkRead,
          onController: onController,
          config: config,
          callbacks: callbacks,
          policies: policies,
          viewportStore: viewportStore,
          groupBuilder: groupBuilder,
          dayHeaderBuilder: dayHeaderBuilder,
          unreadDividerBuilder: unreadDividerBuilder,
          edgeBuilder: edgeBuilder,
          historyStartBuilder: historyStartBuilder,
          footerBuilder: footerBuilder,
          emptyBuilder: emptyBuilder,
          loadingBuilder: loadingBuilder,
          errorBuilder: errorBuilder,
          onDayTap: onDayTap,
          padding: padding,
          physics: physics,
          keyboardDismissBehavior: keyboardDismissBehavior,
          scrollbar: scrollbar,
          scrollDownButton: scrollDownButton,
          scrollDownButtonBuilder: scrollDownButtonBuilder,
          floatingDayBuilder: floatingDayBuilder,
        );

  /// A list over a paged backend.
  ///
  /// ```dart
  /// SteadyChatList<ChatMessage>.source(
  ///   source: MyBackendSource(api, socket),
  ///   adapter: adapter,
  ///   list: ListId(chat.id),
  ///   itemBuilder: (context, message, info) => MessageBubble(message),
  /// );
  /// ```
  const SteadyChatList.source({
    Key? key,
    required MessageSource<M> source,
    required MessageAdapter<M> adapter,
    required MessageItemBuilder<M> itemBuilder,
    ListId list = const ListId('chat'),
    void Function(MessageListController<M> controller)? onController,
    MessageListConfig config = const MessageListConfig(),
    MessageListCallbacks<M>? callbacks,
    MessageListPolicies<M>? policies,
    ViewportStore? viewportStore,
    MessageGroupBuilder<M>? groupBuilder,
    DayHeaderBuilder? dayHeaderBuilder,
    WidgetBuilder? unreadDividerBuilder,
    EdgeBuilder? edgeBuilder,
    WidgetBuilder? historyStartBuilder,
    WidgetBuilder? footerBuilder,
    WidgetBuilder? emptyBuilder,
    WidgetBuilder? loadingBuilder,
    WidgetBuilder? errorBuilder,
    void Function(DateTime day)? onDayTap,
    EdgeInsets padding = EdgeInsets.zero,
    ScrollPhysics? physics,
    ScrollViewKeyboardDismissBehavior keyboardDismissBehavior =
        ScrollViewKeyboardDismissBehavior.onDrag,
    bool scrollbar = true,
    bool scrollDownButton = true,
    Widget Function(BuildContext context, int unread, VoidCallback onTap)?
        scrollDownButtonBuilder,
    DayHeaderBuilder? floatingDayBuilder,
  }) : this._(
          key: key,
          source: source,
          adapter: adapter,
          itemBuilder: itemBuilder,
          list: list,
          onController: onController,
          config: config,
          callbacks: callbacks,
          policies: policies,
          viewportStore: viewportStore,
          groupBuilder: groupBuilder,
          dayHeaderBuilder: dayHeaderBuilder,
          unreadDividerBuilder: unreadDividerBuilder,
          edgeBuilder: edgeBuilder,
          historyStartBuilder: historyStartBuilder,
          footerBuilder: footerBuilder,
          emptyBuilder: emptyBuilder,
          loadingBuilder: loadingBuilder,
          errorBuilder: errorBuilder,
          onDayTap: onDayTap,
          padding: padding,
          physics: physics,
          keyboardDismissBehavior: keyboardDismissBehavior,
          scrollbar: scrollbar,
          scrollDownButton: scrollDownButton,
          scrollDownButtonBuilder: scrollDownButtonBuilder,
          floatingDayBuilder: floatingDayBuilder,
        );

  /// List mode: every message of the conversation.
  final List<M>? messages;

  /// Stream mode: a stream of complete message lists.
  final Stream<List<M>>? stream;

  /// Source mode: the paged backend.
  final MessageSource<M>? source;

  /// List mode: read markers and unread counters (opens at the first
  /// unread message when `unreadCount > 0`).
  final ReadState? readState;

  /// Reads keys and dates from the app's message class.
  final MessageAdapter<M> adapter;

  /// Builds one message.
  final MessageItemBuilder<M> itemBuilder;

  /// The conversation. Changing it switches the list (the previous one
  /// stays on screen until the new one is ready).
  final ListId list;

  /// List and stream mode: the user has read up to a key.
  final MarkReadCallback? onMarkRead;

  /// Called with the controller this widget created (and again if it has
  /// to create a new one).
  final void Function(MessageListController<M> controller)? onController;

  /// Tunable numbers.
  final MessageListConfig config;

  /// App hooks.
  final MessageListCallbacks<M>? callbacks;

  /// Replaceable decisions.
  final MessageListPolicies<M>? policies;

  /// Where the scroll position is persisted across restarts.
  final ViewportStore? viewportStore;

  /// See [MessageListView.groupBuilder].
  final MessageGroupBuilder<M>? groupBuilder;

  /// See [MessageListView.dayHeaderBuilder].
  final DayHeaderBuilder? dayHeaderBuilder;

  /// See [MessageListView.unreadDividerBuilder].
  final WidgetBuilder? unreadDividerBuilder;

  /// See [MessageListView.edgeBuilder].
  final EdgeBuilder? edgeBuilder;

  /// See [MessageListView.historyStartBuilder].
  final WidgetBuilder? historyStartBuilder;

  /// See [MessageListView.footerBuilder].
  final WidgetBuilder? footerBuilder;

  /// See [MessageListView.emptyBuilder].
  final WidgetBuilder? emptyBuilder;

  /// See [MessageListView.loadingBuilder].
  final WidgetBuilder? loadingBuilder;

  /// See [MessageListView.errorBuilder].
  final WidgetBuilder? errorBuilder;

  /// See [MessageListView.onDayTap].
  final void Function(DateTime day)? onDayTap;

  /// See [MessageListView.padding].
  final EdgeInsets padding;

  /// See [MessageListView.physics].
  final ScrollPhysics? physics;

  /// See [MessageListView.keyboardDismissBehavior].
  final ScrollViewKeyboardDismissBehavior keyboardDismissBehavior;

  /// See [MessageListView.scrollbar].
  final bool scrollbar;

  /// Whether a scroll-to-bottom button with the unread count floats over
  /// the list (the default [ScrollDownButton], or
  /// [scrollDownButtonBuilder]).
  final bool scrollDownButton;

  /// See [MessageListView.scrollDownButtonBuilder].
  final Widget Function(BuildContext context, int unread, VoidCallback onTap)?
      scrollDownButtonBuilder;

  /// See [MessageListView.floatingDayBuilder].
  final DayHeaderBuilder? floatingDayBuilder;

  @override
  State<SteadyChatList<M>> createState() => _SteadyChatListState<M>();
}

class _SteadyChatListState<M> extends State<SteadyChatList<M>> {
  ListMessageSource<M>? _listSource;
  StreamMessageSource<M>? _streamSource;
  late MessageListHub<M> _hub;
  late MessageListController<M> _controller;
  List<M> _shown = const [];

  @override
  void initState() {
    super.initState();
    _create();
  }

  void _create() {
    final w = widget;
    final MessageSource<M> source;
    final messages = w.messages;
    final stream = w.stream;
    if (messages != null) {
      _shown = List<M>.of(messages);
      final listSource = ListMessageSource<M>(
        adapter: w.adapter,
        initial: {w.list: messages},
        onMarkRead: w.onMarkRead,
      );
      final readState = w.readState;
      if (readState != null) listSource.setReadState(w.list, readState);
      source = _listSource = listSource;
    } else if (stream != null) {
      source = _streamSource = StreamMessageSource<M>(
        adapter: w.adapter,
        snapshots: (_) => stream,
        onMarkRead: w.onMarkRead,
      );
    } else {
      source = w.source!;
    }
    _hub = MessageListHub<M>(
      source: source,
      adapter: w.adapter,
      viewportStore: w.viewportStore,
    );
    _controller = MessageListController<M>(
      hub: _hub,
      list: w.list,
      config: w.config,
      callbacks: w.callbacks ?? MessageListCallbacks<M>(),
      policies: w.policies ?? MessageListPolicies<M>(),
    );
    _prime(w.list);
    unawaited(_controller.open());
    w.onController?.call(_controller);
  }

  /// List mode: put the newest messages into memory, so the list opens in
  /// the first frame instead of after a loading frame.
  void _prime(ListId list) {
    final listSource = _listSource;
    if (listSource == null) return;
    final request = PageRequest(
      list: list,
      direction: PageDirection.latest,
      limit: widget.config.windowSize,
    );
    _hub.store.list(list).applyPage(request, listSource.page(request));
  }

  void _destroy() {
    _controller.dispose();
    _hub.dispose();
    _listSource?.dispose();
    _streamSource?.dispose();
    _listSource = null;
    _streamSource = null;
  }

  @override
  void didUpdateWidget(SteadyChatList<M> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final w = widget;
    final modeChanged = (w.messages == null) != (oldWidget.messages == null) ||
        !identical(w.stream, oldWidget.stream) ||
        !identical(w.source, oldWidget.source) ||
        !identical(w.adapter, oldWidget.adapter);
    if (modeChanged) {
      _destroy();
      _create();
      return;
    }
    final messages = w.messages;
    final listSource = _listSource;
    if (messages != null && listSource != null) {
      final listChanged = w.list != oldWidget.list;
      if (listChanged || !_sameItems(messages, _shown)) {
        _shown = List<M>.of(messages);
        listSource.setAll(w.list, messages);
      }
      final readState = w.readState;
      if (readState != null &&
          (listChanged || readState != oldWidget.readState)) {
        listSource.setReadState(w.list, readState);
      }
      if (listChanged) _prime(w.list);
    }
    if (w.list != oldWidget.list) unawaited(_controller.switchTo(w.list));
  }

  /// Whether [a] holds the same message objects as [b]. Catches a list that
  /// was changed in place, without diffing an unchanged one.
  static bool _sameItems(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return MessageListView<M>(
      controller: _controller,
      itemBuilder: w.itemBuilder,
      groupBuilder: w.groupBuilder,
      dayHeaderBuilder: w.dayHeaderBuilder,
      unreadDividerBuilder: w.unreadDividerBuilder,
      edgeBuilder: w.edgeBuilder,
      historyStartBuilder: w.historyStartBuilder,
      footerBuilder: w.footerBuilder,
      emptyBuilder: w.emptyBuilder,
      loadingBuilder: w.loadingBuilder,
      errorBuilder: w.errorBuilder,
      onDayTap: w.onDayTap,
      padding: w.padding,
      physics: w.physics,
      keyboardDismissBehavior: w.keyboardDismissBehavior,
      scrollbar: w.scrollbar,
      floatingDayBuilder: w.floatingDayBuilder,
      scrollDownButtonBuilder: !w.scrollDownButton
          ? null
          : w.scrollDownButtonBuilder ??
              (context, unread, onTap) => ValueListenableBuilder(
                    valueListenable: _controller.jumpInProgress,
                    builder: (context, jump, _) => ScrollDownButton(
                      unread: unread,
                      onTap: onTap,
                      loading: jump?.isLoading ?? false,
                    ),
                  ),
    );
  }
}
