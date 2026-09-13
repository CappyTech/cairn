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

  /// Ask for the "Allow all the time" location permission needed for background.
  /// Returns true if background sharing is usable.
  static Future<bool> _ensureAlwaysPermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever ||
        perm == LocationPermission.denied) {
      return false;
    }
    // whileInUse -> request again nudges toward "always" (Android shows the
    // upgrade prompt; if not granted the user can set it in system settings).
    if (perm == LocationPermission.whileInUse) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  static Future<bool> enable() async {
    if (!await _ensureAlwaysPermission()) return false;
    await _storage.write(key: _enabledKey, value: '1');
    if (!await _service.isRunning()) await _service.startService();
    return true;
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
