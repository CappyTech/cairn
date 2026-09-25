import 'dart:math' as math;
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

  /// The local calendar-day key ("YYYY-MM-DD") a timestamp belongs to, so a
  /// day in History runs midnight to midnight where the phone is. (Rows written
  /// before this were keyed by UTC day; [loadDay] reads the neighbouring rows
  /// too and filters by local day, so both kinds show up on the right day.)
  static String dayKey(DateTime t) => _keyOfDate(t.toLocal());

  /// "YYYY-MM-DD" from a date's own fields (no timezone conversion).
  static String _keyOfDate(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
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
          await appendToDay(pb, me.id, subject, d.key, d.value);
        } catch (_) {
          // Put these points back so we retry next flush.
          (_buffer[subject] ??= []).addAll(d.value);
        }
      }
    }
  }

  /// How many times [appendToDay] re-reads and retries after losing a race.
  static const _maxWriteAttempts = 5;

  /// Merge new points into a day's blob (dedup by second, sorted), sealing the
  /// result to myself. Pure merge logic is factored into [mergePoints].
  ///
  /// Other writers append to the same row too (this phone's background
  /// service, my other devices), so the write is compare-and-swap: an update
  /// carries the row's `rev` + 1 and the server (pb_hooks/history_rev.pb.js)
  /// refuses it with 409 if someone wrote in between. Then — or if a create
  /// lost to someone else's create — re-read, re-merge and try again. Throws
  /// once out of attempts, so [flush] keeps the points for next time.
  ///
  /// [seal]/[open] default to sealing to myself; tests pass plain text so a
  /// live-server test can run this without a device key.
  static Future<void> appendToDay(PocketBase client, String ownerId,
      String subject, String day, List<HistoryPoint> newPts,
      {Future<String> Function(String clear) seal = CryptoService.sealTextForSelf,
      Future<String> Function(String blob) open =
          CryptoService.openSealedText}) async {
    for (var attempt = 1;; attempt++) {
      try {
        await _tryAppendToDay(
            client, ownerId, subject, day, newPts, seal, open);
        return;
      } on ClientException catch (e) {
        final lostRace = e.statusCode == 409 || e.statusCode == 400;
        if (!lostRace || attempt >= _maxWriteAttempts) rethrow;
        // Brief, growing pause so two writers don't collide in lockstep.
        await Future<void>.delayed(Duration(milliseconds: 150 * attempt));
      }
    }
  }

  static Future<void> _tryAppendToDay(
      PocketBase client,
      String ownerId,
      String subject,
      String day,
      List<HistoryPoint> newPts,
      Future<String> Function(String) seal,
      Future<String> Function(String) open) async {
    RecordModel? existing;
    try {
      existing = await client.collection(_collection).getFirstListItem(
            'owner = "$ownerId" && subject = "$subject" && day = "$day"',
          );
    } on ClientException catch (e) {
      if (e.statusCode != 404) rethrow; // offline etc. — don't clobber
      existing = null; // no row yet
    }

    final current = <HistoryPoint>[];
    if (existing != null) {
      try {
        final clear = await open(existing.getStringValue('ciphertext'));
        for (final j in (jsonDecode(clear) as Map<String, dynamic>)['points']
            as List) {
          current.add(HistoryPoint.fromJson(j as Map<String, dynamic>));
        }
      } catch (_) {/* unreadable blob — start fresh for the day */}
    }

    final merged = mergePoints(current, newPts);
    final blob =
        await seal(jsonEncode({'points': [for (final p in merged) p.toJson()]}));

    if (existing != null) {
      await client.collection(_collection).update(existing.id, body: {
        'ciphertext': blob,
        'rev': existing.getIntValue('rev') + 1,
      });
    } else {
      // A concurrent create for the same day hits the unique index (400);
      // the retry then finds that row and merges into it.
      await client.collection(_collection).create(body: {
        'owner': ownerId,
        'subject': subject,
        'day': day,
        'ciphertext': blob,
        'rev': 1,
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

  /// Load + decrypt a subject's breadcrumb points for one local [day]
  /// (sorted). Reads the rows for the day either side as well — older rows are
  /// keyed by UTC day, and a phone in another timezone keys by its own — then
  /// keeps only the points that fall on [day] locally.
  static Future<List<HistoryPoint>> loadDay(String subject, String day) async {
    final me = AuthService.currentUser;
    if (me == null) return [];
    final d = DateTime.parse('${day}T12:00:00');
    final lo = dayKey(d.subtract(const Duration(days: 1)));
    final hi = dayKey(d.add(const Duration(days: 1)));
    List<RecordModel> rows;
    try {
      rows = await pb.collection(_collection).getFullList(
            filter: 'owner = "${me.id}" && subject = "$subject" && '
                'day >= "$lo" && day <= "$hi"',
          );
    } catch (_) {
      return [];
    }
    var pts = <HistoryPoint>[];
    for (final row in rows) {
      try {
        final clear = await CryptoService.openSealedText(
            row.getStringValue('ciphertext'));
        pts = mergePoints(pts, [
          for (final j in (jsonDecode(clear) as Map<String, dynamic>)['points']
              as List)
            HistoryPoint.fromJson(j as Map<String, dynamic>)
        ]);
      } catch (_) {/* unreadable row — skip it */}
    }
    return pointsOnDay(pts, day);
  }

  /// The points of [pts] whose local calendar day is [day], sorted. Pure.
  static List<HistoryPoint> pointsOnDay(List<HistoryPoint> pts, String day) =>
      [for (final p in pts) if (dayKey(p.t) == day) p]
        ..sort((a, b) => a.t.compareTo(b.t));

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
  static Future<int> fetchServerRetentionDays() async =>
      await tryFetchServerRetentionDays() ?? 0;

  /// As [fetchServerRetentionDays], but null when the server can't be reached
  /// (so an offline phone isn't mistaken for a changed policy).
  static Future<int?> tryFetchServerRetentionDays() async {
    try {
      final rec =
          await pb.collection('server_config').getFirstListItem('');
      final v = rec.getIntValue('history_retention_days');
      return v < 0 ? 0 : v;
    } catch (_) {
      return null;
    }
  }

  /// Whether the background service may record history: the user agreed to
  /// this server's policy, and it hasn't changed since ([serverDays] null =
  /// couldn't check, so trust the stored agreement). Pure.
  static bool backgroundRecordingAllowed(
      {required HistoryConsent? stored, required int? serverDays}) {
    if (stored == null || stored.declined) return false;
    return serverDays == null ||
        !consentNeeded(serverDays: serverDays, stored: stored);
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
  /// ending on [today]'s calendar date (inclusive), and so should be pruned.
  /// 0/negative keepDays = keep everything. Pure (ISO date strings sort
  /// chronologically).
  static List<String> daysToPrune(
      List<String> existingDays, int keepDays, DateTime today) {
    if (keepDays <= 0) return [];
    final cutoffKey = _cutoffKey(keepDays, today);
    return [for (final d in existingDays) if (d.compareTo(cutoffKey) < 0) d];
  }

  /// The oldest day key a [keepDays]-day window ending on [today] keeps.
  static String _cutoffKey(int keepDays, DateTime today) => _keyOfDate(
      DateTime.utc(today.year, today.month, today.day)
          .subtract(Duration(days: keepDays - 1)));

  /// Delete my history rows older than the [keepDays] window (all subjects).
  /// No-op when keeping everything. Best-effort.
  static Future<void> pruneOldDays(int keepDays) async {
    if (keepDays <= 0) return;
    final me = AuthService.currentUser;
    if (me == null) return;
    final cutoffKey = _cutoffKey(keepDays, DateTime.now());
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

/// One entry in a day's timeline: a [Stay] (lingered in one spot), a [Move]
/// (travelled between stays) or a [Gap] (no location data for a while, so we
/// don't know what happened). Derived from the breadcrumb trail.
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

/// How someone was most likely getting about, guessed from speed alone (so a
/// bus and a car look the same: both are [vehicle]).
enum TravelMode { walk, cycle, vehicle }

/// Travel between two stays (or from the start / to the end of the trail).
/// [from]/[to] are the saved places at either end, when there are any. Never
/// spans a [Gap]: the path is continuous data.
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

  /// Average speed over the move (m/s), 0 when it took no time.
  double get avgSpeedMps => duration.inSeconds <= 0
      ? 0
      : distanceMeters / duration.inSeconds;

  TravelMode get mode => HistoryTimeline.modeForSpeed(avgSpeedMps);
}

/// A stretch with no location data (phone off, no signal, app killed) between
/// two points that are too far apart in time to join up. [fromLat]/[fromLng]
/// is the last fix before it and [toLat]/[toLng] the first one after.
class Gap extends TimelineEntry {
  final double fromLat;
  final double fromLng;
  final double toLat;
  final double toLng;
  const Gap({
    required this.fromLat,
    required this.fromLng,
    required this.toLat,
    required this.toLng,
    required DateTime start,
    required DateTime end,
  }) : super(start, end);

  /// Straight-line distance between the fixes either side of the gap.
  double get distanceMeters =>
      PlacesService.distanceMeters(fromLat, fromLng, toLat, toLng);
}

/// Stay/move/gap segmentation of a day's trail, plus the geometry the map
/// draws from it — pure, so it's unit-tested.
abstract final class HistoryTimeline {
  /// Points within this distance of a stay's centre belong to the same stay.
  static const stayRadiusMeters = 100.0;

  /// Minimum time lingering in an unnamed spot for it to count as a stay.
  static const minStay = Duration(minutes: 5);

  /// Two consecutive fixes further apart than this (and not in the same spot)
  /// are a [Gap], not travel: we don't know the route or the timing between
  /// them. Comfortably above the slowest background cadence.
  static const maxGap = Duration(minutes: 20);

  /// Fixes less precise than this are dropped: they scatter across the map and
  /// read as journeys that never happened.
  static const maxAccuracyMeters = 250.0;

  /// Speed (m/s) at or above which travel is cycling (~8 km/h), and at or
  /// above which it's a vehicle (~25 km/h).
  static const cycleMps = 2.2;
  static const vehicleMps = 7.0;

  static TravelMode modeForSpeed(double mps) => mps >= vehicleMps
      ? TravelMode.vehicle
      : mps >= cycleMps
          ? TravelMode.cycle
          : TravelMode.walk;

  /// [pts] without the imprecise fixes — unless that would leave nothing, in
  /// which case a rough trail beats an empty one. Pure.
  static List<HistoryPoint> usable(List<HistoryPoint> pts) {
    final good = [
      for (final p in pts)
        if (p.acc == null || p.acc! <= maxAccuracyMeters) p
    ];
    return good.isEmpty ? [...pts] : good;
  }

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

  /// Distance actually travelled in a timeline: the moves only, not the
  /// straight-line jumps across gaps.
  static double travelledMeters(List<TimelineEntry> timeline) => timeline
      .whereType<Move>()
      .fold(0.0, (sum, m) => sum + m.distanceMeters);

  /// Up to [n] of [timeline]'s moves, newest first. Pure.
  static List<Move> latestMoves(List<TimelineEntry> timeline, int n) =>
      timeline.whereType<Move>().toList().reversed.take(n).toList();

  /// Split a day's [pts] into stays, moves and gaps. Consecutive points in the
  /// same saved place, or within [stayRadiusMeters] of each other outside any
  /// place, form a cluster; a cluster is a stay when it lasts at least
  /// [minStay], or is in a saved place at the start/end of the day, or is the
  /// only cluster. Everything between stays is travel, cut into moves wherever
  /// the data drops out for longer than [maxGap].
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

    // 3. Interleave travel between the stays: moves over continuous data,
    // gaps where it drops out. [fromIsStay]/[toIsStay]: whether s[from]/s[to]
    // is the edge point of a stay (already shown, so not repeated here).
    final out = <TimelineEntry>[];
    void travel(int from, int to, Place? fromPlace, Place? toPlace,
        {required bool fromIsStay, required bool toIsStay}) {
      // Cut [from..to] into runs of points with no gap longer than maxGap.
      final runs = <(int, int)>[];
      var runStart = from;
      for (var k = from; k < to; k++) {
        if (s[k + 1].t.difference(s[k].t) > maxGap) {
          runs.add((runStart, k));
          runStart = k + 1;
        }
      }
      runs.add((runStart, to));

      for (var r = 0; r < runs.length; r++) {
        final (a, b) = runs[r];
        if (r > 0) {
          final prevEnd = runs[r - 1].$2;
          out.add(Gap(
            fromLat: s[prevEnd].lat,
            fromLng: s[prevEnd].lng,
            toLat: s[a].lat,
            toLng: s[a].lng,
            start: s[prevEnd].t,
            end: s[a].t,
          ));
        }
        // Next to a gap, a run that never goes anywhere is someone seen in
        // one spot, not a (0 m) journey: show it as a stop. Leave out a
        // neighbouring stay's own edge point.
        if (runs.length > 1) {
          final lo = a == from && fromIsStay ? a + 1 : a;
          final hi = b == to && toIsStay ? b - 1 : b;
          if (lo > hi) continue; // only a stay's edge point
          final spot = _stationary(s, placeOf, lo, hi);
          if (spot != null) {
            out.add(spot);
            continue;
          }
        }
        if (b > a) {
          final path = s.sublist(a, b + 1);
          out.add(Move(
            from: r == 0 ? fromPlace : null,
            to: r == runs.length - 1 ? toPlace : null,
            distanceMeters: pathLength(path),
            path: path,
            start: s[a].t,
            end: s[b].t,
          ));
        }
      }
    }

    if (stays.isEmpty) {
      travel(0, s.length - 1, null, null, fromIsStay: false, toIsStay: false);
      return out;
    }
    if (stays.first.start > 0) {
      travel(0, stays.first.start, null, stays.first.place,
          fromIsStay: false, toIsStay: true);
    }
    for (var k = 0; k < stays.length; k++) {
      final c = stays[k];
      if (k > 0) {
        final prev = stays[k - 1];
        travel(prev.end, c.start, prev.place, c.place,
            fromIsStay: true, toIsStay: true);
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
      travel(stays.last.end, s.length - 1, stays.last.place, null,
          fromIsStay: true, toIsStay: false);
    }
    return out;
  }

  /// s[lo..hi] as a [Stay] if every point is within [stayRadiusMeters] of the
  /// first, else null. Named after their saved place if they all share one.
  static Stay? _stationary(
      List<HistoryPoint> s, List<Place?> placeOf, int lo, int hi) {
    var lat = 0.0, lng = 0.0;
    for (var k = lo; k <= hi; k++) {
      if (PlacesService.distanceMeters(
              s[lo].lat, s[lo].lng, s[k].lat, s[k].lng) >
          stayRadiusMeters) {
        return null;
      }
      lat += s[k].lat;
      lng += s[k].lng;
    }
    final place = placeOf[lo];
    var shared = place != null;
    for (var k = lo; k <= hi && shared; k++) {
      shared = placeOf[k]?.id == place!.id;
    }
    final n = hi - lo + 1;
    return Stay(
      place: shared ? place : null,
      lat: shared ? place!.lat : lat / n,
      lng: shared ? place!.lng : lng / n,
      start: s[lo].t,
      end: s[hi].t,
    );
  }

  /// Where the trail was at [t]: interpolated between the fixes either side,
  /// or — inside a gap — the last fix before it, with [known] false. Clamped
  /// to the trail's ends. [pts] must be time-sorted and non-empty. Pure.
  static ({double lat, double lng, bool known}) positionAt(
      List<HistoryPoint> pts, DateTime t) {
    if (!t.isAfter(pts.first.t)) {
      return (lat: pts.first.lat, lng: pts.first.lng, known: true);
    }
    if (!t.isBefore(pts.last.t)) {
      return (lat: pts.last.lat, lng: pts.last.lng, known: true);
    }
    // Binary search for the last fix at or before t.
    var lo = 0, hi = pts.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) ~/ 2;
      if (pts[mid].t.isAfter(t)) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    final a = pts[lo], b = pts[hi];
    final span = b.t.difference(a.t);
    if (span > maxGap) return (lat: a.lat, lng: a.lng, known: false);
    final f = span.inMilliseconds == 0
        ? 0.0
        : t.difference(a.t).inMilliseconds / span.inMilliseconds;
    return (
      lat: a.lat + (b.lat - a.lat) * f,
      lng: a.lng + (b.lng - a.lng) * f,
      known: true,
    );
  }

  /// Split a move's [path] into runs of the same speed band (for colouring
  /// the line by speed). Neighbouring runs share their boundary point so the
  /// line stays joined up. Pure.
  static List<({TravelMode mode, List<HistoryPoint> points})> speedRuns(
      List<HistoryPoint> path) {
    final out = <({TravelMode mode, List<HistoryPoint> points})>[];
    for (var i = 0; i + 1 < path.length; i++) {
      final a = path[i], b = path[i + 1];
      final secs = b.t.difference(a.t).inMilliseconds / 1000;
      final mps = secs <= 0
          ? 0.0
          : PlacesService.distanceMeters(a.lat, a.lng, b.lat, b.lng) / secs;
      final mode = modeForSpeed(mps);
      if (out.isNotEmpty && out.last.mode == mode) {
        out.last.points.add(b);
      } else {
        out.add((mode: mode, points: [a, b]));
      }
    }
    return out;
  }

  /// Initial compass bearing (degrees clockwise from north) from a to b.
  static double bearing(double lat1, double lng1, double lat2, double lng2) {
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dl = (lng2 - lng1) * math.pi / 180;
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) -
        math.sin(p1) * math.cos(p2) * math.cos(dl);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Evenly spaced direction arrows along [path]: one per [spacingMeters] of
  /// travel (at least one on any path longer than that, at most [maxArrows]),
  /// each pointing along the segment it sits on. Pure.
  static List<({double lat, double lng, double bearing})> arrows(
      List<HistoryPoint> path,
      {double spacingMeters = 400,
      int maxArrows = 8}) {
    final total = pathLength(path);
    if (path.length < 2 || total < spacingMeters) return [];
    final n = math.min(maxArrows, (total / spacingMeters).floor());
    final out = <({double lat, double lng, double bearing})>[];
    var walked = 0.0;
    var k = 0;
    for (var i = 0; i + 1 < path.length && k < n; i++) {
      final a = path[i], b = path[i + 1];
      final seg = PlacesService.distanceMeters(a.lat, a.lng, b.lat, b.lng);
      // Arrows sit at the middle of each 1/n share of the path.
      while (k < n && walked + seg >= total * (k + 0.5) / n) {
        final f = seg == 0 ? 0.0 : (total * (k + 0.5) / n - walked) / seg;
        out.add((
          lat: a.lat + (b.lat - a.lat) * f,
          lng: a.lng + (b.lng - a.lng) * f,
          bearing: bearing(a.lat, a.lng, b.lat, b.lng),
        ));
        k++;
      }
      walked += seg;
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
