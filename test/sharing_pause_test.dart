import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/sharing_pause.dart';

void main() {
  final now = DateTime(2026, 10, 1, 14, 30);
  String hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  group('active', () {
    test('not paused without an end', () {
      expect(SharingPause.active(null, now), isFalse);
    });

    test('paused until the end, then not', () {
      final end = now.add(const Duration(hours: 1));
      expect(SharingPause.active(end, now), isTrue);
      expect(SharingPause.active(end, end), isFalse);
      expect(SharingPause.active(end, end.add(const Duration(seconds: 1))),
          isFalse);
    });

    test('"until I resume" never runs out', () {
      expect(SharingPause.active(SharingPause.forever, DateTime(3000)), isTrue);
    });
  });

  test('tomorrow morning is 8 am the next day, across a month end', () {
    expect(SharingPause.tomorrowMorning(now), DateTime(2026, 10, 2, 8));
    expect(SharingPause.tomorrowMorning(DateTime(2026, 10, 31, 23, 50)),
        DateTime(2026, 11, 1, 8));
  });

  group('describe', () {
    test('later today', () {
      expect(SharingPause.describe(DateTime(2026, 10, 1, 15, 30), now, time: hm),
          'until 15:30');
    });

    test('tomorrow', () {
      expect(
          SharingPause.describe(SharingPause.tomorrowMorning(now), now,
              time: hm),
          'until tomorrow, 08:00');
    });

    test('further off', () {
      expect(SharingPause.describe(DateTime(2026, 10, 5, 9), now, time: hm),
          'until 5/10, 09:00');
    });

    test('until I resume', () {
      expect(SharingPause.describe(SharingPause.forever, now, time: hm),
          'until you resume');
    });

    test('a stored UTC end reads in local time', () {
      final end = DateTime(2026, 10, 1, 16, 45);
      expect(SharingPause.describe(end.toUtc(), now, time: hm), 'until 16:45');
    });
  });
}
