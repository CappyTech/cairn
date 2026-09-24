import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:my_app/screens/map_screen.dart';

/// Map helpers (the direction-cone gates now live in motion_test.dart).
void main() {
  group('fitTargets', () {
    final me = LatLng(51.5, -0.1);
    final a = LatLng(52.0, -1.0);
    final b = LatLng(53.0, -2.0);

    test('includes me and every contact', () {
      final t = fitTargets(me: me, contacts: [a, b]);
      expect(t, [me, a, b]);
    });

    test('omits me when unknown', () {
      expect(fitTargets(me: null, contacts: [a]), [a]);
    });

    test('empty when nothing to frame', () {
      expect(fitTargets(me: null, contacts: const []), isEmpty);
    });

    test('just me when no contacts', () {
      expect(fitTargets(me: me, contacts: const []), [me]);
    });
  });
}
