import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../services/auth_service.dart';
import '../services/history_service.dart';
import '../services/location_service.dart';
import '../services/location_sharing_service.dart';
import '../services/notification_service.dart';
import '../services/places_service.dart';
import '../services/prefs.dart';
import '../services/shared_places_service.dart';
import '../services/stale_alert_store.dart';
import '../theme/brand.dart';

/// Live map: shows the device's own location AND paired contacts' locations
/// (decrypted from their encrypted shares), and shares this device's location
/// with them while the map is open.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  static const _fallback = LatLng(51.5074, -0.1278);

  LatLng? _me;
  Position? _lastPos;
  Map<String, ContactLocation> _contacts = {};
  List<Place> _places = [];
  List<SharedPin> _sharedPins = [];
  String? _error;

  StreamSubscription<Position>? _posSub;
  Future<void> Function()? _unsub;
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    _loadPlaces();
    _start();
  }

  /// My places, shown as labelled circles and used to tag a contact as "at
  /// Home". Best-effort — the map works fine without them.
  Future<void> _loadPlaces() async {
    try {
      final places = await PlacesService.list();
      if (mounted) setState(() => _places = places);
    } catch (_) {}
    try {
      final pins = await SharedPlacesService.sharedWithMe();
      if (mounted) setState(() => _sharedPins = pins);
    } catch (_) {}
  }

  Future<void> _start() async {
    // Receive contacts' locations regardless of our own GPS state.
    // (Guard so a Retry after a GPS error doesn't subscribe twice.)
    _unsub ??= await LocationSharingService.subscribe((map) {
      if (!mounted) return;
      setState(() => _contacts = map);
      unawaited(_checkStale());
    });

    // Show the map straight away, centred on the last cached fix. A precise
    // fix can take several seconds (high-accuracy GPS, cold start, indoors),
    // and blocking the whole screen on it is what made the map feel slow to
    // load. The basemap and contacts are usable immediately; we refine our own
    // position below. Don't record this cached (possibly stale) fix into the
    // trail — that's for live positions only.
    final last = await LocationService.lastKnown();
    if (!mounted) return;
    if (last != null) _onPosition(last, recenter: true, record: false);

    try {
      final pos = await LocationService.current();
      // The fix above can take several seconds; the user may have left the
      // screen meanwhile. Bail before touching state or the map controller.
      if (!mounted) return;
      // Only recentre if we haven't already snapped to the cached fix, so we
      // don't yank the map from under a user who's started panning.
      _onPosition(pos, recenter: _me == null);
      _publish(pos); // one share on first fix so contacts aren't left blank

      _posSub = LocationService.stream().listen((p) => _onPosition(p));
      // Publish on a FIXED cadence, not per movement. The map tracks our own
      // position live and locally, but shares go out every 30s whether we're
      // moving or standing still — so the server can't read our movement /
      // activity timing off the share update times (a metadata side-channel).
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        if (_lastPos != null) _publish(_lastPos!);
        // Staleness is time-based, so re-evaluate on a timer (not just on
        // incoming shares) to catch a contact who simply stopped sharing.
        unawaited(_checkStale());
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // If a cached fix already put us on the map, keep showing it rather
        // than replacing the whole screen with an error card.
        if (_me == null) _error = e.toString();
      });
    }
  }

  void _onPosition(Position p, {bool recenter = false, bool record = true}) {
    _lastPos = p;
    // Record my own trail (sampled; the geofence monitor flushes periodically).
    final me = AuthService.currentUser;
    if (record && me != null) {
      HistoryService.record(
        subject: me.id,
        lat: p.latitude,
        lng: p.longitude,
        ts: DateTime.now().toUtc(),
        accuracy: p.accuracy,
      );
    }
    if (!mounted) return; // moving a disposed MapController throws
    setState(() => _me = LatLng(p.latitude, p.longitude));
    if (recenter) _map.move(_me!, 14);
    // Note: no publish here. Shares go out on a fixed 30s cadence (the
    // heartbeat), not per movement, so the server can't infer our movement /
    // activity timing from share-update times. The first fix is shared once in
    // _start().
  }

  Future<void> _publish(Position p) async {
    try {
      await LocationSharingService.publish(
          lat: p.latitude, lng: p.longitude, accuracy: p.accuracy);
    } catch (_) {/* offline / no contacts — fine */}
  }

  /// Fire a one-off local notification when a contact crosses into "stale"
  /// (stopped sharing for a while), and re-arm once they're fresh again. The
  /// edge-trigger state is the shared, persisted [StaleAlertStore] — the same
  /// one the background isolate uses — so the two never double-fire, and a
  /// contact already alerted about stays quiet across a restart. The first pass
  /// seeds the baseline (contacts already quiet on open don't alert). Silent
  /// when the user has turned activity alerts off.
  Future<void> _checkStale() async {
    if (!await Prefs.activityAlerts()) return;
    // Snapshot now — the async gaps below mean _contacts could change under us.
    final updatedById = {
      for (final e in _contacts.entries) e.key: e.value.updated,
    };
    final names = {for (final e in _contacts.entries) e.key: e.value.name};
    final toNotify = await StaleAlertStore.evaluate(
      updatedById: updatedById,
      now: DateTime.now(),
    );
    for (final id in toNotify) {
      final name = names[id] ?? 'A contact';
      await NotificationService.show(
        id: NotificationService.idFor('stale:$id'),
        title: 'Contact went quiet',
        body: "$name hasn't shared their location in a while.",
      );
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _heartbeat?.cancel();
    _unsub?.call();
    super.dispose();
  }

  // Presence: colour + label from how long ago a contact last shared.
  static (Color, String) _presence(DateTime updated) {
    final age = DateTime.now().difference(updated);
    if (age.inMinutes < 2) return (Colors.green, 'live');
    if (age.inMinutes < 15) return (Colors.amber, '${age.inMinutes}m ago');
    if (age.inHours < 24) {
      return (Colors.orange, '${age.inHours}h ago');
    }
    return (Colors.grey, '${age.inDays}d ago');
  }

  /// My places drawn as soft lichen circles at their true radius.
  List<CircleMarker> _placeCircles() => [
        for (final p in _places)
          CircleMarker(
            point: LatLng(p.lat, p.lng),
            radius: p.radiusMeters,
            useRadiusInMeter: true,
            color: Brand.lichen.withValues(alpha: 0.12),
            borderColor: Brand.lichen.withValues(alpha: 0.7),
            borderStrokeWidth: 1.5,
          ),
      ];

  /// A small name label at the centre of each place.
  List<Marker> _placeMarkers() => [
        for (final p in _places)
          Marker(
            point: LatLng(p.lat, p.lng),
            width: 120,
            height: 22,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.place, size: 13, color: Brand.lichen),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(p.name,
                      style: const TextStyle(
                          fontSize: 11,
                          color: Brand.slate,
                          fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
      ];

  /// Pins contacts have shared with me — a distinct bookmark marker with the
  /// sharer + pin name (e.g. "Alice · Grand Hotel").
  List<Marker> _sharedPinMarkers() => [
        for (final p in _sharedPins)
          Marker(
            point: LatLng(p.lat, p.lng),
            width: 200,
            height: 60,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [
                      BoxShadow(
                          blurRadius: 4,
                          color: Colors.black26,
                          offset: Offset(0, 1)),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.push_pin, size: 13, color: Brand.lichen),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          p.sharerName.isEmpty
                              ? p.name
                              : '${p.sharerName} · ${p.name}',
                          style: const TextStyle(
                              fontSize: 11,
                              color: Brand.slate,
                              fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.push_pin, color: Brand.lichen, size: 26, shadows: [
                  Shadow(blurRadius: 3, color: Colors.black45, offset: Offset(0, 1)),
                ]),
              ],
            ),
          ),
      ];

  List<Marker> _markers() {
    final markers = <Marker>[];
    for (final c in _contacts.values) {
      final (color, presenceLabel) = _presence(c.updated);
      // Where they are: a status THEY broadcast ("Hotel") wins; otherwise, if
      // they're inside one of MY places, note that ("at Home").
      final at = PlacesService.placeContaining(_places, c.lat, c.lng);
      final where = c.label ?? (at != null ? 'at ${at.name}' : null);
      final label =
          where != null ? '$presenceLabel · $where' : presenceLabel;
      markers.add(Marker(
        point: LatLng(c.lat, c.lng),
        width: 190,
        height: 76,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Name + freshness chip, on-brand: slate text on a soft card.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(blurRadius: 4, color: Colors.black26, offset: Offset(0, 1)),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A small dot echoes the pin colour → ties chip to marker.
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  Flexible(
                    child: Text('${c.name} · $label',
                        style: const TextStyle(
                            fontSize: 11,
                            color: Brand.slate,
                            fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            // Teardrop pin with a white halo so it reads on the pale basemap.
            Icon(Icons.location_on, color: color, size: 36, shadows: const [
              Shadow(blurRadius: 3, color: Colors.black45, offset: Offset(0, 1)),
            ]),
          ],
        ),
      ));
    }
    if (_me != null) {
      markers.add(Marker(
        point: _me!,
        width: 28,
        height: 28,
        child: _meDot(),
      ));
    }
    return markers;
  }

  /// This device's own position: a slate dot with a white ring — a calm,
  /// on-brand take on the familiar "you are here" marker.
  Widget _meDot() => Container(
        decoration: BoxDecoration(
          color: Brand.slate,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [
            BoxShadow(blurRadius: 4, color: Colors.black38, offset: Offset(0, 1)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Map · ${_contacts.length} sharing'),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _me ?? _fallback,
              initialZoom: _me == null ? 3 : 14,
            ),
            children: [
              // A muted, minimal light-grey basemap (Esri "Light Gray Canvas")
              // — calmer and far less visually loud than raw OSM tiles, so
              // contacts' pins are what stands out. This layer already carries
              // its own place labels. Key-less; for a fully self-hosted stack,
              // point this at your own tile server instead.
              TileLayer(
                urlTemplate:
                    'https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}',
                userAgentPackageName: 'uk.cappylabs.cairn',
                maxNativeZoom: 16,
              ),
              CircleLayer(circles: _placeCircles()),
              MarkerLayer(markers: _placeMarkers()),
              MarkerLayer(markers: _sharedPinMarkers()),
              MarkerLayer(markers: _markers()),
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© Esri'),
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
          // Non-blocking "locating" chip: the map (basemap + contacts) stays
          // visible and interactive while we acquire our own precise fix,
          // rather than a full-screen spinner hiding everything.
          if (_me == null && _error == null)
            const SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: _LocatingChip(),
                ),
              ),
            ),
          if (_error != null)
            Center(
              child: Card(
                margin: const EdgeInsets.all(24),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_disabled, size: 40),
                      const SizedBox(height: 8),
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 4),
                      const Text(
                        "You can still see contacts below; sharing your own "
                        "location needs permission.",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() => _error = null);
                          _start();
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: _me == null
          ? null
          : FloatingActionButton(
              tooltip: 'Centre on me',
              onPressed: () => _map.move(_me!, 15),
              child: const Icon(Icons.my_location),
            ),
    );
  }
}

/// A small, unobtrusive pill shown while we're still acquiring this device's
/// own fix. Unlike a full-screen spinner it leaves the map (basemap and
/// contacts) visible and interactive underneath.
class _LocatingChip extends StatelessWidget {
  const _LocatingChip();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 2,
      borderRadius: BorderRadius.circular(20),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Brand.lichen),
            ),
            SizedBox(width: 8),
            Text('Finding your location…',
                style: TextStyle(
                    fontSize: 12,
                    color: Brand.slate,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
