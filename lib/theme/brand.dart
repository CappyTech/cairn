import 'package:flutter/material.dart';

/// Cairn brand system (by CappyLabs). Palette from the brand sheet:
/// Slate, Stone, Pebble, Mist, and Lichen — the only accent.
class Brand {
  static const slate = Color(0xFF1F2A2E);
  static const stone = Color(0xFF6F7A7E);
  static const pebble = Color(0xFFC9CFCD);
  static const mist = Color(0xFFEDF0EE);
  static const lichen = Color(0xFF8FA35D);

  /// Dark-mode backdrop: a deeper Slate, so Slate itself reads as a surface.
  static const night = Color(0xFF151D20);

  static ThemeData theme() => _build(
        brightness: Brightness.light,
        primary: slate,
        onPrimary: mist,
        background: mist,
        foreground: slate,
      );

  /// The dark theme: Slate surfaces, Mist text, Lichen still the only accent.
  static ThemeData darkTheme() => _build(
        brightness: Brightness.dark,
        primary: mist,
        onPrimary: slate,
        background: night,
        foreground: mist,
        surface: night,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color primary,
    required Color onPrimary,
    required Color background,
    required Color foreground,
    Color? surface,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: slate,
      primary: primary,
      onPrimary: onPrimary,
      secondary: lichen,
      surface: surface,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: foreground,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
    );
  }

  /// Muted Esri basemap tiles matching the current theme (light or dark grey).
  static String basemapUrl(BuildContext context) {
    final shade = Theme.of(context).brightness == Brightness.dark
        ? 'Dark'
        : 'Light';
    return 'https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/'
        'World_${shade}_Gray_Base/MapServer/tile/{z}/{y}/{x}';
  }

  /// Ink for marks, icons and emphasised text drawn straight on the page or
  /// the map: Slate in light mode, Mist in dark.
  static Color ink(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;
}

/// The Cairn mark: three stacked stones with a lichen dot on top.
/// Drawn natively (no asset) so it scales crisply anywhere.
class CairnMark extends StatelessWidget {
  final double size;
  final Color? stoneColor; // defaults to the theme's ink (Slate / Mist)
  const CairnMark({super.key, this.size = 28, this.stoneColor});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
          painter: _CairnPainter(stoneColor ?? Brand.ink(context))),
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
