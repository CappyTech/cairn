import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A viewer's stored answer to a server's history-retention policy.
class HistoryConsent {
  final int days; // the retention window (days) the choice was made against; 0 = keep all
  final bool declined; // true = user declined to sync history to this server

  const HistoryConsent({required this.days, required this.declined});

  Map<String, dynamic> toJson() => {'days': days, 'declined': declined};
  static HistoryConsent fromJson(Map<String, dynamic> j) => HistoryConsent(
        days: (j['days'] as num?)?.toInt() ?? 0,
        declined: j['declined'] == true,
      );
}

/// How the home screen is arranged — a per-device look preference.
///  - [refined]: greeting, compact sharing card, then people (the default);
///  - [people]: people fill the screen, sharing collapses to a status pill;
///  - [map]: the live map is home, with a pull-up sheet of controls + people.
enum HomeLayout { refined, people, map }

/// Small on-device preferences.
class Prefs {
  static const _s = FlutterSecureStorage();

  static Future<HomeLayout> homeLayout() async {
    final v = await _s.read(key: 'home_layout');
    return HomeLayout.values.firstWhere((l) => l.name == v,
        orElse: () => HomeLayout.refined);
  }

  static Future<void> setHomeLayout(HomeLayout v) async =>
      _s.write(key: 'home_layout', value: v.name);

  /// Landscape Map first: whether the floating panel is open (default yes).
  static Future<bool> mapPanelOpen() async =>
      (await _s.read(key: 'map_panel_open')) != '0';

  static Future<void> setMapPanelOpen(bool v) async =>
      _s.write(key: 'map_panel_open', value: v ? '1' : '0');

  /// Global privacy master-switch: when on, EVERY contact receives only
  /// approximate (rounded) location, regardless of their per-contact setting.
  static Future<bool> approxOnly() async =>
      (await _s.read(key: 'approx_only')) == '1';

  static Future<void> setApproxOnly(bool v) async =>
      _s.write(key: 'approx_only', value: v ? '1' : '0');

  /// The user agreed to send a trip's coordinates to a public routing server
  /// to snap it to roads in History, without being asked each time.
  static Future<bool> roadSnapAllowed() async =>
      (await _s.read(key: 'road_snap_allowed')) == '1';

  static Future<void> setRoadSnapAllowed(bool v) async =>
      _s.write(key: 'road_snap_allowed', value: v ? '1' : '0');

  /// Tag my recorded fixes with the phone's activity sensor (walking,
  /// cycling, in a vehicle) so History knows how I travelled. Off until the
  /// user turns it on and grants the permission.
  static Future<bool> activitySensing() async =>
      (await _s.read(key: 'activity_sensing')) == '1';

  static Future<void> setActivitySensing(bool v) async =>
      _s.write(key: 'activity_sensing', value: v ? '1' : '0');

  /// Whether first-run onboarding has been completed on this device.
  static Future<bool> onboardingDone() async =>
      (await _s.read(key: 'onboarding_done')) == '1';

  static Future<void> setOnboardingDone() async =>
      _s.write(key: 'onboarding_done', value: '1');

  /// The user chose "Not now" for location in onboarding: don't pop the
  /// system prompt unasked; Home shows a "not sharing" notice with Retry.
  static Future<bool> locationDeferred() async =>
      (await _s.read(key: 'location_deferred')) == '1';

  static Future<void> setLocationDeferred(bool v) async =>
      _s.write(key: 'location_deferred', value: v ? '1' : '0');

  /// Same for notifications: don't request the permission implicitly (e.g.
  /// when alerts first initialise) until the user asks for alerts.
  static Future<bool> notificationsDeferred() async =>
      (await _s.read(key: 'notifications_deferred')) == '1';

  static Future<void> setNotificationsDeferred(bool v) async =>
      _s.write(key: 'notifications_deferred', value: v ? '1' : '0');

  /// Whether to raise the content-free activity notifications — a new contact
  /// pairing, and a contact going quiet. Default ON. Gates both the foreground
  /// and the background-isolate alerts, so turning it off silences them
  /// everywhere. (Stored, not derived, so the background isolate reads the same
  /// answer.) A missing value reads as ON so an existing install isn't silently
  /// opted out.
  static Future<bool> activityAlerts() async =>
      (await _s.read(key: 'activity_alerts')) != '0';

  static Future<void> setActivityAlerts(bool v) async =>
      _s.write(key: 'activity_alerts', value: v ? '1' : '0');

  /// This device's own display name, kept on-device (the server only ever holds
  /// an encrypted-to-self copy, so it can't read your name).
  static Future<String?> name() async => _s.read(key: 'display_name');
  static Future<void> setName(String v) async =>
      _s.write(key: 'display_name', value: v);

  // --- Location history retention ---------------------------------------------

  /// The user's answer to a server's history-retention policy, per server URL
  /// (history syncs only to a server whose policy they've agreed to). Null until
  /// they've been asked for that server.
  static Future<HistoryConsent?> historyConsent(String serverUrl) async {
    final map = await _consentMap();
    final v = map[serverUrl];
    return v == null ? null : HistoryConsent.fromJson(v);
  }

  static Future<void> setHistoryConsent(
      String serverUrl, HistoryConsent consent) async {
    final map = await _consentMap();
    map[serverUrl] = consent.toJson();
    await _s.write(key: 'history_consent_v1', value: jsonEncode(map));
  }

  static Future<Map<String, dynamic>> _consentMap() async {
    final raw = await _s.read(key: 'history_consent_v1');
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return {};
    }
  }

  /// The user's optional local retention override (days; 0 = keep all). Null =
  /// follow the server's policy. Lets a user keep *less* than the server does.
  static Future<int?> historyLocalRetentionDays() async {
    final v = await _s.read(key: 'history_local_retention');
    if (v == null || v.isEmpty) return null;
    return int.tryParse(v);
  }

  static Future<void> setHistoryLocalRetentionDays(int? days) async {
    if (days == null) {
      await _s.delete(key: 'history_local_retention');
    } else {
      await _s.write(key: 'history_local_retention', value: days.toString());
    }
  }

  // --- Motion & direction ---------------------------------------------------
  // What contacts get (speed / direction ride the E2E-encrypted location blob,
  // default OFF — they say more than position does) and what I see on my own
  // map (default ON — it never leaves the device).

  /// Share my speed with contacts (precise shares only).
  static Future<bool> shareSpeed() async =>
      (await _s.read(key: 'share_speed')) == '1';

  static Future<void> setShareSpeed(bool v) async =>
      _s.write(key: 'share_speed', value: v ? '1' : '0');

  /// Share my direction of travel with contacts (precise shares only).
  static Future<bool> shareHeading() async =>
      (await _s.read(key: 'share_heading')) == '1';

  static Future<void> setShareHeading(bool v) async =>
      _s.write(key: 'share_heading', value: v ? '1' : '0');

  /// Draw the direction cone on my own dot.
  static Future<bool> showMyHeading() async =>
      (await _s.read(key: 'show_my_heading')) != '0';

  static Future<void> setShowMyHeading(bool v) async =>
      _s.write(key: 'show_my_heading', value: v ? '1' : '0');

  /// Point my cone with the compass when I'm still (uses the motion sensors
  /// while the map is open).
  static Future<bool> useCompass() async =>
      (await _s.read(key: 'use_compass')) != '0';

  static Future<void> setUseCompass(bool v) async =>
      _s.write(key: 'use_compass', value: v ? '1' : '0');

  /// Show contacts' speed and direction, when they share them.
  static Future<bool> showContactsMotion() async =>
      (await _s.read(key: 'show_contacts_motion')) != '0';

  static Future<void> setShowContactsMotion(bool v) async =>
      _s.write(key: 'show_contacts_motion', value: v ? '1' : '0');

  // --- Shared status --------------------------------------------------------

  /// A short label I choose to broadcast to contacts alongside my location
  /// (e.g. "Hotel"), so they see where I am without recreating a place. Empty/
  /// null = no status. Rides the E2E-encrypted location blob.
  static Future<String?> sharedStatus() async => _s.read(key: 'shared_status');

  static Future<void> setSharedStatus(String? v) async {
    final t = v?.trim() ?? '';
    if (t.isEmpty) {
      await _s.delete(key: 'shared_status');
    } else {
      await _s.write(key: 'shared_status', value: t);
    }
  }
}
