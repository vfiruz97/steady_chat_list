// Flutter 3.24's widgets library doesn't export Brightness yet.
// ignore: unnecessary_import
import 'dart:ui' show Brightness;

import 'package:flutter/widgets.dart';

/// Colors of the default widgets of a message list (scroll-down button,
/// day chips, unread divider, jump flash). Put a [MessageListThemeScope]
/// above the list to change them:
///
/// ```dart
/// MessageListThemeScope(
///   theme: const MessageListTheme(badgeColor: Color(0xFF7C4DFF)),
///   child: chatScreen,
/// );
/// ```
///
/// Without a scope the defaults follow the platform brightness. It does
/// not depend on Material or Cupertino; every default widget can also be
/// replaced by a builder.
@immutable
class MessageListTheme {
  /// Creates a light theme; every color can be replaced.
  const MessageListTheme({
    this.buttonColor = const Color(0xFFFFFFFF),
    this.buttonIconColor = const Color(0xFF707579),
    this.buttonShadowColor = const Color(0x33000000),
    this.badgeColor = const Color(0xFF3390EC),
    this.badgeTextColor = const Color(0xFFFFFFFF),
    this.chipColor = const Color(0x8C000000),
    this.chipTextColor = const Color(0xFFFFFFFF),
    this.dividerColor = const Color(0x1A3390EC),
    this.dividerTextColor = const Color(0xFF3390EC),
    this.highlightColor = const Color(0x403390EC),
  });

  /// The defaults for dark backgrounds.
  const MessageListTheme.dark({
    this.buttonColor = const Color(0xFF2B2B2B),
    this.buttonIconColor = const Color(0xFFAAAAAA),
    this.buttonShadowColor = const Color(0x66000000),
    this.badgeColor = const Color(0xFF8774E1),
    this.badgeTextColor = const Color(0xFFFFFFFF),
    this.chipColor = const Color(0x99000000),
    this.chipTextColor = const Color(0xFFFFFFFF),
    this.dividerColor = const Color(0x268774E1),
    this.dividerTextColor = const Color(0xFFB8A9FF),
    this.highlightColor = const Color(0x408774E1),
  });

  /// Background of the floating round buttons.
  final Color buttonColor;

  /// Icon color of the floating buttons.
  final Color buttonIconColor;

  /// Shadow under the floating buttons.
  final Color buttonShadowColor;

  /// Background of the unread badge.
  final Color badgeColor;

  /// Text color of the unread badge.
  final Color badgeTextColor;

  /// Background of day headers and the floating day chip.
  final Color chipColor;

  /// Text color of day chips.
  final Color chipTextColor;

  /// Background of the unread divider.
  final Color dividerColor;

  /// Text color of the unread divider.
  final Color dividerTextColor;

  /// Tint of the flash on a jump target.
  final Color highlightColor;

  /// The theme for [context]: the nearest [MessageListThemeScope], else
  /// light or dark defaults by the platform brightness.
  ///
  /// ```dart
  /// final colors = MessageListTheme.of(context);
  /// ```
  static MessageListTheme of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<MessageListThemeScope>();
    if (scope != null) return scope.theme;
    return MediaQuery.maybePlatformBrightnessOf(context) == Brightness.dark
        ? const MessageListTheme.dark()
        : const MessageListTheme();
  }

  /// A copy with the given colors replaced.
  MessageListTheme copyWith({
    Color? buttonColor,
    Color? buttonIconColor,
    Color? buttonShadowColor,
    Color? badgeColor,
    Color? badgeTextColor,
    Color? chipColor,
    Color? chipTextColor,
    Color? dividerColor,
    Color? dividerTextColor,
    Color? highlightColor,
  }) =>
      MessageListTheme(
        buttonColor: buttonColor ?? this.buttonColor,
        buttonIconColor: buttonIconColor ?? this.buttonIconColor,
        buttonShadowColor: buttonShadowColor ?? this.buttonShadowColor,
        badgeColor: badgeColor ?? this.badgeColor,
        badgeTextColor: badgeTextColor ?? this.badgeTextColor,
        chipColor: chipColor ?? this.chipColor,
        chipTextColor: chipTextColor ?? this.chipTextColor,
        dividerColor: dividerColor ?? this.dividerColor,
        dividerTextColor: dividerTextColor ?? this.dividerTextColor,
        highlightColor: highlightColor ?? this.highlightColor,
      );

  /// A theme between this one and [other] (for animated theme changes).
  MessageListTheme lerp(MessageListTheme? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return MessageListTheme(
      buttonColor: mix(buttonColor, other.buttonColor),
      buttonIconColor: mix(buttonIconColor, other.buttonIconColor),
      buttonShadowColor: mix(buttonShadowColor, other.buttonShadowColor),
      badgeColor: mix(badgeColor, other.badgeColor),
      badgeTextColor: mix(badgeTextColor, other.badgeTextColor),
      chipColor: mix(chipColor, other.chipColor),
      chipTextColor: mix(chipTextColor, other.chipTextColor),
      dividerColor: mix(dividerColor, other.dividerColor),
      dividerTextColor: mix(dividerTextColor, other.dividerTextColor),
      highlightColor: mix(highlightColor, other.highlightColor),
    );
  }
}

/// Provides a [MessageListTheme] to the lists below it.
///
/// ```dart
/// MessageListThemeScope(
///   theme: isDark ? const MessageListTheme.dark() : const MessageListTheme(),
///   child: child,
/// );
/// ```
class MessageListThemeScope extends InheritedWidget {
  /// Creates a scope.
  const MessageListThemeScope({
    super.key,
    required this.theme,
    required super.child,
  });

  /// The colors for the lists below.
  final MessageListTheme theme;

  @override
  bool updateShouldNotify(MessageListThemeScope oldWidget) =>
      !identical(oldWidget.theme, theme);
}
