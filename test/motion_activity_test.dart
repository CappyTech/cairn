import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/motion_activity.dart';
import 'package:my_app/services/location_sharing_service.dart';

/// The motion state is derived on-device from GPS speed, sent as a coarse
/// bucket inside the encrypted payload, and read back by the recipient. These
/// cover that pure classification and its round trip through the payload.
void main() {
  group('MotionActivity.fromSpeed', () {
    test('classifies representative speeds', () {
      expect(MotionActivity.fromSpeed(0.0), MotionActivity.idle); //   stopped
      expect(MotionActivity.fromSpeed(1.4), MotionActivity.walking); // ~5 km/h
      expect(MotionActivity.fromSpeed(13.0), MotionActivity.driving); // ~47 km/h
      expect(MotionActivity.fromSpeed(55.0), MotionActivity.train); // ~200 km/h
      expect(MotionActivity.fromSpeed(250.0), MotionActivity.plane); // ~900 km/h
    });

    test('boundaries fall on the upper bucket', () {
      // Just below / at each threshold.
      expect(MotionActivity.fromSpeed(0.59), MotionActivity.idle);
      expect(MotionActivity.fromSpeed(0.6), MotionActivity.walking);
      expect(MotionActivity.fromSpeed(3.49), MotionActivity.walking);
      expect(MotionActivity.fromSpeed(3.5), MotionActivity.driving);
      expect(MotionActivity.fromSpeed(35.9), MotionActivity.driving);
      expect(MotionActivity.fromSpeed(36.0), MotionActivity.train);
      expect(MotionActivity.fromSpeed(96.9), MotionActivity.train);
      expect(MotionActivity.fromSpeed(97.0), MotionActivity.plane);
    });

    test('no usable reading is unknown, not a guessed idle', () {
      expect(MotionActivity.fromSpeed(null), MotionActivity.unknown);
      expect(MotionActivity.fromSpeed(-1.0), MotionActivity.unknown);
      expect(MotionActivity.fromSpeed(double.nan), MotionActivity.unknown);
    });
  });

  group('wire <-> enum', () {
    test('round-trips every state through its wire token', () {
      for (final a in MotionActivity.values) {
        expect(MotionActivity.fromWire(a.wire), a);
      }
    });

    test('an unrecognised or missing token is unknown (older sender)', () {
      expect(MotionActivity.fromWire(null), MotionActivity.unknown);
      expect(MotionActivity.fromWire('teleporting'), MotionActivity.unknown);
      expect(MotionActivity.fromWire(42), MotionActivity.unknown);
    });
  });

  group('labels & flags', () {
    test('labels read naturally; unknown has none', () {
      expect(MotionActivity.train.label, 'on a train');
      expect(MotionActivity.plane.label, 'on a plane');
      expect(MotionActivity.unknown.label, isEmpty);
    });

    test('isMoving excludes idle and unknown', () {
      expect(MotionActivity.idle.isMoving, isFalse);
      expect(MotionActivity.unknown.isMoving, isFalse);
      expect(MotionActivity.walking.isMoving, isTrue);
      expect(MotionActivity.plane.isMoving, isTrue);
    });
  });

  group('payload integration', () {
    test('buildPayload carries the state derived from speed', () {
      final p = LocationSharingService.buildPayload(
          lat: 51.5, lng: -0.1, speed: 13.0, approximate: false, ts: 'T');
      expect(p['act'], MotionActivity.driving.wire);
    });

    test('a payload without speed reports idle (0 m/s default upstream)', () {
      // speed omitted -> null -> unknown on the wire.
      final p = LocationSharingService.buildPayload(
          lat: 51.5, lng: -0.1, approximate: true, ts: 'T');
      expect(p['act'], MotionActivity.unknown.wire);
    });

    test('contactLocationFrom reads the state back', () {
      final loc = LocationSharingService.contactLocationFrom(
        senderId: 'ada',
        name: 'Ada',
        data: {
          'lat': 51.5,
          'lng': -0.1,
          'act': MotionActivity.train.wire,
        },
        updatedIso: '2026-01-01T00:00:00.000Z',
      );
      expect(loc.activity, MotionActivity.train);
    });

    test('a legacy payload with no state parses as unknown', () {
      final loc = LocationSharingService.contactLocationFrom(
        senderId: 'x',
        name: 'X',
        data: {'lat': 1.0, 'lng': 2.0},
        updatedIso: '2026-01-01T00:00:00.000Z',
      );
      expect(loc.activity, MotionActivity.unknown);
    });
  });
}
