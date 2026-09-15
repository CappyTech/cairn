import 'package:geolocator/geolocator.dart';

/// How the background isolate should behave on a given tick: how often to
/// publish, and how accurate a GPS fix to ask for.
///
/// IMPORTANT — this varies the cadence by BATTERY, never by movement. The
/// share cadence is deliberately independent of whether the user is moving so
/// the server can't read movement / activity timing off `location_shares.updated`
/// (see `docs/metadata-privacy.md`). Battery level is not location-correlated,
/// so slowing down on a low battery leaks nothing about where the user is or
/// whether they're on the move — it only trades freshness for power.
class BgStrategy {
  /// Time to wait before the next publish tick.
  final Duration interval;

  /// Desired GPS accuracy. Lower accuracy keeps the GPS radio on for less time.
  final LocationAccuracy accuracy;

  /// A short label for the foreground notification, so the user can see when
  /// battery-saving has kicked in.
  final String label;

  const BgStrategy(this.interval, this.accuracy, this.label);

  @override
  bool operator ==(Object other) =>
      other is BgStrategy &&
      other.interval == interval &&
      other.accuracy == accuracy &&
      other.label == label;

  @override
  int get hashCode => Object.hash(interval, accuracy, label);

  @override
  String toString() =>
      'BgStrategy(${interval.inMinutes}min, $accuracy, "$label")';
}

/// Pick a background strategy from the device's battery state. Pure, so the
/// thresholds are unit-tested without a device.
///
/// - [percent] is the battery level 0–100, or null when it can't be read
///   (treated as healthy — never punish an unknown reading with worse service).
/// - [charging] is true while plugged in (or full): no need to conserve.
///
/// Tiers (discharging):
///   > 35%   → every 2 min, high accuracy   (normal)
///   16–35%  → every 5 min, medium accuracy (saver)
///   ≤ 15%   → every 10 min, medium accuracy (deep saver)
BgStrategy backgroundStrategy({required int? percent, required bool charging}) {
  if (charging) {
    return const BgStrategy(
        Duration(minutes: 2), LocationAccuracy.high, 'Sharing your location');
  }
  final p = percent ?? 100; // unknown battery → assume healthy
  if (p <= 15) {
    return const BgStrategy(Duration(minutes: 10), LocationAccuracy.medium,
        'Sharing your location · battery saver');
  }
  if (p <= 35) {
    return const BgStrategy(Duration(minutes: 5), LocationAccuracy.medium,
        'Sharing your location · battery saver');
  }
  return const BgStrategy(
      Duration(minutes: 2), LocationAccuracy.high, 'Sharing your location');
}
