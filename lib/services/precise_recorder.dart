import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'activity_sensor.dart';
import 'auth_service.dart';
import 'history_service.dart';
import 'prefs.dart';

/// "Precise trip recording": while I'm moving, keep a GPS stream open in the
/// background service and record every fix for History, so trips follow the
/// roads instead of joining fixes minutes apart.
///
/// Recording only — sharing keeps its fixed, battery-based cadence (see
/// bg_strategy.dart), so contacts' feeds and the server's share timestamps
/// still say nothing about when I move. Points are flushed on that same
/// tick, and history blobs are padded ([HistoryService.padded]).
///
/// With the activity sensor on, the stream runs only while it says I'm
/// walking, cycling or in a vehicle (and for [linger] after, so a red light
/// doesn't cut a trip up). Without it, the stream runs whenever the setting
/// is on; its distance filter keeps a still phone quiet, but the GPS stays
/// on, so that costs more battery.
class PreciseRecorder {
  PreciseRecorder._();
  static final instance = PreciseRecorder._();

  /// Metres between streamed fixes.
  static const distanceFilter = 25;

  /// At most one recorded fix per this long (a car covers ~50 m in it).
  static const minGap = Duration(seconds: 4);

  /// Keep going this long after the sensor last said I was moving.
  static const linger = Duration(minutes: 5);

  StreamSubscription<Position>? _stream;
  StreamSubscription<TravelMode?>? _changes;
  DateTime? _lastMoving;
  DateTime? _lastRecorded;

  bool get running => _stream != null;

  /// Whether the stream should be running. Pure.
  static bool shouldRun({
    required bool enabled,
    required bool sensing,
    required TravelMode? mode,
    required DateTime? lastMoving,
    required DateTime now,
  }) {
    if (!enabled) return false;
    if (!sensing) return true;
    if (mode != null) return true;
    return lastMoving != null && now.difference(lastMoving) < linger;
  }

  Future<void>? _updating;

  /// Start or stop the stream to match the settings and what the sensor
  /// says now. Call on every background tick; also reacts to sensor changes
  /// by itself once called. Calls run one at a time.
  Future<void> update() =>
      _updating = (_updating ?? Future<void>.value()).then((_) => _update());

  Future<void> _update() async {
    _changes ??= ActivitySensor.changes.listen((_) => update());
    final now = DateTime.now();
    final sensing = await Prefs.activitySensing();
    final mode = sensing ? ActivitySensor.modeAt(now) : null;
    if (mode != null) _lastMoving = now;
    final run = shouldRun(
      enabled: await Prefs.preciseRecording(),
      sensing: sensing,
      mode: mode,
      lastMoving: _lastMoving,
      now: now,
    );
    if (run && _stream == null) {
      _stream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: distanceFilter,
        ),
      ).listen(_onPosition, onError: (_) => stop());
    } else if (!run && _stream != null) {
      await stop();
    }
  }

  Future<void> stop() async {
    final s = _stream;
    _stream = null;
    await s?.cancel();
  }

  void _onPosition(Position p) {
    final t = p.timestamp.toUtc();
    final last = _lastRecorded;
    if (last != null && t.difference(last) < minGap) return;
    final me = AuthService.currentUser;
    if (me == null) return;
    _lastRecorded = t;
    HistoryService.record(
      subject: me.id,
      lat: p.latitude,
      lng: p.longitude,
      ts: t,
      accuracy: p.accuracy,
      mode: ActivitySensor.modeAt(p.timestamp),
    );
    // Keep the linger window fresh while fixes keep coming in motion.
    if (ActivitySensor.modeAt(DateTime.now()) != null) {
      _lastMoving = DateTime.now();
    }
  }
}
