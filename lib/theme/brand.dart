import 'package:flutter/material.dart';

/// Cairn brand system (by CappyLabs). Palette from the brand sheet:
/// Slate, Stone, Pebble, Mist, and Lichen — the only accent.
class Brand {
  static const slate = Color(0xFF1F2A2E);
  static const stone = Color(0xFF6F7A7E);
  static const pebble = Color(0xFFC9CFCD);
  static const mist = Color(0xFFEDF0EE);
  static const lichen = Color(0xFF8FA35D);

  // Dark-mode companions, derived from slate so the app still reads as Cairn.
  static const night = Color(0xFF121A1D); // page background
  static const nightCard = Color(0xFF1C2629); // cards, sheets, dialogs
  static const nightLine = Color(0xFF33434A); // borders, dividers, handles
  static const fog = Color(0xFF9AA6AA); // muted text on night

  /// Esri's muted grey basemap tiles — the light canvas, or its dark twin in
  /// dark mode — so pins stay the loudest thing on the map either way.
  static String basemapUrl(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return 'https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/'
        '${dark ? 'World_Dark_Gray_Base' : 'World_Light_Gray_Base'}'
        '/MapServer/tile/{z}/{y}/{x}';
  }

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: slate,
      primary: slate,
      secondary: lichen,
      // Pin the container roles to the palette too; left to the seed they come
      // out a Material blue/cyan (tonal buttons, FABs) that isn't on-brand.
      primaryContainer: slate,
      onPrimaryContainer: mist,
      secondaryContainer: pebble,
      onSecondaryContainer: slate,
      brightness: Brightness.light,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: mist,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: mist,
        foregroundColor: slate,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      extensions: const [CairnColors.light],
    );
  }

  /// The same brand in the dark: night backgrounds, mist text, lichen accent.
  /// Filled buttons invert to mist-on-slate so they stay the strongest action.
  static ThemeData darkTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: slate,
      brightness: Brightness.dark,
      primary: mist,
      onPrimary: slate,
      secondary: lichen,
      primaryContainer: mist,
      onPrimaryContainer: slate,
      secondaryContainer: nightLine,
      onSecondaryContainer: mist,
      surface: nightCard,
      onSurface: mist,
      outline: nightLine,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: night,
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: night,
        foregroundColor: mist,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: const CardThemeData(color: nightCard),
      // Off switches need a visible outline and thumb on dark cards.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? slate : fog),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? mist : nightLine),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? mist : fog),
      ),
      dividerColor: nightLine,
      extensions: const [CairnColors.dark],
    );
  }
}

/// Brand colours by role, resolved for the current light/dark theme — use
/// these (via `context.cairn`) instead of the raw palette for UI chrome, so it
/// works in both. Map overlays (pins, labels on the basemap) keep fixed colours.
@immutable
class CairnColors extends ThemeExtension<CairnColors> {
  final Color ink; // main text / icons
  final Color muted; // secondary text, quiet icons
  final Color card; // raised surfaces: cards, pills, panels
  final Color outline; // borders, dividers, drag handles
  final Color sheet; // the page colour, for sheets drawn over other content

  const CairnColors({
    required this.ink,
    required this.muted,
    required this.card,
    required this.outline,
    required this.sheet,
  });

  static const light = CairnColors(
    ink: Brand.slate,
    muted: Brand.stone,
    card: Colors.white,
    outline: Brand.pebble,
    sheet: Brand.mist,
  );

  static const dark = CairnColors(
    ink: Brand.mist,
    muted: Brand.fog,
    card: Brand.nightCard,
    outline: Brand.nightLine,
    sheet: Brand.night,
  );

  @override
  CairnColors copyWith({
    Color? ink,
    Color? muted,
    Color? card,
    Color? outline,
    Color? sheet,
  }) =>
      CairnColors(
        ink: ink ?? this.ink,
        muted: muted ?? this.muted,
        card: card ?? this.card,
        outline: outline ?? this.outline,
        sheet: sheet ?? this.sheet,
      );

  @override
  CairnColors lerp(ThemeExtension<CairnColors>? other, double t) {
    if (other is! CairnColors) return this;
    return CairnColors(
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      card: Color.lerp(card, other.card, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      sheet: Color.lerp(sheet, other.sheet, t)!,
    );
  }
}

extension CairnColorsContext on BuildContext {
  /// The brand colours for the current theme (light or dark).
  CairnColors get cairn =>
      Theme.of(this).extension<CairnColors>() ?? CairnColors.light;
}

/// The Cairn mark: three stacked stones with a lichen dot on top.
/// Drawn natively (no asset) so it scales crisply anywhere. The stones follow
/// the theme's ink colour unless [stoneColor] is given.
class CairnMark extends StatelessWidget {
  final double size;
  final Color? stoneColor;
  const CairnMark({super.key, this.size = 28, this.stoneColor});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
          painter: _CairnPainter(stoneColor ?? context.cairn.ink)),
    );
  }
}

class _CairnPainter extends CustomPainter {
  final Color stone;
  _CairnPainter(this.stone);

  @override
  void paint(Canvas canvas, Size size) {
    // Coordinates from the brand mark, in a 100×100 reference box.
    final s = size.width / 100;
    final p = Paint()..color = stone;
    RRect rr(double x, double y, double w, double h, double r) =>
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x * s, y * s, w * s, h * s), Radius.circular(r * s));
    canvas.drawRRect(rr(14, 70, 72, 18, 9), p);
    canvas.drawRRect(rr(24, 50, 52, 17, 8.5), p);
    canvas.drawRRect(rr(30, 32, 36, 15, 7.5), p);
    canvas.drawCircle(Offset(50 * s, 20 * s), 8 * s, Paint()..color = Brand.lichen);
  }

  @override
  bool shouldRepaint(covariant _CairnPainter old) => old.stone != stone;
}
