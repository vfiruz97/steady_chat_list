import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// A small spinning arc in the current text color. Used by the default
/// loading and edge rows; it needs no Material or Cupertino ancestor.
///
/// ```dart
/// const SteadySpinner(size: 24);
/// ```
class SteadySpinner extends StatefulWidget {
  /// Creates a spinner of [size] logical pixels.
  const SteadySpinner({super.key, this.size = 20, this.color});

  /// Width and height.
  final double size;

  /// Arc color; the ambient text color at 60% when null.
  final Color? color;

  @override
  State<SteadySpinner> createState() => _SteadySpinnerState();
}

class _SteadySpinnerState extends State<SteadySpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ??
        (DefaultTextStyle.of(context).style.color ?? const Color(0xFF808080))
            .withAlpha(153);
    return SizedBox.square(
      dimension: widget.size,
      child: RotationTransition(
        turns: _turn,
        child: CustomPaint(painter: _ArcPainter(color)),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide / 9;
    canvas.drawArc(
      Offset(stroke, stroke) &
          Size(size.width - 2 * stroke, size.height - 2 * stroke),
      0,
      math.pi * 1.5,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter oldDelegate) => oldDelegate.color != color;
}

/// The default "first page is loading" state: a centered spinner.
class DefaultLoadingState extends StatelessWidget {
  /// Creates the widget.
  const DefaultLoadingState({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: SteadySpinner(size: 28));
}

/// The default empty state: a centered line of text.
///
/// ```dart
/// emptyBuilder: (context) => const DefaultEmptyState(text: 'Say hi 👋'),
/// ```
class DefaultEmptyState extends StatelessWidget {
  /// Creates the widget.
  const DefaultEmptyState({super.key, this.text = 'No messages yet'});

  /// What to say.
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}

/// The default error state and edge error row: a line of text that retries
/// when tapped.
///
/// ```dart
/// errorBuilder: (context) => DefaultErrorState(
///   text: 'Offline. Tap to try again.',
///   onRetry: controller.open,
/// ),
/// ```
class DefaultErrorState extends StatelessWidget {
  /// Creates the widget.
  const DefaultErrorState({
    super.key,
    required this.onRetry,
    this.text = "Couldn't load messages. Tap to retry.",
    this.expand = true,
  });

  /// Called on tap.
  final VoidCallback onRetry;

  /// What to say.
  final String text;

  /// Whether to fill the available space (false for an edge row).
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final label = Padding(
      padding: EdgeInsets.symmetric(horizontal: 24, vertical: expand ? 24 : 12),
      child: Text(text, textAlign: TextAlign.center),
    );
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onRetry,
        child: expand
            ? Center(child: label)
            : Center(heightFactor: 1, child: label),
      ),
    );
  }
}
