import 'package:activity_recognition_flutter/activity_recognition_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/activity_sensor.dart';
import 'package:my_app/services/history_service.dart';

void main() {
  test('activity types map onto travel modes', () {
    expect(ActivitySensor.modeFor(ActivityType.IN_VEHICLE), TravelMode.vehicle);
    expect(ActivitySensor.modeFor(ActivityType.ON_BICYCLE), TravelMode.cycle);
    for (final t in [
      ActivityType.WALKING,
      ActivityType.RUNNING,
      ActivityType.ON_FOOT
    ]) {
      expect(ActivitySensor.modeFor(t), TravelMode.walk);
    }
    for (final t in [
      ActivityType.STILL,
      ActivityType.TILTING,
      ActivityType.UNKNOWN
    ]) {
      expect(ActivitySensor.modeFor(t), isNull);
    }
  });
}
