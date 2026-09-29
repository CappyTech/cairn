import 'package:flutter/material.dart';
import '../services/prefs.dart';

/// The app's light / dark / follow-system choice, persisted on-device and
/// listened to by [MaterialApp] so a change applies immediately.
class ThemeController {
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.system);

  /// Stored name ↔ [ThemeMode]; unknown or missing values mean "system".
  static ThemeMode parse(String? v) => switch (v) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  /// Restore the saved choice (call once at startup).
  static Future<void> load() async {
    try {
      mode.value = parse(await Prefs.themeMode());
    } catch (_) {/* storage unavailable — keep following the system */}
  }

  static Future<void> set(ThemeMode m) async {
    mode.value = m;
    try {
      await Prefs.setThemeMode(m.name);
    } catch (_) {}
  }
}
