import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/location_sharing_service.dart';
import 'package:my_app/services/places_service.dart';

/// The shared "status label" a sender broadcasts with their location: how it's
/// chosen (manual status vs. a contact-visible place), how it rides the payload,
/// and how it's read back. All pure — no PocketBase.
void main() {
  const home = Place(
      id: 'home',
      name: 'Home',
      lat: 51.5074,
      lng: -0.1278,
      radiusMeters: 150,
      shareLabel: true);
  const secret = Place(
      id: 'secret',
      name: 'Secret',
      lat: 51.5074,
      lng: -0.1278,
      radiusMeters: 150,
      shareLabel: false); // not contact-visible

  group('labelForPosition', () {
    test('a manual status wins over everything', () {
      final l = LocationSharingService.labelForPosition(
          manualStatus: 'Hotel', places: [home], lat: 51.5074, lng: -0.1278);
      expect(l, 'Hotel');
    });

    test('inside a contact-visible place → its name', () {
      final l = LocationSharingService.labelForPosition(
          manualStatus: null, places: [home], lat: 51.5074, lng: -0.1278);
      expect(l, 'Home');
    });

    test('a place that is not contact-visible is never used', () {
      final l = LocationSharingService.labelForPosition(
          manualStatus: null, places: [secret], lat: 51.5074, lng: -0.1278);
      expect(l, isNull);
    });

    test('outside every place and no status → null', () {
      final l = LocationSharingService.labelForPosition(
          manualStatus: '  ', places: [home], lat: 0, lng: 0);
      expect(l, isNull);
    });
  });

  group('payload carries the label', () {
    test('buildPayload includes a non-empty label as "lbl"', () {
      final p = LocationSharingService.buildPayload(
          lat: 1, lng: 2, approximate: false, ts: 't', label: 'Hotel');
      expect(p['lbl'], 'Hotel');
    });

    test('buildPayload omits the label when null/empty', () {
      final p1 = LocationSharingService.buildPayload(
          lat: 1, lng: 2, approximate: false, ts: 't');
      final p2 = LocationSharingService.buildPayload(
          lat: 1, lng: 2, approximate: false, ts: 't', label: '');
      expect(p1.containsKey('lbl'), isFalse);
      expect(p2.containsKey('lbl'), isFalse);
    });

    test('contactLocationFrom reads the label back (and null when absent)', () {
      final withLabel = LocationSharingService.contactLocationFrom(
        senderId: 's',
        name: 'Alice',
        data: {'lat': 1.0, 'lng': 2.0, 'lbl': 'Hotel'},
        updatedIso: DateTime.utc(2026, 9, 22).toIso8601String(),
      );
      expect(withLabel.label, 'Hotel');
      final without = LocationSharingService.contactLocationFrom(
        senderId: 's',
        name: 'Alice',
        data: {'lat': 1.0, 'lng': 2.0},
        updatedIso: DateTime.utc(2026, 9, 22).toIso8601String(),
      );
      expect(without.label, isNull);
    });
  });
}
