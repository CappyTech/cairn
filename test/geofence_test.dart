import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/geofence_monitor.dart';
import 'package:my_app/services/places_service.dart';

/// The pure geofence transition logic: first sighting is seeded silently, a
/// genuine crossing fires exactly one enter/leave, staying put is silent, and
/// alerts-off / stale-key pruning behave.
void main() {
  const home = Place(
    id: 'home',
    name: 'Home',
    lat: 51.5074,
    lng: -0.1278,
    radiusMeters: 150,
  );
  // A point comfortably outside Home's radius.
  const outLat = 51.5074 + 0.01; // ~1.1 km north
  const inLat = 51.5074;

  ({List<GeofenceTransition> transitions, Map<String, bool> nextInside}) eval(
    double lat,
    Map<String, bool> prev, {
    List<Place> places = const [home],
  }) =>
      GeofenceMonitor.evaluateContact(
        places: places,
        contactId: 'alice',
        contactName: 'Alice',
        lat: lat,
        lng: -0.1278,
        prevInside: prev,
      );

  test('first sighting is seeded silently (no alert), even if already inside', () {
    final r = eval(inLat, {});
    expect(r.transitions, isEmpty);
    expect(r.nextInside['alice|home'], isTrue);
  });

  test('crossing in from a known-outside state fires one "arrived"', () {
    final seeded = eval(outLat, {}).nextInside; // known: outside
    final r = eval(inLat, seeded);
    expect(r.transitions, hasLength(1));
    expect(r.transitions.single.entered, isTrue);
    expect(r.transitions.single.placeName, 'Home');
    expect(r.transitions.single.contactName, 'Alice');
    expect(r.nextInside['alice|home'], isTrue);
  });

  test('staying inside is silent', () {
    final inside = eval(inLat, eval(outLat, {}).nextInside).nextInside;
    final r = eval(inLat, inside);
    expect(r.transitions, isEmpty);
  });

  test('crossing out fires one "left"', () {
    final inside = eval(inLat, eval(outLat, {}).nextInside).nextInside;
    final r = eval(outLat, inside);
    expect(r.transitions, hasLength(1));
    expect(r.transitions.single.entered, isFalse);
  });

  test('a place with alerts off produces no transition and clears its state', () {
    const off = Place(
        id: 'home', name: 'Home', lat: 51.5074, lng: -0.1278, alerts: false);
    final r = eval(inLat, {'alice|home': false}, places: [off]);
    expect(r.transitions, isEmpty);
    expect(r.nextInside.containsKey('alice|home'), isFalse);
  });

  test('a stable notifId per contact+place (so alerts replace, not stack)', () {
    final a = eval(inLat, eval(outLat, {}).nextInside).transitions.single;
    final b = eval(outLat, eval(inLat, eval(outLat, {}).nextInside).nextInside)
        .transitions
        .single;
    expect(a.notifId, b.notifId); // same contact+place → same id
  });

  group('prune', () {
    test('drops keys for removed places and gone contacts', () {
      final pruned = GeofenceMonitor.prune(
        {'alice|home': true, 'bob|home': false, 'alice|old': true},
        {'alice'}, // bob no longer sharing
        {'home'}, // 'old' place deleted
      );
      expect(pruned, {'alice|home': true});
    });
  });
}
