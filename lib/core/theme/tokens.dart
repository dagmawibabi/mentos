import 'package:flutter/material.dart';

/// Design tokens. Monochrome surfaces with a single emerald accent.
/// Emerald is reserved for things that are *live*: presence, sync, the send
/// action and the active destination. Everything else stays ink and paper.
class Palette {
  const Palette({
    required this.bg,
    required this.surface,
    required this.raised,
    required this.line,
    required this.ink,
    required this.inkSoft,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accentInk,
    required this.accentSoft,
    required this.danger,
    required this.dangerSoft,
    required this.bubbleMine,
    required this.bubbleMineInk,
    required this.isDark,
  });

  final Color bg;
  final Color surface;
  final Color raised;
  final Color line;
  final Color ink;
  final Color inkSoft;
  final Color muted;
  final Color faint;
  final Color accent;
  final Color accentInk;
  final Color accentSoft;
  final Color danger;
  final Color dangerSoft;
  final Color bubbleMine;
  final Color bubbleMineInk;
  final bool isDark;

  static const light = Palette(
    bg: Color(0xFFF5F6F5),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFEDEFEE),
    line: Color(0xFFE1E4E2),
    ink: Color(0xFF0D1110),
    inkSoft: Color(0xFF2C3330),
    muted: Color(0xFF68716D),
    faint: Color(0xFFA3AAA6),
    accent: Color(0xFF0E9F6E),
    accentInk: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFE0F3EA),
    danger: Color(0xFFD1453B),
    dangerSoft: Color(0xFFFBE7E5),
    bubbleMine: Color(0xFF0D1110),
    bubbleMineInk: Color(0xFFF5F6F5),
    isDark: false,
  );

  static const dark = Palette(
    bg: Color(0xFF0A0C0B),
    surface: Color(0xFF121514),
    raised: Color(0xFF1A1E1C),
    line: Color(0xFF232826),
    ink: Color(0xFFECEFED),
    inkSoft: Color(0xFFC9CFCC),
    muted: Color(0xFF89928E),
    faint: Color(0xFF545C58),
    accent: Color(0xFF34D399),
    accentInk: Color(0xFF04140D),
    accentSoft: Color(0xFF0F2A1F),
    danger: Color(0xFFF2675C),
    dangerSoft: Color(0xFF2E1513),
    bubbleMine: Color(0xFF1C2B26),
    bubbleMineInk: Color(0xFFECEFED),
    isDark: true,
  );

  /// Applies colors a theme plugin set, by field name.
  Palette withOverrides(Map<String, Color> o) {
    if (o.isEmpty) return this;
    return Palette(
      bg: o['bg'] ?? bg,
      surface: o['surface'] ?? surface,
      raised: o['raised'] ?? raised,
      line: o['line'] ?? line,
      ink: o['ink'] ?? ink,
      inkSoft: o['inkSoft'] ?? inkSoft,
      muted: o['muted'] ?? muted,
      faint: o['faint'] ?? faint,
      accent: o['accent'] ?? accent,
      accentInk: o['accentInk'] ?? accentInk,
      accentSoft: o['accentSoft'] ?? accentSoft,
      danger: o['danger'] ?? danger,
      dangerSoft: dangerSoft,
      bubbleMine: o['bubbleMine'] ?? bubbleMine,
      bubbleMineInk: o['bubbleMineInk'] ?? bubbleMineInk,
      isDark: isDark,
    );
  }

  /// Recolors the live accent. Surfaces stay the same.
  Palette withAccent(String name) {
    if (name == 'emerald' || name.isEmpty) return this;
    final (Color color, Color onColor, Color soft) = switch (name) {
      'blue' => isDark
          ? (const Color(0xFF60A5FA), const Color(0xFF041018), const Color(0xFF122033))
          : (const Color(0xFF2563EB), const Color(0xFFFFFFFF), const Color(0xFFDBEAFE)),
      'amber' => isDark
          ? (const Color(0xFFFBBF24), const Color(0xFF1C1404), const Color(0xFF2A2110))
          : (const Color(0xFFD97706), const Color(0xFF1C1204), const Color(0xFFFEF3C7)),
      'ink' => (ink, bg, raised),
      _ => (accent, accentInk, accentSoft),
    };
    return Palette(
      bg: bg,
      surface: surface,
      raised: raised,
      line: line,
      ink: this.ink,
      inkSoft: inkSoft,
      muted: muted,
      faint: faint,
      accent: color,
      accentInk: onColor,
      accentSoft: soft,
      danger: danger,
      dangerSoft: dangerSoft,
      bubbleMine: bubbleMine,
      bubbleMineInk: bubbleMineInk,
      isDark: isDark,
    );
  }
}

class Space {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double gutter = 20;
}

class Radii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double bubble = 20;
  static const double pill = 999;
}

class Motion {
  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 420);
  static const curve = Curves.easeOutCubic;
}

const kSans = 'Geist';
const kMono = 'GeistMono';
