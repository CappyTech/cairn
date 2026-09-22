import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/screens/map_screen.dart';

/// The gate that decides whether to draw my direction cone: only with a live
/// GPS course (moving, and a valid heading), since course-over-ground is
/// meaningless when still and comes through as -1 / NaN with no fix.
void main() {
  group('coneHeading', () {
    test('returns the heading when moving with a valid course', () {
      expect(coneHeading(speed: 3.0, heading: 90), 90);
    });

    test('hides the cone when stationary (below the walk threshold)', () {
      expect(coneHeading(speed: 0.1, heading: 90), isNull);
    });

    test('respects a custom minimum speed', () {
      expect(coneHeading(speed: 1.0, heading: 90, minSpeed: 2.0), isNull);
      expect(coneHeading(speed: 2.0, heading: 90, minSpeed: 2.0), 90);
    });

    test('hides the cone for an absent heading (-1) even when moving', () {
      expect(coneHeading(speed: 5.0, heading: -1), isNull);
    });

    test('hides the cone for NaN speed or heading', () {
      expect(coneHeading(speed: double.nan, heading: 90), isNull);
      expect(coneHeading(speed: 3.0, heading: double.nan), isNull);
    });

    test('accepts the boundary headings 0 and 360', () {
      expect(coneHeading(speed: 3.0, heading: 0), 0);
      expect(coneHeading(speed: 3.0, heading: 360), 360);
    });

    test('rejects an out-of-range heading', () {
      expect(coneHeading(speed: 3.0, heading: 361), isNull);
    });
  });
}
