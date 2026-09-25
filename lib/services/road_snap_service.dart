import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'history_service.dart';
import 'pb_client.dart';
import 'prefs.dart';

/// Opt-in "snap to roads" for a trip in History: matches the trip's fixes to
/// the streets for its travel mode, so a sparse trail follows the roads
/// instead of cutting corners.
///
/// First choice is this Cairn server's own router (Valhalla map matching
/// behind `/api/cairn/snap`, signed-in users only; see
/// `pb_hooks/road_snap.pb.js`). If the server has none or it's down, falls
/// back to a public OSRM router ([host]).
///
/// PRIVACY: this is the one place History sends coordinates off the device
/// outside end-to-end encryption — to my server, or failing that a third
/// party. It only runs for a trip the user picked, after they agreed (see
/// [Prefs.roadSnapAllowed]).
abstract final class RoadSnapService {
  /// FOSSGIS's public OSRM, which (unlike the OSRM demo) has foot and bike
  /// profiles as well as car. The fallback.
  static const host = 'routing.openstreetmap.de';

  /// Map matching wants the trail as recorded, but within reason.
  static const maxServerPoints = 500;

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

  static String modeName(TravelMode mode) => switch (mode) {
        TravelMode.walk => 'walk',
        TravelMode.cycle => 'cycle',
        TravelMode.vehicle => 'vehicle',
      };

  /// The request body for my server's `/api/cairn/snap`. Pure.
  static Map<String, dynamic> serverBody(TravelMode mode, List<HistoryPoint> pts) =>
      {
        'mode': modeName(mode),
        'points': [
          for (final p in waypoints(pts, max: maxServerPoints)) [p.lat, p.lng]
        ],
      };

  /// The matched line from my server's response, or null. Pure.
  static List<LatLng>? parseServerLine(Object? json) {
    try {
      final line = [
        for (final c in (json as Map<String, dynamic>)['line'] as List)
          LatLng(((c as List)[0] as num).toDouble(), (c[1] as num).toDouble())
      ];
      return line.length < 2 ? null : line;
    } catch (_) {
      return null;
    }
  }

  /// Route [move] along the roads for its travel mode: my server's router,
  /// else the public one. Null on any failure (offline, no route, servers
  /// busy) — the caller keeps the raw line.
  static Future<List<LatLng>?> snap(Move move) async {
    if (move.path.length < 2) return null;
    return await _snapOnServer(move) ?? await _snapPublic(move);
  }

  static Future<List<LatLng>?> _snapOnServer(Move move) async {
    try {
      final res = await pb
          .send('/api/cairn/snap',
              method: 'POST', body: serverBody(move.mode, move.path))
          .timeout(const Duration(seconds: 25));
      return parseServerLine(res);
    } catch (_) {
      return null; // no router on this server, or it's down
    }
  }

  static Future<List<LatLng>?> _snapPublic(Move move) async {
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
