import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/geofence_monitor.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import '../services/places_service.dart';
import '../services/shared_places_service.dart';
import '../widgets/contact_picker.dart';
import '../theme/brand.dart';
import 'shared_pins_screen.dart';

/// Manage my places (Home, Work…). Places sync (encrypted-to-self) and drive the
/// on-device arrive/leave alerts for contacts. The server can't read them.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key});

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  List<Place> _places = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final places = await PlacesService.list();
      if (mounted) setState(() { _places = places; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    // Keep the running monitor's cache in step with any change.
    await GeofenceMonitor.instance.refreshPlaces();
  }

  Future<void> _edit([Place? place]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PlaceEditorScreen(place: place)),
    );
    if (saved == true) await _load();
  }

  /// Share a place as a pin to selected contacts (encrypted per recipient).
  Future<void> _sharePlace(Place p) async {
    final recipients =
        await pickShareRecipients(context, title: 'Share "${p.name}" with…');
    if (recipients == null || recipients.isEmpty || !mounted) return;
    try {
      await SharedPlacesService.share(
          name: p.name, lat: p.lat, lng: p.lng, recipients: recipients);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Shared "${p.name}" with ${recipients.length} contact${recipients.length == 1 ? '' : 's'}.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't share: $e")));
      }
    }
  }

  Future<void> _delete(Place p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${p.name}"?'),
        content: const Text(
            'This place and its arrive/leave alerts will be removed from all '
            'your devices.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await PlacesService.delete(p.id);
    await _load();
  }

  String _radiusLabel(double m) =>
      m >= 1000 ? '${(m / 1000).toStringAsFixed(m % 1000 == 0 ? 0 : 1)} km' : '${m.round()} m';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Places'),
        actions: [
          IconButton(
            tooltip: 'Shared pins',
            icon: const Icon(Icons.ios_share),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SharedPinsScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Add place'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _places.isEmpty
              ? _empty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
                        child: Text(
                          'Get an alert when a contact arrives at or leaves a '
                          'place. Places stay end-to-end encrypted — only you '
                          'can see them.',
                          style: TextStyle(color: context.cairn.muted, fontSize: 13),
                        ),
                      ),
                      ..._places.map(_tile),
                    ],
                  ),
                ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.place_outlined, size: 48),
              const SizedBox(height: 12),
              Text(
                'No places yet.\nAdd Home or Work to get arrive/leave alerts '
                'for your contacts.',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.cairn.muted),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Add a place'),
              ),
            ],
          ),
        ),
      );

  Widget _tile(Place p) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: context.cairn.outline,
            child: Icon(Icons.place, color: context.cairn.ink),
          ),
          title: Text(p.name),
          subtitle: Text(
            '${_radiusLabel(p.radiusMeters)} radius · '
            '${p.alerts ? 'alerts on' : 'alerts off'}',
          ),
          onTap: () => _edit(p),
          trailing: PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'edit' => _edit(p),
              'share' => _sharePlace(p),
              _ => _delete(p),
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                      leading: Icon(Icons.edit), title: Text('Edit'))),
              PopupMenuItem(
                  value: 'share',
                  child: ListTile(
                      leading: Icon(Icons.ios_share),
                      title: Text('Share with contacts'))),
              PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Delete'))),
            ],
          ),
        ),
      );
}

/// Add or edit a single place: pan the map so the pin sits over the spot, name
/// it, set the radius, and choose whether it raises alerts.
class PlaceEditorScreen extends StatefulWidget {
  final Place? place;
  /// For a NEW place, the point to start centred on (e.g. a spot long-pressed
  /// on the map). Ignored when editing an existing [place].
  final LatLng? initialCenter;
  const PlaceEditorScreen({super.key, this.place, this.initialCenter});

  @override
  State<PlaceEditorScreen> createState() => _PlaceEditorScreenState();
}

class _PlaceEditorScreenState extends State<PlaceEditorScreen> {
  static const _fallback = LatLng(51.5074, -0.1278);
  final _map = MapController();
  final _nameCtl = TextEditingController();

  late LatLng _center;
  double _radius = Place.defaultRadius;
  bool _alerts = true;
  bool _shareLabel = false;
  bool _saving = false;

  bool get _isEdit => widget.place != null;

  @override
  void initState() {
    super.initState();
    final p = widget.place;
    if (p != null) {
      _nameCtl.text = p.name;
      _center = LatLng(p.lat, p.lng);
      _radius = p.radiusMeters;
      _alerts = p.alerts;
      _shareLabel = p.shareLabel;
    } else if (widget.initialCenter != null) {
      // A spot the user picked on the map — start there, don't chase GPS.
      _center = widget.initialCenter!;
    } else {
      _center = _fallback;
      _useMyLocation(recenter: true); // start on the user where possible
    }
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  Future<void> _useMyLocation({bool recenter = false}) async {
    try {
      final pos = await LocationService.current();
      if (!mounted) return;
      setState(() => _center = LatLng(pos.latitude, pos.longitude));
      _map.move(_center, 16);
    } catch (_) {
      if (recenter) _map.move(_center, 13); // fall back to the default view
    }
  }

  Future<void> _save() async {
    final name = _nameCtl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Give the place a name.')));
      return;
    }
    setState(() => _saving = true);
    final place = (widget.place ??
            Place(id: '', name: name, lat: _center.latitude, lng: _center.longitude))
        .copyWith(
      name: name,
      lat: _center.latitude,
      lng: _center.longitude,
      radiusMeters: _radius,
      alerts: _alerts,
      shareLabel: _shareLabel,
    );
    try {
      if (_isEdit) {
        await PlacesService.update(place);
      } else {
        await PlacesService.create(place);
      }
      // So alerts can actually show — init also requests the notification
      // permission (Android 13+/iOS), which the user may not have granted yet.
      if (_alerts) await NotificationService.requestPermission();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit place' : 'New place'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: _center,
                    initialZoom: 16,
                    // The map pans under a fixed centre pin; the place sits
                    // wherever the pin points when saved.
                    onPositionChanged: (camera, _) {
                      setState(() => _center = camera.center);
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          Brand.basemapUrl(context),
                      userAgentPackageName: 'uk.cappylabs.cairn',
                      maxNativeZoom: 16,
                    ),
                    CircleLayer(circles: [
                      CircleMarker(
                        point: _center,
                        radius: _radius,
                        useRadiusInMeter: true,
                        color: Brand.lichen.withValues(alpha: 0.18),
                        borderColor: Brand.lichen,
                        borderStrokeWidth: 2,
                      ),
                    ]),
                  ],
                ),
                // Fixed centre pin (sits above the map, marks the chosen point).
                const IgnorePointer(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 34),
                    child: Icon(Icons.place,
                        size: 40,
                        color: Brand.slate,
                        shadows: [
                          Shadow(blurRadius: 3, color: Colors.black45, offset: Offset(0, 1))
                        ]),
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'myloc',
                    tooltip: 'Use current location',
                    onPressed: () => _useMyLocation(),
                    child: const Icon(Icons.my_location),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: _nameCtl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g. Home, Work, School',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.social_distance, size: 20),
                      const SizedBox(width: 8),
                      Text('Radius: ${_radius.round()} m',
                          style: const TextStyle(fontWeight: FontWeight.w500)),
                    ],
                  ),
                  Slider(
                    value: _radius,
                    min: 50,
                    max: 1000,
                    divisions: 19,
                    label: '${_radius.round()} m',
                    onChanged: (v) => setState(() => _radius = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _alerts,
                    onChanged: (v) => setState(() => _alerts = v),
                    secondary: const Icon(Icons.notifications_active_outlined),
                    title: const Text('Alert me about contacts'),
                    subtitle: const Text(
                        'Notify when a contact arrives here or leaves.',
                        style: TextStyle(fontSize: 12)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _shareLabel,
                    onChanged: (v) => setState(() => _shareLabel = v),
                    secondary: const Icon(Icons.label_outline),
                    title: const Text('Show name to contacts when I\'m here'),
                    subtitle: const Text(
                        'Contacts see e.g. "at Home" on your pin while you\'re '
                        'inside this place. The place itself stays private.',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
