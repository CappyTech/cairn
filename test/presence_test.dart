import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/presence.dart';

/// Edge-triggered staleness: alert once when a contact goes quiet, re-arm when
/// they come back. These pin that logic without a clock or a server.
void main() {
  final now = DateTime(2026, 1, 1, 12, 0, 0);
  DateTime agoMin(int m) => now.subtract(Duration(minutes: m));

  group('Presence.newlyStale', () {
    test('flags a contact past the threshold', () {
      final stale = Presence.newlyStale(
        updatedById: {'a': agoMin(20), 'b': agoMin(2)},
        alreadyNotified: {},
        now: now,
      );
      expect(stale, {'a'});
    });

    test('does not re-flag one already notified', () {
      final stale = Presence.newlyStale(
        updatedById: {'a': agoMin(20)},
        alreadyNotified: {'a'},
        now: now,
      );
      expect(stale, isEmpty);
    });

    test('threshold is inclusive at exactly 15 min', () {
      expect(
        Presence.newlyStale(
            updatedById: {'a': agoMin(15)}, alreadyNotified: {}, now: now),
        {'a'},
      );
      expect(
        Presence.newlyStale(
            updatedById: {'a': agoMin(14)}, alreadyNotified: {}, now: now),
        isEmpty,
      );
    });

    test('respects a custom threshold', () {
      expect(
        Presence.newlyStale(
          updatedById: {'a': agoMin(6)},
          alreadyNotified: {},
          now: now,
          threshold: const Duration(minutes: 5),
        ),
        {'a'},
      );
    });
  });

  group('Presence.freshAgain', () {
    test('clears a contact that came back fresh', () {
      final cleared = Presence.freshAgain(
        updatedById: {'a': agoMin(1)},
        alreadyNotified: {'a'},
        now: now,
      );
      expect(cleared, {'a'});
    });

    test('keeps a still-stale contact flagged', () {
      final cleared = Presence.freshAgain(
        updatedById: {'a': agoMin(30)},
        alreadyNotified: {'a'},
        now: now,
      );
      expect(cleared, isEmpty);
    });

    test('drops a contact that disappeared (e.g. removed)', () {
      final cleared = Presence.freshAgain(
        updatedById: {},
        alreadyNotified: {'a'},
        now: now,
      );
      expect(cleared, {'a'});
    });
  });

  test('full cycle: stale → notified → fresh → re-armed', () {
    final notified = <String>{};

    // Goes quiet → newly stale.
    var newly = Presence.newlyStale(
        updatedById: {'a': agoMin(20)}, alreadyNotified: notified, now: now);
    expect(newly, {'a'});
    notified.addAll(newly);

    // Still quiet → not re-flagged.
    newly = Presence.newlyStale(
        updatedById: {'a': agoMin(25)}, alreadyNotified: notified, now: now);
    expect(newly, isEmpty);

    // Comes back fresh → cleared from the notified set.
    notified.removeAll(Presence.freshAgain(
        updatedById: {'a': agoMin(0)}, alreadyNotified: notified, now: now));
    expect(notified, isEmpty);

    // Goes quiet again → alerts once more.
    newly = Presence.newlyStale(
        updatedById: {'a': agoMin(20)}, alreadyNotified: notified, now: now);
    expect(newly, {'a'});
  });

  group('Presence.describe', () {
    ({PresenceLevel level, String label}) at(Duration ago) =>
        Presence.describe(updated: now.subtract(ago), now: now);

    test('never shared → "No location yet"', () {
      final r = Presence.describe(updated: null, now: now);
      expect(r.level, PresenceLevel.never);
      expect(r.label, 'No location yet');
    });

    test('under 2 minutes → Live', () {
      expect(at(const Duration(seconds: 30)).level, PresenceLevel.live);
      expect(at(const Duration(seconds: 30)).label, 'Live');
    });

    test('minutes ago → recent', () {
      final r = at(const Duration(minutes: 5));
      expect(r.level, PresenceLevel.recent);
      expect(r.label, '5m ago');
    });

    test('hours ago → stale', () {
      final r = at(const Duration(hours: 3));
      expect(r.level, PresenceLevel.stale);
      expect(r.label, '3h ago');
    });

    test('days ago → old', () {
      final r = at(const Duration(days: 2, hours: 1));
      expect(r.level, PresenceLevel.old);
      expect(r.label, '2d ago');
    });

    test('boundaries: 2 min recent, 15 min stale, 24 h old', () {
      expect(at(const Duration(minutes: 2)).level, PresenceLevel.recent);
      expect(at(const Duration(minutes: 15)).level, PresenceLevel.stale);
      expect(at(const Duration(hours: 24)).level, PresenceLevel.old);
    });
  });
}
