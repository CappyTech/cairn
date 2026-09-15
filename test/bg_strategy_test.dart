import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:my_app/services/bg_strategy.dart';

/// The background isolate slows its publish cadence as the battery drains, but
/// never based on movement (that would leak movement timing to the server —
/// see docs/metadata-privacy.md). These pin the battery tiers.
void main() {
  group('backgroundStrategy', () {
    test('charging → frequent + high accuracy regardless of level', () {
      for (final p in [5, 15, 50, 100]) {
        final s = backgroundStrategy(percent: p, charging: true);
        expect(s.interval, const Duration(minutes: 2));
        expect(s.accuracy, LocationAccuracy.high);
        expect(s.label, 'Sharing your location');
      }
    });

    test('healthy battery (>35%) → 2 min / high accuracy', () {
      final s = backgroundStrategy(percent: 80, charging: false);
      expect(s.interval, const Duration(minutes: 2));
      expect(s.accuracy, LocationAccuracy.high);
      expect(s.label, isNot(contains('saver')));
    });

    test('saver tier (16–35%) → 5 min / medium accuracy', () {
      final s = backgroundStrategy(percent: 30, charging: false);
      expect(s.interval, const Duration(minutes: 5));
      expect(s.accuracy, LocationAccuracy.medium);
      expect(s.label, contains('battery saver'));
    });

    test('deep saver (≤15%) → 10 min / medium accuracy', () {
      final s = backgroundStrategy(percent: 10, charging: false);
      expect(s.interval, const Duration(minutes: 10));
      expect(s.accuracy, LocationAccuracy.medium);
      expect(s.label, contains('battery saver'));
    });

    test('tier boundaries are inclusive at 15 and 35', () {
      expect(backgroundStrategy(percent: 15, charging: false).interval,
          const Duration(minutes: 10));
      expect(backgroundStrategy(percent: 16, charging: false).interval,
          const Duration(minutes: 5));
      expect(backgroundStrategy(percent: 35, charging: false).interval,
          const Duration(minutes: 5));
      expect(backgroundStrategy(percent: 36, charging: false).interval,
          const Duration(minutes: 2));
    });

    test('unknown battery (null) is treated as healthy, not punished', () {
      final s = backgroundStrategy(percent: null, charging: false);
      expect(s.interval, const Duration(minutes: 2));
      expect(s.accuracy, LocationAccuracy.high);
    });
  });
}
