import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/history_service.dart';
import 'package:my_app/services/places_service.dart';
import 'package:my_app/widgets/recent_activity.dart';

/// Home's recent places: which saved places show, in what order, and how a
/// day's timeline yields the latest visit to each.
void main() {
  Place place(String id) => Place(id: id, name: id, lat: 0, lng: 0);
  final home = place('home'), work = place('work'), gym = place('gym');
  final t = DateTime.utc(2026, 9, 29, 12);

  test('most recently visited first, then unvisited in saved order', () {
    final visits = <String, PlaceVisit>{
      'work': (day: '2026-09-28', at: t.subtract(const Duration(days: 1))),
      'gym': (day: '2026-09-29', at: t),
    };
    expect(RecentActivity.recentPlaces([home, work, gym], visits, 3),
        [gym, work, home]);
  });

  test('caps at n, and keeps saved order when nothing was visited', () {
    final four = [home, work, gym, place('school')];
    expect(RecentActivity.recentPlaces(four, {}, 3), [home, work, gym]);
    expect(RecentActivity.recentPlaces([], {}, 3), isEmpty);
  });

  test("a day's latest stay per saved place; unnamed stays are ignored", () {
    Stay stay(Place? p, int startH, int endH) => Stay(
        place: p,
        lat: 0,
        lng: 0,
        start: t.add(Duration(hours: startH)),
        end: t.add(Duration(hours: endH)));
    final timeline = <TimelineEntry>[
      stay(home, 0, 1),
      stay(null, 2, 3),
      stay(work, 4, 5),
      stay(home, 6, 7),
    ];
    expect(RecentActivity.lastStays(timeline), {
      'home': t.add(const Duration(hours: 7)),
      'work': t.add(const Duration(hours: 5)),
    });
  });
}
