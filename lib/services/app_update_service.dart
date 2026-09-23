import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'pb_client.dart';

/// How urgently this install should be updated.
enum UpdateNeed {
  /// Up to date (or nothing to go on).
  none,

  /// A newer version exists — suggest it, don't block.
  recommended,

  /// This version is no longer supported — block until updated.
  required,
}

/// The server operator's app-version policy (`server_config`). Empty = unset.
class AppVersionPolicy {
  final String minVersion;
  final String latestVersion;
  const AppVersionPolicy({this.minVersion = '', this.latestVersion = ''});
}

/// Tells the user when their copy of Cairn is out of date, from two sources:
///  - the server's policy (`min_app_version` / `latest_app_version` in
///    `server_config`) — the operator's lever for breaking server changes;
///  - Google Play's in-app updates — a newer build published to Play, with
///    Play's update priority (0–5) marking urgent ones.
class AppUpdateService {
  static const _packageId = 'uk.cappylabs.cairn';
  static final _storeUrl =
      Uri.parse('https://play.google.com/store/apps/details?id=$_packageId');

  /// Play update priority at or above which an update is treated as required.
  static const urgentPriority = 4;

  /// Compare dotted version names ("1.2.3"), ignoring any "+build" or
  /// "-prerelease" suffix; missing parts count as 0. Negative if [a] < [b],
  /// zero if equal, positive if [a] > [b]. Pure, so it's unit-tested.
  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .trim()
        .split(RegExp(r'[+-]'))
        .first
        .split('.')
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    final pa = parts(a), pb = parts(b);
    for (var i = 0; i < pa.length || i < pb.length; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x - y;
    }
    return 0;
  }

  /// Whether a version name is usable (digits and dots, e.g. "0.0.16").
  static bool _valid(String v) =>
      RegExp(r'^\d+(\.\d+)*([+-].*)?$').hasMatch(v.trim());

  /// Decide from the server policy and Play's view. Blank/invalid policy
  /// values are ignored, so a misconfigured server can't lock everyone out
  /// with junk. Pure, so it's unit-tested.
  static UpdateNeed evaluate({
    required String current,
    AppVersionPolicy policy = const AppVersionPolicy(),
    bool playUpdateAvailable = false,
    int playPriority = 0,
  }) {
    if (_valid(policy.minVersion) &&
        compareVersions(current, policy.minVersion) < 0) {
      return UpdateNeed.required;
    }
    if (playUpdateAvailable && playPriority >= urgentPriority) {
      return UpdateNeed.required;
    }
    if (_valid(policy.latestVersion) &&
        compareVersions(current, policy.latestVersion) < 0) {
      return UpdateNeed.recommended;
    }
    if (playUpdateAvailable) return UpdateNeed.recommended;
    return UpdateNeed.none;
  }

  /// This install's version name, e.g. "0.0.16".
  static Future<String> currentVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  /// The server's policy. Best-effort: an older server without the fields, or
  /// no network, reads as "no policy".
  static Future<AppVersionPolicy> fetchPolicy() async {
    try {
      final rec = await pb.collection('server_config').getFirstListItem('');
      return AppVersionPolicy(
        minVersion: rec.getStringValue('min_app_version'),
        latestVersion: rec.getStringValue('latest_app_version'),
      );
    } catch (_) {
      return const AppVersionPolicy();
    }
  }

  /// In-app updates only exist for Android installs from Google Play.
  static bool get playSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Ask Play about a newer build. Null when not applicable — not Android, or
  /// not installed from Play (debug / sideloaded builds make Play throw).
  static Future<AppUpdateInfo?> checkPlay() async {
    if (!playSupported) return null;
    try {
      return await InAppUpdate.checkForUpdate();
    } catch (_) {
      return null;
    }
  }

  /// Open Cairn's store listing (fallback when Play's in-app flow can't run).
  static Future<void> openStore() async {
    try {
      await launchUrl(_storeUrl, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}
