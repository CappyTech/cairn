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

  /// The last cached fix, if any — returns instantly (no GPS wait) so the map
  /// can centre itself on the first frame while a fresh, precise fix is still
  /// being acquired. Best-effort: returns null when there's no cached fix or
  /// permission hasn't been granted yet, and never throws.
  static Future<Position?> lastKnown() async {
    try {
      return await Geolocator.getLastKnownPosition();
    } catch (_) {
      return null;
    }
  }

  static Future<Position> current() async {
    await ensureReady();
    // Bound the wait: high-accuracy can block indefinitely when there's no
    // fresh fix (e.g. indoors, or a cold emulator), which risks an ANR. Fall
    // back to the last known fix so the map still opens promptly.
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      rethrow;
    }
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
