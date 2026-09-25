import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/history_service.dart';
import 'package:my_app/services/road_snap_service.dart';

/// Pure parts of opt-in road snapping: waypoint thinning, the request URL,
/// and reading OSRM's response. No network.
void main() {
  final t0 = DateTime.utc(2026, 9, 20, 8);
  List<HistoryPoint> line(int n) => [
        for (var i = 0; i < n; i++)
          HistoryPoint(51.5 + i * 0.001, -0.1, t0.add(Duration(minutes: i)))
      ];

  test('waypoints keeps short paths and thins long ones, ends included', () {
    expect(RoadSnapService.waypoints(line(5)), hasLength(5));
    final long = line(200);
    final w = RoadSnapService.waypoints(long, max: 25);
    expect(w, hasLength(25));
    expect(w.first, same(long.first));
    expect(w.last, same(long.last));
  });

  test('routeUri uses the mode profile and lng,lat order', () {
    final u = RoadSnapService.routeUri(TravelMode.walk, line(2));
    expect(u.host, RoadSnapService.host);
    expect(u.path,
        '/routed-foot/route/v1/driving/-0.100000,51.500000;-0.100000,51.501000');
    expect(u.queryParameters['geometries'], 'geojson');
    expect(RoadSnapService.routeUri(TravelMode.vehicle, line(2)).path,
        startsWith('/routed-car/'));
  });

  test('parseRoute reads the geometry, or null on anything else', () {
    const ok = '{"code":"Ok","routes":[{"geometry":{"type":"LineString",'
        '"coordinates":[[-0.1,51.5],[-0.11,51.51]]}}]}';
    final r = RoadSnapService.parseRoute(ok)!;
    expect(r.first.latitude, 51.5);
    expect(r.first.longitude, -0.1);
    expect(r, hasLength(2));
    expect(RoadSnapService.parseRoute('{"code":"NoRoute"}'), isNull);
    expect(RoadSnapService.parseRoute('not json'), isNull);
  });

  test('server body: mode name and lat,lng pairs, thinned to the cap', () {
    final b = RoadSnapService.serverBody(TravelMode.cycle, line(3));
    expect(b['mode'], 'cycle');
    expect(b['points'], [
      [51.5, -0.1],
      [51.501, -0.1],
      [51.502, -0.1],
    ]);
    final long = RoadSnapService.serverBody(TravelMode.vehicle, line(900));
    expect(long['points'], hasLength(RoadSnapService.maxServerPoints));
  });

  test('parseServerLine reads the line, or null on anything else', () {
    final l = RoadSnapService.parseServerLine({
      'line': [
        [51.5, -0.12],
        [51.51, -0.13]
      ]
    })!;
    expect(l.last.latitude, 51.51);
    expect(l.last.longitude, -0.13);
    expect(RoadSnapService.parseServerLine({'line': [[1, 2]]}), isNull);
    expect(RoadSnapService.parseServerLine({'error': 'x'}), isNull);
    expect(RoadSnapService.parseServerLine(null), isNull);
  });
}
