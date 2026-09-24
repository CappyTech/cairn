import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'history_service.dart';
import 'prefs.dart';

/// Opt-in "snap to roads" for a trip in History: asks a public OSRM router to
/// route along the trip's fixes, so a sparse trail follows the streets instead
/// of cutting corners.
///
/// PRIVACY: this is the one place History sends coordinates off the device —
/// in the clear, to a third party ([host]). It only runs for a trip the user
/// picked, after they agreed (see [Prefs.roadSnapAllowed]).
abstract final class RoadSnapService {
  /// FOSSGIS's public OSRM, which (unlike the OSRM demo) has foot and bike
  /// profiles as well as car.
  static const host = 'routing.openstreetmap.de';

  /// Public OSRM servers cap the waypoints per request.
  static const maxWaypoints = 25;

  static String profileFor(TravelMode mode) => switch (mode) {
        TravelMode.walk => 'routed-foot',
        TravelMode.cycle => 'routed-bike',
        TravelMode.vehicle => 'routed-car',
      };

  /// At most [max] of [path]'s points, evenly spread, always keeping both
  /// ends. Pure.
  static List<HistoryPoint> waypoints(List<HistoryPoint> path,
      {int max = maxWaypoints}) {
    if (path.length <= max) return [...path];
    return [
      for (var i = 0; i < max; i++)
        path[(i * (path.length - 1) / (max - 1)).round()]
    ];
  }

  /// The OSRM route request for [pts] (lng,lat order, as OSRM wants). Pure.
  static Uri routeUri(TravelMode mode, List<HistoryPoint> pts) {
    final coords = [
      for (final p in pts)
        '${p.lng.toStringAsFixed(6)},${p.lat.toStringAsFixed(6)}'
    ].join(';');
    return Uri.https(host, '/${profileFor(mode)}/route/v1/driving/$coords', {
      'overview': 'full',
      'geometries': 'geojson',
    });
  }

  /// The route's line from an OSRM response body, or null if there isn't one.
  /// Pure.
  static List<LatLng>? parseRoute(String body) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['code'] != 'Ok') return null;
      final coords = (((j['routes'] as List).first
          as Map<String, dynamic>)['geometry'] as Map<String, dynamic>)[
          'coordinates'] as List;
      final line = [
        for (final c in coords)
          LatLng(((c as List)[1] as num).toDouble(), (c[0] as num).toDouble())
      ];
      return line.length < 2 ? null : line;
    } catch (_) {
      return null;
    }
  }

  /// Route [move] along the roads for its travel mode. Null on any failure
  /// (offline, no route, server busy) — the caller keeps the raw line.
  static Future<List<LatLng>?> snap(Move move) async {
    if (move.path.length < 2) return null;
    try {
      final res = await http
          .get(routeUri(move.mode, waypoints(move.path)),
              headers: {'User-Agent': 'Cairn (uk.cappylabs.cairn)'})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      return parseRoute(res.body);
    } catch (_) {
      return null;
    }
  }
}
