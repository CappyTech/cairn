import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/theme/brand.dart';
import 'package:my_app/theme/theme_controller.dart';

/// Appearance: stored theme names, the light/dark palettes, and theme-aware
/// helpers (ink, basemap) that must follow the active brightness.
void main() {
  test('stored names parse to a ThemeMode; anything else follows the system',
      () {
    expect(ThemeController.parse('light'), ThemeMode.light);
    expect(ThemeController.parse('dark'), ThemeMode.dark);
    expect(ThemeController.parse('system'), ThemeMode.system);
    expect(ThemeController.parse(null), ThemeMode.system);
    expect(ThemeController.parse('bogus'), ThemeMode.system);
    // Round-trips through the name that's persisted.
    for (final m in ThemeMode.values) {
      expect(ThemeController.parse(m.name), m);
    }
  });

  test('light and dark themes use the brand palette', () {
    final light = Brand.theme();
    final dark = Brand.darkTheme();
    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(light.scaffoldBackgroundColor, Brand.mist);
    expect(dark.scaffoldBackgroundColor, Brand.night);
    expect(light.colorScheme.primary, Brand.slate);
    expect(dark.colorScheme.primary, Brand.mist);
    expect(dark.colorScheme.secondary, Brand.lichen);
  });

  Future<(Color, String)> helpersUnder(WidgetTester t, ThemeData theme) async {
    late Color ink;
    late String url;
    await t.pumpWidget(MaterialApp(
      theme: theme,
      home: Builder(builder: (context) {
        ink = Brand.ink(context);
        url = Brand.basemapUrl(context);
        return const SizedBox();
      }),
    ));
    await t.pumpAndSettle(); // let MaterialApp's theme transition finish
    return (ink, url);
  }

  testWidgets('ink and basemap follow the active theme', (t) async {
    final (lightInk, lightUrl) = await helpersUnder(t, Brand.theme());
    final (darkInk, darkUrl) = await helpersUnder(t, Brand.darkTheme());
    expect(lightUrl, contains('World_Light_Gray_Base'));
    expect(darkUrl, contains('World_Dark_Gray_Base'));
    // Light ink is dark and dark ink is light, so marks stay visible.
    expect(lightInk.computeLuminance(), lessThan(0.2));
    expect(darkInk.computeLuminance(), greaterThan(0.6));
  });
}
