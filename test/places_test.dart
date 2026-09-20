import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/places_service.dart';

/// Pure logic behind places: the seal payload round-trip (model ↔ JSON) and the
/// geofence geometry (Haversine distance, inside test, nearest-containing).
/// None of this needs a live PocketBase.
void main() {
  const home = Place(
    id: 'p1',
    name: 'Home',
    lat: 51.5074,
    lng: -0.1278,
    radiusMeters: 150,
  );

  group('Place payload', () {
    test('toPayload → fromPayload round-trips the fields', () {
      final data = home.toPayload();
      final back = Place.fromPayload('p1', data);
      expect(back.id, 'p1');
      expect(back.name, 'Home');
      expect(back.lat, closeTo(51.5074, 1e-9));
      expect(back.lng, closeTo(-0.1278, 1e-9));
      expect(back.radiusMeters, 150);
      expect(back.alerts, isTrue);
    });

    test('fromPayload tolerates missing fields with safe defaults', () {
      final p = Place.fromPayload('x', {'lat': 1.0, 'lng': 2.0});
      expect(p.name, 'Place'); // blank/absent name → placeholder
      expect(p.radiusMeters, Place.defaultRadius);
      expect(p.alerts, isTrue); // default on
    });

    test('alerts:false survives the round-trip', () {
      final off = home.copyWith(alerts: false);
      expect(Place.fromPayload('p1', off.toPayload()).alerts, isFalse);
    });
  });

  group('distanceMeters', () {
    test('is ~0 for the same point', () {
      expect(
        PlacesService.distanceMeters(51.5074, -0.1278, 51.5074, -0.1278),
        closeTo(0, 0.001),
      );
    });

    test('matches a known distance (London → Paris ≈ 343 km)', () {
      final d = PlacesService.distanceMeters(51.5074, -0.1278, 48.8566, 2.3522);
      expect(d, closeTo(343000, 5000)); // within 5 km of the ~343 km great circle
    });
  });

  group('isInside', () {
    test('the centre is inside', () {
      expect(PlacesService.isInside(home, 51.5074, -0.1278), isTrue);
    });

    test('a point ~50 m away is inside a 150 m radius', () {
      // ~0.00045° latitude ≈ 50 m north.
      expect(PlacesService.isInside(home, 51.5074 + 0.00045, -0.1278), isTrue);
    });

    test('a point ~300 m away is outside a 150 m radius', () {
      expect(PlacesService.isInside(home, 51.5074 + 0.0027, -0.1278), isFalse);
    });
  });

  group('placeContaining', () {
    final work = home.copyWith(id: 'p2', name: 'Work', lat: 52.0, lng: -1.0);

    test('returns null when the point is in no place', () {
      expect(PlacesService.placeContaining([home, work], 0, 0), isNull);
    });

    test('returns the place the point sits in', () {
      final p = PlacesService.placeContaining([home, work], 51.5074, -0.1278);
      expect(p?.name, 'Home');
    });

    test('when two overlap, the nearest centre wins', () {
      final a = home.copyWith(id: 'a', name: 'A', radiusMeters: 1000);
      final b = home.copyWith(
          id: 'b', name: 'B', lat: 51.5074 + 0.001, radiusMeters: 1000);
      // A point right on A's centre is nearer A than B.
      expect(
        PlacesService.placeContaining([a, b], 51.5074, -0.1278)?.name,
        'A',
      );
    });
  });
}
