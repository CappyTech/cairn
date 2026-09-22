import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui; // latlong2 also exports a `Path`; disambiguate the UI one
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pocketbase/pocketbase.dart';
import '../services/auth_service.dart';
import '../services/background_share.dart';
import '../services/history_service.dart';
import '../services/location_service.dart';
import '../services/location_sharing_service.dart';
import '../services/nickname_service.dart';
import '../services/notification_service.dart';
import '../services/pairing_service.dart';
import '../services/places_service.dart';
import '../services/prefs.dart';
import '../services/presence.dart';
import '../services/shared_places_service.dart';
import '../services/stale_alert_store.dart';
import '../widgets/background_share_ux.dart';
import '../widgets/contact_picker.dart';
import '../theme/brand.dart';
import 'history_screen.dart';
import 'places_screen.dart';

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
  double? _heading; // GPS course to point my direction cone at; null = hide it
  bool _follow = false; // keep the map centred on me as I move
  Map<String, ContactLocation> _contacts = {};
  List<Place> _places = [];
  List<SharedPin> _sharedPins = [];
  String? _error;
  bool _loading = true;

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
        unawaited(_checkStale());
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
    // Record my own trail (sampled; the geofence monitor flushes periodically).
    final me = AuthService.currentUser;
    if (me != null) {
      HistoryService.record(
        subject: me.id,
        lat: p.latitude,
        lng: p.longitude,
        ts: DateTime.now().toUtc(),
        accuracy: p.accuracy,
      );
    }
    if (!mounted) return; // moving a disposed MapController throws
    setState(() {
      _me = LatLng(p.latitude, p.longitude);
      _heading = coneHeading(speed: p.speed, heading: p.heading);
    });
    if (recenter) {
      _map.move(_me!, 14);
    } else if (_follow) {
      // Follow mode: keep me centred as I move, without changing zoom.
      _map.move(_me!, _map.camera.zoom);
    }
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

  // Marker colour for a contact's freshness. The bands + label live in the
  // shared Presence.describe (used by the contacts list too); this only maps
  // its level to a pin colour, so the map and the list can't drift apart.
  static Color _presenceColor(PresenceLevel level) => switch (level) {
        PresenceLevel.live => Colors.green,
        PresenceLevel.recent => Colors.amber,
        PresenceLevel.stale => Colors.orange,
        PresenceLevel.old => Colors.grey,
        PresenceLevel.never => Colors.grey,
      };

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
      final pres = Presence.describe(updated: c.updated, now: DateTime.now());
      final color = _presenceColor(pres.level);
      final presenceLabel = pres.label;
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
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openContactSheet(c),
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
        ),
      ));
    }
    if (_me != null) {
      markers.add(Marker(
        point: _me!,
        // Roomy enough for the direction cone to fan out around the dot; the
        // dot stays centred on the point (default centre alignment).
        width: 56,
        height: 56,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _openMeSheet,
          child: _meMarker(),
        ),
      ));
    }
    return markers;
  }

  /// This device's own position: the dot, plus a direction cone fanning out in
  /// the way I'm heading when there's a live GPS course (i.e. while moving).
  Widget _meMarker() {
    final heading = _heading;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (heading != null)
          Transform.rotate(
            // GPS heading is degrees clockwise from north; the cone is drawn
            // pointing up (north), so rotating it clockwise by the heading
            // aims it correctly on this north-up map.
            angle: heading * math.pi / 180,
            child: const CustomPaint(
              size: Size(56, 56),
              painter: _HeadingConePainter(),
            ),
          ),
        _meDot(),
      ],
    );
  }

  /// This device's own position: a slate dot with a white ring — a calm,
  /// on-brand take on the familiar "you are here" marker.
  Widget _meDot() => Container(
        width: 22,
        height: 22,
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
              onLongPress: (_, point) => _onLongPress(point),
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
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Follow: keep the map on me as I move (pairs with the heading
                // cone). Highlighted when on.
                FloatingActionButton.small(
                  heroTag: 'follow',
                  tooltip: _follow ? 'Stop following' : 'Follow me',
                  backgroundColor: _follow ? Brand.slate : null,
                  foregroundColor: _follow ? Colors.white : null,
                  onPressed: _toggleFollow,
                  child: Icon(_follow ? Icons.navigation : Icons.navigation_outlined),
                ),
                const SizedBox(height: 8),
                // Frame me + everyone currently sharing.
                if (_contacts.isNotEmpty)
                  FloatingActionButton.small(
                    heroTag: 'fit',
                    tooltip: 'Fit everyone',
                    onPressed: _fitEveryone,
                    child: const Icon(Icons.zoom_out_map),
                  ),
                if (_contacts.isNotEmpty) const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'centre',
                  tooltip: 'Centre on me',
                  onPressed: () => _map.move(_me!, 15),
                  child: const Icon(Icons.my_location),
                ),
              ],
            ),
    );
  }

  void _toggleFollow() {
    setState(() => _follow = !_follow);
    if (_follow && _me != null) _map.move(_me!, _map.camera.zoom);
  }

  /// Frame me + every sharing contact on screen.
  void _fitEveryone() {
    final targets = fitTargets(
      me: _me,
      contacts: [for (final c in _contacts.values) LatLng(c.lat, c.lng)],
    );
    if (targets.isEmpty) return;
    if (targets.length == 1) {
      _map.move(targets.first, 15);
      return;
    }
    _map.fitCamera(CameraFit.coordinates(
      coordinates: targets,
      padding: const EdgeInsets.all(64),
      maxZoom: 16,
    ));
  }

  /// Long-press on the map: offer to add a place or share a pin at that point.
  Future<void> _onLongPress(LatLng point) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_location_alt),
              title: const Text('Add a place here'),
              subtitle: const Text('A private geofence for arrive/leave alerts.'),
              onTap: () => Navigator.pop(ctx, 'place'),
            ),
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: const Text('Share a pin here'),
              subtitle: const Text('Send this spot to chosen contacts.'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'place') {
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => PlaceEditorScreen(initialCenter: point)),
      );
      if (saved == true) await _loadPlaces();
    } else if (choice == 'pin') {
      await _sharePinAt(point);
    }
  }

  /// Share a one-off pin at [point] with selected contacts (encrypted per
  /// recipient; the server can't read the name or coordinates).
  Future<void> _sharePinAt(LatLng point) async {
    final nameCtl = TextEditingController(text: 'Pin');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this pin'),
        content: TextField(
          controller: nameCtl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              hintText: 'e.g. Meet here, My hotel',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, nameCtl.text.trim()),
              child: const Text('Next')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;

    if (!mounted) return;
    final recipients =
        await pickShareRecipients(context, title: 'Share "$name" with…');
    if (recipients == null || recipients.isEmpty || !mounted) return;
    try {
      await SharedPlacesService.share(
        name: name,
        lat: point.latitude,
        lng: point.longitude,
        recipients: recipients,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Shared "$name" with ${recipients.length} contact${recipients.length == 1 ? '' : 's'}.')));
      }
      await _loadPlaces(); // refresh my own shared-pin markers
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't share: $e")));
      }
    }
  }

  /// Tap a contact pin → a sheet with their freshness, where they are, distance,
  /// and the per-contact controls (precision / pause, rename, history).
  Future<void> _openContactSheet(ContactLocation c) async {
    RecordModel? rec;
    try {
      for (final r in await PairingService.myContacts()) {
        if (r.getStringValue('peer') == c.senderId) {
          rec = r;
          break;
        }
      }
    } catch (_) {/* offline — the sheet still shows position info */}
    if (!mounted) return;

    final at = PlacesService.placeContaining(_places, c.lat, c.lng);
    final where = c.label ?? (at != null ? 'at ${at.name}' : null);
    final distance = _me == null
        ? null
        : PlacesService.distanceMeters(
            _me!.latitude, _me!.longitude, c.lat, c.lng);
    var name = c.name;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final pres = Presence.describe(updated: c.updated, now: DateTime.now());
          final precision = rec?.getStringValue('precision') ?? 'precise';
          final keyChanged = rec?.getStringValue('status') == 'key_changed';
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                          color: _presenceColor(pres.level),
                          shape: BoxShape.circle),
                    ),
                    Expanded(
                      child: Text(name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    [
                      pres.label,
                      ?where,
                      if (distance != null) _formatDistance(distance),
                      if (c.approximate) 'approximate',
                    ].join(' · '),
                    style: const TextStyle(color: Brand.stone, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  if (keyChanged)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        "This contact's security key changed — re-scan in "
                        'person to confirm before sharing resumes.',
                        style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error,
                            fontSize: 12),
                      ),
                    ),
                  const Text('How precisely I share with them',
                      style: TextStyle(fontSize: 12, color: Brand.stone)),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'precise',
                          label: Text('Precise'),
                          icon: Icon(Icons.gps_fixed, size: 16)),
                      ButtonSegment(
                          value: 'approximate',
                          label: Text('~1 km'),
                          icon: Icon(Icons.blur_on, size: 16)),
                      ButtonSegment(
                          value: 'off',
                          label: Text('Paused'),
                          icon: Icon(Icons.pause, size: 16)),
                    ],
                    selected: {precision},
                    onSelectionChanged: rec == null
                        ? null
                        : (s) async {
                            await PairingService.setPrecision(
                                rec!.id, c.senderId, s.first);
                            rec!.set('precision', s.first);
                            setSheet(() {});
                          },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final newName = await _renamePrompt(name);
                            if (newName == null) return;
                            await NicknameService.set(c.senderId, newName);
                            if (ctx.mounted) {
                              setSheet(() => name =
                                  newName.isEmpty ? c.name : newName);
                            }
                          },
                          icon: const Icon(Icons.drive_file_rename_outline),
                          label: const Text('Rename'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => HistoryScreen(
                                        initialSubjectId: c.senderId)));
                          },
                          icon: const Icon(Icons.timeline),
                          label: const Text('History'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Tap my own dot → a sheet to set my broadcast status and toggle background
  /// sharing, without leaving the map.
  Future<void> _openMeSheet() async {
    var status = await Prefs.sharedStatus() ?? '';
    var bgEnabled = _bgSupported ? await BackgroundShare.isEnabled() : false;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('You',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.label_outline),
                  title: const Text('Status'),
                  subtitle: Text(
                    status.isEmpty
                        ? 'Off — set a label contacts see by your pin.'
                        : 'Contacts see: "$status"',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Icon(
                      status.isEmpty ? Icons.edit_outlined : Icons.close),
                  onTap: () async {
                    if (status.isNotEmpty) {
                      await Prefs.setSharedStatus('');
                      setSheet(() => status = '');
                      return;
                    }
                    final v = await _statusPrompt(status);
                    if (v == null) return;
                    await Prefs.setSharedStatus(v);
                    if (ctx.mounted) setSheet(() => status = v.trim());
                  },
                ),
                if (_bgSupported)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: bgEnabled,
                    secondary: const Icon(Icons.share_location),
                    title: const Text('Share in the background'),
                    subtitle: Text(
                      bgEnabled
                          ? 'On — sharing continues when the app is closed.'
                          : 'Off — you only share while the app is open.',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onChanged: (on) async {
                      final now =
                          await BackgroundShareUx.toggle(ctx, on: on);
                      if (ctx.mounted) setSheet(() => bgEnabled = now);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _bgSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<String?> _renamePrompt(String current) {
    final ctl = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename contact'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'e.g. Mum, Work', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
  }

  Future<String?> _statusPrompt(String current) {
    final ctl = TextEditingController(text: current);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set status'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              hintText: "e.g. Hotel, Airport", border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
  }

  static String _formatDistance(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(m % 1000 < 100 ? 0 : 1)} km away'
      : '${m.round()} m away';
}

/// The points the "fit everyone" control should frame: me (when known) plus
/// every contact currently on the map. Empty when there's nothing to frame.
/// Pure and side-effect-free, so it's unit-tested without a map controller.
List<LatLng> fitTargets({LatLng? me, required Iterable<LatLng> contacts}) => [
      ?me,
      ...contacts,
    ];

/// The GPS course to draw my direction cone at, or null when we shouldn't show
/// one. The course from geolocator is course-over-ground, not a compass, so
/// it's only meaningful while actually moving; when still (or when the device
/// reports no fix on heading) it comes through as -1 / NaN or with ~zero
/// speed. Pure and side-effect-free, so the gate is unit-tested.
double? coneHeading({
  required double speed,
  required double heading,
  double minSpeed = 0.5, // m/s ≈ a slow walk
}) {
  if (speed.isNaN || speed < minSpeed) return null;
  if (heading.isNaN || heading < 0 || heading > 360) return null;
  return heading;
}

/// A soft wedge fanning "up" (north) from the centre, faded out at its far
/// edge — rotated by the caller to point along the heading. On-brand slate,
/// low alpha so it reads as a hint, not a hard shape.
class _HeadingConePainter extends CustomPainter {
  const _HeadingConePainter();

  static const _halfSpread = 35 * math.pi / 180; // 70° total fan

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    // Canvas angles are clockwise from the +x axis; straight up is -pi/2.
    const start = -math.pi / 2 - _halfSpread;
    const sweep = 2 * _halfSpread;
    final path = ui.Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(Rect.fromCircle(center: center, radius: radius), start, sweep, false)
      ..close();
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: [
          Brand.slate.withValues(alpha: 0.45),
          Brand.slate.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HeadingConePainter oldDelegate) => false;
}
