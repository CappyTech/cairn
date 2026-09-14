import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'pb_client.dart';
import 'auth_service.dart';
import 'location_sharing_service.dart';

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

    // Resume the service if the user had it on.
    if (await isEnabled() && !(await _service.isRunning())) {
      await _service.startService();
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

  service.on('stop').listen((_) => service.stopSelf());

  // The background isolate has its own globals — set them up from scratch.
  await initPocketBase();
  try {
    await AuthService.signInWithDevice();
  } catch (_) {}

  Future<void> publishOnce() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await LocationSharingService.publish(
          lat: pos.latitude, lng: pos.longitude, accuracy: pos.accuracy);
    } catch (_) {
      // offline / no permission / no contacts — skip this tick.
    }
  }

  await publishOnce();
  Timer.periodic(const Duration(minutes: 2), (_) => publishOnce());
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}
