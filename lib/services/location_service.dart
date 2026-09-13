import 'package:geolocator/geolocator.dart';

/// Reads this device's GPS position and handles the permission dance.
class LocationService {
  /// Ensures location services are on and permission is granted.
  /// Throws a human-readable message if not usable.
  static Future<void> ensureReady() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw 'Location is turned off on this device. Turn it on and try again.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      throw 'Location permission was denied.';
    }
    if (perm == LocationPermission.deniedForever) {
      throw 'Location permission is permanently denied. Enable it in settings.';
    }
  }

  static Future<Position> current() async {
    await ensureReady();
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }

  /// A live stream of positions (updates as you move ~10m).
  static Stream<Position> stream() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    );
  }
}
