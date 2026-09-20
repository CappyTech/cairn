import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../services/location_service.dart';
import '../services/location_sharing_service.dart';
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

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // Receive contacts' locations regardless of our own GPS state.
    // (Guard so a Retry after a GPS error doesn't subscribe twice.)
    _unsub ??= await LocationSharingService.subscribe((map) {
      if (mounted) setState(() => _contacts = map);
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
        width: 140,
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
              MarkerLayer(markers: _markers()),
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© Esri'),
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
