import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/location_sharing_service.dart';
import 'package:my_app/services/motion.dart';

/// Speed / direction gates, heading blending, and the motion fields of the
/// shared payload — including the padding that keeps "moving" out of the
/// server-visible ciphertext size.
void main() {
  group('trustedSpeed', () {
    test('passes a speed well above its error', () {
      expect(Motion.trustedSpeed(10, 0.5), 10);
    });

    test('reports 0 for a speed inside twice its error (jitter)', () {
      expect(Motion.trustedSpeed(0.8, 0.5), 0);
    });

    test('trusts the raw speed when accuracy is not reported', () {
      expect(Motion.trustedSpeed(3, 0), 3);
      expect(Motion.trustedSpeed(3, double.nan), 3);
    });

    test('rejects NaN / negative speeds', () {
      expect(Motion.trustedSpeed(double.nan, 1), isNull);
      expect(Motion.trustedSpeed(-1, 1), isNull);
    });

    test('clamps absurd speeds', () {
      expect(Motion.trustedSpeed(9999, 0), Motion.maxSpeed);
    });
  });

  group('course', () {
    test('returns the heading when moving with a valid course', () {
      expect(Motion.course(speed: 3, heading: 90), 90);
    });

    test('null when slower than a brisk walk', () {
      expect(Motion.course(speed: 1.0, heading: 90), isNull);
    });

    test('null for an absent (-1), NaN or out-of-range heading', () {
      expect(Motion.course(speed: 5, heading: -1), isNull);
      expect(Motion.course(speed: 5, heading: double.nan), isNull);
      expect(Motion.course(speed: 5, heading: 361), isNull);
      expect(Motion.course(speed: double.nan, heading: 90), isNull);
    });

    test('null when the reported course error is too wide', () {
      expect(Motion.course(speed: 5, heading: 90, headingAccuracy: 60),
          isNull);
      expect(Motion.course(speed: 5, heading: 90, headingAccuracy: 30), 90);
    });

    test('360 is wrapped to 0', () {
      expect(Motion.course(speed: 5, heading: 360), 0);
    });
  });

  group('blend', () {
    test('course wins while moving', () {
      expect(Motion.blend(course: 90, compass: 200, useCompass: true), 90);
    });

    test('compass when still, if enabled', () {
      expect(Motion.blend(course: null, compass: 200, useCompass: true), 200);
      expect(Motion.blend(course: null, compass: -10, useCompass: true), 350);
    });

    test('nothing when still and the compass is off or absent', () {
      expect(Motion.blend(course: null, compass: 200, useCompass: false),
          isNull);
      expect(Motion.blend(course: null, compass: null, useCompass: true),
          isNull);
    });
  });

  group('smoothAngle', () {
    test('first reading passes straight through', () {
      expect(Motion.smoothAngle(null, 370), 10);
    });

    test('steps the short way across north', () {
      final v = Motion.smoothAngle(350, 10, alpha: 0.5);
      expect(v, closeTo(0, 1e-9));
    });

    test('steps the short way the other direction too', () {
      final v = Motion.smoothAngle(10, 350, alpha: 0.5);
      expect(v, closeTo(0, 1e-9));
    });
  });

  group('freshness', () {
    final now = DateTime(2026, 1, 1, 12);

    test('own fix: fresh within 20 s', () {
      expect(Motion.isFresh(now.subtract(const Duration(seconds: 5)), now),
          isTrue);
      expect(Motion.isFresh(now.subtract(const Duration(seconds: 30)), now),
          isFalse);
    });

    test('contact share: covers the 2-min background cadence', () {
      expect(
          Motion.contactMotionFresh(
              now.subtract(const Duration(minutes: 2, seconds: 20)), now),
          isTrue);
      expect(
          Motion.contactMotionFresh(
              now.subtract(const Duration(minutes: 5)), now),
          isFalse);
    });
  });

  group('formatting', () {
    test('compass points', () {
      expect(Motion.compassPoint(0), 'N');
      expect(Motion.compassPoint(44), 'NE');
      expect(Motion.compassPoint(180), 'S');
      expect(Motion.compassPoint(338), 'N');
      expect(Motion.compassPoint(-90), 'W');
    });

    test('speed units', () {
      expect(Motion.formatSpeed(10, mph: true), '22 mph');
      expect(Motion.formatSpeed(10, mph: false), '36 km/h');
      expect(Motion.formatSpeed(0.1, mph: true), 'still');
    });

    test('mph countries', () {
      expect(Motion.usesMph('GB'), isTrue);
      expect(Motion.usesMph('us'), isTrue);
      expect(Motion.usesMph('FR'), isFalse);
      expect(Motion.usesMph(null), isFalse);
    });
  });

  group('payload motion fields', () {
    Map<String, dynamic> build({
      bool approximate = false,
      double? speed,
      double? heading,
      String? label,
    }) =>
        LocationSharingService.buildPayload(
          lat: 51.5074,
          lng: -0.1278,
          accuracy: 5,
          approximate: approximate,
          ts: '2026-01-01T00:00:00.000Z',
          label: label,
          speed: speed,
          heading: heading,
        );

    test('included (rounded) on a precise share', () {
      final p = build(speed: 12.345, heading: 89.6);
      expect(p['spd'], 12.3);
      expect(p['hdg'], 90);
    });

    test('omitted when not given', () {
      final p = build();
      expect(p.containsKey('spd'), isFalse);
      expect(p.containsKey('hdg'), isFalse);
    });

    test('never sent on an approximate share', () {
      final p = build(approximate: true, speed: 12, heading: 90);
      expect(p.containsKey('spd'), isFalse);
      expect(p.containsKey('hdg'), isFalse);
    });

    test('round-trips into ContactLocation', () {
      final bytes = LocationSharingService.encodePayload(
          build(speed: 4.2, heading: 270));
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final loc = LocationSharingService.contactLocationFrom(
        senderId: 'a',
        name: 'A',
        data: data,
        updatedIso: '2026-01-01T00:00:00.000Z',
      );
      expect(loc.speed, 4.2);
      expect(loc.heading, 270);
    });

    test('older payloads without motion still parse', () {
      final loc = LocationSharingService.contactLocationFrom(
        senderId: 'a',
        name: 'A',
        data: {'lat': 1, 'lng': 2, 'approx': false, 'ts': 'T'},
        updatedIso: '2026-01-01T00:00:00.000Z',
      );
      expect(loc.speed, isNull);
      expect(loc.heading, isNull);
    });
  });

  group('encodePayload padding', () {
    List<int> enc({double? speed, double? heading, String? label}) =>
        LocationSharingService.encodePayload(
            LocationSharingService.buildPayload(
          lat: 51.5074,
          lng: -0.1278,
          accuracy: 5,
          approximate: false,
          ts: '2026-01-01T00:00:00.000Z',
          label: label,
          speed: speed,
          heading: heading,
        ));

    test('moving and still encode to the same length', () {
      final still = enc();
      for (final (s, h) in [
        (0.0, null),
        (1.2, 5.0),
        (349.9, 359.0),
        (9999.0, 180.0),
        (null, 45.0),
      ]) {
        expect(enc(speed: s, heading: h).length, still.length,
            reason: 'spd=$s hdg=$h');
      }
    });

    test('also with a (non-ASCII) status label', () {
      expect(enc(label: 'Café', speed: 30, heading: 12).length,
          enc(label: 'Café').length);
    });

    test('is a multiple of the pad block and still valid JSON', () {
      final b = enc(speed: 3, heading: 3);
      expect(b.length % 64, 0);
      final data = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
      expect(data['lat'], 51.5074);
      expect(data['pad'], isA<String>());
    });
  });
}
