import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:url_launcher/url_launcher.dart';

/// Hands a spot to the phone's own maps app for directions. Nothing goes to
/// any server of ours; the user picks which maps app (if any) sees it.
class Directions {
  Directions._();

  /// Android: a `geo:` link, so the user's choice of maps app opens it.
  /// iOS: Apple Maps. Elsewhere: OpenStreetMap's route planner.
  static Uri uri(double lat, double lng,
      {String? label, TargetPlatform? platform, bool web = kIsWeb}) {
    final at = '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
    final p = platform ?? defaultTargetPlatform;
    if (!web && p == TargetPlatform.android) {
      final name = label?.replaceAll(RegExp(r'[()]'), '').trim();
      final q = (name == null || name.isEmpty) ? at : '$at($name)';
      return Uri.parse('geo:0,0?q=${Uri.encodeComponent(q)}');
    }
    if (!web && p == TargetPlatform.iOS) {
      return Uri.https('maps.apple.com', '/', {'daddr': at});
    }
    return osm(lat, lng);
  }

  /// OpenStreetMap directions to the spot, starting from wherever you are.
  static Uri osm(double lat, double lng) => Uri.https(
      'www.openstreetmap.org',
      '/directions',
      {'route': ';${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}'});

  /// Open directions; falls back to OpenStreetMap in the browser when no app
  /// takes the link. False if nothing could open it.
  static Future<bool> open(double lat, double lng, {String? label}) async {
    try {
      if (await launchUrl(uri(lat, lng, label: label),
          mode: LaunchMode.externalApplication)) {
        return true;
      }
    } catch (_) {/* no app for geo: — try the browser */}
    try {
      return await launchUrl(osm(lat, lng),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
