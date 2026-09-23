import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'pb_client.dart';
import 'auth_service.dart';
import 'location_sharing_service.dart';
import 'bg_strategy.dart';
import 'places_service.dart';
import 'geofence_monitor.dart';
import 'history_service.dart';
import 'pairing_service.dart';
import 'prefs.dart';
import 'stale_alert_store.dart';
import 'notification_service.dart';

/// Outcome of trying to turn on background sharing.
enum BgEnableResult {
  /// Background permission was already granted; the service is running.
  enabled,

  /// Foreground location is granted but "Allow all the time" is not — the user
  /// must enable it in system settings (Android 11+).
  needsAllTheTime,

  /// Location permission was denied.
  denied,
}

const _channelId = 'cairn_location';
const _notifId = 8888;
const _enabledKey = 'bg_share_enabled';
const _storage = FlutterSecureStorage();

/// Keeps sharing location with contacts while the app is closed, via an Android
/// foreground service (a persistent notification is required by the OS).
class BackgroundShare {
  static final _service = FlutterBackgroundService();

  /// Configure the service once at app start (does not start it).
  static Future<void> init() async {
    final fln = FlutterLocalNotificationsPlugin();
    const channel = AndroidNotificationChannel(
      _channelId,
      'Location sharing',
      description: 'Cairn is sharing your location in the background',
      importance: Importance.low,
    );
    await fln
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'Cairn',
        initialNotificationContent: 'Sharing your location',
        foregroundServiceNotificationId: _notifId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );

    // Resume the service if the user had it on — and make sure it's NOT
    // running if they didn't (the plugin's watchdog can resurrect it; see
    // onStart).
    final running = await _service.isRunning();
    if (await isEnabled()) {
      if (!running) await _service.startService();
    } else if (running) {
      _service.invoke('stop');
    }
  }

  static Future<bool> isEnabled() async =>
      (await _storage.read(key: _enabledKey)) == '1';

  /// Open the app's system settings page (Permissions → Location) so the user
  /// can pick "Allow all the time" — the only way to grant background location
  /// on Android 11+.
  static Future<void> openAppLocationSettings() => Geolocator.openAppSettings();

  /// Try to start background sharing.
  ///
  /// Requires the "Allow all the time" (background) location permission. On
  /// Android 11+ that can't be granted from an in-app dialog — the user must
  /// enable it in system settings — so this reports [BgEnableResult.needsAllTheTime]
  /// once foreground location is granted, letting the UI walk them there.
  static Future<BgEnableResult> enable() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      // Foreground runtime prompt ("While using the app").
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return BgEnableResult.denied;
    }
    if (perm != LocationPermission.always) {
      // Foreground granted, but background ("all the time") is not — needs the
      // system-settings step.
      return BgEnableResult.needsAllTheTime;
    }
    // The foreground service shows a permanent notification; on Android 13+ that
    // needs the POST_NOTIFICATIONS runtime permission or the notification (and
    // the user's only signal that sharing is on) is silently hidden.
    await _ensureNotificationPermission();
    await _storage.write(key: _enabledKey, value: '1');
    if (!await _service.isRunning()) await _service.startService();
    return BgEnableResult.enabled;
  }

  static Future<void> _ensureNotificationPermission() async {
    try {
      final android = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (await android?.areNotificationsEnabled() == false) {
        await android?.requestNotificationsPermission();
      }
    } catch (_) {/* older Android / plugin no-op — notification still posts */}
  }

  static Future<void> disable() async {
    await _storage.write(key: _enabledKey, value: '0');
    _service.invoke('stop');
  }
}

/// Entry point that runs inside the background isolate.
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  Timer? tickTimer;
  service.on('stop').listen((_) {
    tickTimer?.cancel();
    service.stopSelf();
  });

  // The plugin's watchdog alarm restarts this service whenever it died without
  // an explicit stop (app killed or updated, a lost 'stop' message), regardless
  // of the user's setting. So never trust being started: share only while the
  // user has background sharing ON. stopSelf() also cancels the watchdog.
  Future<bool> stillEnabled() async {
    try {
      return (await _storage.read(key: _enabledKey)) == '1';
    } catch (_) {
      return false; // can't confirm consent → don't share
    }
  }

  if (!await stillEnabled()) {
    service.stopSelf();
    return;
  }

  // The background isolate has its own globals — set them up from scratch.
  await initPocketBase();
  try {
    await AuthService.signInWithDevice();
  } catch (_) {}

  final battery = Battery();

  // Read battery state and pick this tick's cadence + accuracy. Battery is not
  // location-correlated, so backing off on a low battery saves power without
  // leaking movement timing (unlike a movement-triggered backoff would).
  Future<BgStrategy> currentStrategy() async {
    int? percent;
    var charging = false;
    try {
      percent = await battery.batteryLevel;
      final state = await battery.batteryState;
      charging =
          state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {
      // Battery unreadable (e.g. emulator) → healthy defaults.
    }
    return backgroundStrategy(percent: percent, charging: charging);
  }

  Future<void> publishOnce(LocationAccuracy accuracy) async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(accuracy: accuracy),
      );
      await LocationSharingService.publish(
          lat: pos.latitude, lng: pos.longitude, accuracy: pos.accuracy);
      // Record my own trail too (sampled; flushed at the end of the tick).
      final me = AuthService.currentUser;
      if (me != null) {
        HistoryService.record(
          subject: me.id,
          lat: pos.latitude,
          lng: pos.longitude,
          ts: DateTime.now().toUtc(),
          accuracy: pos.accuracy,
        );
      }
    } catch (_) {
      // offline / no permission / no contacts — skip this tick.
    }
  }

  // Fire arrive/leave alerts while the app is closed: pull contacts' latest
  // (already-decrypted) locations and test them against my places. Skips
  // cheaply when I have no places.
  Future<void> checkGeofencesOnce() async {
    try {
      final places = await PlacesService.list();
      if (places.isEmpty) return;
      final byId = await LocationSharingService.fetchOnce();
      await GeofenceMonitor.processLocations(byId, places);
    } catch (_) {
      // offline / no contacts — skip this tick.
    }
  }

  // Reciprocate any pairing that landed while the app was closed, and raise a
  // content-free "new contact" alert for each — the same notification the
  // foreground shows, so a scan completed with the app shut isn't missed until
  // next open. Only creates contacts for proof-of-scan requests (the pairing
  // service enforces that); the notification carries a name at most.
  Future<void> checkPairingsOnce() async {
    try {
      final newlyPaired = await PairingService.processPendingRequests();
      for (final name in newlyPaired) {
        await NotificationService.show(
          id: NotificationService.idFor('pair:$name:${DateTime.now()}'),
          title: 'New contact',
          body: "You're now connected with $name.",
        );
      }
    } catch (_) {
      // offline / not signed in — skip this tick.
    }
  }

  // Raise a "contact went quiet" alert while the app is closed, edge-triggered
  // off the shared persisted state so it agrees with the foreground map screen
  // (no double-fire) and re-arms once they're fresh again. Reads contacts'
  // last-share times, which are already fetched for the geofence check.
  Future<void> checkStaleOnce() async {
    try {
      final byId = await LocationSharingService.fetchOnce();
      final updatedById = {
        for (final e in byId.entries) e.key: e.value.updated,
      };
      final toNotify = await StaleAlertStore.evaluate(
        updatedById: updatedById,
        now: DateTime.now(),
      );
      for (final id in toNotify) {
        final name = byId[id]?.name ?? 'A contact';
        await NotificationService.show(
          id: NotificationService.idFor('stale:$id'),
          title: 'Contact went quiet',
          body: "$name hasn't shared their location in a while.",
        );
      }
    } catch (_) {
      // offline / no contacts — skip this tick.
    }
  }

  // Self-rescheduling tick: the interval can change between ticks as the
  // battery drains or the phone is plugged in, so we re-arm a one-shot Timer
  // each time rather than a fixed Timer.periodic.
  Future<void> tick() async {
    if (!await stillEnabled()) {
      service.stopSelf();
      return;
    }
    final strategy = await currentStrategy();
    // Surface the current mode in the persistent notification.
    if (service is AndroidServiceInstance) {
      try {
        await service.setForegroundNotificationInfo(
            title: 'Cairn', content: strategy.label);
      } catch (_) {/* best-effort */}
    }
    await publishOnce(strategy.accuracy);
    await checkGeofencesOnce();
    // Content-free activity alerts (new pairing, contact went quiet) while the
    // app is closed — off entirely if the user turned them off.
    if (await Prefs.activityAlerts()) {
      await checkPairingsOnce();
      await checkStaleOnce();
    }
    // Persist this tick's buffered history points (mine + contacts').
    await HistoryService.flush();
    tickTimer = Timer(strategy.interval, tick);
  }

  await tick();
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}
