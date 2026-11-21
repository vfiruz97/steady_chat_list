import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show DateFormat;

import 'controller.dart';
import 'defaults.dart';
import 'theme.dart';

/// Formats an unread count for a badge: 1–999 as is, then 1K, 7.2K, 12K,
/// 1M.
///
/// ```dart
/// formatUnreadCount(7200); // '7.2K'
/// ```
String formatUnreadCount(int count) {
  if (count < 1000) return '$count';
  String short(double value, String unit) {
    if (value >= 10) return '${value.floor()}$unit';
    final tenths = (value * 10).floor();
    return tenths % 10 == 0
        ? '${tenths ~/ 10}$unit'
        : '${tenths ~/ 10}.${tenths % 10}$unit';
  }

  return count < 1000000
      ? short(count / 1000, 'K')
      : short(count / 1000000, 'M');
}

/// The label of a day: "Today", "Yesterday", the weekday within the last
/// week, else the date (with the year when it is not this year).
///
/// ```dart
/// formatDayLabel(DateTime(2026, 11, 13), now: DateTime(2026, 11, 20));
/// // 'November 13'
/// ```
String formatDayLabel(DateTime day, {DateTime? now, String? locale}) {
  final today = now ?? DateTime.now();
  final a = DateTime(today.year, today.month, today.day);
  final b = DateTime(day.year, day.month, day.day);
  final days = a.difference(b).inHours / 24;
  final ago = days.round();
  if (ago == 0) return 'Today';
  if (ago == 1) return 'Yesterday';
  if (ago > 1 && ago < 7) return DateFormat.EEEE(locale).format(b);
  return b.year == a.year
      ? DateFormat.MMMMd(locale).format(b)
      : DateFormat.yMMMMd(locale).format(b);
}

/// The round button that brings the list back to the newest message, with
/// the unread count as a badge and a ring while a jump is loading.
///
/// ```dart
/// scrollDownButtonBuilder: (context, unread, onTap) =>
///     ScrollDownButton(unread: unread, onTap: onTap),
/// ```
class ScrollDownButton extends StatelessWidget {
  /// Creates the button.
  const ScrollDownButton({
    super.key,
    required this.unread,
    required this.onTap,
    this.loading = false,
    this.size = 44,
  });

  /// Unread messages; no badge for 0.
  final int unread;

  /// Called on tap.
  final VoidCallback onTap;

  /// Shows a progress ring (the jump is loading a page).
  final bool loading;

  /// Diameter.
  final double size;

  @override
  Widget build(BuildContext context) => RoundListButton(
        onTap: onTap,
        size: size,
        badge: unread,
        loading: loading,
        semanticLabel: 'Scroll to bottom',
        child: CustomPaint(
          size: Size.square(size * 0.4),
          painter:
              _ChevronPainter(MessageListTheme.of(context).buttonIconColor),
        ),
      );
}

/// The button that jumps to the next unread mention.
///
/// ```dart
/// MentionButton(count: mentions, onTap: controller.jumpToNextUnreadMention);
/// ```
class MentionButton extends StatelessWidget {
  /// Creates the button.
  const MentionButton({
    super.key,
    required this.count,
    required this.onTap,
    this.size = 44,
  });

  /// Unread mentions.
  final int count;

  /// Called on tap.
  final VoidCallback onTap;

  /// Diameter.
  final double size;

  @override
  Widget build(BuildContext context) => RoundListButton(
        onTap: onTap,
        size: size,
        badge: count,
        semanticLabel: 'Next mention',
        child: _Glyph('@', size),
      );
}

/// The button that jumps to the next unread reaction.
///
/// ```dart
/// ReactionButton(
///     count: reactions, onTap: controller.jumpToNextUnreadReaction);
/// ```
class ReactionButton extends StatelessWidget {
  /// Creates the button.
  const ReactionButton({
    super.key,
    required this.count,
    required this.onTap,
    this.size = 44,
  });

  /// Unread reactions.
  final int count;

  /// Called on tap.
  final VoidCallback onTap;

  /// Diameter.
  final double size;

  @override
  Widget build(BuildContext context) => RoundListButton(
        onTap: onTap,
        size: size,
        badge: count,
        semanticLabel: 'Next reaction',
        child: _Glyph('♥', size),
      );
}

class _Glyph extends StatelessWidget {
  const _Glyph(this.text, this.size);

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: size * 0.45,
          height: 1,
          color: MessageListTheme.of(context).buttonIconColor,
          decoration: TextDecoration.none,
        ),
      );
}

/// A floating round button with an optional count badge and progress ring;
/// the base of [ScrollDownButton], [MentionButton] and [ReactionButton].
///
/// ```dart
/// RoundListButton(onTap: openPolls, badge: 2, child: const Text('%'));
/// ```
class RoundListButton extends StatelessWidget {
  /// Creates the button.
  const RoundListButton({
    super.key,
    required this.onTap,
    required this.child,
    this.badge = 0,
    this.loading = false,
    this.size = 44,
    this.semanticLabel,
  });

  /// Called on tap.
  final VoidCallback onTap;

  /// The icon.
  final Widget child;

  /// The count shown above the button; hidden for 0.
  final int badge;

  /// Shows a progress ring around the icon.
  final bool loading;

  /// Diameter.
  final double size;

  /// What a screen reader says.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = MessageListTheme.of(context);
    return Semantics(
      button: true,
      label: semanticLabel,
      value: badge > 0 ? '$badge' : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size + (badge > 0 ? 8 : 0),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.buttonColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: theme.buttonShadowColor,
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: SizedBox.square(
                  dimension: size,
                  child: Center(
                    child: loading
                        ? SteadySpinner(
                            size: size * 0.5,
                            color: theme.badgeColor,
                          )
                        : child,
                  ),
                ),
              ),
              if (badge > 0)
                Positioned(
                  top: 0,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: theme.badgeColor,
                      shape: const StadiumBorder(),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Text(
                        formatUnreadCount(badge),
                        style: TextStyle(
                          color: theme.badgeTextColor,
                          fontSize: 12,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, size.height * 0.3)
      ..lineTo(size.width / 2, size.height * 0.75)
      ..lineTo(size.width, size.height * 0.3);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, size.width / 8)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) => oldDelegate.color != color;
}

/// A rounded chip with a day label: the header at the start of each day
/// and the chip that floats at the top while scrolling.
///
/// ```dart
/// dayHeaderBuilder: (context, day, onTap) => DayHeader(day: day, onTap: onTap),
/// ```
class DayHeader extends StatelessWidget {
  /// Creates the chip.
  const DayHeader({
    super.key,
    required this.day,
    this.onTap,
    this.label,
    this.padding = const EdgeInsets.symmetric(vertical: 6),
  });

  /// The day (local midnight).
  final DateTime day;

  /// Called on tap (open a date picker).
  final VoidCallback? onTap;

  /// The text; [formatDayLabel] by default. Pass your own to localize.
  final String? label;

  /// Space around the chip.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = MessageListTheme.of(context);
    return Padding(
      padding: padding,
      child: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: theme.chipColor,
              shape: const StadiumBorder(),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                label ?? formatDayLabel(day),
                style: TextStyle(
                  color: theme.chipTextColor,
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Unread messages" divider shown above the first unread message.
///
/// ```dart
/// unreadDividerBuilder: (context) => const UnreadDivider(text: 'New'),
/// ```
class UnreadDivider extends StatelessWidget {
  /// Creates the divider.
  const UnreadDivider({super.key, this.text = 'Unread messages'});

  /// The label.
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = MessageListTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ColoredBox(
        color: theme.dividerColor,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Center(
            child: Text(
              text,
              style: TextStyle(
                color: theme.dividerTextColor,
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The floating buttons of a list, driven by a controller: next mention,
/// next reaction and scroll to bottom. Each one appears only when it has
/// something to do. Put it in a `Stack` over the list.
///
/// ```dart
/// Stack(children: [
///   MessageListView(controller: controller, itemBuilder: ...),
///   Positioned(right: 12, bottom: 12,
///       child: MessageListButtons(controller: controller)),
/// ]);
/// ```
class MessageListButtons<M> extends StatelessWidget {
  /// Creates the buttons for [controller].
  const MessageListButtons({
    super.key,
    required this.controller,
    this.spacing = 8,
  });

  /// The list the buttons act on.
  final MessageListController<M> controller;

  /// Space between the buttons.
  final double spacing;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          VisibleWhen<int>(
            value: controller.unreadMentionsCount,
            shown: (count) => count > 0,
            builder: (context, count) => Padding(
              padding: EdgeInsets.only(bottom: spacing),
              child: MentionButton(
                count: count,
                onTap: controller.jumpToNextUnreadMention,
              ),
            ),
          ),
          VisibleWhen<int>(
            value: controller.unreadReactionsCount,
            shown: (count) => count > 0,
            builder: (context, count) => Padding(
              padding: EdgeInsets.only(bottom: spacing),
              child: ReactionButton(
                count: count,
                onTap: controller.jumpToNextUnreadReaction,
              ),
            ),
          ),
          VisibleWhen<bool>(
            value: controller.showScrollDownButton,
            shown: (show) => show,
            builder: (context, _) => ListenableBuilder(
              listenable: Listenable.merge(
                [controller.unreadCount, controller.jumpInProgress],
              ),
              builder: (context, _) => ScrollDownButton(
                unread: controller.unreadCount.value,
                loading: controller.jumpInProgress.value?.isLoading ?? false,
                onTap: controller.jumpToBottom,
              ),
            ),
          ),
        ],
      );
}

/// Shows its child with a scale and fade while a value says so, and keeps
/// showing the last visible value while it animates out. The floating
/// buttons use it.
///
/// ```dart
/// VisibleWhen<int>(
///   value: controller.unreadCount,
///   shown: (count) => count > 0,
///   builder: (context, count) => Text('$count new'),
/// );
/// ```
class VisibleWhen<T> extends StatefulWidget {
  /// Creates the widget.
  const VisibleWhen({
    required this.value,
    required this.shown,
    required this.builder,
    super.key,
  });

  /// What decides.
  final ValueListenable<T> value;

  /// Whether the child is visible for a value.
  final bool Function(T value) shown;

  /// Builds the child for the last visible value.
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<VisibleWhen<T>> createState() => _VisibleWhenState<T>();
}

class _VisibleWhenState<T> extends State<VisibleWhen<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _show;
  late T _last;

  @override
  void initState() {
    super.initState();
    _last = widget.value.value;
    _show = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      value: widget.shown(_last) ? 1 : 0,
    )..addStatusListener((_) => setState(() {}));
    widget.value.addListener(_changed);
  }

  @override
  void didUpdateWidget(VisibleWhen<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.value, widget.value)) {
      oldWidget.value.removeListener(_changed);
      widget.value.addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    widget.value.removeListener(_changed);
    _show.dispose();
    super.dispose();
  }

  void _changed() {
    final value = widget.value.value;
    final visible = widget.shown(value);
    // While it animates out it keeps showing the last visible value.
    if (visible) _last = value;
    if (visible) {
      _show.forward();
    } else {
      _show.reverse();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_show.isDismissed) return const SizedBox.shrink();
    return FadeTransition(
      opacity: _show,
      child: ScaleTransition(
        scale: _show,
        child: widget.builder(context, _last),
      ),
    );
  }
}

/// Lets a message be swiped sideways to trigger an action (reply) without
/// fighting the list: a drag that is more than 20° off horizontal, or that
/// starts while the list is scrolling, is left to the list (§11.6).
///
/// ```dart
/// SwipeToReply(
///   onTriggered: () => composer.replyTo(message),
///   child: MessageBubble(message),
/// );
/// ```
class SwipeToReply extends StatefulWidget {
  /// Creates the gesture wrapper.
  const SwipeToReply({
    super.key,
    required this.child,
    required this.onTriggered,
    this.threshold = 56,
    this.maxOffset = 84,
    this.background,
  });

  /// The message.
  final Widget child;

  /// Called once when the drag is released beyond [threshold].
  final VoidCallback onTriggered;

  /// How far (px) the message must be dragged.
  final double threshold;

  /// How far the message can move at most.
  final double maxOffset;

  /// Shown behind the message while it is dragged (a reply icon). It gets
  /// the progress 0–1 through an [Animation].
  final Widget Function(BuildContext context, Animation<double> progress)?
      background;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  // 0 = at rest, 1 = dragged by maxOffset.
  late final AnimationController _drag = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Offset _down = Offset.zero; // where the finger went down
  double _travel = 0;
  bool _locked = false; // this gesture belongs to the list

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _start(DragStartDetails details) {
    _travel = 0;
    // Never while the list itself is moving.
    final scrolling =
        Scrollable.maybeOf(context)?.position.isScrollingNotifier.value ??
            false;
    // More than 20° off the horizontal axis (measured from where the finger
    // went down): it is a vertical gesture.
    const limit = 0.36397; // tan(20°)
    final raw = details.globalPosition - _down;
    _locked = scrolling || raw.dy.abs() > raw.dx.abs() * limit;
  }

  void _update(DragUpdateDetails details) {
    if (_locked) return;
    _travel += details.delta.dx;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final toward = rtl ? _travel : -_travel; // toward the start edge
    _drag.value = (toward / widget.maxOffset).clamp(0.0, 1.0);
  }

  void _end(DragEndDetails details) {
    final triggered =
        !_locked && _drag.value * widget.maxOffset >= widget.threshold;
    _drag.animateBack(0, curve: Curves.easeOut);
    if (triggered) widget.onTriggered();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final background = widget.background;
    return Listener(
      onPointerDown: (event) => _down = event.position,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _start,
        onHorizontalDragUpdate: _update,
        onHorizontalDragEnd: _end,
        onHorizontalDragCancel: () => _drag.animateBack(0),
        child: Stack(
          children: [
            if (background != null)
              Positioned.fill(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: background(context, _drag),
                ),
              ),
            AnimatedBuilder(
              animation: _drag,
              builder: (context, child) => Transform.translate(
                offset: Offset(
                  (rtl ? 1 : -1) * _drag.value * widget.maxOffset,
                  0,
                ),
                child: child,
              ),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }
}
