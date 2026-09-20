import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/auth_service.dart';
import '../services/history_service.dart';
import '../services/nickname_service.dart';
import '../services/pairing_service.dart';
import '../services/places_service.dart';
import '../theme/brand.dart';

/// A person whose history I can view: me, or a paired contact.
class _Subject {
  final String id;
  final String name;
  const _Subject(this.id, this.name);
}

/// History & trips: pick a person and a day to see where they've been — the
/// breadcrumb path on the map, a scrubbable timeline, and the trips they took
/// between your places. All from locations already end-to-end encrypted to me.
class HistoryScreen extends StatefulWidget {
  /// Optionally open straight to a given subject (e.g. from a contact tile).
  final String? initialSubjectId;
  const HistoryScreen({super.key, this.initialSubjectId});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _map = MapController();

  List<_Subject> _subjects = [];
  List<Place> _places = [];
  String? _subjectId;
  List<String> _days = [];
  String? _day;

  List<HistoryPoint> _points = [];
  List<Trip> _trips = [];
  int _scrub = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _places = await _safe(PlacesService.list(), <Place>[]);
    // Build the subject list: me first, then contacts (nickname-resolved).
    final me = AuthService.currentUser;
    final subjects = <_Subject>[];
    if (me != null) {
      subjects.add(_Subject(me.id, 'You'));
    }
    try {
      final nicks = await NicknameService.all();
      for (final c in await PairingService.myContacts()) {
        final peerId = c.getStringValue('peer');
        final name = NicknameService.resolveName(
          alias: nicks[peerId],
          peerName:
              await PairingService.decryptName(c.getStringValue('peer_name')),
        );
        subjects.add(_Subject(peerId, name));
      }
    } catch (_) {}

    _subjects = subjects;
    _subjectId = widget.initialSubjectId ??
        (subjects.isNotEmpty ? subjects.first.id : null);
    if (mounted) setState(() {});
    await _loadDaysThenLatest();
  }

  Future<T> _safe<T>(Future<T> f, T fallback) async {
    try {
      return await f;
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _loadDaysThenLatest() async {
    if (_subjectId == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    _days = await _safe(HistoryService.availableDays(_subjectId!), <String>[]);
    _day = _days.isNotEmpty ? _days.first : null;
    await _loadDay();
  }

  Future<void> _loadDay() async {
    setState(() => _loading = true);
    final pts = _day == null
        ? <HistoryPoint>[]
        : await _safe(HistoryService.loadDay(_subjectId!, _day!), <HistoryPoint>[]);
    final trips = HistoryService.tripsFromPoints(pts, _places);
    if (!mounted) return;
    setState(() {
      _points = pts;
      _trips = trips;
      _scrub = pts.isEmpty ? 0 : pts.length - 1;
      _loading = false;
    });
    _fitToPoints();
  }

  void _fitToPoints() {
    if (_points.isEmpty) return;
    final coords = [for (final p in _points) LatLng(p.lat, p.lng)];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (coords.length == 1) {
          _map.move(coords.first, 15);
        } else {
          _map.fitCamera(CameraFit.coordinates(
            coordinates: coords,
            padding: const EdgeInsets.all(48),
          ));
        }
      } catch (_) {}
    });
  }

  // ---- formatting helpers ----
  static String _hm(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  static String _dist(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(1)} km'
      : '${m.round()} m';

  static String _dur(Duration d) {
    if (d.inMinutes < 1) return '<1 min';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          if (_subjectId != null && _days.isNotEmpty)
            IconButton(
              tooltip: 'Clear this person\'s history',
              icon: const Icon(Icons.delete_outline),
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: Column(
        children: [
          _selectors(),
          Expanded(child: _mapArea()),
          if (_points.length > 1) _scrubber(),
          Expanded(child: _tripsList()),
        ],
      ),
    );
  }

  Widget _selectors() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _subjectId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Person',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: [
                  for (final s in _subjects)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) {
                  if (v == null || v == _subjectId) return;
                  setState(() => _subjectId = v);
                  _loadDaysThenLatest();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _day,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Day',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: [
                  for (final d in _days)
                    DropdownMenuItem(value: d, child: Text(d)),
                ],
                onChanged: (v) {
                  if (v == null || v == _day) return;
                  setState(() => _day = v);
                  _loadDay();
                },
              ),
            ),
          ],
        ),
      );

  Widget _mapArea() {
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: const MapOptions(
            initialCenter: LatLng(51.5074, -0.1278),
            initialZoom: 12,
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}',
              userAgentPackageName: 'uk.cappylabs.cairn',
              maxNativeZoom: 16,
            ),
            // My places for context.
            CircleLayer(circles: [
              for (final p in _places)
                CircleMarker(
                  point: LatLng(p.lat, p.lng),
                  radius: p.radiusMeters,
                  useRadiusInMeter: true,
                  color: Brand.lichen.withValues(alpha: 0.10),
                  borderColor: Brand.lichen.withValues(alpha: 0.6),
                  borderStrokeWidth: 1,
                ),
            ]),
            if (_points.length > 1)
              PolylineLayer(polylines: [
                Polyline(
                  points: [for (final p in _points) LatLng(p.lat, p.lng)],
                  strokeWidth: 4,
                  color: Brand.slate.withValues(alpha: 0.7),
                ),
              ]),
            MarkerLayer(markers: _mapMarkers()),
          ],
        ),
        if (_loading) const Center(child: CircularProgressIndicator()),
        if (!_loading && _points.isEmpty)
          Center(
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _days.isEmpty
                      ? 'No history recorded yet.\nOpen the map or turn on '
                          'background sharing to start building a trail.'
                      : 'No points for this day.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Brand.stone),
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Marker> _mapMarkers() {
    final markers = <Marker>[];
    if (_points.isEmpty) return markers;
    // Start (green) and end (red) of the day's trail.
    markers.add(_dot(_points.first, Colors.green, 'Start'));
    markers.add(_dot(_points.last, Colors.redAccent, 'End'));
    // The scrubber's current position.
    if (_scrub >= 0 && _scrub < _points.length) {
      final p = _points[_scrub];
      markers.add(Marker(
        point: LatLng(p.lat, p.lng),
        width: 120,
        height: 46,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(blurRadius: 3, color: Colors.black26)
                ],
              ),
              child: Text(_hm(p.t),
                  style: const TextStyle(
                      fontSize: 11,
                      color: Brand.slate,
                      fontWeight: FontWeight.w600)),
            ),
            const Icon(Icons.circle, size: 14, color: Brand.slate),
          ],
        ),
      ));
    }
    return markers;
  }

  Marker _dot(HistoryPoint p, Color color, String label) => Marker(
        point: LatLng(p.lat, p.lng),
        width: 18,
        height: 18,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      );

  Widget _scrubber() {
    final p = _points[_scrub.clamp(0, _points.length - 1)];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(_hm(_points.first.t),
              style: const TextStyle(fontSize: 11, color: Brand.stone)),
          Expanded(
            child: Slider(
              value: _scrub.toDouble(),
              min: 0,
              max: (_points.length - 1).toDouble(),
              label: _hm(p.t),
              onChanged: (v) {
                setState(() => _scrub = v.round());
                try {
                  _map.move(LatLng(p.lat, p.lng), _map.camera.zoom);
                } catch (_) {}
              },
            ),
          ),
          Text(_hm(_points.last.t),
              style: const TextStyle(fontSize: 11, color: Brand.stone)),
        ],
      ),
    );
  }

  Widget _tripsList() {
    if (_loading) return const SizedBox.shrink();
    if (_trips.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No trips between your places on this day.\n'
            'Add places (Home, Work…) to see trips here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Brand.stone, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _trips.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = _trips[i];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.route, color: Brand.lichen),
          title: Text('${t.fromLabel} → ${t.toLabel}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
              '${_hm(t.start)}–${_hm(t.end)} · ${_dist(t.distanceMeters)} · ${_dur(t.duration)}'),
          onTap: () => _focusTrip(t),
        );
      },
    );
  }

  void _focusTrip(Trip t) {
    // Snap the scrubber to the trip's start and frame its path.
    final startIdx = _points.indexWhere((p) => !p.t.isBefore(t.start));
    if (startIdx >= 0) setState(() => _scrub = startIdx);
    final coords = [for (final p in t.path) LatLng(p.lat, p.lng)];
    if (coords.isEmpty) return;
    try {
      if (coords.length == 1) {
        _map.move(coords.first, 15);
      } else {
        _map.fitCamera(CameraFit.coordinates(
            coordinates: coords, padding: const EdgeInsets.all(60)));
      }
    } catch (_) {}
  }

  Future<void> _confirmClear() async {
    final subject = _subjects.firstWhere((s) => s.id == _subjectId,
        orElse: () => const _Subject('', 'this person'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear ${subject.name}\'s history?'),
        content: const Text(
            'This deletes every recorded day for this person from all your '
            'devices. It can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true || _subjectId == null) return;
    await HistoryService.deleteSubject(_subjectId!);
    await _loadDaysThenLatest();
  }
}
