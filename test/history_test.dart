import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/history_service.dart';
import 'package:my_app/services/places_service.dart';

/// Pure logic behind history: point wire round-trip, day bucketing, merge/dedup,
/// and trip segmentation from a breadcrumb trail + places. No live PocketBase.
void main() {
  const home = Place(
      id: 'home', name: 'Home', lat: 51.5074, lng: -0.1278, radiusMeters: 150);
  const work = Place(
      id: 'work', name: 'Work', lat: 51.5155, lng: -0.1420, radiusMeters: 150);

  HistoryPoint at(Place p, DateTime t) => HistoryPoint(p.lat, p.lng, t);
  // A point ~1 km away from Home (outside any place) — "on the road".
  HistoryPoint away(DateTime t) => HistoryPoint(51.5074 + 0.009, -0.1278, t);
  DateTime base(int minute) => DateTime.utc(2026, 9, 20, 8, minute);

  group('HistoryPoint wire', () {
    test('round-trips through JSON (epoch-second precision)', () {
      final p = HistoryPoint(51.5, -0.1, DateTime.utc(2026, 9, 20, 8, 30, 15), 12.5);
      final back = HistoryPoint.fromJson(p.toJson());
      expect(back.lat, closeTo(51.5, 1e-9));
      expect(back.lng, closeTo(-0.1, 1e-9));
      expect(back.acc, 12.5);
      expect(back.t, DateTime.utc(2026, 9, 20, 8, 30, 15));
    });
  });

  group('dayKey', () {
    test('is the UTC calendar day', () {
      expect(HistoryService.dayKey(DateTime.utc(2026, 9, 20, 23, 59)), '2026-09-20');
      // A local-time instant is normalised to UTC first.
      expect(HistoryService.dayKey(DateTime.utc(2026, 1, 5, 0, 0)), '2026-01-05');
    });
  });

  group('mergePoints', () {
    test('dedups by second and sorts by time', () {
      final a = [
        HistoryPoint(1, 1, DateTime.utc(2026, 9, 20, 8, 0, 0)),
        HistoryPoint(2, 2, DateTime.utc(2026, 9, 20, 8, 0, 30)),
      ];
      final b = [
        HistoryPoint(9, 9, DateTime.utc(2026, 9, 20, 8, 0, 0)), // same second → replaces
        HistoryPoint(3, 3, DateTime.utc(2026, 9, 20, 8, 0, 15)),
      ];
      final merged = HistoryService.mergePoints(a, b);
      expect(merged.length, 3); // 8:00:00 (deduped), 8:00:15, 8:00:30
      expect(merged.first.lat, 9); // b's later write won the 8:00:00 slot
      expect(
          merged.map((p) => p.t).toList(),
          [
            DateTime.utc(2026, 9, 20, 8, 0, 0),
            DateTime.utc(2026, 9, 20, 8, 0, 15),
            DateTime.utc(2026, 9, 20, 8, 0, 30),
          ]);
    });
  });

  group('tripsFromPoints', () {
    test('empty / single point → no trips', () {
      expect(HistoryService.tripsFromPoints([], [home, work]), isEmpty);
      expect(
          HistoryService.tripsFromPoints([at(home, base(0))], [home, work]),
          isEmpty);
    });

    test('Home → Work is one trip with the right endpoints and timing', () {
      final pts = [
        at(home, base(0)),
        at(home, base(5)), // dwell at Home
        away(base(10)), // on the road
        away(base(15)),
        at(work, base(20)),
        at(work, base(25)), // dwell at Work
      ];
      final trips = HistoryService.tripsFromPoints(pts, [home, work]);
      expect(trips, hasLength(1));
      final t = trips.single;
      expect(t.from?.id, 'home');
      expect(t.to?.id, 'work');
      // Departs at the last Home point, arrives at the first Work point.
      expect(t.start, base(5));
      expect(t.end, base(20));
      expect(t.distanceMeters, greaterThan(0));
    });

    test('Home → Work → Home is two trips', () {
      final pts = [
        at(home, base(0)),
        away(base(10)),
        at(work, base(20)),
        away(base(30)),
        at(home, base(40)),
      ];
      final trips = HistoryService.tripsFromPoints(pts, [home, work]);
      expect(trips, hasLength(2));
      expect(trips[0].from?.id, 'home');
      expect(trips[0].to?.id, 'work');
      expect(trips[1].from?.id, 'work');
      expect(trips[1].to?.id, 'home');
    });

    test('a leading trip has a null "from" (started away)', () {
      final pts = [away(base(0)), away(base(5)), at(home, base(10))];
      final trips = HistoryService.tripsFromPoints(pts, [home, work]);
      expect(trips, hasLength(1));
      expect(trips.single.from, isNull); // "Away"
      expect(trips.single.to?.id, 'home');
    });

    test('a trailing trip has a null "to" (ended away)', () {
      final pts = [at(home, base(0)), away(base(10)), away(base(20))];
      final trips = HistoryService.tripsFromPoints(pts, [home, work]);
      expect(trips, hasLength(1));
      expect(trips.single.from?.id, 'home');
      expect(trips.single.to, isNull); // "Away"
    });

    test('staying at one place all day → no trips', () {
      final pts = [at(home, base(0)), at(home, base(30)), at(home, base(60))];
      expect(HistoryService.tripsFromPoints(pts, [home, work]), isEmpty);
    });
  });

  group('HistoryTimeline.build', () {
    // ~500 m north of Home, outside any place: an unnamed spot.
    HistoryPoint cafe(DateTime t) => HistoryPoint(51.5074 + 0.0045, -0.1278, t);

    test('empty → nothing; a single point → one stay', () {
      expect(HistoryTimeline.build([], [home]), isEmpty);
      final one = HistoryTimeline.build([at(home, base(0))], [home]);
      expect(one, hasLength(1));
      expect((one.single as Stay).place?.id, 'home');
      // Works without any saved places too (the unnamed-spot case).
      final bare = HistoryTimeline.build([cafe(base(0))], []);
      expect((bare.single as Stay).place, isNull);
    });

    test('Home → Work alternates stay, move, stay', () {
      final pts = [
        at(home, base(0)),
        at(home, base(5)),
        away(base(10)),
        cafe(base(15)), // still moving,
        at(work, base(20)),
        at(work, base(25)),
      ];
      final tl = HistoryTimeline.build(pts, [home, work]);
      expect(tl.map((e) => e.runtimeType), [Stay, Move, Stay]);
      final m = tl[1] as Move;
      expect(m.from?.id, 'home');
      expect(m.to?.id, 'work');
      expect(m.start, base(5));
      expect(m.end, base(20));
      expect(m.distanceMeters, greaterThan(0));
      expect((tl[2] as Stay).start, base(20));
    });

    test('lingering in an unnamed spot becomes a stay', () {
      final pts = [
        at(home, base(0)),
        away(base(5)),
        cafe(base(10)),
        cafe(base(20)), // 10 min at the café
        cafe(base(30)),
        away(base(35)),
        at(home, base(40)),
      ];
      final tl = HistoryTimeline.build(pts, [home]);
      expect(tl.map((e) => e.runtimeType), [Stay, Move, Stay, Move, Stay]);
      final stop = tl[2] as Stay;
      expect(stop.place, isNull);
      expect(stop.start, base(10));
      expect(stop.end, base(30));
    });

    test('passing briefly through a spot is not a stay', () {
      final pts = [
        at(home, base(0)),
        cafe(base(2)),
        cafe(base(3)), // only 1 min
        away(base(6)),
        at(work, base(10)),
      ];
      final tl = HistoryTimeline.build(pts, [home, work]);
      expect(tl.map((e) => e.runtimeType), [Stay, Move, Stay]);
    });

    test('all movement, no stays → a single move', () {
      final pts = [
        away(base(0)),
        cafe(base(1)),
        HistoryPoint(51.5074 - 0.01, -0.1278, base(2)),
      ];
      final tl = HistoryTimeline.build(pts, []);
      expect(tl, hasLength(1));
      expect(tl.single, isA<Move>());
      expect((tl.single as Move).from, isNull);
    });

    test('pathLength sums consecutive hops', () {
      expect(HistoryTimeline.pathLength([]), 0);
      final d = HistoryTimeline.pathLength([at(home, base(0)), away(base(1))]);
      expect(d, closeTo(1000, 20)); // 0.009° latitude ≈ 1 km
    });
  });
}
