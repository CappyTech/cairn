import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small on-device preferences.
class Prefs {
  static const _s = FlutterSecureStorage();

  /// Global privacy master-switch: when on, EVERY contact receives only
  /// approximate (rounded) location, regardless of their per-contact setting.
  static Future<bool> approxOnly() async =>
      (await _s.read(key: 'approx_only')) == '1';

  static Future<void> setApproxOnly(bool v) async =>
      _s.write(key: 'approx_only', value: v ? '1' : '0');

  /// This device's own display name, kept on-device (the server only ever holds
  /// an encrypted-to-self copy, so it can't read your name).
  static Future<String?> name() async => _s.read(key: 'display_name');
  static Future<void> setName(String v) async =>
      _s.write(key: 'display_name', value: v);
}
