import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/auth_service.dart';
import '../services/history_policy.dart';
import '../services/history_service.dart';
import '../services/nickname_service.dart';
import '../services/pairing_service.dart';
import '../services/places_service.dart';
import '../services/prefs.dart';
import '../services/road_snap_service.dart';
import '../services/shared_places_service.dart';
import '../theme/brand.dart';
import 'places_screen.dart';

/// A person whose history I can view: me, or a paired contact.
class _Subject {
  final String id;
  final String name;
  const _Subject(this.id, this.name);
}

/// History: pick a person and a day to see where they've been — the day's
/// trips on the map (coloured by speed, with direction arrows and numbered
/// stops), a time scrubber, and a timeline of stays, trips and gaps in the
/// data. Tap a trip to focus it (and optionally snap it to roads). All from
/// locations already end-to-end encrypted to me.
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
  List<SharedPin> _pins = [];
  String? _subjectId;
  List<String> _days = [];
  String? _day;

  List<HistoryPoint> _points = [];
  List<TimelineEntry> _timeline = [];
  DateTime? _t; // the scrubber's time
  int? _selected; // index into _timeline of the focused trip (a Move)
  final Map<int, List<LatLng>> _snapped = {}; // road-snapped trips, by index
  bool _snapping = false;
  bool _loading = true;
  int _loadGen = 0; // drops a day's load that finished after a newer one

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _places = await _safe(PlacesService.list(), <Place>[]);
    // Shared pins (theirs and mine) name otherwise-unnamed stops.
    _pins = [
      ...await _safe(SharedPlacesService.sharedWithMe(), <SharedPin>[]),
      ...await _safe(SharedPlacesService.mineShared(), <SharedPin>[]),
    ];
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
    // Opened for a specific person (e.g. from the map's contact sheet) who
    // isn't in the list — contacts failed to load, or they've since unpaired:
    // still show their history rather than break the Person dropdown.
    final initial = widget.initialSubjectId;
    if (initial != null && !subjects.any((s) => s.id == initial)) {
      subjects.add(_Subject(initial, 'Contact'));
    }
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
    final gen = ++_loadGen;
    setState(() => _loading = true);
    final raw = _day == null
        ? <HistoryPoint>[]
        : await _safe(HistoryService.loadDay(_subjectId!, _day!), <HistoryPoint>[]);
    if (!mounted || gen != _loadGen) return;
    final pts = HistoryTimeline.usable(raw);
    setState(() {
      _points = pts;
      _timeline = HistoryTimeline.build(pts, _places);
      _t = pts.isEmpty ? null : pts.last.t;
      _selected = null;
      _snapped.clear();
      _loading = false;
    });
    _fitTo([for (final p in pts) LatLng(p.lat, p.lng)], 48);
  }

  /// Frame [coords] (after the next frame, once the map has its size).
  void _fitTo(List<LatLng> coords, double padding) {
    if (coords.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        final spread = coords.any((c) => c != coords.first);
        if (!spread) {
          _map.move(coords.first, 15);
        } else {
          _map.fitCamera(CameraFit.coordinates(
            coordinates: coords,
            padding: EdgeInsets.all(padding),
            maxZoom: 17,
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

  static const _weekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday',
    'Sunday'
  ];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  /// "YYYY-MM-DD" day key → a UTC midnight (no DST surprises when diffing).
  static DateTime _parseDay(String key) => DateTime.parse('${key}T00:00:00Z');

  static String _keyOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Friendly day label: Today, Yesterday, a weekday this week, else a date.
  static String _dayLabel(String key) {
    final d = _parseDay(key);
    final today = _parseDay(HistoryService.dayKey(DateTime.now()));
    final ago = today.difference(d).inDays;
    if (ago == 0) return 'Today';
    if (ago == 1) return 'Yesterday';
    if (ago > 1 && ago < 7) return _weekdays[d.weekday - 1];
    final short = '${_weekdays[d.weekday - 1].substring(0, 3)} ${d.day} '
        '${_months[d.month - 1]}';
    return d.year == today.year ? short : '$short ${d.year}';
  }

  static String _span(DateTime a, DateTime b) =>
      _hm(a) == _hm(b) ? _hm(a) : '${_hm(a)}–${_hm(b)}';

  static String _dur(Duration d) {
    if (d.inMinutes < 1) return '<1 min';
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  static String _kmh(double mps) => '${(mps * 3.6).round()} km/h';

  // ---- travel modes ----
  static Color _modeColor(TravelMode m) => switch (m) {
        TravelMode.walk => Brand.lichen,
        TravelMode.cycle => const Color(0xFFD9A441),
        TravelMode.vehicle => const Color(0xFF4A86C5),
      };

  static IconData _modeIcon(TravelMode m) => switch (m) {
        TravelMode.walk => Icons.directions_walk,
        TravelMode.cycle => Icons.directions_bike,
        TravelMode.vehicle => Icons.directions_car,
      };

  static String _modeName(TravelMode m) => switch (m) {
        TravelMode.walk => 'Walk',
        TravelMode.cycle => 'Cycle',
        TravelMode.vehicle => 'Vehicle',
      };

  /// The timeline's stays, in order — their position is the stop's number.
  List<Stay> get _stays => _timeline.whereType<Stay>().toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Retention settings',
            icon: const Icon(Icons.tune),
            onPressed: _retentionSettings,
          ),
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
          if (!_loading && _points.isNotEmpty) _bottomPanel(),
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
            Expanded(child: _dayPicker()),
          ],
        ),
      );

  /// Index of the selected day in [_days] (newest first), or -1.
  int get _dayIndex => _day == null ? -1 : _days.indexOf(_day!);

  void _selectDay(String day) {
    if (day == _day) return;
    setState(() => _day = day);
    _loadDay();
  }

  /// ‹ Day › — step through recorded days, or tap the label for a calendar
  /// limited to days that actually have history.
  Widget _dayPicker() {
    final i = _dayIndex;
    final older = i >= 0 && i + 1 < _days.length ? _days[i + 1] : null;
    final newer = i > 0 ? _days[i - 1] : null;
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Day',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous day',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_left),
            onPressed: older == null ? null : () => _selectDay(older),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: _days.isEmpty ? null : _pickDay,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  _day == null ? '—' : _dayLabel(_day!),
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Next day',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_right),
            onPressed: newer == null ? null : () => _selectDay(newer),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDay() async {
    if (_days.isEmpty) return;
    DateTime local(String key) {
      final d = _parseDay(key);
      return DateTime(d.year, d.month, d.day);
    }

    final available = _days.toSet();
    final picked = await showDatePicker(
      context: context,
      initialDate: local(_day ?? _days.first),
      firstDate: local(_days.last),
      lastDate: local(_days.first),
      selectableDayPredicate: (d) => available.contains(_keyOf(d)),
      helpText: 'Days with history',
    );
    if (picked != null) _selectDay(_keyOf(picked));
  }

  Widget _mapArea() {
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: const MapOptions(
            initialCenter: LatLng(51.5074, -0.1278),
            initialZoom: 12,
            // North stays up so the direction arrows read true.
            interactionOptions: InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
          ),
          children: [
            TileLayer(
              urlTemplate:
                  Brand.basemapUrl(context),
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
            PolylineLayer(polylines: _lines()),
            MarkerLayer(markers: _arrowMarkers()),
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
                  style: TextStyle(color: context.cairn.muted),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Every trip coloured by speed (or its road-snapped line), and a dashed
  /// straight line across each gap in the data. With a trip focused, the rest
  /// fade back and the focused one is drawn on top.
  List<Polyline> _lines() {
    final dimmed = <Polyline>[];
    final lit = <Polyline>[];
    for (var i = 0; i < _timeline.length; i++) {
      final e = _timeline[i];
      final dim = _selected != null && _selected != i;
      final into = dim ? dimmed : lit;
      final alpha = dim ? 0.25 : 0.95;
      switch (e) {
        case Move():
          final snapped = _snapped[i];
          if (snapped != null) {
            into.add(_line(snapped, _modeColor(e.mode), alpha));
          } else {
            for (final run in HistoryTimeline.speedRuns(e.path)) {
              into.add(_line([for (final p in run.points) LatLng(p.lat, p.lng)],
                  _modeColor(run.mode), alpha));
            }
          }
        case Gap():
          into.add(Polyline(
            points: [LatLng(e.fromLat, e.fromLng), LatLng(e.toLat, e.toLng)],
            strokeWidth: 3,
            color: context.cairn.muted.withValues(alpha: dim ? 0.25 : 0.8),
            pattern: StrokePattern.dashed(segments: const [10, 8]),
          ));
        case Stay():
          break;
      }
    }
    return [...dimmed, ...lit];
  }

  Polyline _line(List<LatLng> pts, Color color, double alpha) => Polyline(
        points: pts,
        strokeWidth: 5,
        color: color.withValues(alpha: alpha),
        borderStrokeWidth: 1.5,
        borderColor: Colors.white.withValues(alpha: alpha * 0.8),
      );

  /// Direction arrows along each (non-faded) trip.
  List<Marker> _arrowMarkers() {
    final markers = <Marker>[];
    for (var i = 0; i < _timeline.length; i++) {
      final e = _timeline[i];
      if (e is! Move || (_selected != null && _selected != i)) continue;
      final snapped = _snapped[i];
      final path = snapped == null
          ? e.path
          : [for (final c in snapped) HistoryPoint(c.latitude, c.longitude, e.start)];
      for (final a in HistoryTimeline.arrows(path)) {
        markers.add(Marker(
          point: LatLng(a.lat, a.lng),
          width: 16,
          height: 16,
          child: Transform.rotate(
            angle: a.bearing * math.pi / 180,
            child: const Icon(Icons.navigation, size: 14, color: Colors.white,
                shadows: [Shadow(blurRadius: 2, color: Colors.black54)]),
          ),
        ));
      }
    }
    return markers;
  }

  List<Marker> _mapMarkers() {
    final markers = <Marker>[];
    if (_points.isEmpty) return markers;
    // Where the trail starts/ends when that's mid-journey (a stop has its own
    // numbered marker).
    if (_timeline.isNotEmpty && _timeline.first is! Stay) {
      markers.add(_dot(_points.first, Colors.green));
    }
    if (_timeline.isNotEmpty && _timeline.last is! Stay) {
      markers.add(_dot(_points.last, Colors.redAccent));
    }
    // Numbered stops.
    final stays = _stays;
    for (var n = 0; n < stays.length; n++) {
      markers.add(Marker(
        point: LatLng(stays[n].lat, stays[n].lng),
        width: 26,
        height: 26,
        child: _stopBadge(n + 1),
      ));
    }
    // The scrubber's current position.
    final t = _t;
    if (t != null) {
      final pos = HistoryTimeline.positionAt(_points, t);
      // The dot sits exactly on the point; the time label floats above it.
      markers.add(Marker(
        point: LatLng(pos.lat, pos.lng),
        width: 160,
        height: 64,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: pos.known ? Brand.slate : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(
                    color: pos.known ? Colors.white : Brand.stone, width: 3),
                boxShadow: const [
                  BoxShadow(blurRadius: 3, color: Colors.black38)
                ],
              ),
            ),
            Transform.translate(
              offset: const Offset(0, -22),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: const [
                    BoxShadow(blurRadius: 3, color: Colors.black26)
                  ],
                ),
                child: Text(pos.known ? _hm(t) : '${_hm(t)} · no data',
                    style: const TextStyle(
                        fontSize: 11,
                        color: Brand.slate,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ));
    }
    return markers;
  }

  Widget _stopBadge(int n, {double size = 26}) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Brand.slate,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
        ),
        child: Text('$n',
            style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.45,
                fontWeight: FontWeight.w700)),
      );

  Marker _dot(HistoryPoint p, Color color) => Marker(
        point: LatLng(p.lat, p.lng),
        width: 16,
        height: 16,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      );

  /// The scrubber's range: the focused trip, else the whole day.
  (DateTime, DateTime) get _range {
    final sel = _selected;
    if (sel != null) return (_timeline[sel].start, _timeline[sel].end);
    return (_points.first.t, _points.last.t);
  }

  /// A time slider (not a point slider): an hour takes the same room whether
  /// it has one fix or a hundred, and dragging through a gap says so.
  Widget _scrubber() {
    final (start, end) = _range;
    final total = end.difference(start).inSeconds;
    if (total <= 0) return const SizedBox.shrink();
    final t = _t ?? end;
    final at = t.difference(start).inSeconds.clamp(0, total);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(_hm(start),
              style: TextStyle(fontSize: 11, color: context.cairn.muted)),
          Expanded(
            child: Slider(
              value: at.toDouble(),
              min: 0,
              max: total.toDouble(),
              label: _hm(t),
              onChanged: (v) {
                final nt = start.add(Duration(seconds: v.round()));
                setState(() => _t = nt);
                _keepInView(nt);
              },
            ),
          ),
          Text(_hm(end),
              style: TextStyle(fontSize: 11, color: context.cairn.muted)),
        ],
      ),
    );
  }

  /// Pan (without zooming) if the scrubbed position has left the screen.
  void _keepInView(DateTime t) {
    final pos = HistoryTimeline.positionAt(_points, t);
    final ll = LatLng(pos.lat, pos.lng);
    try {
      if (!_map.camera.visibleBounds.contains(ll)) {
        _map.move(ll, _map.camera.zoom);
      }
    } catch (_) {}
  }

  /// Summary, scrubber and the day's timeline, sized to its content (capped)
  /// so the map keeps most of the screen.
  Widget _bottomPanel() {
    final maxList = MediaQuery.sizeOf(context).height * 0.32;
    return Material(
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_selected != null) _selectedBar() else _summary(),
            if (_points.length > 1) _scrubber(),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxList),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _timeline.length,
                itemBuilder: (context, i) => _timelineTile(i),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One line: stops · distance travelled · time span (or a single sighting),
  /// then a key to the line colours.
  Widget _summary() {
    final String text;
    if (_points.length == 1) {
      text = '1 location · seen at ${_hm(_points.first.t)}';
    } else {
      final stops = _stays.length;
      text = [
        '$stops ${stops == 1 ? 'stop' : 'stops'}',
        _dist(HistoryTimeline.travelledMeters(_timeline)),
        _span(_points.first.t, _points.last.t),
      ].join(' · ');
    }
    final modes = {
      for (final m in _timeline.whereType<Move>())
        for (final r in HistoryTimeline.speedRuns(m.path)) r.mode
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(text,
              style: TextStyle(
                  color: context.cairn.ink,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
          for (final m in TravelMode.values)
            if (modes.contains(m))
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                    width: 14,
                    height: 4,
                    decoration: BoxDecoration(
                        color: _modeColor(m),
                        borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 4),
                Text(_modeName(m),
                    style:
                        TextStyle(fontSize: 11, color: context.cairn.muted)),
              ]),
        ],
      ),
    );
  }

  /// Header while a trip is focused: what it is, snap-to-roads, and a way out.
  Widget _selectedBar() {
    final i = _selected!;
    final m = _timeline[i] as Move;
    final snapped = _snapped.containsKey(i);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
      child: Row(
        children: [
          Icon(_modeIcon(m.mode), size: 18, color: _modeColor(m.mode)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${_dist(m.distanceMeters)} · ${_span(m.start, m.end)}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: context.cairn.ink,
                  fontWeight: FontWeight.w600,
                  fontSize: 13),
            ),
          ),
          if (_snapping)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            TextButton.icon(
              icon: Icon(snapped ? Icons.timeline : Icons.alt_route, size: 18),
              label: Text(snapped ? 'Show fixes' : 'Snap to roads'),
              onPressed: () => snapped
                  ? setState(() => _snapped.remove(i))
                  : _snap(i, m),
            ),
          IconButton(
            tooltip: 'Show the whole day',
            icon: const Icon(Icons.close),
            onPressed: _clearSelection,
          ),
        ],
      ),
    );
  }

  Widget _timelineTile(int i) {
    final e = _timeline[i];
    switch (e) {
      case Stay():
        final named = e.place != null;
        final pin =
            named ? null : HistoryTimeline.pinNear(_pins, e.lat, e.lng);
        return ListTile(
          dense: true,
          leading: SizedBox(
              width: 24,
              child: Center(
                  child: _stopBadge(_stays.indexOf(e) + 1, size: 22))),
          title: Text(e.place?.name ?? pin?.name ?? 'Stopped',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(e.duration.inMinutes < 1
              ? 'Seen at ${_hm(e.start)}'
              : '${_span(e.start, e.end)} · ${_dur(e.duration)}'),
          trailing: named
              ? null
              : IconButton(
                  tooltip: 'Save as place',
                  icon: const Icon(Icons.add_location_alt_outlined),
                  onPressed: () => _saveAsPlace(e),
                ),
          onTap: () => _focusStay(e),
        );
      case Move():
        return ListTile(
          dense: true,
          selected: _selected == i,
          leading: Icon(_modeIcon(e.mode), color: _modeColor(e.mode)),
          title: Text('${_modeName(e.mode)} · ${_dist(e.distanceMeters)}'),
          subtitle: Text([
            _span(e.start, e.end),
            _dur(e.duration),
            if (e.duration.inSeconds > 0) 'avg ${_kmh(e.avgSpeedMps)}',
          ].join(' · ')),
          onTap: () => _selected == i ? _clearSelection() : _focusMove(i, e),
        );
      case Gap():
        final apart = e.distanceMeters > HistoryTimeline.stayRadiusMeters;
        return ListTile(
          dense: true,
          leading:
              Icon(Icons.location_off_outlined, color: context.cairn.muted),
          title: Text('No location data',
              style: TextStyle(color: context.cairn.muted)),
          subtitle: Text([
            _span(e.start, e.end),
            _dur(e.duration),
            if (apart) '${_dist(e.distanceMeters)} apart',
          ].join(' · ')),
          onTap: () => _focusGap(e),
        );
    }
  }

  void _focusStay(Stay s) {
    setState(() {
      _selected = null;
      _t = s.start;
    });
    try {
      _map.move(LatLng(s.lat, s.lng), 16);
    } catch (_) {}
  }

  /// Focus one trip: fade the rest, scrub within it, and frame its path.
  void _focusMove(int i, Move m) {
    setState(() {
      _selected = i;
      _t = m.start;
    });
    _fitTo(_snapped[i] ?? [for (final p in m.path) LatLng(p.lat, p.lng)], 60);
  }

  void _focusGap(Gap g) {
    setState(() {
      _selected = null;
      _t = g.start;
    });
    _fitTo([LatLng(g.fromLat, g.fromLng), LatLng(g.toLat, g.toLng)], 60);
  }

  void _clearSelection() {
    setState(() => _selected = null);
    _fitTo([for (final p in _points) LatLng(p.lat, p.lng)], 48);
  }

  /// Snap a trip to roads — after the user agrees to send its coordinates to
  /// the routing server (once, or every time).
  Future<void> _snap(int i, Move m) async {
    if (!await Prefs.roadSnapAllowed()) {
      if (!mounted || await _askSnap() != true) return;
    }
    setState(() => _snapping = true);
    final line = await RoadSnapService.snap(m);
    if (!mounted) return;
    setState(() {
      _snapping = false;
      if (line != null && _selected == i) _snapped[i] = line;
    });
    if (line == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Couldn't snap this trip to roads. Try again later.")));
    }
  }

  Future<bool?> _askSnap() {
    var always = false;
    return showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Snap to roads?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'This sends this trip\'s coordinates — not who you are or '
                  'who it is — to ${RoadSnapService.host}, a public routing '
                  'server, unencrypted. Everything else in History stays on '
                  'your devices.'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: always,
                onChanged: (v) => setDialog(() => always = v ?? false),
                title: const Text("Don't ask again"),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () async {
                  if (always) await Prefs.setRoadSnapAllowed(true);
                  if (context.mounted) Navigator.pop(context, true);
                },
                child: const Text('Snap')),
          ],
        ),
      ),
    );
  }

  /// Open the place editor at an unnamed stop; once saved, re-derive the
  /// timeline so the stop picks up its new name.
  Future<void> _saveAsPlace(Stay s) async {
    final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                PlaceEditorScreen(initialCenter: LatLng(s.lat, s.lng))));
    if (saved != true || !mounted) return;
    _places = await _safe(PlacesService.list(), _places);
    if (!mounted) return;
    setState(() {
      _timeline = HistoryTimeline.build(_points, _places);
      _selected = null; // indices may have shifted
      _snapped.clear();
    });
  }

  /// Let the user keep *less* history than the server does. Options are capped
  /// by the server's own policy (you can't keep more than it stores).
  Future<void> _retentionSettings() async {
    final current = await Prefs.historyLocalRetentionDays();
    final snapAllowed = await Prefs.roadSnapAllowed();
    final serverDays = HistoryPolicy.serverDays;
    // null = follow server; 0 = keep all (only offered if the server keeps all).
    final options = <({String label, int? value})>[
      (label: 'Follow server', value: null),
      if (serverDays == 0) (label: 'Keep everything', value: 0),
      (label: 'Last 90 days', value: 90),
      (label: 'Last 30 days', value: 30),
      (label: 'Last 7 days', value: 7),
    ];
    if (!mounted) return;
    final picked = await showDialog<({String label, int? value})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Keep history for'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              serverDays == 0
                  ? 'This server keeps everything. Choose a shorter window to '
                      'auto-delete your older history on this device\'s account.'
                  : 'This server keeps $serverDays days. You can keep less.',
              style: TextStyle(color: context.cairn.muted, fontSize: 13),
            ),
          ),
          for (final o in options)
            ListTile(
              leading: Icon(
                o.value == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                
              ),
              title: Text(o.label),
              onTap: () => Navigator.pop(context, o),
            ),
          if (snapAllowed)
            ListTile(
              leading: const Icon(Icons.alt_route),
              title: const Text('Ask before snapping trips to roads'),
              subtitle: const Text('You chose not to be asked'),
              onTap: () async {
                await Prefs.setRoadSnapAllowed(false);
                if (context.mounted) Navigator.pop(context);
              },
            ),
        ],
      ),
    );
    if (picked == null) return;
    await Prefs.setHistoryLocalRetentionDays(picked.value);
    await HistoryPolicy.applyLocalChange();
    await _loadDaysThenLatest();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Keeping history: ${picked.label.toLowerCase()}')));
    }
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
