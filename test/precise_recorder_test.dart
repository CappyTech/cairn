import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:my_app/services/history_service.dart';
import 'package:my_app/services/precise_recorder.dart';
import 'package:my_app/services/snap_cache.dart';

void main() {
  final now = DateTime.utc(2026, 9, 25, 18);

  group('PreciseRecorder.shouldRun', () {
    bool run({
      bool enabled = true,
      bool sensing = true,
      TravelMode? mode,
      DateTime? lastMoving,
    }) =>
        PreciseRecorder.shouldRun(
            enabled: enabled,
            sensing: sensing,
            mode: mode,
            lastMoving: lastMoving,
            now: now);

    test('off when the setting is off', () {
      expect(run(enabled: false, mode: TravelMode.vehicle), isFalse);
    });
    test('without the sensor, always on', () {
      expect(run(sensing: false), isTrue);
    });
    test('with the sensor, while moving and for a while after', () {
      expect(run(mode: TravelMode.walk), isTrue);
      expect(run(), isFalse);
      expect(run(lastMoving: now.subtract(const Duration(minutes: 2))), isTrue);
      expect(
          run(lastMoving: now.subtract(PreciseRecorder.linger)), isFalse);
    });
  });

  group('SnapCache', () {
    test('encode/decode round-trips to ~10 cm and skips junk', () {
      final json = SnapCache.encode({
        'a': [const LatLng(51.123456789, -0.1), const LatLng(51.2, -0.2)],
      });
      final back = SnapCache.decode(json);
      expect(back['a']!.first.latitude, 51.123457);
      expect(SnapCache.decode('{"a": [[1, 2]], "b": "x"}').keys, ['a']);
      expect(SnapCache.decode('not json'), isEmpty);
    });

    test('keys change when the trip gains fixes', () {
      Move m(int n) => Move(
            from: null,
            to: null,
            distanceMeters: 1000,
            path: [for (var i = 0; i < n; i++) HistoryPoint(51, 0, now)],
            start: now,
            end: now.add(const Duration(minutes: 10)),
          );
      expect(SnapCache.keyFor('me', m(3)), isNot(SnapCache.keyFor('me', m(4))));
      expect(SnapCache.keyFor('me', m(3)), SnapCache.keyFor('me', m(3)));
    });
  });
}
