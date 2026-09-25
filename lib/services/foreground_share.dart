import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'auth_service.dart';
import 'activity_sensor.dart';
import 'history_service.dart';
import 'location_service.dart';
import 'location_sharing_service.dart';
import 'motion.dart';
import 'prefs.dart';

/// Shares this device's location with contacts whenever the app is open —
/// whichever screen or home layout is showing — and stops the moment it's
/// backgrounded (the separate [BackgroundShare] service covers closed-app
/// sharing, if the user turned it on).
///
/// Publishing is on a FIXED 30 s cadence, not per movement, so the server can't
/// read movement / activity timing off share-update times (see
/// `docs/metadata-privacy.md`). Own position is still tracked live and locally
/// in [position] — the map follows it without it leaving the device.
class ForegroundShare with WidgetsBindingObserver {
  ForegroundShare._();
  static final instance = ForegroundShare._();

  static const _cadence = Duration(seconds: 30);

  /// Latest fix from this device's GPS (local only). Null until the first fix.
  /// Seeded from the OS's last known fix while a fresh one is acquired, so the
  /// map can show me straight away.
  final position = ValueNotifier<Position?>(null);

  /// Why sharing isn't running (location off, permission denied), or null.
  final error = ValueNotifier<String?>(null);

  bool _attached = false;
  bool _running = false;
  // Bumped on every pause, so a slow first fix that lands after the app was
  // backgrounded doesn't restart GPS behind the user's back.
  int _generation = 0;
  StreamSubscription<Position>? _posSub;
  Timer? _heartbeat;

  /// Start sharing now and follow the app lifecycle from here on. Idempotent.
  void start() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    // If the user said "Not now" to location in onboarding, don't prompt
    // unasked — Home shows the "not sharing" notice with Retry instead.
    Prefs.locationDeferred()
        .then((deferred) => _resume(askPermission: !deferred));
  }

  /// Stop sharing and stop following the lifecycle (e.g. on sign-out/restart).
  void stop() {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
    _pause();
  }

  /// Try again after an [error] — asks for permission if needed.
  Future<void> retry() async {
    await Prefs.setLocationDeferred(false);
    await _resume(askPermission: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // Don't re-prompt on every return to the app; if the user granted
        // access in system settings meanwhile, this picks it up silently.
        _resume(askPermission: false);
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _pause();
      case AppLifecycleState.inactive:
        break; // transient (a system dialog, the app switcher) — keep going
    }
  }

  Future<void> _resume({required bool askPermission}) async {
    if (_running) return;
    _running = true;
    final gen = _generation;
    try {
      if (!askPermission) {
        final perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied ||
            perm == LocationPermission.deniedForever) {
          // Not asked yet ("Not now" in onboarding) or refused — either way,
          // Retry asks.
          throw "Cairn doesn't have location access yet.";
        }
      }
      // Show the cached fix straight away (a precise one can take seconds);
      // it's display-only — not recorded to history or shared.
      if (position.value == null) {
        final last = await LocationService.lastKnown();
        if (gen != _generation) return;
        if (last != null && position.value == null) position.value = last;
      }
      final pos = await LocationService.current(); // asks, if still needed
      if (gen != _generation) return; // backgrounded while waiting for a fix
      error.value = null;
      _onPosition(pos);
      _publish(pos); // one share on the first fix so contacts aren't left blank
      _posSub = LocationService.stream().listen(_onPosition, onError: (_) {});
      _heartbeat = Timer.periodic(_cadence, (_) {
        final p = position.value;
        if (p != null) _publish(p);
      });
    } catch (e) {
      if (gen != _generation) return;
      _running = false;
      error.value = e.toString();
    }
  }

  void _pause() {
    _generation++;
    _running = false;
    _posSub?.cancel();
    _posSub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _onPosition(Position p) {
    position.value = p;
    // Record my own trail (sampled; the geofence monitor flushes periodically).
    final me = AuthService.currentUser;
    if (me != null) {
      HistoryService.record(
        subject: me.id,
        lat: p.latitude,
        lng: p.longitude,
        ts: p.timestamp.toUtc(), // when the fix was taken
        accuracy: p.accuracy,
        mode: ActivitySensor.modeAt(p.timestamp),
      );
    }
  }

  Future<void> _publish(Position p) async {
    // A fix that's gone stale (stopped moving → no new fixes) no longer says
    // anything about speed or course, so only a fresh one carries motion.
    final fresh = Motion.isFresh(p.timestamp, DateTime.now());
    try {
      await LocationSharingService.publish(
        lat: p.latitude,
        lng: p.longitude,
        accuracy: p.accuracy,
        speed: fresh ? p.speed : null,
        speedAccuracy: p.speedAccuracy,
        heading: fresh ? p.heading : null,
        headingAccuracy: p.headingAccuracy,
      );
    } catch (_) {
      /* offline / no contacts — fine */
    }
  }
}
