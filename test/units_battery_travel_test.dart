import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/history_service.dart';
import 'package:my_app/services/location_sharing_service.dart';
import 'package:my_app/services/motion.dart';
import 'package:my_app/services/road_snap_service.dart';

/// Speed units, battery in the shared payload, and trains / planes guessed
/// from a trip's average speed.
void main() {
  group('speed units', () {
    test('auto follows the region; mph and km/h override it', () {
      expect(Motion.mphFor(SpeedUnit.auto, 'GB'), isTrue);
      expect(Motion.mphFor(SpeedUnit.auto, 'FR'), isFalse);
      expect(Motion.mphFor(SpeedUnit.kmh, 'GB'), isFalse);
      expect(Motion.mphFor(SpeedUnit.mph, 'FR'), isTrue);
    });

    test('stored names parse; anything else is auto', () {
      for (final u in SpeedUnit.values) {
        expect(SpeedUnit.parse(u.name), u);
      }
      expect(SpeedUnit.parse(null), SpeedUnit.auto);
      expect(SpeedUnit.parse('knots'), SpeedUnit.auto);
    });
  });

  group('battery in the payload', () {
    Map<String, dynamic> build(
            {bool approximate = false,
            int? battery,
            bool charging = false,
            double? speed}) =>
        LocationSharingService.buildPayload(
          lat: 51.5074,
          lng: -0.1278,
          accuracy: 5,
          approximate: approximate,
          ts: '2026-01-01T00:00:00.000Z',
          battery: battery,
          charging: charging,
          speed: speed,
        );

    test('sent on precise and approximate shares; omitted when not given', () {
      expect(build(battery: 82)['bat'], 82);
      expect(build(approximate: true, battery: 82)['bat'], 82);
      expect(build().containsKey('bat'), isFalse);
      expect(build(charging: true).containsKey('chg'), isFalse);
      expect(build(battery: 50)['chg'], isNull);
      expect(build(battery: 50, charging: true)['chg'], isTrue);
    });

    test('clamped to 0–100', () {
      expect(build(battery: 140)['bat'], 100);
      expect(build(battery: -3)['bat'], 0);
    });

    test('every battery/motion combination encodes to the same length', () {
      final plain = LocationSharingService.encodePayload(build()).length;
      for (final (b, c, s) in [
        (5, false, null),
        (100, true, null),
        (100, true, 349.9),
        (null, false, 12.0),
      ]) {
        expect(
            LocationSharingService.encodePayload(
                    build(battery: b, charging: c, speed: s))
                .length,
            plain,
            reason: 'bat=$b chg=$c spd=$s');
      }
    });

    test('round-trips into ContactLocation; old payloads have none', () {
      final data = jsonDecode(utf8.decode(LocationSharingService.encodePayload(
          build(battery: 7, charging: true)))) as Map<String, dynamic>;
      final loc = LocationSharingService.contactLocationFrom(
          senderId: 'a', name: 'A', data: data, updatedIso: '2026-01-01T00:00:00Z');
      expect(loc.battery, 7);
      expect(loc.charging, isTrue);
      final old = LocationSharingService.contactLocationFrom(
          senderId: 'a',
          name: 'A',
          data: {'lat': 1, 'lng': 2, 'approx': false, 'ts': 'T'},
          updatedIso: '2026-01-01T00:00:00Z');
      expect(old.battery, isNull);
      expect(old.charging, isFalse);
    });
  });

  group('trains and planes', () {
    final t0 = DateTime.utc(2026, 9, 29, 8);
    // One point a minute heading north, [kmPerMin] apart, the sensor saying
    // [sensed] (a train or plane reads as a vehicle to it).
    Move trip(double kmPerMin, {int mins = 30, TravelMode? sensed}) =>
        HistoryTimeline.build([
          for (var i = 0; i <= mins; i++)
            HistoryPoint(51.0 + i * kmPerMin / 111.2, -0.1,
                t0.add(Duration(minutes: i)), null, sensed)
        ], []).whereType<Move>().single;

    test('thresholds', () {
      expect(HistoryTimeline.fastMode(30), isNull); // ~108 km/h: a car
      expect(HistoryTimeline.fastMode(40), TravelMode.train); // ~144 km/h
      expect(HistoryTimeline.fastMode(80), TravelMode.plane); // ~288 km/h
    });

    test('a fast trip is a train or plane, whatever the sensor said', () {
      expect(trip(1.8, sensed: TravelMode.vehicle).mode,
          TravelMode.vehicle); // 108 km/h
      expect(trip(2.7, sensed: TravelMode.vehicle).mode,
          TravelMode.train); // 162 km/h
      expect(trip(8, sensed: TravelMode.vehicle).mode,
          TravelMode.plane); // 480 km/h
      expect(trip(2.7).mode, TravelMode.train); // no sensor data either
    });

    test('drawn as one run, and never snapped to roads', () {
      final train = trip(2.7);
      expect(HistoryTimeline.speedRuns(train.path).map((r) => r.mode),
          [TravelMode.train]);
      expect(RoadSnapService.canSnap(TravelMode.train), isFalse);
      expect(RoadSnapService.canSnap(TravelMode.plane), isFalse);
      expect(RoadSnapService.canSnap(TravelMode.vehicle), isTrue);
    });
  });
}
