import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'prefs.dart';

/// The kinds of alert Cairn raises. Each is its own Android notification
/// channel with its own sound, so people can tell them apart by ear and tune or
/// mute each one in the phone's settings.
enum AlertKind {
  arrive('cairn_arrive', 'Arrivals', 'A contact arrives at one of your places'),
  leave('cairn_leave', 'Departures', 'A contact leaves one of your places'),
  quiet('cairn_quiet', 'Contact went quiet',
      "A contact hasn't shared their location in a while"),
  contact('cairn_contact', 'New contacts', 'Someone connects with you');

  /// The channel id and its sound: `res/raw/<channel>.wav`.
  final String channel;
  final String name;
  final String description;
  const AlertKind(this.channel, this.name, this.description);
}

/// Local, on-device notifications for app events (a new pairing, a contact
/// going stale). These are **local** — composed and shown on the phone, never
/// routed through the server — so they can't leak content the way a push
/// service would. Bodies are deliberately generic (a name at most, never a
/// location).
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  /// The single channel every alert used before [AlertKind]; removed on init
  /// (a channel's sound can't be changed once it exists).
  static const _legacyChannelId = 'cairn_alerts';
  static bool _ready = false;

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Idempotent one-time setup: init the plugin, create the Android channels,
  /// and ask for notification permission (Android 13+, iOS) — unless the user
  /// deferred it in onboarding (see [requestPermission]).
  static Future<void> init() async {
    if (!_supported || _ready) return;
    // Status-bar icon: the Cairn mark as a white silhouette (a full-colour
    // launcher icon would render as a plain blob).
    const android = AndroidInitializationSettings('@drawable/ic_stat_cairn');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
        settings: const InitializationSettings(android: android, iOS: ios));

    final android13 = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    for (final k in AlertKind.values) {
      await android13?.createNotificationChannel(AndroidNotificationChannel(
        k.channel,
        k.name,
        description: k.description,
        importance: Importance.defaultImportance,
        sound: RawResourceAndroidNotificationSound(k.channel),
      ));
    }
    try {
      await android13?.deleteNotificationChannel(channelId: _legacyChannelId);
    } catch (_) {/* never created, or already gone */}
    if (!await Prefs.notificationsDeferred()) await _ask();
    _ready = true;
  }

  static Future<void> _ask() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (await android?.areNotificationsEnabled() == false) {
        await android?.requestNotificationsPermission();
      }
    } catch (_) {/* older Android — no runtime permission needed */}
  }

  /// The user explicitly asked for alerts (onboarding "Allow", or turning on
  /// place alerts): clear any deferral and ask now.
  static Future<void> requestPermission() async {
    if (!_supported) return;
    await Prefs.setNotificationsDeferred(false);
    await init();
    await _ask();
  }

  /// Show a notification. Best-effort: silently no-ops on unsupported platforms
  /// or if the OS suppresses it (e.g. permission not granted).
  static Future<void> show({
    required AlertKind kind,
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
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            kind.channel,
            kind.name,
            channelDescription: kind.description,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            sound: RawResourceAndroidNotificationSound(kind.channel),
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    } catch (_) {/* best-effort */}
  }

  /// A stable, non-negative notification id derived from a string key, so
  /// repeat alerts for the same subject (e.g. a stale contact) replace rather
  /// than stack.
  static int idFor(String key) => key.hashCode & 0x7fffffff;
}
