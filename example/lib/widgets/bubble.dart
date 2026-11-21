import 'package:flutter/material.dart';
import 'package:steady_chat_list/steady_chat_list.dart';

import '../data/models.dart';

/// A chat bubble: text, an image placeholder with a known aspect ratio, a
/// reply preview, reactions, time and delivery checkmarks. It shows what
/// `MessageItemInfo` offers: grouping, highlight, selection, send state.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.info,
    this.showSender = false,
    this.replyPreview,
    this.onReplyTap,
    this.onReact,
    this.onTap,
    this.onLongPress,
  });

  final ChatMessage message;
  final MessageItemInfo info;
  final bool showSender;

  /// The text of the message this one replies to, when it is loaded.
  final String? replyPreview;
  final VoidCallback? onReplyTap;
  final void Function(String emoji)? onReact;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (message.service) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            message.text,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
        ),
      );
    }
    final mine = message.outgoing;
    final color = mine ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    final radius = BorderRadius.only(
      topLeft: Radius.circular(mine || info.isFirstInGroup ? 16 : 6),
      topRight: Radius.circular(!mine || info.isFirstInGroup ? 16 : 6),
      bottomLeft: Radius.circular(mine || info.isLastInGroup ? 16 : 6),
      bottomRight: Radius.circular(!mine || info.isLastInGroup ? 16 : 6),
    );
    final bubble = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, borderRadius: radius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showSender && info.isFirstInGroup && !mine)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    senderName(message.senderId),
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              if (message.replyTo != null) _reply(scheme),
              if (message.imageAspect != null) _image(scheme),
              if (message.text.isNotEmpty)
                _HighlightedText(
                  text: message.text,
                  query: info.highlightQuery,
                  color: scheme.onSurface,
                  mark: scheme.tertiaryContainer,
                ),
              if (message.reactions.isNotEmpty) _reactions(scheme),
              _footer(scheme),
            ],
          ),
        ),
      ),
    );
    return JumpHighlightBackground(
      info: info,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.only(
            left: 8,
            right: 8,
            top: info.isFirstInGroup ? 6 : 1.5,
            bottom: 1.5,
          ),
          child: Row(
            children: [
              if (info.selectionActive)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    info.isSelected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: info.isSelected ? scheme.primary : scheme.outline,
                  ),
                ),
              Expanded(
                child: Align(
                  alignment:
                      mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: bubble,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reply(ColorScheme scheme) => GestureDetector(
        onTap: onReplyTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: scheme.primary, width: 3)),
            color: scheme.primary.withAlpha(20),
          ),
          child: Text(
            replyPreview ?? 'Message ${message.replyTo!.id} (tap to jump)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
      );

  // The aspect ratio is known before the image loads, so the row has its
  // final height from the start (see the README: give media a size).
  Widget _image(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: message.imageAspect!,
            child: ColoredBox(
              color: message.imageLoaded
                  ? scheme.tertiaryContainer
                  : scheme.surfaceContainerHighest,
              child: Center(
                child: message.imageLoaded
                    ? Icon(Icons.image, color: scheme.onTertiaryContainer)
                    : const SteadySpinner(),
              ),
            ),
          ),
        ),
      );

  Widget _reactions(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final entry in message.reactions.entries)
              GestureDetector(
                onTap: onReact == null ? null : () => onReact!(entry.key),
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: message.myReactions.contains(entry.key)
                        ? scheme.primary.withAlpha(60)
                        : scheme.surface.withAlpha(160),
                    shape: const StadiumBorder(),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    child: Text(
                      '${entry.key} ${entry.value}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _footer(ColorScheme scheme) {
    final time = TimeOfDay.fromDateTime(message.sentAt);
    final label = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${message.edited ? 'edited ' : ''}$label',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          if (info.sendState != SendState.none) ...[
            const SizedBox(width: 4),
            Icon(
              switch (info.sendState) {
                SendState.sending => Icons.schedule,
                SendState.failed => Icons.error_outline,
                _ => info.isRead ? Icons.done_all : Icons.done,
              },
              size: 14,
              color: info.sendState == SendState.failed
                  ? scheme.error
                  : info.isRead
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
            ),
          ],
        ],
      ),
    );
  }
}

/// Text with the search term marked.
class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.text,
    required this.query,
    required this.color,
    required this.mark,
  });

  final String text;
  final String? query;
  final Color color;
  final Color mark;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: color, fontSize: 15, height: 1.3);
    final wanted = query?.toLowerCase();
    if (wanted == null || wanted.isEmpty) return Text(text, style: style);
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    while (true) {
      final at = lower.indexOf(wanted, from);
      if (at < 0) break;
      spans
        ..add(TextSpan(text: text.substring(from, at)))
        ..add(
          TextSpan(
            text: text.substring(at, at + wanted.length),
            style: TextStyle(backgroundColor: mark),
          ),
        );
      from = at + wanted.length;
    }
    spans.add(TextSpan(text: text.substring(from)));
    return Text.rich(TextSpan(children: spans), style: style);
  }
}

/// An album: several photos in one row.
class AlbumBubble extends StatelessWidget {
  const AlbumBubble({super.key, required this.messages, required this.info});

  final List<ChatMessage> messages;
  final MessageItemInfo info;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return JumpHighlightBackground(
      info: info,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 140,
                child: Row(
                  children: [
                    for (var i = 0; i < messages.length; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: i == 0 ? 0 : 2),
                          child: ColoredBox(
                            color: scheme.tertiaryContainer,
                            child: Center(
                              child: Icon(
                                Icons.photo,
                                color: scheme.onTertiaryContainer,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
