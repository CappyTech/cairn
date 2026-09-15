import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local, on-device notifications for app events (a new pairing, a contact
/// going stale). These are **local** — composed and shown on the phone, never
/// routed through the server — so they can't leak content the way a push
/// service would. Bodies are deliberately generic (a name at most, never a
/// location).
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'cairn_alerts';
  static bool _ready = false;

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Idempotent one-time setup: init the plugin, create the Android channel,
  /// and ask for notification permission (Android 13+, iOS).
  static Future<void> init() async {
    if (!_supported || _ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
        settings: const InitializationSettings(android: android, iOS: ios));

    final android13 = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android13?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      'Alerts',
      description: 'New pairings and contact activity',
      importance: Importance.defaultImportance,
    ));
    try {
      if (await android13?.areNotificationsEnabled() == false) {
        await android13?.requestNotificationsPermission();
      }
    } catch (_) {/* older Android — no runtime permission needed */}
    _ready = true;
  }

  /// Show a notification. Best-effort: silently no-ops on unsupported platforms
  /// or if the OS suppresses it (e.g. permission not granted).
  static Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_supported) return;
    try {
      await init();
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Alerts',
            channelDescription: 'New pairings and contact activity',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {/* best-effort */}
  }

  /// A stable, non-negative notification id derived from a string key, so
  /// repeat alerts for the same subject (e.g. a stale contact) replace rather
  /// than stack.
  static int idFor(String key) => key.hashCode & 0x7fffffff;
}
