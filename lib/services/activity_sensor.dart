import 'dart:async';
import 'package:activity_recognition_flutter/activity_recognition_flutter.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';
import 'history_service.dart';
import 'prefs.dart';

/// The phone's activity sensor (Android activity recognition / iOS Core
/// Motion): whether I'm walking, cycling or in a vehicle, so History can say
/// how I travelled instead of guessing from speed — a slow drive through town
/// averages cycling speed. Opt-in ([Prefs.activitySensing]); runs only while
/// the app or its background service is, and only tags my own fixes. Nothing
/// leaves the device except inside my end-to-end-encrypted history.
abstract final class ActivitySensor {
  static const _channel = MethodChannel('uk.cappylabs.cairn/activity');

  /// A detection older than this no longer describes the current fix.
  static const fresh = Duration(minutes: 3);

  /// Detections below this confidence (0–100) are ignored.
  static const minConfidence = 50;

  /// With no detection for this long, re-subscribe: the platform stops
  /// delivering if another engine (the UI going away) unregistered updates.
  static const _restartAfter = Duration(minutes: 10);

  static StreamSubscription<ActivityEvent>? _sub;
  static DateTime? _startedAt;
  static TravelMode? _mode;
  static DateTime? _at; // when [_mode] was detected (null: nothing yet)
  static final _changes = StreamController<TravelMode?>.broadcast();

  /// The sensed mode each time it changes (null: still / unknown), so the
  /// precise recorder can start the moment I set off.
  static Stream<TravelMode?> get changes => _changes.stream;

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// How [type] maps onto History's modes; null when it says nothing about
  /// travel (still, tilting, unknown). Pure.
  static TravelMode? modeFor(ActivityType type) => switch (type) {
        ActivityType.IN_VEHICLE => TravelMode.vehicle,
        ActivityType.ON_BICYCLE => TravelMode.cycle,
        ActivityType.WALKING ||
        ActivityType.RUNNING ||
        ActivityType.ON_FOOT =>
          TravelMode.walk,
        _ => null,
      };

  /// The mode to tag a fix taken at [t] with: the latest confident detection,
  /// if it's recent. Also (re)starts listening when enabled.
  static TravelMode? modeAt(DateTime t) {
    unawaited(ensureListening());
    final at = _at;
    if (at == null || t.difference(at).abs() > fresh) return null;
    return _mode;
  }

  /// Listen while the user has the sensor on (stop when they turn it off);
  /// restart a subscription that has gone quiet. Safe to call often.
  static Future<void> ensureListening() async {
    if (!supported) return;
    // Re-read each time: the switch may have flipped in the other isolate.
    if (!await Prefs.activitySensing()) {
      await stop();
      return;
    }
    final now = DateTime.now();
    if (_sub != null) {
      final last = _at ?? _startedAt!;
      if (now.difference(last) < _restartAfter) return;
      await stop();
    }
    if (_sub != null) return; // another call got there first
    _startedAt = now;
    _sub = ActivityRecognition()
        .activityStream(runForegroundService: false) // ours keeps us alive
        .listen(_onEvent, onError: (_) {});
  }

  static Future<void> stop() async {
    final sub = _sub;
    _sub = null;
    _mode = null;
    _at = null;
    await sub?.cancel();
  }

  static void _onEvent(ActivityEvent e) {
    if (e.confidence < minConfidence) return;
    final mode = modeFor(e.type);
    final changed = mode != _mode;
    _mode = mode;
    _at = DateTime.now();
    if (changed) _changes.add(mode);
  }

  /// Whether this device can use the sensor at all (the plugin needs
  /// Android 8+).
  static Future<bool> available() async {
    if (defaultTargetPlatform != TargetPlatform.android) return supported;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the OS lets us read the sensor (Android 10+ asks; iOS asks by
  /// itself on first use).
  static Future<bool> permitted() async {
    if (defaultTargetPlatform != TargetPlatform.android) return supported;
    try {
      return await _channel.invokeMethod<bool>('status') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Ask the OS for permission (Android). True when granted.
  static Future<bool> requestPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) return supported;
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } catch (_) {
      return false;
    }
  }
}
