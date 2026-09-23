import 'package:flutter/material.dart';

/// Cairn brand system (by CappyLabs). Palette from the brand sheet:
/// Slate, Stone, Pebble, Mist, and Lichen — the only accent.
class Brand {
  static const slate = Color(0xFF1F2A2E);
  static const stone = Color(0xFF6F7A7E);
  static const pebble = Color(0xFFC9CFCD);
  static const mist = Color(0xFFEDF0EE);
  static const lichen = Color(0xFF8FA35D);

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
    );
  }
}

/// The Cairn mark: three stacked stones with a lichen dot on top.
/// Drawn natively (no asset) so it scales crisply anywhere.
class CairnMark extends StatelessWidget {
  final double size;
  final Color stoneColor;
  const CairnMark({super.key, this.size = 28, this.stoneColor = Brand.slate});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _CairnPainter(stoneColor)),
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
