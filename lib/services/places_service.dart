import 'dart:convert';
import 'dart:math' as math;
import 'pb_client.dart';
import 'auth_service.dart';
import 'crypto_service.dart';

/// A named place the user cares about — Home, Work, School — with a radius that
/// defines its geofence. Places are MINE: I create them and only I can read
/// them. The server holds a single encrypted-to-self blob per place, so it never
/// learns a place's name or where it is.
///
/// Places sync across my devices (unlike local-only nicknames): restoring my
/// recovery phrase on a new device re-derives the same key, so the blobs
/// decrypt there too.
class Place {
  final String id; // PocketBase record id ('' for one not yet saved)
  final String name;
  final double lat;
  final double lng;
  final double radiusMeters; // geofence radius
  final bool alerts; // fire arrive/leave notifications for contacts

  const Place({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.radiusMeters = defaultRadius,
    this.alerts = true,
  });

  /// A sensible default geofence: large enough to absorb GPS jitter at a
  /// building, small enough not to trip from the next street over.
  static const double defaultRadius = 150;

  Place copyWith({
    String? id,
    String? name,
    double? lat,
    double? lng,
    double? radiusMeters,
    bool? alerts,
  }) =>
      Place(
        id: id ?? this.id,
        name: name ?? this.name,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        radiusMeters: radiusMeters ?? this.radiusMeters,
        alerts: alerts ?? this.alerts,
      );

  /// The cleartext JSON that gets sealed to my own key. Pure — unit-tested.
  Map<String, dynamic> toPayload() => {
        'name': name,
        'lat': lat,
        'lng': lng,
        'radius': radiusMeters,
        'alerts': alerts,
      };

  /// Rebuild a [Place] from a decrypted payload and its record [id]. Pure.
  /// Tolerant of missing/renamed fields so an older or partial blob still
  /// yields a usable place rather than throwing.
  static Place fromPayload(String id, Map<String, dynamic> data) => Place(
        id: id,
        name: (data['name'] as String?)?.trim().isNotEmpty == true
            ? (data['name'] as String).trim()
            : 'Place',
        lat: (data['lat'] as num?)?.toDouble() ?? 0,
        lng: (data['lng'] as num?)?.toDouble() ?? 0,
        radiusMeters: (data['radius'] as num?)?.toDouble() ?? defaultRadius,
        alerts: data['alerts'] != false, // default on
      );
}

/// Stores + retrieves the user's places (encrypted-to-self) and provides the
/// pure geometry the geofence monitor evaluates against.
class PlacesService {
  static const _collection = 'places';

  // ---------------------------------------------------------------------------
  // Pure geometry — no I/O, so it's unit-tested and reused on-device wherever a
  // location needs to be tested against a place (map labels, alerts, background).
  // ---------------------------------------------------------------------------

  static const double _earthRadiusM = 6371000;

  /// Great-circle (Haversine) distance in metres between two lat/lng points.
  static double distanceMeters(
      double lat1, double lng1, double lat2, double lng2) {
    double toRad(double d) => d * math.pi / 180;
    final dLat = toRad(lat2 - lat1);
    final dLng = toRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(toRad(lat1)) *
            math.cos(toRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return _earthRadiusM * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Whether [lat]/[lng] falls within [place]'s geofence. Pure.
  static bool isInside(Place place, double lat, double lng) =>
      distanceMeters(place.lat, place.lng, lat, lng) <= place.radiusMeters;

  /// The first place that contains [lat]/[lng], or null if none — used to label
  /// a contact as "at Home". Pure; when several overlap, the nearest wins.
  static Place? placeContaining(List<Place> places, double lat, double lng) {
    Place? best;
    double bestDist = double.infinity;
    for (final p in places) {
      final d = distanceMeters(p.lat, p.lng, lat, lng);
      if (d <= p.radiusMeters && d < bestDist) {
        best = p;
        bestDist = d;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // CRUD (encrypted-to-self).
  // ---------------------------------------------------------------------------

  /// All of my places, decrypted. Undecryptable rows are skipped rather than
  /// throwing, so one bad blob can't hide the rest.
  static Future<List<Place>> list() async {
    final me = AuthService.currentUser;
    if (me == null) return [];
    final rows = await pb.collection(_collection).getFullList(
          filter: 'owner = "${me.id}"',
          sort: 'created',
        );
    final places = <Place>[];
    for (final r in rows) {
      try {
        final clear =
            await CryptoService.openSealedText(r.getStringValue('ciphertext'));
        places.add(
            Place.fromPayload(r.id, jsonDecode(clear) as Map<String, dynamic>));
      } catch (_) {
        // Skip an undecryptable / malformed place.
      }
    }
    return places;
  }

  /// Create a new place; returns its saved record id.
  static Future<String> create(Place place) async {
    final me = AuthService.currentUser!;
    final blob =
        await CryptoService.sealTextForSelf(jsonEncode(place.toPayload()));
    final rec = await pb.collection(_collection).create(body: {
      'owner': me.id,
      'ciphertext': blob,
    });
    return rec.id;
  }

  /// Update an existing place (identified by [Place.id]).
  static Future<void> update(Place place) async {
    final blob =
        await CryptoService.sealTextForSelf(jsonEncode(place.toPayload()));
    await pb.collection(_collection).update(place.id, body: {
      'ciphertext': blob,
    });
  }

  /// Delete a place by record id.
  static Future<void> delete(String id) async {
    await pb.collection(_collection).delete(id);
  }
}
