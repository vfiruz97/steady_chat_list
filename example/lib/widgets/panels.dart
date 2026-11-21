import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import '../data/fake_chat_server.dart';
import '../data/models.dart';

/// Knobs of the simulated server and things that "happen" to the open chat:
/// latency, failures, incoming messages, reaction storms, remote deletes
/// and edits, a lost connection.
class ServerPanel extends StatelessWidget {
  const ServerPanel({
    super.key,
    required this.server,
    required this.controller,
  });

  final FakeChatServer server;

  /// The chat the actions apply to.
  final ValueNotifier<MessageListController<ChatMessage>?> controller;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<MessageListController<ChatMessage>?>(
        valueListenable: controller,
        builder: (context, chat, _) => ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Server', style: Theme.of(context).textTheme.titleSmall),
            _slider('Latency', server.latencyMs, 0, 2000, 'ms'),
            _slider('Failure rate', server.failurePercent, 0, 50, '%'),
            _slider(
              'Incoming messages',
              server.incomingPerSecond,
              0,
              50,
              '/s',
              onChanged: server.applyRates,
            ),
            _slider(
              'Reaction storm',
              server.reactionsPerSecond,
              0,
              200,
              '/s',
              onChanged: server.applyRates,
            ),
            _switch('Out-of-order acks', server.outOfOrderAcks),
            ValueListenableBuilder<bool>(
              valueListenable: server.online,
              builder: (context, online, _) => SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(online ? 'Online' : 'Offline (events are lost)'),
                value: online,
                onChanged: (value) {
                  if (value) {
                    server.reconnect();
                    // After a reconnect: refresh without moving.
                    unawaited(chat?.invalidate());
                  } else {
                    server.disconnect();
                  }
                },
              ),
            ),
            if (chat != null) ...[
              const Divider(),
              Text(
                'Happens in this chat',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _action('Incoming message', () => server.incoming(chat.list)),
                  _action('Delete a visible one', () => _delete(chat, 0)),
                  _action('Delete above viewport', () => _delete(chat, -1)),
                  _action('Delete below viewport', () => _delete(chat, 1)),
                  _action('Delete a batch of 5', () => _delete(chat, 0, 5)),
                  _action('Edit (changes height)', () {
                    final visible = chat.visibleItems;
                    if (visible.isEmpty) return;
                    server.remoteEdit(
                      chat.list,
                      visible[visible.length ~/ 2].key,
                    );
                  }),
                  _action('Edit above viewport', () {
                    final keys = chat.window.value.keys;
                    final visible = chat.visibleItems;
                    if (visible.isEmpty) return;
                    final first = keys.indexOf(visible.first.key);
                    if (first > 2) {
                      server.remoteEdit(chat.list, keys[first - 2]);
                    }
                  }),
                  _action(
                    'Typing…',
                    () {
                      server.setTyping(chat.list, typing: true);
                      Timer(
                        const Duration(seconds: 3),
                        () => server.setTyping(chat.list, typing: false),
                      );
                    },
                  ),
                  _action('Refresh (invalidate)', chat.invalidate),
                  _action('Reset list', chat.reset),
                ],
              ),
            ],
          ],
        ),
      );

  /// Deletes messages "from another device": [where] is -1 above the
  /// viewport, 0 inside, 1 below.
  void _delete(
    MessageListController<ChatMessage> chat,
    int where, [
    int count = 1,
  ]) {
    final keys = chat.window.value.keys;
    final visible = chat.visibleItems;
    if (visible.isEmpty) return;
    final first = keys.indexOf(visible.first.key);
    final last = keys.indexOf(visible.last.key);
    final targets = <MessageKey>[];
    if (where < 0) {
      for (var i = first - 2; i >= 0 && targets.length < count; i -= 2) {
        targets.add(keys[i]);
      }
    } else if (where > 0) {
      for (var i = last + 2;
          i < keys.length && targets.length < count;
          i += 2) {
        targets.add(keys[i]);
      }
    } else {
      for (var i = first + 1; i <= last && targets.length < count; i += 2) {
        targets.add(keys[i]);
      }
    }
    server.remoteDelete(chat.list, targets);
  }

  Widget _action(String label, VoidCallback onPressed) => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );

  Widget _switch(String label, ValueNotifier<bool> value) =>
      ValueListenableBuilder<bool>(
        valueListenable: value,
        builder: (context, on, _) => SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          value: on,
          onChanged: (v) => value.value = v,
        ),
      );

  Widget _slider(
    String label,
    ValueNotifier<int> value,
    int min,
    int max,
    String unit, {
    VoidCallback? onChanged,
  }) =>
      ValueListenableBuilder<int>(
        valueListenable: value,
        builder: (context, current, _) => Row(
          children: [
            SizedBox(width: 118, child: Text(label)),
            Expanded(
              child: Slider(
                value: current.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                onChanged: (v) {
                  value.value = v.round();
                  onChanged?.call();
                },
              ),
            ),
            SizedBox(width: 62, child: Text('$current $unit')),
          ],
        ),
      );
}

/// Frame times of the last two seconds: build (which includes layout) and
/// raster, as the framework reports them.
class PerfHud extends StatefulWidget {
  const PerfHud({super.key});

  @override
  State<PerfHud> createState() => _PerfHudState();
}

class _PerfHudState extends State<PerfHud> {
  final List<FrameTiming> _frames = [];
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _refresh = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _refresh?.cancel();
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    _frames.addAll(timings);
    if (_frames.length > 120) _frames.removeRange(0, _frames.length - 120);
  }

  @override
  Widget build(BuildContext context) {
    double ms(Duration d) => d.inMicroseconds / 1000;
    final builds = [for (final f in _frames) ms(f.buildDuration)]..sort();
    final totals = [for (final f in _frames) ms(f.totalSpan)]..sort();
    String p(List<double> sorted, double q) => sorted.isEmpty
        ? '–'
        : sorted[((sorted.length - 1) * q).round()].toStringAsFixed(1);
    final slow = totals.where((t) => t > 16.7).length;
    return DecoratedBox(
      decoration: BoxDecoration(
        // Nearly opaque: it sits on top of messages.
        color: Colors.black.withAlpha(235),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          'build p50 ${p(builds, 0.5)} · p95 ${p(builds, 0.95)} ms\n'
          'frame p95 ${p(totals, 0.95)} · max ${p(totals, 1)} ms\n'
          'slow frames: $slow of ${_frames.length}',
          style: const TextStyle(
            color: Color(0xFF7CFC00),
            fontSize: 11,
            fontFamily: 'monospace',
            height: 1.3,
          ),
        ),
      ),
    );
  }
}

/// A scrolling log of what a controller reports.
class EventLog extends StatefulWidget {
  const EventLog({super.key, required this.controller});

  final MessageListController<ChatMessage> controller;

  @override
  State<EventLog> createState() => _EventLogState();
}

class _EventLogState extends State<EventLog> {
  final List<String> _lines = [];
  StreamSubscription<MessageListEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.controller.events.listen(_add);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _add(MessageListEvent event) {
    final text = switch (event) {
      ListOpened(:final resolution) => 'opened: ${resolution.name}',
      PageRequested(:final request) =>
        'page requested: ${request.direction.name}',
      PageLoaded(:final result, :final duration) =>
        'page loaded: ${result.items.length} in ${duration.inMilliseconds} ms',
      PageFailed(:final error) => 'page failed: $error',
      ReadUpTo(:final key) => 'read up to ${key.id}',
      UnreadChanged(:final count) => 'unread: $count',
      AtBottomChanged(:final atBottom) => 'at bottom: $atBottom',
      WindowChanged(:final first, :final last, :final count) =>
        'window: ${first?.id}..${last?.id} ($count)',
      MessageInserted(:final keys, :final cause) =>
        'inserted ${keys.length} (${cause.name})',
      MessageUpdated(:final keys) => 'updated ${keys.length}',
      MessageRemoved(:final keys, :final cause) =>
        'removed ${keys.length} (${cause.name})',
      KeyReplaced(:final oldKey, :final newKey) =>
        'acked: ${oldKey.id} → ${newKey.id}',
      SnapshotSaved(:final reason) => 'position saved (${reason.name})',
      Jumped(:final jump) => 'jump ${jump.toMap()}',
      CurrentPinnedChanged(:final key) => 'pinned bar: ${key?.id}',
      VisibleRangeChanged(:final range) => 'visible: $range',
      ItemVisibilityChanged(:final key, :final fraction) =>
        'visibility ${key.id}: ${fraction.toStringAsFixed(2)}',
      MessagesSeen(:final keys) => 'seen ${keys.length}',
      ItemDisposed(:final key) => 'left the window: ${key.id}',
      PrefetchSuggested(:final messages) =>
        'prefetch suggested: ${messages.length}',
      TopVisibleDayChanged(:final day) =>
        'top day: ${day == null ? '–' : formatDayLabel(day)}',
      DayTapped(:final day) => 'day tapped: ${formatDayLabel(day)}',
      DiagnosticReported(:final diagnostic) => 'diagnostic: $diagnostic',
    };
    if (!mounted) return;
    setState(() {
      _lines.insert(0, text);
      if (_lines.length > 200) _lines.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: _lines.length,
        itemBuilder: (context, i) => Text(
          _lines[i],
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        ),
      );
}
