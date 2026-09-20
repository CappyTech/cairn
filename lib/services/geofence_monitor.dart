import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'location_sharing_service.dart';
import 'notification_service.dart';
import 'places_service.dart';

/// One arrive/leave event for a contact at one of my places.
class GeofenceTransition {
  final String contactId;
  final String contactName;
  final String placeId;
  final String placeName;
  final bool entered; // true = arrived, false = left

  const GeofenceTransition({
    required this.contactId,
    required this.contactName,
    required this.placeId,
    required this.placeName,
    required this.entered,
  });

  String get title => entered ? '$contactName arrived' : '$contactName left';
  String get body => entered
      ? '$contactName is now at $placeName'
      : '$contactName has left $placeName';

  /// Stable per contact+place, so a new alert for the same pair replaces the
  /// previous one instead of stacking.
  int get notifId => '$contactId|$placeId'.hashCode & 0x7fffffff;
}

/// Watches paired contacts' (already-decrypted) locations and raises a local
/// notification when one crosses into or out of one of MY places. All of this
/// runs on-device against locations I can already read — the server learns
/// nothing new about who is where.
class GeofenceMonitor {
  static const _storage = FlutterSecureStorage();
  static const _stateKey = 'geofence_state_v1';

  static String _key(String contactId, String placeId) =>
      '$contactId|$placeId';

  // ---------------------------------------------------------------------------
  // Pure transition logic — no I/O, so it's unit-tested.
  // ---------------------------------------------------------------------------

  /// Evaluate one contact's position against every place, given the previously
  /// recorded inside/outside state (keyed by "contactId|placeId").
  ///
  /// The FIRST time a (contact, place) pair is seen it is *seeded silently* —
  /// no alert — so opening the app (or adding a place) while a contact is
  /// already home doesn't fire a spurious "arrived". Only a genuine change from
  /// a known prior state produces a transition. Places with alerts off are
  /// skipped and their state cleared. Pure.
  static ({List<GeofenceTransition> transitions, Map<String, bool> nextInside})
      evaluateContact({
    required List<Place> places,
    required String contactId,
    required String contactName,
    required double lat,
    required double lng,
    required Map<String, bool> prevInside,
  }) {
    final transitions = <GeofenceTransition>[];
    final next = Map<String, bool>.from(prevInside);
    for (final p in places) {
      final key = _key(contactId, p.id);
      if (!p.alerts) {
        next.remove(key);
        continue;
      }
      final nowInside = PlacesService.isInside(p, lat, lng);
      final known = prevInside.containsKey(key);
      next[key] = nowInside;
      if (known && prevInside[key] != nowInside) {
        transitions.add(GeofenceTransition(
          contactId: contactId,
          contactName: contactName,
          placeId: p.id,
          placeName: p.name,
          entered: nowInside,
        ));
      }
    }
    return (transitions: transitions, nextInside: next);
  }

  /// Keep only state for pairs that still exist (contact still shares, place
  /// still defined), so removed places/contacts don't leave stale keys. Pure.
  static Map<String, bool> prune(
      Map<String, bool> state, Set<String> contactIds, Set<String> placeIds) {
    final out = <String, bool>{};
    state.forEach((k, v) {
      final parts = k.split('|');
      if (parts.length == 2 &&
          contactIds.contains(parts[0]) &&
          placeIds.contains(parts[1])) {
        out[k] = v;
      }
    });
    return out;
  }

  // ---------------------------------------------------------------------------
  // Persisted state.
  // ---------------------------------------------------------------------------

  static Future<Map<String, bool>> loadState() async {
    try {
      final raw = await _storage.read(key: _stateKey);
      if (raw == null || raw.isEmpty) return {};
      return (jsonDecode(raw) as Map<String, dynamic>).cast<String, bool>();
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveState(Map<String, bool> state) async {
    try {
      await _storage.write(key: _stateKey, value: jsonEncode(state));
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // The shared processing step — used by the foreground monitor AND the
  // background isolate. Loads state, evaluates every contact, persists the new
  // state, and fires notifications for the transitions found.
  // ---------------------------------------------------------------------------

  static Future<void> processLocations(
      Map<String, ContactLocation> byId, List<Place> places) async {
    if (places.isEmpty || byId.isEmpty) return;
    var state = await loadState();
    final alerts = <GeofenceTransition>[];
    for (final c in byId.values) {
      final r = evaluateContact(
        places: places,
        contactId: c.senderId,
        contactName: c.name,
        lat: c.lat,
        lng: c.lng,
        prevInside: state,
      );
      state = r.nextInside;
      alerts.addAll(r.transitions);
    }
    state = prune(
      state,
      byId.keys.toSet(),
      places.map((p) => p.id).toSet(),
    );
    await saveState(state);
    for (final t in alerts) {
      await NotificationService.show(
          id: t.notifId, title: t.title, body: t.body);
    }
  }

  // ---------------------------------------------------------------------------
  // Foreground lifetime: one subscription that runs while the app is open, so
  // alerts fire wherever the user is in the app — not only on the map.
  // ---------------------------------------------------------------------------

  static final GeofenceMonitor instance = GeofenceMonitor._();
  GeofenceMonitor._();

  Future<void> Function()? _unsub;
  List<Place> _places = [];
  bool _running = false;
  Future<void> _chain = Future.value(); // serialise overlapping updates

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await NotificationService.init();
    await refreshPlaces();
    try {
      _unsub = await LocationSharingService.subscribe((byId) {
        // Serialise so two quick updates can't race on the stored state.
        _chain = _chain.then((_) => processLocations(byId, _places));
      });
    } catch (_) {
      _running = false; // couldn't subscribe (e.g. offline) — allow a retry
    }
  }

  /// Reload my places (call after adding/editing/removing one).
  Future<void> refreshPlaces() async {
    try {
      _places = await PlacesService.list();
    } catch (_) {}
  }

  Future<void> stop() async {
    await _unsub?.call();
    _unsub = null;
    _running = false;
  }
}
