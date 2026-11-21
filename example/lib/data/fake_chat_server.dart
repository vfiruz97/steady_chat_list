import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import 'models.dart';

/// One simulated chat: how many messages it has and how they look.
class DemoChat {
  const DemoChat({
    required this.id,
    required this.title,
    required this.count,
    this.unread = 0,
    this.group = false,
    this.media = false,
    this.pinnedEvery = 0,
  });

  final String id;
  final String title;

  /// Messages on the "server". They are generated on demand, so ten million
  /// cost nothing.
  final int count;
  final int unread;
  final bool group;
  final bool media;

  /// One pinned message every this many messages from the end (0 = none).
  final int pinnedEvery;

  ListId get list => ListId(id);
}

const bigChannel = DemoChat(
  id: 'big',
  title: 'Big channel',
  count: 10000000,
  unread: 7200,
  media: true,
);
const groupChat = DemoChat(
  id: 'group',
  title: 'Group',
  count: 200000,
  unread: 18,
  group: true,
  pinnedEvery: 400,
);
const friendChat = DemoChat(id: 'friend', title: 'Friend', count: 5000);
const savedChat = DemoChat(id: 'saved', title: 'Saved', count: 300);

const demoChats = [bigChannel, groupChat, friendChat, savedChat];

/// The words messages are made of. The first word of message `n` is word
/// `n % words.length`, which makes search over ten million messages a
/// formula instead of a scan.
const words = [
  'invoice', 'meeting', 'tomorrow', 'coffee', 'release', 'design', 'review',
  'ticket', 'flight', 'budget', 'lunch', 'deploy', 'photo', 'weekend',
  'update', 'question', 'thanks', 'draft', 'client', 'schedule', 'report',
  'server', 'bug', 'feature', 'holiday', 'contract', 'price', 'reminder',
  'video', 'music', 'train', 'address', 'password', 'birthday', 'dinner',
  'project', 'deadline', 'feedback', 'hotel', 'parking', //
];

const _phrases = [
  'sounds good to me',
  'can we talk about it after the call?',
  'I will send the details in a minute',
  'did anyone check this yet',
  'let me know what you think',
  'that is exactly what I meant, and here is a bit more text so that this '
      'message wraps over a few lines on a narrow screen',
  'ok',
  'on it',
  'please have a look when you have time, no rush at all',
  'done ✅',
];

/// An in-process backend with deterministic content and adjustable
/// behavior: latency, failures, incoming messages, reaction storms, remote
/// deletes and edits, lost connections.
class FakeChatServer
    implements MessageSource<ChatMessage>, MessageSearchSource {
  FakeChatServer() {
    for (final chat in demoChats) {
      _chats[chat.id] = _ChatState(chat);
    }
  }

  // Knobs of the debug panel.
  final ValueNotifier<int> latencyMs = ValueNotifier(150);
  final ValueNotifier<int> failurePercent = ValueNotifier(0);
  final ValueNotifier<bool> outOfOrderAcks = ValueNotifier(true);
  final ValueNotifier<int> incomingPerSecond = ValueNotifier(0);
  final ValueNotifier<int> reactionsPerSecond = ValueNotifier(0);
  final ValueNotifier<bool> online = ValueNotifier(true);

  /// Number of requests answered, for the debug panel.
  final ValueNotifier<int> requestCount = ValueNotifier(0);

  final Map<String, _ChatState> _chats = {};
  final Random _random = Random(7);
  Timer? _incoming;
  Timer? _storm;
  ListId? _activeList;
  List<MessageKey> Function()? _visibleKeys;

  static const int _step = 4; // ids have gaps: 4, 8, 12, …
  static final DateTime _epoch = DateTime(2020, 1, 1, 8);

  _ChatState _state(ListId list) => _chats[list.chatId] ??= _ChatState(
        DemoChat(id: list.chatId, title: list.chatId, count: 40),
      );

  DemoChat chatOf(ListId list) => _state(list).chat;

  /// The chat the storms and incoming messages go to, and how to learn
  /// which messages are on screen.
  void activate(ListId list, List<MessageKey> Function() visibleKeys) {
    _activeList = list;
    _visibleKeys = visibleKeys;
  }

  void deactivate(ListId list) {
    if (_activeList == list) {
      _activeList = null;
      _visibleKeys = null;
    }
  }

  // ------------------------------------------------------------- content

  /// The message with number [n] (1 = oldest) of a chat.
  ChatMessage _generate(_ChatState state, int n) {
    final chat = state.chat;
    final order = n * _step;
    final override = state.edited[order];
    if (override != null) return override;
    // Small factors: the same result on the web, where integers are
    // doubles.
    var h = ((n & 0xffff) * 40503 + (n >> 16) * 30011 + 12345) & 0x7fffffff;
    h ^= h >> 7;
    final service = chat.media && h % 50 == 7;
    final album = chat.media && !service && (n ~/ 3) % 20 == 5;
    final image = chat.media && !service && (album || h % 10 == 3);
    final sender = chat.group
        ? senders[1 + (n ~/ 3 + h % 2) % (senders.length - 1)]
        : chat.id == 'big'
            ? 'channel'
            : (n ~/ 2 + h % 3) % 3 == 0
                ? 'me'
                : 'alice';
    final outgoing = sender == 'me';
    final first = words[n % words.length];
    final text = service
        ? '${senderName(senders[1 + h % 5])} joined the channel'
        : image && !album
            ? 'A $first photo'
            : album
                ? ''
                : '${first[0].toUpperCase()}${first.substring(1)}: '
                    '${_phrases[h % _phrases.length]}';
    final mentions = chat.group && n % 157 == 0;
    final reactions = chat.group && h % 6 == 0
        ? {'👍': 1 + h % 4, if (h % 12 == 0) '🔥': 1 + h % 3}
        : chat.media && h % 9 == 0
            ? {'❤️': 3 + h % 40}
            : const <String, int>{};
    return ChatMessage(
      key: MessageKey(order: order, id: '$order'),
      text: mentions ? '@you $text' : text,
      senderId: sender,
      // One message per minute, so a day has 1,440 of them.
      sentAt: _epoch.add(Duration(minutes: n)),
      outgoing: outgoing,
      service: service,
      mentionsMe: mentions,
      albumId: album ? 'album-${n ~/ 3}' : null,
      imageAspect: image ? [1.5, 1.0, 0.75][h % 3] : null,
      replyTo: chat.group && n % 9 == 0 && n > 40
          ? MessageKey(
              order: (n - 3 - h % 30) * _step,
              id: '${(n - 3 - h % 30) * _step}',
            )
          : null,
      reactions: reactions,
    );
  }

  ChatMessage? _at(_ChatState state, int order) {
    if (state.deleted.contains(order)) return null;
    final extra = state.added[order];
    if (extra != null) return state.edited[order] ?? extra;
    if (order <= 0 || order % _step != 0) return null;
    final n = order ~/ _step;
    return n > state.chat.count ? null : _generate(state, n);
  }

  int? _next(_ChatState state, int order) {
    final count = state.chat.count;
    for (var n = order < 0 ? 1 : order ~/ _step + 1; n <= count; n++) {
      if (!state.deleted.contains(n * _step)) return n * _step;
    }
    for (final key in state.added.keys) {
      if (key > order && !state.deleted.contains(key)) return key;
    }
    return null;
  }

  int? _previous(_ChatState state, int order) {
    for (final key in state.added.keys.toList().reversed) {
      if (key < order && !state.deleted.contains(key)) return key;
    }
    var n = (order - 1) ~/ _step;
    if (n > state.chat.count) n = state.chat.count;
    for (; n >= 1; n--) {
      if (!state.deleted.contains(n * _step)) return n * _step;
    }
    return null;
  }

  int _newest(_ChatState state) =>
      state.added.isEmpty ? state.chat.count * _step : state.added.keys.last;

  ({List<ChatMessage> items, bool end}) _walk(
    _ChatState state,
    int from,
    int limit,
    int? Function(_ChatState, int) step,
  ) {
    final items = <ChatMessage>[];
    int? cursor = from;
    while (items.length < limit) {
      cursor = step(state, cursor!);
      if (cursor == null) break;
      items.add(_at(state, cursor)!);
    }
    return (
      items: items,
      end: cursor == null || step(state, cursor) == null,
    );
  }

  /// The key of message number [n] of [list].
  MessageKey keyOfNumber(int n) =>
      MessageKey(order: n * _step, id: '${n * _step}');

  /// The newest key of [list].
  MessageKey newestKey(ListId list) {
    final order = _newest(_state(list));
    return MessageKey(order: order, id: '$order');
  }

  ReadState readStateOf(ListId list) => _state(list).readState();

  /// The pinned messages of [list].
  List<MessageKey> pinnedOf(ListId list) {
    final chat = _state(list).chat;
    if (chat.pinnedEvery == 0) return const [];
    return [
      for (var i = 1; i <= 5; i++)
        keyOfNumber(chat.count - i * chat.pinnedEvery),
    ];
  }

  // -------------------------------------------------------- MessageSource

  Future<void> _delay() async {
    requestCount.value++;
    await Future<void>.delayed(Duration(milliseconds: latencyMs.value));
    if (!online.value) throw StateError('No connection');
    if (_random.nextInt(100) < failurePercent.value) {
      throw StateError('Simulated server error');
    }
  }

  @override
  Future<PageResult<ChatMessage>> fetch(PageRequest request) async {
    await _delay();
    final state = _state(request.list);
    var anchor = request.anchor?.order;
    final date = request.anchorDate;
    if (anchor == null && date != null) {
      final minutes = date.difference(_epoch).inMinutes;
      anchor = (minutes < 1 ? 1 : minutes + 1) * _step;
      final newest = _newest(state);
      if (anchor > newest) anchor = newest;
    }
    final read = state.readState();
    switch (request.direction) {
      case PageDirection.latest:
        final page = _walk(state, _newest(state) + 1, request.limit, _previous);
        return PageResult(
          items: page.items,
          reachedOldest: page.end,
          reachedNewest: true,
          readState: read,
        );
      case PageDirection.older:
        final page = _walk(state, anchor!, request.limit, _previous);
        return PageResult(
          items: page.items,
          reachedOldest: page.end,
          readState: read,
        );
      case PageDirection.newer:
        final page = _walk(state, anchor!, request.limit, _next);
        return PageResult(
          items: page.items,
          reachedNewest: page.end,
          readState: read,
        );
      case PageDirection.around:
        final half = request.limit ~/ 2;
        final before = _walk(state, anchor!, half, _previous);
        final after = _walk(state, anchor, half, _next);
        final self = _at(state, anchor);
        return PageResult(
          items: [...before.items, if (self != null) self, ...after.items],
          reachedOldest: before.end,
          reachedNewest: after.end,
          readState: read,
        );
    }
  }

  @override
  Stream<ListEvent<ChatMessage>> events(ListId list) {
    final state = _state(list);
    // Pinned messages are sent to every new subscriber.
    scheduleMicrotask(() {
      final pinned = pinnedOf(list);
      if (pinned.isNotEmpty) {
        state.events.add(PinnedChanged<ChatMessage>(list, pinned));
      }
    });
    return state.events.stream;
  }

  @override
  Future<void> markRead(ListId list, MessageKey upTo) async {
    await _delay();
    final state = _state(list);
    final before = state.lastRead;
    if (upTo.order <= before) return;
    state
      ..unread = max(0, state.unread - (upTo.order - before) ~/ _step)
      ..lastRead = upTo.order;
    if (upTo.order >= _newest(state)) state.unread = 0;
    state.events.add(ReadStateChanged<ChatMessage>(list, state.readState()));
  }

  void _emit(ListId list, ListEvent<ChatMessage> event) {
    if (online.value) {
      _state(list).events.add(event);
    } else {
      _state(list).missed.add(event); // lost: the client must refetch
    }
  }

  // --------------------------------------------------------------- search

  @override
  Future<SearchPage> search(
    ListId list,
    String query, {
    String? cursor,
    int limit = 50,
  }) async {
    await _delay();
    final state = _state(list);
    final wanted = query.toLowerCase();
    // The residues n % words.length whose first word matches the query.
    final residues = [
      for (var i = 0; i < words.length; i++)
        if (words[i].startsWith(wanted)) i,
    ];
    if (residues.isEmpty) return const SearchPage(keys: [], totalCount: 0);
    final count = state.chat.count;
    var total = 0;
    for (final r in residues) {
      // Numbers 1..count with n % words.length == r.
      total += r == 0
          ? count ~/ words.length
          : count >= r
              ? (count - r) ~/ words.length + 1
              : 0;
    }
    // Walk downward from the cursor (a message number).
    var n = cursor == null ? count : int.parse(cursor);
    final keys = <MessageKey>[];
    while (n >= 1 && keys.length < limit) {
      if (residues.contains(n % words.length) &&
          !state.deleted.contains(n * _step)) {
        keys.add(keyOfNumber(n));
      }
      n--;
    }
    return SearchPage(
      keys: keys,
      totalCount: total,
      nextCursor: n >= 1 ? '$n' : null,
    );
  }

  // -------------------------------------------------------------- sending

  /// Confirms (or fails) a message the client inserted with [localId].
  void send(ListId list, String localId, ChatMessage pending) {
    final state = _state(list);
    final jitter = outOfOrderAcks.value ? _random.nextInt(700) : 0;
    Timer(Duration(milliseconds: latencyMs.value + 250 + jitter), () {
      if (!online.value || _random.nextInt(100) < failurePercent.value) {
        state.events.add(
          LocalFailed<ChatMessage>(list, localId, 'Not delivered'),
        );
        return;
      }
      final order = _newest(state) + _step;
      final confirmed = ChatMessage(
        key: MessageKey(order: order, id: '$order'),
        text: pending.text,
        senderId: 'me',
        sentAt: DateTime.now(),
        outgoing: true,
        replyTo: pending.replyTo,
      );
      state.added[order] = confirmed;
      state.events.add(LocalAcked<ChatMessage>(list, localId, confirmed));
      // The peer reads it a moment later.
      Timer(const Duration(seconds: 2), () {
        state.readOutbox = order;
        state.events.add(
          ReadStateChanged<ChatMessage>(list, state.readState()),
        );
      });
    });
  }

  // ------------------------------------------------- things that "happen"

  /// A new message from someone else arrives in [list].
  ChatMessage incoming(ListId list, {String? text}) {
    final state = _state(list);
    final order = _newest(state) + _step;
    final n = order ~/ _step;
    final message = ChatMessage(
      key: MessageKey(order: order, id: '$order'),
      text: text ??
          '${words[n % words.length]}: ${_phrases[n % _phrases.length]}',
      senderId: state.chat.group ? senders[1 + n % 5] : 'alice',
      sentAt: DateTime.now(),
    );
    state
      ..added[order] = message
      ..unread += 1;
    _emit(list, MessagesAdded<ChatMessage>(list, [message]));
    return message;
  }

  /// Deletes messages "from another device".
  void remoteDelete(ListId list, Iterable<MessageKey> keys) {
    final state = _state(list);
    final ids = <String>[];
    for (final key in keys) {
      state.deleted.add(key.order);
      ids.add(key.id);
    }
    if (ids.isNotEmpty) _emit(list, MessagesDeleted<ChatMessage>(list, ids));
  }

  /// Changes a message on the server (an edit, a reaction, an image that
  /// finished loading).
  void update(ListId list, ChatMessage message) {
    _state(list).edited[message.key.order] = message;
    _emit(list, MessagesUpdated<ChatMessage>(list, [message]));
  }

  /// The current server version of [key].
  ChatMessage? messageAt(ListId list, MessageKey key) =>
      _at(_state(list), key.order);

  /// Edits a message so that its height changes.
  void remoteEdit(ListId list, MessageKey key) {
    final current = messageAt(list, key);
    if (current == null || current.service) return;
    final longer = current.text.length < 120;
    update(
      list,
      current.copyWith(
        edited: true,
        text: longer
            ? '${current.text}\n\n(edited) ${_phrases[5]} ${_phrases[8]}'
            : 'Edited: short now',
      ),
    );
  }

  void setTyping(ListId list, {required bool typing}) => _emit(
        list,
        TypingChanged<ChatMessage>(list, typing ? {'alice'} : const {}),
      );

  /// Loses the connection: events are dropped until [reconnect].
  void disconnect() => online.value = false;

  /// Comes back online. What happened meanwhile is not replayed; clients
  /// call `controller.invalidate()`.
  void reconnect() {
    online.value = true;
    for (final state in _chats.values) {
      state.missed.clear();
    }
  }

  /// Starts or stops the timers of the debug panel.
  void applyRates() {
    _incoming?.cancel();
    _storm?.cancel();
    final perSecond = incomingPerSecond.value;
    if (perSecond > 0) {
      _incoming = Timer.periodic(
        Duration(microseconds: 1000000 ~/ perSecond),
        (_) {
          final list = _activeList;
          if (list != null) incoming(list);
        },
      );
    }
    final reactions = reactionsPerSecond.value;
    if (reactions > 0) {
      _storm = Timer.periodic(
        Duration(microseconds: 1000000 ~/ reactions),
        (_) => _react(),
      );
    }
  }

  void _react() {
    final list = _activeList;
    final visible = _visibleKeys?.call() ?? const <MessageKey>[];
    if (list == null || visible.isEmpty) return;
    final key = visible[_random.nextInt(visible.length)];
    final current = messageAt(list, key);
    if (current == null || current.service) return;
    final emoji = const ['👍', '🔥', '❤️', '😂'][_random.nextInt(4)];
    update(
      list,
      current.copyWith(
        reactions: {
          ...current.reactions,
          emoji: (current.reactions[emoji] ?? 0) + 1,
        },
      ),
    );
  }

  void dispose() {
    _incoming?.cancel();
    _storm?.cancel();
    for (final state in _chats.values) {
      unawaited(state.events.close());
    }
  }
}

class _ChatState {
  _ChatState(this.chat)
      : unread = chat.unread,
        lastRead = (chat.count - chat.unread) * 4;

  final DemoChat chat;
  final StreamController<ListEvent<ChatMessage>> events =
      StreamController<ListEvent<ChatMessage>>.broadcast();
  final Set<int> deleted = {};
  final Map<int, ChatMessage> edited = {};
  final SplayTreeMapLike added = SplayTreeMapLike();
  final List<ListEvent<ChatMessage>> missed = [];
  int unread;
  int lastRead;
  int readOutbox = 0;

  ReadState readState() => ReadState(
        lastReadInbox:
            lastRead <= 0 ? null : MessageKey(order: lastRead, id: '$lastRead'),
        lastReadOutbox: readOutbox <= 0
            ? null
            : MessageKey(order: readOutbox, id: '$readOutbox'),
        unreadCount: unread,
        unreadMentions: chat.group && unread > 0
            ? [
                for (var n = chat.count - unread + 1; n <= chat.count; n++)
                  if (n % 157 == 0) MessageKey(order: n * 4, id: '${n * 4}'),
              ]
            : const [],
      );
}

/// Messages that arrived after the generated history, by order.
class SplayTreeMapLike {
  final Map<int, ChatMessage> _map = {};
  final List<int> _keys = [];

  bool get isEmpty => _keys.isEmpty;
  List<int> get keys => _keys;
  ChatMessage? operator [](int order) => _map[order];

  void operator []=(int order, ChatMessage message) {
    if (!_map.containsKey(order)) _keys.add(order); // orders only grow
    _map[order] = message;
  }
}
