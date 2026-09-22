import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/presence.dart';

/// Pure presence buckets used by the contacts list and map.
void main() {
  final now = DateTime.utc(2026, 9, 22, 12, 0, 0);
  ({PresenceLevel level, String label}) at(Duration ago) =>
      Presence.describe(updated: now.subtract(ago), now: now);

  test('never shared → "No location yet"', () {
    final r = Presence.describe(updated: null, now: now);
    expect(r.level, PresenceLevel.never);
    expect(r.label, 'No location yet');
  });

  test('under 2 minutes → Live', () {
    final r = at(const Duration(seconds: 30));
    expect(r.level, PresenceLevel.live);
    expect(r.label, 'Live');
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

  test('boundaries: 2 min is recent, 15 min is stale, 24 h is old', () {
    expect(at(const Duration(minutes: 2)).level, PresenceLevel.recent);
    expect(at(const Duration(minutes: 15)).level, PresenceLevel.stale);
    expect(at(const Duration(hours: 24)).level, PresenceLevel.old);
  });
}
