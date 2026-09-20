import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/speed_format.dart';
import 'package:my_app/services/location_sharing_service.dart';

/// Speed display: converting the device's m/s reading into whole mph / km/h,
/// the locale default, and the payload carrying (or withholding) raw speed.
void main() {
  group('SpeedUnit.format', () {
    test('converts m/s to whole mph and km/h', () {
      expect(SpeedUnit.format(10.0, miles: true), '22 mph'); // 10 m/s
      expect(SpeedUnit.format(10.0, miles: false), '36 km/h');
      expect(SpeedUnit.format(0.0, miles: true), '0 mph');
      expect(SpeedUnit.format(27.78, miles: false), '100 km/h'); // ~100 km/h
    });

    test('null / negative / NaN read as zero', () {
      expect(SpeedUnit.format(null, miles: true), '0 mph');
      expect(SpeedUnit.format(-5.0, miles: false), '0 km/h');
      expect(SpeedUnit.format(double.nan, miles: true), '0 mph');
    });

    test('label returns the bare unit', () {
      expect(SpeedUnit.label(miles: true), 'mph');
      expect(SpeedUnit.label(miles: false), 'km/h');
    });
  });

  group('SpeedUnit.defaultMilesForCountry', () {
    test('mph countries default to miles; others to km/h', () {
      for (final c in ['US', 'GB', 'gb', 'LR', 'MM']) {
        expect(SpeedUnit.defaultMilesForCountry(c), isTrue, reason: c);
      }
      for (final c in ['FR', 'DE', 'JP', null, '']) {
        expect(SpeedUnit.defaultMilesForCountry(c), isFalse, reason: '$c');
      }
    });
  });

  group('payload carries speed only on a precise share', () {
    test('precise share includes raw speed', () {
      final p = LocationSharingService.buildPayload(
          lat: 51.5, lng: -0.1, speed: 13.0, approximate: false, ts: 'T');
      expect(p['spd'], 13.0);
    });

    test('approximate share withholds exact speed (keeps only the bucket)', () {
      final p = LocationSharingService.buildPayload(
          lat: 51.5, lng: -0.1, speed: 13.0, approximate: true, ts: 'T');
      expect(p['spd'], isNull);
      expect(p['act'], isNotNull); // coarse state still shared
    });

    test('contactLocationFrom reads the speed back', () {
      final loc = LocationSharingService.contactLocationFrom(
        senderId: 'ada',
        name: 'Ada',
        data: {'lat': 51.5, 'lng': -0.1, 'spd': 13.0},
        updatedIso: '2026-01-01T00:00:00.000Z',
      );
      expect(loc.speedMps, 13.0);
    });

    test('a payload with no speed leaves it null', () {
      final loc = LocationSharingService.contactLocationFrom(
        senderId: 'x',
        name: 'X',
        data: {'lat': 1.0, 'lng': 2.0},
        updatedIso: '2026-01-01T00:00:00.000Z',
      );
      expect(loc.speedMps, isNull);
    });
  });
}
