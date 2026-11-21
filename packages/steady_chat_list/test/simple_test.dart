// The one-widget API, the default widgets, page tokens and a streaming
// (AI assistant) message.
// ignore_for_file: unawaited_futures
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'support/env.dart';
import 'support/fake_chat_server.dart';
import 'support/fake_viewport.dart';
import 'support/list_harness.dart' show ListHarness;

final _adapter = MessageAdapter<Msg>.from(
  key: (m) => m.key,
  date: (m) => DateTime.fromMillisecondsSinceEpoch(m.order * 60000),
  isOutgoing: (m) => m.outgoing,
  equals: (a, b) => a.rev == b.rev,
);

Widget _frame(Widget child, {double height = 600}) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 400, height: height, child: child),
      ),
    );

Widget _item(BuildContext context, Msg m, MessageItemInfo info) => SizedBox(
      key: ValueKey('item-${m.id}'),
      height: 50.0 + m.rev * 10,
    );

Finder _find(int order) =>
    find.byKey(ValueKey('item-m$order'), skipOffstage: false);

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 40));
}

void main() {
  group('SteadyChatList.list', () {
    testWidgets('shows the newest messages in the first frame', (tester) async {
      MessageListController<Msg>? controller;
      final messages = [for (var i = 1; i <= 200; i++) Msg(i * 10)];
      await tester.pumpWidget(
        _frame(
          SteadyChatList<Msg>.list(
            messages: messages,
            adapter: _adapter,
            itemBuilder: _item,
            onController: (c) => controller = c,
          ),
        ),
      );
      // One pump: no loading frame.
      expect(tester.getBottomLeft(_find(2000)).dy, 600);
      expect(controller!.phase.value, ListPhase.ready);
      await _settle(tester);
      expect(controller!.isAtBottom.value, isTrue);
      expect(controller!.newerEdge.value, isA<EdgeEnd>());
      await _unmount(tester);
    });

    testWidgets('rebuilding with changed messages updates only those',
        (tester) async {
      var messages = [for (var i = 1; i <= 30; i++) Msg(i * 10)];
      late StateSetter rebuild;
      final builds = <String>[];
      await tester.pumpWidget(
        _frame(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SteadyChatList<Msg>.list(
                messages: messages,
                adapter: _adapter,
                itemBuilder: (context, m, info) {
                  builds.add(m.id);
                  return _item(context, m, info);
                },
              );
            },
          ),
        ),
      );
      await _settle(tester);

      // A new list with one more message: pinned to the bottom.
      rebuild(() => messages = [...messages, const Msg(310)]);
      await _settle(tester, 3);
      expect(tester.getBottomLeft(_find(310)).dy, 600);

      // The same list changed in place: an edit and a delete.
      rebuild(() {
        messages[29] = const Msg(300, rev: 3);
        messages.removeAt(27);
      });
      await _settle(tester, 7);
      expect(tester.getSize(_find(300)).height, 80);
      expect(_find(280), findsNothing);
      expect(tester.getBottomLeft(_find(310)).dy, 600);

      // Nothing changed: the messages are not diffed or rebuilt needlessly.
      builds.clear();
      rebuild(() {});
      await tester.pump();
      expect(builds.toSet().length, builds.length, reason: 'one build each');
      await _unmount(tester);
    });

    testWidgets('an empty list shows the default empty state, then fills',
        (tester) async {
      var messages = <Msg>[];
      late StateSetter rebuild;
      await tester.pumpWidget(
        _frame(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SteadyChatList<Msg>.list(
                messages: messages,
                adapter: _adapter,
                itemBuilder: _item,
              );
            },
          ),
        ),
      );
      expect(find.text('No messages yet'), findsOneWidget);
      rebuild(() => messages = [const Msg(10)]);
      await _settle(tester, 3);
      expect(find.text('No messages yet'), findsNothing);
      expect(tester.getBottomLeft(_find(10)).dy, 600);
      await _unmount(tester);
    });

    testWidgets('read state opens at the first unread; reads are reported',
        (tester) async {
      final read = <MessageKey>[];
      var readState = ReadState(lastReadInbox: k(1700), unreadCount: 30);
      late StateSetter rebuild;
      MessageListController<Msg>? controller;
      final messages = [for (var i = 1; i <= 200; i++) Msg(i * 10)];
      await tester.pumpWidget(
        _frame(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SteadyChatList<Msg>.list(
                messages: messages,
                adapter: _adapter,
                readState: readState,
                onMarkRead: (list, key) => read.add(key),
                onController: (c) => controller = c,
                itemBuilder: _item,
                unreadDividerBuilder: (context) =>
                    const SizedBox(key: ValueKey('divider'), height: 30),
              );
            },
          ),
        ),
      );
      expect(tester.getTopLeft(find.byKey(const ValueKey('divider'))).dy, 10);
      expect(controller!.unreadCount.value, 30);
      await _settle(tester, 20);
      expect(read, isNotEmpty);
      expect(controller!.unreadCount.value, lessThan(30));
      rebuild(
        () => readState = ReadState(lastReadInbox: k(2000)),
      );
      await _settle(tester, 3);
      expect(controller!.unreadCount.value, 0);
      await _unmount(tester);
    });

    testWidgets('changing the list id switches the conversation',
        (tester) async {
      var list = const ListId('a');
      var messages = [for (var i = 1; i <= 30; i++) Msg(i * 10)];
      late StateSetter rebuild;
      await tester.pumpWidget(
        _frame(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SteadyChatList<Msg>.list(
                messages: messages,
                list: list,
                adapter: _adapter,
                itemBuilder: _item,
              );
            },
          ),
        ),
      );
      await _settle(tester);
      rebuild(() {
        list = const ListId('b');
        messages = [for (var i = 1; i <= 5; i++) Msg(i * 1000)];
      });
      await _settle(tester);
      expect(_find(300), findsNothing);
      expect(tester.getBottomLeft(_find(5000)).dy, 600);
      expect(tester.getTopLeft(_find(1000)).dy, 350, reason: 'short: bottom');
      await _unmount(tester);
    });
  });

  group('SteadyChatList.stream', () {
    testWidgets('loads from the first snapshot and follows the next ones',
        (tester) async {
      final feed = StreamController<List<Msg>>.broadcast();
      await tester.pumpWidget(
        _frame(
          SteadyChatList<Msg>.stream(
            stream: feed.stream,
            adapter: _adapter,
            itemBuilder: _item,
          ),
        ),
      );
      expect(find.byType(DefaultLoadingState), findsOneWidget);
      feed.add([for (var i = 1; i <= 100; i++) Msg(i * 10)]);
      await _settle(tester);
      expect(tester.getBottomLeft(_find(1000)).dy, 600);

      feed.add([
        for (var i = 1; i <= 100; i++)
          if (i != 99) Msg(i * 10, rev: i == 100 ? 2 : 0),
        const Msg(1010),
      ]);
      await _settle(tester, 7);
      expect(_find(990), findsNothing);
      expect(tester.getSize(_find(1000)).height, 70);
      expect(tester.getBottomLeft(_find(1010)).dy, 600);

      // A different stream object: everything is rebuilt on it.
      final second = StreamController<List<Msg>>.broadcast();
      await tester.pumpWidget(
        _frame(
          SteadyChatList<Msg>.stream(
            stream: second.stream,
            adapter: _adapter,
            itemBuilder: _item,
          ),
        ),
      );
      second.add(const [Msg(7)]);
      await _settle(tester);
      expect(_find(1010), findsNothing);
      expect(tester.getBottomLeft(_find(7)).dy, 600);
      await _unmount(tester);
      await feed.close();
      await second.close();
    });
  });

  group('SteadyChatList.source', () {
    testWidgets('pages a backend and forwards the view options',
        (tester) async {
      final server = FakeChatServer(count: 1000);
      MessageListController<Msg>? controller;
      await tester.pumpWidget(
        _frame(
          SteadyChatList<Msg>.source(
            source: server,
            adapter: const MsgAdapter(),
            onController: (c) => controller = c,
            itemBuilder: _item,
            padding: const EdgeInsets.only(bottom: 20),
            scrollbar: false,
            footerBuilder: (context) =>
                const SizedBox(key: ValueKey('footer'), height: 30),
            callbacks: MessageListCallbacks<Msg>(onOpened: (list, how) {}),
            policies: const MessageListPolicies<Msg>(),
          ),
        ),
      );
      expect(find.byType(DefaultLoadingState), findsOneWidget);
      await _settle(tester, 20);
      expect(tester.getBottomLeft(_find(10000)).dy, 550);
      expect(controller!.list, const ListId('chat'));
      await _unmount(tester);
    });

    testWidgets('an adapter created inline in build does not restart the list',
        (tester) async {
      final server = FakeChatServer(count: 1000);
      final controllers = <MessageListController<Msg>>[];
      var outgoing = false;
      Widget build() => _frame(
            SteadyChatList<Msg>.source(
              source: server,
              // A new adapter object on every build.
              adapter: MessageAdapter<Msg>.from(
                key: (m) => m.key,
                date: (m) => DateTime.utc(2026).add(Duration(minutes: m.order)),
                isOutgoing: (m) => outgoing,
                equals: (a, b) => a.rev == b.rev,
              ),
              onController: controllers.add,
              itemBuilder: _item,
            ),
          );
      await tester.pumpWidget(build());
      await _settle(tester, 20);
      final requests = server.requests.length;
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      position.jumpTo(position.pixels - 300);
      await _settle(tester, 20);
      final pixels = position.pixels;
      final top = tester.getTopLeft(_find(9900)).dy;

      outgoing = true;
      await tester.pumpWidget(build());
      await tester.pumpWidget(build());
      await _settle(tester, 20);
      expect(controllers, hasLength(1), reason: 'the list was not recreated');
      expect(position.pixels, pixels);
      expect(tester.getTopLeft(_find(9900)).dy, top);
      expect(server.requests.length, requests, reason: 'nothing was reloaded');
      // The newest adapter is the one that is read.
      expect(
        controllers.single.hub.adapter.isOutgoing(const Msg(10)),
        isTrue,
      );
      final adapter = controllers.single.hub.adapter;
      expect(adapter.groupIdOf(const Msg(10)), isNull);
      expect(adapter.senderIdOf(const Msg(10)), isNull);
      expect(adapter.isService(const Msg(10)), isFalse);
      expect(adapter.mentionsMe(const Msg(10)), isFalse);
      expect(adapter.dateOf(const Msg(10)), DateTime.utc(2026, 1, 1, 0, 10));
      await _unmount(tester);
    });

    testWidgets('default error state retries; default edge rows show',
        (tester) async {
      final server = FakeChatServer(count: 300)..failNextFetches = 5;
      MessageListController<Msg>? controller;
      await tester.pumpWidget(
        _frame(
          SteadyChatList<Msg>.source(
            source: server,
            adapter: const MsgAdapter(),
            onController: (c) => controller = c,
            itemBuilder: _item,
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.byType(DefaultErrorState), findsOneWidget);
      await tester.tap(find.byType(DefaultErrorState));
      await _settle(tester, 20);
      expect(_find(3000), findsOneWidget);

      // The older edge: a spinner while loading, tap-to-retry on failure.
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      server.failNextFetches = 1000;
      position.jumpTo(position.minScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byType(SteadySpinner, skipOffstage: false), findsOneWidget);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(controller!.olderEdge.value, isA<EdgeError>());
      server.failNextFetches = 0;
      position.jumpTo(position.minScrollExtent);
      await tester.pump();
      await tester.tap(find.text("Couldn't load more. Tap to retry."));
      await _settle(tester, 10);
      expect(controller!.olderEdge.value, isNot(isA<EdgeError>()));
      expect(
        controller!.window.value.keys.first.order,
        lessThan(2410),
      );
      await _unmount(tester);
    });
  });

  testWidgets(
      'a streaming reply grows at the bottom without moving the '
      'reader', (tester) async {
    // An AI assistant answer: one message that gets taller every frame.
    final h = ListHarness(tester);
    h.controller.open();
    await h.pump();
    h.server.incoming(const ListId('chat'));
    await h.settle(const Duration(milliseconds: 100));
    final reply = h.server.newest;
    for (var height = 60.0; height <= 900; height += 40) {
      h.resize(reply, height);
      await tester.pump(const Duration(milliseconds: 16));
      expect(h.bottomOf(reply), 600, reason: 'pinned at $height px');
    }
    expect(h.controller.isAtBottom.value, isTrue);

    // The reader scrolls up to re-read: the growing reply moves nothing.
    await h.scrollBy(-1500);
    await h.settle(const Duration(milliseconds: 100));
    final visible = h.visible;
    final ys = [for (final o in visible) h.yOf(o)!];
    for (var height = 940.0; height <= 1500; height += 40) {
      h.resize(reply, height);
      await tester.pump(const Duration(milliseconds: 16));
      expect([for (final o in visible) h.yOf(o)!], ys);
    }
    await h.dispose();
  });

  test('page tokens from the backend come back on the next page', () {
    run(
      env: (async) => Env(async, count: 300, cursors: true),
      (env) {
        final controller = env.controller()..open();
        final view = FakeViewport(controller);
        env.settle();
        for (var i = 0; i < 3; i++) {
          view.scrollToTop();
          env.settle();
        }
        final older = env.server.requestsOf(PageDirection.older).toList();
        expect(older.length, greaterThan(2));
        for (final request in older) {
          expect(request.cursor, 'before-${request.anchor!.order}');
        }
      },
    );
  });

  testWidgets('the default spinner and states need no Material ancestor',
      (tester) async {
    await tester.pumpWidget(
      _frame(
        Column(
          children: [
            const SteadySpinner(color: Color(0xFF112233)),
            const Expanded(child: DefaultLoadingState()),
            const Expanded(child: DefaultEmptyState(text: 'Say hi')),
            Expanded(child: DefaultErrorState(onRetry: () {}, text: 'Oops')),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Say hi'), findsOneWidget);
    expect(find.text('Oops'), findsOneWidget);
    expect(find.byType(SteadySpinner), findsNWidgets(2));
    // A new color repaints the arc.
    await tester.pumpWidget(
      _frame(const SteadySpinner(color: Color(0xFF112233))),
    );
    await tester.pumpWidget(
      _frame(const SteadySpinner(color: Color(0xFF445566))),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
