import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../services/location_service.dart';
import '../services/location_sharing_service.dart';
import '../services/notification_service.dart';
import '../services/presence.dart';
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
  String? _error;
  bool _loading = true;

  StreamSubscription<Position>? _posSub;
  Future<void> Function()? _unsub;
  Timer? _heartbeat;

  // Peer ids we've already alerted about going quiet, so a still-offline
  // contact doesn't re-notify every tick. Cleared when they come back fresh.
  final Set<String> _staleNotified = {};
  // Skip the very first evaluation: contacts loaded already-stale on open
  // shouldn't fire an alert (you didn't just "lose" them this session).
  bool _presenceSeeded = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // Receive contacts' locations regardless of our own GPS state.
    // (Guard so a Retry after a GPS error doesn't subscribe twice.)
    _unsub ??= await LocationSharingService.subscribe((map) {
      if (!mounted) return;
      setState(() => _contacts = map);
      _checkStale();
    });

    try {
      final pos = await LocationService.current();
      // The fix above can take several seconds; the user may have left the
      // screen meanwhile. Bail before touching state or the map controller.
      if (!mounted) return;
      _onPosition(pos, recenter: true);
      _publish(pos); // one share on first fix so contacts aren't left blank
      setState(() => _loading = false);

      _posSub = LocationService.stream().listen((p) => _onPosition(p));
      // Publish on a FIXED cadence, not per movement. The map tracks our own
      // position live and locally, but shares go out every 30s whether we're
      // moving or standing still — so the server can't read our movement /
      // activity timing off the share update times (a metadata side-channel).
      _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
        if (_lastPos != null) _publish(_lastPos!);
        // Staleness is time-based, so re-evaluate on a timer (not just on
        // incoming shares) to catch a contact who simply stopped sharing.
        _checkStale();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _onPosition(Position p, {bool recenter = false}) {
    _lastPos = p;
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
  /// first pass seeds the baseline so contacts already quiet on open don't
  /// alert — only genuine transitions this session do.
  void _checkStale() {
    final now = DateTime.now();
    final updatedById = {
      for (final e in _contacts.entries) e.key: e.value.updated,
    };
    _staleNotified.removeAll(Presence.freshAgain(
      updatedById: updatedById,
      alreadyNotified: _staleNotified,
      now: now,
    ));
    final newly = Presence.newlyStale(
      updatedById: updatedById,
      alreadyNotified: _staleNotified,
      now: now,
    );
    _staleNotified.addAll(newly);
    if (!_presenceSeeded) {
      _presenceSeeded = true; // adopt current state as baseline, don't alert
      return;
    }
    for (final id in newly) {
      final name = _contacts[id]?.name ?? 'A contact';
      NotificationService.show(
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

  List<Marker> _markers() {
    final markers = <Marker>[];
    for (final c in _contacts.values) {
      final (color, label) = _presence(c.updated);
      markers.add(Marker(
        point: LatLng(c.lat, c.lng),
        width: 120,
        height: 70,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
              ),
              child: Text('${c.name} · $label',
                  style: const TextStyle(fontSize: 11),
                  overflow: TextOverflow.ellipsis),
            ),
            Icon(Icons.location_on, color: color, size: 34),
          ],
        ),
      ));
    }
    if (_me != null) {
      markers.add(Marker(
        point: _me!,
        width: 44,
        height: 44,
        child:
            const Icon(Icons.my_location, color: Brand.slate, size: 34),
      ));
    }
    return markers;
  }

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
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.my_app',
              ),
              MarkerLayer(markers: _markers()),
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
          if (_loading) const Center(child: CircularProgressIndicator()),
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
                          setState(() {
                            _error = null;
                            _loading = true;
                          });
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
