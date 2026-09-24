import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'motion.dart';

/// The direction this device is facing, from the OS's fused rotation-vector
/// sensor (accelerometer + gyroscope + magnetometer). Local only — the compass
/// is never shared; contacts only ever get the GNSS course (see
/// [LocationSharingService.publish]).
///
/// Holder-counted and lifecycle-aware: the sensor runs only while something
/// (the map) holds an [acquire]d handle AND the app is in the foreground, so
/// it costs no battery when nobody's looking.
class CompassService {
  CompassService._();

  /// Smoothed heading in degrees clockwise from magnetic north, or null when
  /// there's no compass (or it isn't running).
  static final heading = ValueNotifier<double?>(null);

  /// True while the OS reports the magnetometer as poorly calibrated — worth a
  /// "move your phone in a figure-of-eight" nudge.
  static final needsCalibration = ValueNotifier<bool>(false);

  /// Android maps its accuracy buckets to fixed errors (high 15°, medium 30°,
  /// low 45°); iOS reports a real figure. 45°+ is worth recalibrating.
  static const _poorAccuracy = 45.0; // degrees

  static StreamSubscription<CompassEvent>? _sub;
  static int _holders = 0;
  static final _lifecycle = _CompassLifecycle();

  /// Start the compass (if not already running). Pair with [release].
  static void acquire() {
    if (_holders++ == 0) {
      WidgetsBinding.instance.addObserver(_lifecycle);
      _listen();
    }
  }

  /// Stop the compass once the last holder lets go.
  static void release() {
    if (_holders == 0) return;
    if (--_holders > 0) return;
    WidgetsBinding.instance.removeObserver(_lifecycle);
    _stop();
  }

  static void _listen() {
    if (_sub != null) return;
    final events = FlutterCompass.events;
    if (events == null) return; // no sensor
    _sub = events.listen((e) {
      final h = e.heading;
      if (h == null || h.isNaN) return;
      heading.value = Motion.smoothAngle(heading.value, h);
      final acc = e.accuracy;
      needsCalibration.value = acc != null && acc >= _poorAccuracy;
    }, onError: (_) {});
  }

  static void _stop() {
    _sub?.cancel();
    _sub = null;
    heading.value = null;
    needsCalibration.value = false;
  }
}

class _CompassLifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        CompassService._listen();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        CompassService._stop();
      case AppLifecycleState.inactive:
        break;
    }
  }
}
