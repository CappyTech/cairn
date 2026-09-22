import 'dart:convert';
import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'auth_service.dart';
import 'crypto_service.dart';
import 'places_service.dart';
import 'prefs.dart';
import 'shared_places_service.dart';

/// One recorded position in a subject's trail.
class HistoryPoint {
  final double lat;
  final double lng;
  final DateTime t; // UTC instant of the fix
  final double? acc; // accuracy in metres, when known

  const HistoryPoint(this.lat, this.lng, this.t, [this.acc]);

  /// Compact wire form (epoch seconds keeps the daily blob small).
  Map<String, dynamic> toJson() => {
        'la': lat,
        'ln': lng,
        't': t.toUtc().millisecondsSinceEpoch ~/ 1000,
        if (acc != null) 'a': acc,
      };

  static HistoryPoint fromJson(Map<String, dynamic> j) => HistoryPoint(
        (j['la'] as num).toDouble(),
        (j['ln'] as num).toDouble(),
        DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt() * 1000,
            isUtc: true),
        (j['a'] as num?)?.toDouble(),
      );
}

/// A movement from one place to another (or to/from somewhere unnamed),
/// derived from a day's breadcrumb trail plus the user's places.
class Trip {
  final Place? from; // where it started (null = unnamed area / start of day)
  final Place? to; // where it ended (null = unnamed / still out)
  final DateTime start; // left `from`
  final DateTime end; // arrived `to`
  final double distanceMeters; // path length
  final List<HistoryPoint> path; // points along the trip (endpoints included)

  const Trip({
    required this.from,
    required this.to,
    required this.start,
    required this.end,
    required this.distanceMeters,
    required this.path,
  });

  Duration get duration => end.difference(start);
  String get fromLabel => from?.name ?? 'Away';
  String get toLabel => to?.name ?? 'Away';
}

/// Records where the owner and their contacts have been (a day-bucketed,
/// encrypted-to-self trail) and derives trips from it. History is always the
/// owner's OWN observations — my GPS fixes and the locations contacts already
/// share with me — re-encrypted to myself, so I never store data I couldn't
/// already read live. The server holds only encrypted daily blobs.
class HistoryService {
  static const _collection = 'location_history';

  // Sampling thresholds: record a subject's point only if enough time has
  // passed OR they've moved far enough since the last recorded one. Keeps the
  // daily blob from bloating when someone is stationary or shares often.
  static const _minInterval = Duration(seconds: 25);
  static const _minDistanceM = 20.0;

  // On-device buffers, flushed to the server periodically.
  static final Map<String, List<HistoryPoint>> _buffer = {};
  static final Map<String, HistoryPoint> _lastAt = {};

  /// Whether history recording/sync is allowed on the current server. Off until
  /// the user has agreed to the server's retention policy (see [HistoryPolicy]).
  /// While off, [record] no-ops, so nothing is buffered or uploaded.
  static bool recordingEnabled = false;

  /// The UTC calendar-day key ("YYYY-MM-DD") a timestamp belongs to.
  static String dayKey(DateTime t) {
    final u = t.toUtc();
    final mm = u.month.toString().padLeft(2, '0');
    final dd = u.day.toString().padLeft(2, '0');
    return '${u.year}-$mm-$dd';
  }

  /// Buffer a point for [subject] (my id, or a contact's), applying sampling so
  /// stationary/duplicate fixes are dropped. Call [flush] to persist.
  static void record({
    required String subject,
    required double lat,
    required double lng,
    required DateTime ts,
    double? accuracy,
  }) {
    if (!recordingEnabled) return; // no consent for this server yet
    final last = _lastAt[subject];
    if (last != null) {
      final dt = ts.difference(last.t).abs();
      final moved = PlacesService.distanceMeters(last.lat, last.lng, lat, lng);
      if (dt < _minInterval && moved < _minDistanceM) return; // too close, skip
      if (!ts.isAfter(last.t) && moved < _minDistanceM) return; // stale/dup
    }
    final p = HistoryPoint(lat, lng, ts.toUtc(), accuracy);
    (_buffer[subject] ??= []).add(p);
    _lastAt[subject] = p;
  }

  /// Persist all buffered points into their per-(subject, day) daily blobs.
  /// Best-effort: on failure the buffer is kept for the next flush.
  static Future<void> flush() async {
    final me = AuthService.currentUser;
    if (me == null || _buffer.isEmpty) return;
    // Snapshot + clear so concurrent records go to the next batch.
    final pending = Map<String, List<HistoryPoint>>.from(_buffer);
    _buffer.clear();
    for (final entry in pending.entries) {
      final subject = entry.key;
      // Group this subject's pending points by day.
      final byDay = <String, List<HistoryPoint>>{};
      for (final p in entry.value) {
        (byDay[dayKey(p.t)] ??= []).add(p);
      }
      for (final d in byDay.entries) {
        try {
          await _appendToDay(me.id, subject, d.key, d.value);
        } catch (_) {
          // Put these points back so we retry next flush.
          (_buffer[subject] ??= []).addAll(d.value);
        }
      }
    }
  }

  /// Merge new points into a day's blob (dedup by second, sorted), sealing the
  /// result to myself. Pure merge logic is factored into [mergePoints].
  static Future<void> _appendToDay(String ownerId, String subject, String day,
      List<HistoryPoint> newPts) async {
    RecordModel? existing;
    try {
      existing = await pb.collection(_collection).getFirstListItem(
            'owner = "$ownerId" && subject = "$subject" && day = "$day"',
          );
    } catch (_) {
      existing = null; // no row yet
    }

    final current = <HistoryPoint>[];
    if (existing != null) {
      try {
        final clear = await CryptoService.openSealedText(
            existing.getStringValue('ciphertext'));
        for (final j in (jsonDecode(clear) as Map<String, dynamic>)['points']
            as List) {
          current.add(HistoryPoint.fromJson(j as Map<String, dynamic>));
        }
      } catch (_) {/* unreadable blob — start fresh for the day */}
    }

    final merged = mergePoints(current, newPts);
    final blob = await CryptoService.sealTextForSelf(
        jsonEncode({'points': [for (final p in merged) p.toJson()]}));

    if (existing != null) {
      await pb.collection(_collection).update(existing.id, body: {'ciphertext': blob});
    } else {
      await pb.collection(_collection).create(body: {
        'owner': ownerId,
        'subject': subject,
        'day': day,
        'ciphertext': blob,
      });
    }
  }

  /// Merge + dedup (by whole-second timestamp) + sort two point lists. Pure.
  static List<HistoryPoint> mergePoints(
      List<HistoryPoint> a, List<HistoryPoint> b) {
    final bySecond = <int, HistoryPoint>{};
    for (final p in [...a, ...b]) {
      bySecond[p.t.toUtc().millisecondsSinceEpoch ~/ 1000] = p;
    }
    final out = bySecond.values.toList()..sort((x, y) => x.t.compareTo(y.t));
    return out;
  }

  // ---------------------------------------------------------------------------
  // Reads.
  // ---------------------------------------------------------------------------

  /// The days (newest first) for which [subject] has any recorded history.
  static Future<List<String>> availableDays(String subject) async {
    final me = AuthService.currentUser;
    if (me == null) return [];
    final rows = await pb.collection(_collection).getFullList(
          filter: 'owner = "${me.id}" && subject = "$subject"',
          sort: '-day',
        );
    return [for (final r in rows) r.getStringValue('day')];
  }

  /// Load + decrypt a subject's breadcrumb points for one day (sorted).
  static Future<List<HistoryPoint>> loadDay(String subject, String day) async {
    final me = AuthService.currentUser;
    if (me == null) return [];
    RecordModel row;
    try {
      row = await pb.collection(_collection).getFirstListItem(
            'owner = "${me.id}" && subject = "$subject" && day = "$day"',
          );
    } catch (_) {
      return [];
    }
    try {
      final clear =
          await CryptoService.openSealedText(row.getStringValue('ciphertext'));
      final pts = [
        for (final j in (jsonDecode(clear) as Map<String, dynamic>)['points']
            as List)
          HistoryPoint.fromJson(j as Map<String, dynamic>)
      ];
      pts.sort((a, b) => a.t.compareTo(b.t));
      return pts;
    } catch (_) {
      return [];
    }
  }

  /// Delete all recorded history for [subject] (all days).
  static Future<void> deleteSubject(String subject) async {
    final me = AuthService.currentUser;
    if (me == null) return;
    final rows = await pb.collection(_collection).getFullList(
          filter: 'owner = "${me.id}" && subject = "$subject"',
        );
    for (final r in rows) {
      await pb.collection(_collection).delete(r.id);
    }
    _buffer.remove(subject);
    _lastAt.remove(subject);
  }

  // ---------------------------------------------------------------------------
  // Retention policy — the server advertises a window; the user may tighten it;
  // the client prunes to the effective window. Pure helpers are unit-tested.
  // ---------------------------------------------------------------------------

  /// The server's advertised retention (days; 0 = keep everything). Read from
  /// the public `server_config` singleton. Best-effort: 0 (keep all) if the
  /// config is missing or unreachable.
  static Future<int> fetchServerRetentionDays() async {
    try {
      final rec =
          await pb.collection('server_config').getFirstListItem('');
      final v = rec.getIntValue('history_retention_days');
      return v < 0 ? 0 : v;
    } catch (_) {
      return 0;
    }
  }

  /// The effective retention window from the server's policy and the user's
  /// optional local override. 0 means "keep everything"; treating 0 as infinity,
  /// the effective window is the *smallest* finite limit (keep less = more
  /// private). Pure.
  static int effectiveRetentionDays(int serverDays, int? localDays) {
    final limits = [serverDays, localDays ?? 0].where((d) => d > 0).toList();
    if (limits.isEmpty) return 0; // both unlimited → keep all
    return limits.reduce((a, b) => a < b ? a : b);
  }

  /// Whether the user must be (re)asked to agree to the server's policy: never
  /// asked, or the policy changed since they last answered. A prior *decline*
  /// still stands for the same policy value, but a changed policy re-prompts.
  /// Pure.
  static bool consentNeeded({required int serverDays, HistoryConsent? stored}) {
    if (stored == null) return true;
    return stored.days != serverDays;
  }

  /// Which of [existingDays] ("YYYY-MM-DD") fall outside a [keepDays]-day window
  /// ending [todayUtc] (inclusive), and so should be pruned. 0/negative keepDays
  /// = keep everything. Pure (ISO date strings sort chronologically).
  static List<String> daysToPrune(
      List<String> existingDays, int keepDays, DateTime todayUtc) {
    if (keepDays <= 0) return [];
    final cutoff = DateTime.utc(todayUtc.year, todayUtc.month, todayUtc.day)
        .subtract(Duration(days: keepDays - 1));
    final cutoffKey = dayKey(cutoff);
    return [for (final d in existingDays) if (d.compareTo(cutoffKey) < 0) d];
  }

  /// Delete my history rows older than the [keepDays] window (all subjects).
  /// No-op when keeping everything. Best-effort.
  static Future<void> pruneOldDays(int keepDays) async {
    if (keepDays <= 0) return;
    final me = AuthService.currentUser;
    if (me == null) return;
    final now = DateTime.now().toUtc();
    final cutoff = DateTime.utc(now.year, now.month, now.day)
        .subtract(Duration(days: keepDays - 1));
    final cutoffKey = dayKey(cutoff);
    try {
      final rows = await pb.collection(_collection).getFullList(
            filter: 'owner = "${me.id}" && day < "$cutoffKey"',
          );
      for (final r in rows) {
        await pb.collection(_collection).delete(r.id);
      }
    } catch (_) {/* best-effort */}
  }

  // ---------------------------------------------------------------------------
  // Trip derivation — pure, so it's unit-tested.
  // ---------------------------------------------------------------------------

  /// Segment a day's [pts] into trips using the user's [places]. A trip is the
  /// movement between two dwells: leaving one place (or the start of the trail)
  /// and arriving at another (or the end of the trail while still out). Points
  /// resolve to the place that contains them, or null ("Away"). Consecutive
  /// same-place points form a dwell; the span between two different places is a
  /// trip. Pure.
  static List<Trip> tripsFromPoints(
      List<HistoryPoint> pts, List<Place> places) {
    if (pts.length < 2) return [];
    final sorted = [...pts]..sort((a, b) => a.t.compareTo(b.t));

    Place? placeAt(HistoryPoint p) =>
        PlacesService.placeContaining(places, p.lat, p.lng);
    final ids = [for (final p in sorted) placeAt(p)?.id];
    Place? placeById(String? id) {
      if (id == null) return null;
      for (final p in places) {
        if (p.id == id) return p;
      }
      return null;
    }

    // Collapse consecutive equal ids into runs [start, end] (inclusive).
    final runs = <({String? id, int start, int end})>[];
    for (var i = 0; i < ids.length; i++) {
      if (runs.isEmpty || runs.last.id != ids[i]) {
        runs.add((id: ids[i], start: i, end: i));
      } else {
        final last = runs.removeLast();
        runs.add((id: last.id, start: last.start, end: i));
      }
    }

    double pathDistance(int from, int to) {
      var d = 0.0;
      for (var i = from; i < to; i++) {
        d += PlacesService.distanceMeters(
            sorted[i].lat, sorted[i].lng, sorted[i + 1].lat, sorted[i + 1].lng);
      }
      return d;
    }

    Trip trip(String? fromId, int depIdx, String? toId, int arrIdx) => Trip(
          from: placeById(fromId),
          to: placeById(toId),
          start: sorted[depIdx].t,
          end: sorted[arrIdx].t,
          distanceMeters: pathDistance(depIdx, arrIdx),
          path: sorted.sublist(depIdx, arrIdx + 1),
        );

    final trips = <Trip>[];
    ({String? id, int start, int end})? lastPlace;
    var sawPlace = false;

    for (final run in runs) {
      if (run.id == null) continue; // moving/unnamed run — handled by spans
      if (!sawPlace) {
        sawPlace = true;
        // Leading movement before the first known place → an arriving trip.
        if (run.start > 0) {
          trips.add(trip(null, 0, run.id, run.start));
        }
      } else if (lastPlace != null && lastPlace.id != run.id) {
        // Left the previous place, arrived at this one.
        trips.add(trip(lastPlace.id, lastPlace.end, run.id, run.start));
      }
      lastPlace = run;
    }

    // Trailing movement after the last known place → a departing trip that ends
    // while still away.
    if (lastPlace != null && lastPlace.end < sorted.length - 1) {
      trips.add(trip(lastPlace.id, lastPlace.end, null, sorted.length - 1));
    }

    return trips;
  }
}

/// One entry in a day's timeline: either a [Stay] (lingered in one spot) or a
/// [Move] (travelled between stays). Derived from the breadcrumb trail.
sealed class TimelineEntry {
  final DateTime start;
  final DateTime end;
  const TimelineEntry(this.start, this.end);
  Duration get duration => end.difference(start);
}

/// Time spent in one spot: inside a saved [place], or (place == null) an
/// unnamed spot where the trail stayed within a small radius for a while.
class Stay extends TimelineEntry {
  final Place? place;
  final double lat; // the place's centre, or the centroid of the stay's points
  final double lng;
  const Stay({
    required this.place,
    required this.lat,
    required this.lng,
    required DateTime start,
    required DateTime end,
  }) : super(start, end);
}

/// Travel between two stays (or from the start / to the end of the trail).
/// [from]/[to] are the saved places at either end, when there are any.
class Move extends TimelineEntry {
  final Place? from;
  final Place? to;
  final double distanceMeters;
  final List<HistoryPoint> path; // endpoints included
  const Move({
    required this.from,
    required this.to,
    required this.distanceMeters,
    required this.path,
    required DateTime start,
    required DateTime end,
  }) : super(start, end);
}

/// Stay/move segmentation of a day's trail — pure, so it's unit-tested.
abstract final class HistoryTimeline {
  /// Points within this distance of a stay's centre belong to the same stay.
  static const stayRadiusMeters = 100.0;

  /// Minimum time lingering in an unnamed spot for it to count as a stay.
  static const minStay = Duration(minutes: 5);

  /// The shared pin nearest [lat]/[lng] within [stayRadiusMeters], or null —
  /// used to name an otherwise-unnamed stop. Pure.
  static SharedPin? pinNear(List<SharedPin> pins, double lat, double lng) {
    SharedPin? best;
    var bestDist = stayRadiusMeters;
    for (final p in pins) {
      final d = PlacesService.distanceMeters(p.lat, p.lng, lat, lng);
      if (d <= bestDist) {
        best = p;
        bestDist = d;
      }
    }
    return best;
  }

  /// Total length of a trail in metres (points assumed time-sorted).
  static double pathLength(List<HistoryPoint> pts) {
    var d = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      d += PlacesService.distanceMeters(
          pts[i].lat, pts[i].lng, pts[i + 1].lat, pts[i + 1].lng);
    }
    return d;
  }

  /// Split a day's [pts] into alternating stays and moves. Consecutive points
  /// in the same saved place, or within [stayRadiusMeters] of each other
  /// outside any place, form a cluster; a cluster is a stay when it lasts at
  /// least [minStay], or is in a saved place at the start/end of the day, or is
  /// the only cluster. Everything between stays is a move.
  static List<TimelineEntry> build(List<HistoryPoint> pts, List<Place> places) {
    if (pts.isEmpty) return [];
    final s = [...pts]..sort((a, b) => a.t.compareTo(b.t));
    final placeOf = [
      for (final p in s) PlacesService.placeContaining(places, p.lat, p.lng)
    ];

    // 1. Cluster consecutive points.
    final clusters = <_Cluster>[];
    var i = 0;
    while (i < s.length) {
      final place = placeOf[i];
      final c = _Cluster(i, place, s[i].lat, s[i].lng);
      var j = i + 1;
      while (j < s.length) {
        final pj = placeOf[j];
        final same = place != null
            ? pj?.id == place.id
            : pj == null &&
                PlacesService.distanceMeters(c.lat, c.lng, s[j].lat, s[j].lng) <=
                    stayRadiusMeters;
        if (!same) break;
        c.add(j, s[j]);
        j++;
      }
      clusters.add(c);
      i = j;
    }

    // 2. Pick out the stays, merging unnamed ones that drifted apart.
    final stays = <_Cluster>[];
    for (var k = 0; k < clusters.length; k++) {
      final c = clusters[k];
      final edge = k == 0 || k == clusters.length - 1;
      final isStay = clusters.length == 1 ||
          s[c.end].t.difference(s[c.start].t) >= minStay ||
          (c.place != null && edge);
      if (!isStay) continue;
      final prev = stays.isEmpty ? null : stays.last;
      if (prev != null &&
          prev.place == null &&
          c.place == null &&
          prev.end + 1 == c.start &&
          PlacesService.distanceMeters(prev.lat, prev.lng, c.lat, c.lng) <=
              stayRadiusMeters) {
        prev.absorb(c);
      } else {
        stays.add(c);
      }
    }

    // 3. Interleave moves between the stays.
    Move move(int from, int to, Place? fromPlace, Place? toPlace) {
      final path = s.sublist(from, to + 1);
      return Move(
        from: fromPlace,
        to: toPlace,
        distanceMeters: pathLength(path),
        path: path,
        start: s[from].t,
        end: s[to].t,
      );
    }

    if (stays.isEmpty) return [move(0, s.length - 1, null, null)];
    final out = <TimelineEntry>[];
    if (stays.first.start > 0) {
      out.add(move(0, stays.first.start, null, stays.first.place));
    }
    for (var k = 0; k < stays.length; k++) {
      final c = stays[k];
      if (k > 0) {
        final prev = stays[k - 1];
        out.add(move(prev.end, c.start, prev.place, c.place));
      }
      out.add(Stay(
        place: c.place,
        lat: c.place?.lat ?? c.lat,
        lng: c.place?.lng ?? c.lng,
        start: s[c.start].t,
        end: s[c.end].t,
      ));
    }
    if (stays.last.end < s.length - 1) {
      out.add(move(stays.last.end, s.length - 1, stays.last.place, null));
    }
    return out;
  }
}

/// A run of consecutive points in one spot (working state for [HistoryTimeline]).
class _Cluster {
  final int start;
  int end;
  final Place? place;
  double lat;
  double lng;
  int _n = 1;
  _Cluster(this.start, this.place, this.lat, this.lng) : end = start;

  void add(int index, HistoryPoint p) {
    lat = (lat * _n + p.lat) / (_n + 1);
    lng = (lng * _n + p.lng) / (_n + 1);
    _n++;
    end = index;
  }

  void absorb(_Cluster other) {
    final n = _n + other._n;
    lat = (lat * _n + other.lat * other._n) / n;
    lng = (lng * _n + other.lng * other._n) / n;
    _n = n;
    end = other.end;
  }
}
