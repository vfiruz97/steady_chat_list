import 'dart:convert';

import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('MessageKey', () {
    test('sorts by order, then localSeq, then id', () {
      final keys = [
        k(2, id: 'b'),
        k(1, id: 'z'),
        k(2, id: 'a'),
        k(1, id: 'p', localSeq: 2),
        k(1, id: 'q', localSeq: 1),
      ]..sort();
      expect([for (final key in keys) key.id], ['z', 'q', 'p', 'a', 'b']);
      expect(k(1) < k(2), isTrue);
      expect(k(2) >= k(2), isTrue);
    });

    test('identity is the id only', () {
      final local = k(5, id: 'x', localSeq: 1);
      final server = k(9, id: 'x');
      expect(local, server);
      expect(local.hashCode, server.hashCode);
      expect(local.isSamePosition(server), isFalse);
      expect(local.isLocal, isTrue);
      expect(server.isLocal, isFalse);
    });

    test('survives JSON', () {
      for (final key in [k(42), k(42, id: 'c', localSeq: 3)]) {
        final back = MessageKey.fromJson(
          jsonDecode(jsonEncode(key.toJson())) as Map<String, Object?>,
        );
        expect(back.isSamePosition(key), isTrue);
      }
    });
  });

  test('ListId compares by chat and thread', () {
    expect(const ListId('a'), const ListId('a'));
    expect(const ListId('a'), isNot(const ListId('a', 't')));
    expect(const ListId('a', 't').storageKey, 'a/t');
    expect({const ListId('a', 't')}.contains(const ListId('a', 't')), isTrue);
  });

  test('ReadState compares positions and survives JSON', () {
    final state = ReadState(
      lastReadInbox: k(10),
      lastReadOutbox: k(8),
      unreadCount: 3,
      unreadMentions: [k(12), k(11)],
      unreadReactions: [k(7)],
    );
    final back = ReadState.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
    );
    expect(back, state);
    expect(state.normalized().unreadMentions, [k(11), k(12)]);
    final sorted = back.normalized();
    expect(identical(sorted.normalized(), sorted), isTrue);
    expect(state.copyWith(unreadCount: 0), isNot(state));
    expect(ReadState.empty, const ReadState());
  });

  test('ViewportSnapshot survives JSON and knows its range', () {
    final snapshot = ViewportSnapshot(
      anchorKey: k(50),
      anchorOffset: -12.5,
      offsetFromBottom: 1600,
      visibleKeys: [k(50), k(60), k(70)],
      connectedToNewest: true,
      viewportWidth: 390,
      savedAt: DateTime.utc(2026, 11, 20, 12),
    );
    final back = ViewportSnapshot.fromJson(
      jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>,
    );
    expect(back.anchorKey.isSamePosition(k(50)), isTrue);
    expect(back.anchorOffset, -12.5);
    expect(back.offsetFromBottom, 1600);
    expect(back.visibleKeys, hasLength(3));
    expect(back.connectedToNewest, isTrue);
    expect(back.viewportWidth, 390);
    expect(back.savedAt, snapshot.savedAt);
    expect(back.range.first, k(50));
    expect(back.range.last.isSamePosition(k(70)), isTrue);
  });

  test('CancellationToken completes once', () async {
    final token = CancellationToken();
    expect(token.isCancelled, isFalse);
    token
      ..cancel()
      ..cancel();
    expect(token.isCancelled, isTrue);
    await token.whenCancelled;
  });
}
