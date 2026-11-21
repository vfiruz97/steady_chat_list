// Reads and writes of the Drift cache on the Dart VM (SPEC §14.1: a page
// read of 40 messages takes at most 10 ms on a device).
//
//   dart run benchmark/drift_benchmark.dart
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:drift/native.dart';
import 'package:steady_chat_list_core/steady_chat_list_core.dart';
import 'package:steady_chat_list_drift/steady_chat_list_drift.dart';

class Message {
  const Message(this.id, this.text);

  factory Message.fromJson(Map<String, Object?> json) =>
      Message(json['id']! as int, json['text']! as String);

  final int id;
  final String text;

  Map<String, Object?> toJson() => {'id': id, 'text': text};
}

class Adapter extends MessageAdapter<Message> {
  const Adapter();

  @override
  MessageKey keyOf(Message m) => MessageKey(order: m.id, id: '${m.id}');

  @override
  DateTime dateOf(Message m) =>
      DateTime.fromMillisecondsSinceEpoch(m.id * 60000, isUtc: true);
}

Map<String, Object?> _toJson(Message m) => m.toJson();

MessageKey k(int id) => MessageKey(order: id, id: '$id');

double median(List<double> values) {
  values.sort();
  return values[values.length ~/ 2];
}

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('steady_bench');
  final cache = DriftMessageCache<Message>(
    SteadyCacheDatabase(NativeDatabase(File('${directory.path}/cache.db'))),
    adapter: const Adapter(),
    codec: const JsonMessageCodec<Message>(Message.fromJson, _toJson),
  );
  const list = ListId('chat');
  const text = 'A message of ordinary length, about as long as a sentence '
      'that somebody types on a phone.';

  // 600 messages in pages of 40, as the hub writes them.
  final writes = <double>[];
  for (var page = 0; page < 15; page++) {
    final first = page * 40 + 1;
    final watch = Stopwatch()..start();
    await cache.applyPage(
      PageRequest(list: list, direction: PageDirection.newer, limit: 40),
      PageResult(
          items: [for (var i = first; i < first + 40; i++) Message(i, text)]),
      segments: [
        Segment(first: k(1), last: k(first + 39), reachedNewest: true),
      ],
    );
    writes.add(watch.elapsedMicroseconds / 1000);
  }

  final page = <double>[];
  final whole = <double>[];
  for (var run = 0; run < 30; run++) {
    var watch = Stopwatch()..start();
    final some = await cache.load(list, limit: 40);
    page.add(watch.elapsedMicroseconds / 1000);
    if (some!.messages.length != 40) throw StateError('expected 40');
    watch = Stopwatch()..start();
    final all = await cache.load(list);
    whole.add(watch.elapsedMicroseconds / 1000);
    if (all!.messages.length != 600) throw StateError('expected 600');
  }

  print('write a page of 40      ${median(writes).toStringAsFixed(2)} ms');
  print('read a page of 40       ${median(page).toStringAsFixed(2)} ms');
  print('read a whole list (600) ${median(whole).toStringAsFixed(2)} ms');
  await cache.close();
  await directory.delete(recursive: true);
  if (median(page) > 10) {
    stderr.writeln('budget exceeded: page read over 10 ms');
    exitCode = 1;
  }
}
