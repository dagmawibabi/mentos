import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

class AppTheme extends ThemeExtension<AppTheme> {
  const AppTheme(this.p);
  final Palette p;

  @override
  AppTheme copyWith({Palette? p}) => AppTheme(p ?? this.p);

  @override
  AppTheme lerp(AppTheme? other, double t) => t < .5 ? this : (other ?? this);
}

extension ThemeX on BuildContext {
  Palette get pal => Theme.of(this).extension<AppTheme>()!.p;
  TextTheme get text => Theme.of(this).textTheme;
}

/// Typographic scale. Geist for reading, Geist Mono for anything machine-made:
/// keys, timestamps, counts, sizes and small labels.
class Txt {
  static TextStyle display(Color c) => TextStyle(
      fontFamily: kSans, fontSize: 30, height: 1.1, fontWeight: FontWeight.w600, letterSpacing: -1.0, color: c);
  static TextStyle title(Color c) => TextStyle(
      fontFamily: kSans, fontSize: 20, height: 1.2, fontWeight: FontWeight.w600, letterSpacing: -0.4, color: c);
  static TextStyle heading(Color c) => TextStyle(
      fontFamily: kSans, fontSize: 16, height: 1.3, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: c);
  static TextStyle body(Color c) =>
      TextStyle(fontFamily: kSans, fontSize: 15, height: 1.45, fontWeight: FontWeight.w400, letterSpacing: -0.1, color: c);
  static TextStyle bodyStrong(Color c) =>
      TextStyle(fontFamily: kSans, fontSize: 15, height: 1.4, fontWeight: FontWeight.w500, letterSpacing: -0.1, color: c);
  static TextStyle small(Color c) =>
      TextStyle(fontFamily: kSans, fontSize: 13, height: 1.35, fontWeight: FontWeight.w400, color: c);
  static TextStyle mono(Color c, {double size = 12, FontWeight w = FontWeight.w400}) =>
      TextStyle(fontFamily: kMono, fontSize: size, height: 1.3, fontWeight: w, letterSpacing: 0.1, color: c);
  static TextStyle label(Color c) =>
      TextStyle(fontFamily: kMono, fontSize: 11, height: 1.2, fontWeight: FontWeight.w500, letterSpacing: 0.8, color: c);
}

ThemeData buildTheme(Palette p) {
  final scheme = ColorScheme(
    brightness: p.isDark ? Brightness.dark : Brightness.light,
    primary: p.accent,
    onPrimary: p.accentInk,
    secondary: p.ink,
    onSecondary: p.bg,
    error: p.danger,
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.ink,
    surfaceContainerHighest: p.raised,
    outline: p.line,
    outlineVariant: p.line,
  );

  final text = TextTheme(
    displaySmall: Txt.display(p.ink),
    headlineSmall: Txt.title(p.ink),
    titleLarge: Txt.title(p.ink),
    titleMedium: Txt.heading(p.ink),
    titleSmall: Txt.bodyStrong(p.ink),
    bodyLarge: Txt.body(p.ink),
    bodyMedium: Txt.body(p.ink),
    bodySmall: Txt.small(p.muted),
    labelLarge: Txt.bodyStrong(p.ink),
    labelMedium: Txt.small(p.muted),
    labelSmall: Txt.label(p.muted),
  );

  final overlay = p.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: kSans,
    textTheme: text,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    dividerColor: p.line,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.ink.withValues(alpha: .04),
    hoverColor: p.ink.withValues(alpha: .03),
    extensions: [AppTheme(p)],
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: Space.gutter,
      titleTextStyle: Txt.title(p.ink),
      systemOverlayStyle: overlay.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: p.bg,
      ),
    ),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.ink, size: 22),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.raised,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      hintStyle: Txt.body(p.faint),
      labelStyle: Txt.small(p.muted),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md), borderSide: BorderSide(color: p.ink, width: 1.2)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.ink,
        foregroundColor: p.bg,
        disabledBackgroundColor: p.raised,
        disabledForegroundColor: p.faint,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: Txt.bodyStrong(p.bg),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        side: BorderSide(color: p.line),
        textStyle: Txt.bodyStrong(p.ink),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        textStyle: Txt.bodyStrong(p.ink),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accentInk : p.surface),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.line),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: p.surface,
      elevation: 0,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      showDragHandle: true,
      dragHandleColor: p.line,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
      titleTextStyle: Txt.heading(p.ink),
      contentTextStyle: Txt.body(p.inkSoft),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.ink,
      contentTextStyle: Txt.small(p.bg),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md), side: BorderSide(color: p.line)),
      textStyle: Txt.body(p.ink),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.accent, linearTrackColor: p.line),
    tabBarTheme: TabBarThemeData(
      labelColor: p.ink,
      unselectedLabelColor: p.muted,
      labelStyle: Txt.bodyStrong(p.ink),
      unselectedLabelStyle: Txt.body(p.muted),
      indicatorColor: p.ink,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: p.line,
      overlayColor: WidgetStateProperty.all(Colors.transparent),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.gutter),
      titleTextStyle: Txt.bodyStrong(p.ink),
      subtitleTextStyle: Txt.small(p.muted),
      iconColor: p.ink,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.raised,
      selectedColor: p.ink,
      labelStyle: Txt.small(p.ink),
      secondaryLabelStyle: Txt.small(p.bg),
      checkmarkColor: p.bg,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.pill)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}
