import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/theme/brand.dart';
import 'package:my_app/theme/theme_controller.dart';

/// Appearance: stored theme names, the light/dark palettes, and theme-aware
/// helpers (the basemap) that must follow the active brightness.
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

  Future<String> basemapUnder(WidgetTester t, ThemeData theme) async {
    late String url;
    await t.pumpWidget(MaterialApp(
      theme: theme,
      home: Builder(builder: (context) {
        url = Brand.basemapUrl(context);
        return const SizedBox();
      }),
    ));
    await t.pumpAndSettle(); // let MaterialApp's theme transition finish
    return url;
  }

  testWidgets('the basemap follows the active theme', (t) async {
    expect(await basemapUnder(t, Brand.theme()),
        contains('World_Light_Gray_Base'));
    expect(await basemapUnder(t, Brand.darkTheme()),
        contains('World_Dark_Gray_Base'));
  });
}
