import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/history_service.dart';
import 'package:my_app/services/places_service.dart';
import 'package:my_app/services/prefs.dart';
import 'package:my_app/services/shared_places_service.dart';

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
    test('is the local calendar day', () {
      expect(HistoryService.dayKey(DateTime(2026, 9, 20, 23, 59)), '2026-09-20');
      expect(HistoryService.dayKey(DateTime(2026, 1, 5, 0, 0)), '2026-01-05');
      // A UTC instant is converted to local time first.
      final utc = DateTime.utc(2026, 9, 20, 23, 30);
      expect(HistoryService.dayKey(utc),
          HistoryService.dayKey(utc.toLocal()));
    });

    test('pointsOnDay keeps only that local day, sorted', () {
      final late = DateTime(2026, 9, 20, 23, 50);
      final early = DateTime(2026, 9, 21, 0, 10);
      final pts = [
        HistoryPoint(1, 1, early.toUtc()),
        HistoryPoint(1, 1, late.add(const Duration(minutes: 5)).toUtc()),
        HistoryPoint(1, 1, late.toUtc()),
      ];
      final day = HistoryService.pointsOnDay(pts, '2026-09-20');
      expect(day.map((p) => p.t),
          [late.toUtc(), late.add(const Duration(minutes: 5)).toUtc()]);
      expect(HistoryService.pointsOnDay(pts, '2026-09-21').single.t,
          early.toUtc());
    });
  });

  group('backgroundRecordingAllowed', () {
    const agreed = HistoryConsent(days: 30, declined: false);
    test('needs an agreement that is not declined', () {
      expect(
          HistoryService.backgroundRecordingAllowed(
              stored: null, serverDays: 30),
          isFalse);
      expect(
          HistoryService.backgroundRecordingAllowed(
              stored: const HistoryConsent(days: 30, declined: true),
              serverDays: 30),
          isFalse);
      expect(
          HistoryService.backgroundRecordingAllowed(
              stored: agreed, serverDays: 30),
          isTrue);
    });
    test('stops if the policy changed; trusts the agreement when offline', () {
      expect(
          HistoryService.backgroundRecordingAllowed(
              stored: agreed, serverDays: 7),
          isFalse);
      expect(
          HistoryService.backgroundRecordingAllowed(
              stored: agreed, serverDays: null),
          isTrue);
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

    test('pinNear names a stop from the closest shared pin in range', () {
      SharedPin pin(String name, double lat) => SharedPin(
          group: name, ownerId: 'o', name: name, lat: lat, lng: -0.1278);
      final pins = [
        pin('Far', 51.5074 + 0.01), // ~1.1 km away
        pin('Near', 51.5074 + 0.0005), // ~55 m
        pin('Nearer', 51.5074 + 0.0002), // ~22 m
      ];
      expect(HistoryTimeline.pinNear(pins, 51.5074, -0.1278)?.name, 'Nearer');
      expect(HistoryTimeline.pinNear([pins.first], 51.5074, -0.1278), isNull);
      expect(HistoryTimeline.pinNear([], 51.5074, -0.1278), isNull);
    });

    test('pathLength sums consecutive hops', () {
      expect(HistoryTimeline.pathLength([]), 0);
      final d = HistoryTimeline.pathLength([at(home, base(0)), away(base(1))]);
      expect(d, closeTo(1000, 20)); // 0.009° latitude ≈ 1 km
    });
  });

  group('gaps in the data', () {
    DateTime at8(int h, int m) => DateTime.utc(2026, 9, 20, h, m);

    test('two far-apart sightings hours apart are a gap, not a trip', () {
      // The reported bug: seen at Work at 04:11, next at Home at 12:42 — this
      // used to read "Travelled 7 km · 8h 31m".
      final pts = [
        at(work, at8(4, 11)),
        at(home, at8(12, 42)),
        at(home, at8(12, 43)),
      ];
      final tl = HistoryTimeline.build(pts, [home, work]);
      expect(tl.map((e) => e.runtimeType), [Stay, Gap, Stay]);
      final gap = tl[1] as Gap;
      expect(gap.start, at8(4, 11));
      expect(gap.end, at8(12, 42));
      expect(gap.distanceMeters, greaterThan(1000));
      expect(HistoryTimeline.travelledMeters(tl), 0);
    });

    test('a trip with a dropout splits into move, gap, move', () {
      final pts = [
        at(home, base(0)),
        at(home, base(5)),
        away(base(8)),
        HistoryPoint(51.5074 + 0.018, -0.1278, base(11)),
        // 40 min of nothing, then picked up again further on.
        HistoryPoint(51.5074 + 0.05, -0.1278, base(51)),
        HistoryPoint(51.5074 + 0.06, -0.1278, base(54)),
      ];
      final tl = HistoryTimeline.build(pts, [home]);
      expect(tl.map((e) => e.runtimeType), [Stay, Move, Gap, Move]);
      expect((tl[1] as Move).from?.id, 'home');
      expect((tl[1] as Move).end, base(11));
      expect((tl[2] as Gap).start, base(11));
      expect((tl[2] as Gap).end, base(51));
      expect((tl[3] as Move).start, base(51));
      // Travelled distance leaves out the jump across the gap.
      expect(HistoryTimeline.travelledMeters(tl),
          lessThan(HistoryTimeline.pathLength(pts)));
    });

    test('a long silence in the same place is still one stay', () {
      final pts = [at(home, at8(1, 0)), at(home, at8(7, 0))];
      final tl = HistoryTimeline.build(pts, [home]);
      expect(tl.single, isA<Stay>());
      expect(tl.single.duration, const Duration(hours: 6));
    });

    test('a lone fix between two gaps is a sighting, not hidden in a gap', () {
      final pts = [
        at(home, at8(8, 0)),
        HistoryPoint(51.53, -0.1278, at8(9, 0)),
        at(work, at8(11, 0)),
      ];
      final tl = HistoryTimeline.build(pts, [home, work]);
      expect(tl.map((e) => e.runtimeType), [Stay, Gap, Stay, Gap, Stay]);
      final seen = tl[2] as Stay;
      expect(seen.place, isNull);
      expect(seen.start, at8(9, 0));
      expect(seen.duration, Duration.zero);
      expect((tl[1] as Gap).end, at8(9, 0));
      expect((tl[3] as Gap).start, at8(9, 0));
    });

    test('staying put right after a gap is a stop, not a 0 m walk', () {
      // No saved places: seen once at 03:11, then twice in one spot a
      // minute apart after an 8½ h dropout. Used to read "Walk · 0 m".
      final a = HistoryPoint(51.5400, -0.1900, at8(3, 11));
      final pts = [
        a,
        HistoryPoint(51.4950, -0.1100, at8(11, 42)),
        HistoryPoint(51.4950, -0.1100, DateTime.utc(2026, 9, 20, 11, 43, 30)),
      ];
      final tl = HistoryTimeline.build(pts, []);
      expect(tl.map((e) => e.runtimeType), [Stay, Gap, Stay]);
      expect(tl.whereType<Move>(), isEmpty);
      expect((tl[0] as Stay).start, a.t);
      expect((tl[2] as Stay).start, at8(11, 42));
      expect((tl[2] as Stay).lat, closeTo(51.4950, 1e-9));
    });

    test('a stay\'s own edge point next to a gap is not shown twice', () {
      final pts = [
        at(home, at8(8, 0)),
        at(home, at8(8, 10)), // 10 min at Home, then a dropout
        at(work, at8(11, 0)),
        at(work, at8(11, 30)),
      ];
      final tl = HistoryTimeline.build(pts, [home, work]);
      expect(tl.map((e) => e.runtimeType), [Stay, Gap, Stay]);
    });

    test('moving after a gap is still a move', () {
      final pts = [
        at(home, at8(8, 0)),
        at(home, at8(8, 10)),
        away(at8(9, 0)), // back after 50 min, already out…
        HistoryPoint(51.5074 + 0.018, -0.1278, at8(9, 5)), // …and moving
      ];
      final tl = HistoryTimeline.build(pts, [home]);
      expect(tl.map((e) => e.runtimeType), [Stay, Gap, Move]);
      expect((tl[2] as Move).distanceMeters, greaterThan(500));
    });
  });

  group('trip geometry', () {
    test('usable drops imprecise fixes, unless that leaves nothing', () {
      final good = HistoryPoint(1, 1, base(0), 20);
      final bad = HistoryPoint(1, 1, base(1), 900);
      final unknown = HistoryPoint(1, 1, base(2));
      expect(HistoryTimeline.usable([good, bad, unknown]), [good, unknown]);
      expect(HistoryTimeline.usable([bad]), [bad]);
    });

    test('travel mode from speed', () {
      expect(HistoryTimeline.modeForSpeed(1.4), TravelMode.walk);
      expect(HistoryTimeline.modeForSpeed(4.5), TravelMode.cycle);
      expect(HistoryTimeline.modeForSpeed(13), TravelMode.vehicle);
      // ~1 km in 12 min ≈ 1.4 m/s → a walk.
      final walk = HistoryTimeline.build(
          [away(base(0)), HistoryPoint(51.5074 + 0.018, -0.1278, base(12))],
          []).single as Move;
      expect(walk.mode, TravelMode.walk);
    });

    test('positionAt interpolates, clamps, and knows about gaps', () {
      final pts = [
        HistoryPoint(0, 0, base(0)),
        HistoryPoint(0, 1, base(10)),
        HistoryPoint(0, 2, base(50)), // 40 min later: a gap
      ];
      final mid = HistoryTimeline.positionAt(pts, base(5));
      expect(mid.lng, closeTo(0.5, 1e-9));
      expect(mid.known, isTrue);
      final inGap = HistoryTimeline.positionAt(pts, base(30));
      expect(inGap.lng, 1); // held at the last fix
      expect(inGap.known, isFalse);
      expect(HistoryTimeline.positionAt(pts, base(-5)).lng, 0);
      expect(HistoryTimeline.positionAt(pts, base(99)).lng, 2);
    });

    test('speedRuns groups segments by band and stays joined up', () {
      // Walk 100 m/min, then drive ~1 km/min, then walk again.
      final pts = [
        HistoryPoint(51.5, -0.1, base(0)),
        HistoryPoint(51.5009, -0.1, base(1)),
        HistoryPoint(51.5018, -0.1, base(2)),
        HistoryPoint(51.5108, -0.1, base(3)),
        HistoryPoint(51.5198, -0.1, base(4)),
        HistoryPoint(51.5207, -0.1, base(5)),
      ];
      final runs = HistoryTimeline.speedRuns(pts);
      expect(runs.map((r) => r.mode),
          [TravelMode.walk, TravelMode.vehicle, TravelMode.walk]);
      expect(runs[0].points.last, same(runs[1].points.first));
      expect(runs.fold<int>(0, (n, r) => n + r.points.length - 1),
          pts.length - 1);
    });

    test('arrows are spaced along the path and point the way it goes', () {
      // ~2 km due north.
      final north = [
        HistoryPoint(51.5, -0.1, base(0)),
        HistoryPoint(51.518, -0.1, base(10)),
      ];
      final arrows = HistoryTimeline.arrows(north, spacingMeters: 400);
      expect(arrows, hasLength(5));
      for (final a in arrows) {
        expect(a.bearing, closeTo(0, 0.5));
      }
      expect(arrows.first.lat, lessThan(arrows.last.lat));
      // Too short for one arrow.
      expect(HistoryTimeline.arrows(north.take(1).toList()), isEmpty);
      // East is 90°.
      expect(HistoryTimeline.bearing(51.5, -0.1, 51.5, -0.09), closeTo(90, 0.5));
    });
  });
}
