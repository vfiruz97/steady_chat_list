import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'fake_chat_server.dart';

const ListId chat = ListId('chat');
const ListId other = ListId('other');

/// A real `MessageListView` on a `FakeChatServer`, with helpers to scroll
/// and measure it.
class ListHarness {
  ListHarness(
    this.tester, {
    int count = 1000,
    int outgoingEvery = 0,
    this.config = const MessageListConfig(),
    this.viewportStore,
    Msg Function(Msg message)? decorate,
  }) : server = FakeChatServer(
          count: count,
          outgoingEvery: outgoingEvery,
          decorate: decorate,
        ) {
    hub = newHub();
    controller = newController();
  }

  final WidgetTester tester;
  final FakeChatServer server;
  final MessageListConfig config;
  final ViewportStore? viewportStore;
  late MessageListHub<Msg> hub;
  late MessageListController<Msg> controller;

  /// Heights by message id; 50 by default.
  final Map<String, double> heights = {};

  /// How often each item was built.
  final Map<String, int> builds = {};

  /// The latest info each item was built with.
  final Map<String, MessageItemInfo> infos = {};

  /// Whether day headers (24 px) are shown.
  bool dayHeaders = false;

  /// Wraps items in the default jump flash.
  bool flash = false;

  /// Right-to-left layout.
  bool rtl = false;

  /// Ids of the items whose `State` was created, in order (one entry per
  /// `initState`).
  final List<String> inits = [];

  /// Optional custom transitions.
  ItemTransitionBuilder? appearBuilder;
  ItemTransitionBuilder? removeBuilder;

  /// Width-dependent heights (text reflow): height = area / width.
  double? area;

  Size size = const Size(400, 600);
  double footer = 0;
  final List<MessageListEvent> events = [];

  MessageListHub<Msg> newHub() => MessageListHub<Msg>(
        source: server,
        adapter: const MsgAdapter(),
        viewportStore: viewportStore,
      );

  MessageListController<Msg> newController({ListId list = chat}) {
    final created =
        MessageListController<Msg>(hub: hub, list: list, config: config);
    created.events.listen(events.add);
    return created;
  }

  Widget build() => Directionality(
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: MessageListView<Msg>(
              controller: controller,
              itemBuilder: (context, message, info) {
                builds[message.id] = (builds[message.id] ?? 0) + 1;
                infos[message.id] = info;
                final item = LayoutBuilder(
                  key: ValueKey('item-${message.id}'),
                  builder: (context, constraints) => SizedBox(
                    height: heights[message.id] ??
                        (area == null ? 50 : area! / constraints.maxWidth),
                  ),
                );
                return _Probe(
                  id: message.id,
                  inits: inits,
                  child: flash
                      ? JumpHighlightBackground(info: info, child: item)
                      : item,
                );
              },
              dayHeaderBuilder: dayHeaders
                  ? (context, day, onTap) => SizedBox(
                        key:
                            ValueKey('day-${day.year}-${day.month}-${day.day}'),
                        height: 24,
                      )
                  : null,
              appearTransitionBuilder: appearBuilder,
              removeTransitionBuilder: removeBuilder,
              unreadDividerBuilder: (context) =>
                  const SizedBox(key: ValueKey('divider'), height: 30),
              footerBuilder: (context) =>
                  SizedBox(key: const ValueKey('footer'), height: footer),
            ),
          ),
        ),
      );

  /// Builds the list and lets pending fetches finish.
  Future<void> pump([Duration settle = const Duration(seconds: 1)]) async {
    await tester.pumpWidget(build());
    await this.settle(settle);
  }

  /// Lets time pass in small frames (fetches, timers, post-frame reports).
  Future<void> settle([Duration time = const Duration(seconds: 1)]) async {
    const frame = Duration(milliseconds: 50);
    for (var t = Duration.zero; t < time; t += frame) {
      await tester.pump(frame);
    }
    await tester.pump();
  }

  AnchoredScrollPosition get position =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position
          as AnchoredScrollPosition;

  /// Also finds items built in the cache area, outside the viewport.
  Finder item(int order) =>
      find.byKey(ValueKey('item-m$order'), skipOffstage: false);

  /// An item by message id (for local messages).
  Finder itemById(String id) =>
      find.byKey(ValueKey('item-$id'), skipOffstage: false);

  /// The opacity of the nearest fade around an item (1 when not fading).
  double opacityOf(Finder item) {
    final fades =
        find.ancestor(of: item, matching: find.byType(FadeTransition));
    var opacity = 1.0;
    for (final element in fades.evaluate()) {
      opacity *= (element.widget as FadeTransition).opacity.value;
    }
    return opacity;
  }

  /// The y of the top edge of a built item, or null.
  double? yOf(int order) {
    final finder = item(order);
    return finder.evaluate().isEmpty ? null : tester.getTopLeft(finder).dy;
  }

  double bottomOf(int order) => tester.getBottomLeft(item(order)).dy;

  /// Orders of the items that intersect the viewport, top to bottom.
  List<int> get visible {
    final orders = <int>[];
    for (final key in controller.window.value.keys) {
      final finder = item(key.order);
      if (finder.evaluate().isEmpty) continue;
      final rect = tester.getRect(finder);
      if (rect.bottom > 0 && rect.top < size.height) orders.add(key.order);
    }
    return orders;
  }

  int get builtItems => find
      .byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('item-'),
        skipOffstage: false,
      )
      .evaluate()
      .length;

  /// Scrolls by [dy] content pixels (positive = toward newer messages).
  ///
  /// The target is kept inside the scroll range: an overscroll would start
  /// a spring animation that keeps moving the list for the next frames.
  Future<void> scrollBy(double dy) async {
    final target = (position.pixels + dy)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    position.jumpTo(target);
    await tester.pump();
  }

  /// A media load or an edit that changes the height of an item.
  void resize(int order, double height) {
    heights['m$order'] = height;
    controller.patch('m$order', (m) => Msg(m.order, rev: m.rev + 1));
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump(const Duration(seconds: 40));
  }
}

/// Records when an item's `State` is created: a message that keeps its
/// widget identity is created once.
class _Probe extends StatefulWidget {
  const _Probe({required this.id, required this.inits, required this.child});

  final String id;
  final List<String> inits;
  final Widget child;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.inits.add(widget.id);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
