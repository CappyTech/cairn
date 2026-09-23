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
import '../services/shared_places_service.dart';
import '../theme/brand.dart';
import 'places_screen.dart';

/// A person whose history I can view: me, or a paired contact.
class _Subject {
  final String id;
  final String name;
  const _Subject(this.id, this.name);
}

/// History: pick a person and a day to see where they've been — the
/// breadcrumb path on the map, a scrubbable slider, and a timeline of where
/// they stayed and how they moved between those stays. All from locations already end-to-end encrypted to me.
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
  int _scrub = 0;
  bool _loading = true;

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
    setState(() => _loading = true);
    final pts = _day == null
        ? <HistoryPoint>[]
        : await _safe(HistoryService.loadDay(_subjectId!, _day!), <HistoryPoint>[]);
    final timeline = HistoryTimeline.build(pts, _places);
    if (!mounted) return;
    setState(() {
      _points = pts;
      _timeline = timeline;
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
                  style: TextStyle(color: context.cairn.muted),
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
      // The dot sits exactly on the point; the time label floats above it.
      markers.add(Marker(
        point: LatLng(p.lat, p.lng),
        width: 120,
        height: 64,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            const Icon(Icons.circle, size: 14, color: Brand.slate),
            Transform.translate(
              offset: const Offset(0, -20),
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
                child: Text(_hm(p.t),
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
              style: TextStyle(fontSize: 11, color: context.cairn.muted)),
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
              style: TextStyle(fontSize: 11, color: context.cairn.muted)),
        ],
      ),
    );
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
            _summary(),
            if (_points.length > 1) _scrubber(),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxList),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _timeline.length,
                itemBuilder: (context, i) => _timelineTile(_timeline[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One line: stops · distance · time span (or a single sighting).
  Widget _summary() {
    final String text;
    if (_points.length == 1) {
      text = '1 location · seen at ${_hm(_points.first.t)}';
    } else {
      final stops = _timeline.whereType<Stay>().length;
      final dist = HistoryTimeline.pathLength(_points);
      text = [
        '$stops ${stops == 1 ? 'stop' : 'stops'}',
        _dist(dist),
        _span(_points.first.t, _points.last.t),
      ].join(' · ');
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(text,
          style: TextStyle(
              color: context.cairn.ink, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }

  Widget _timelineTile(TimelineEntry e) {
    switch (e) {
      case Stay():
        final named = e.place != null;
        final pin =
            named ? null : HistoryTimeline.pinNear(_pins, e.lat, e.lng);
        return ListTile(
          dense: true,
          leading: Icon(
              named
                  ? Icons.place
                  : pin != null
                      ? Icons.push_pin_outlined
                      : Icons.place_outlined,
              ),
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
          leading: Icon(Icons.route, color: context.cairn.ink),
          title: Text('Travelled ${_dist(e.distanceMeters)}'),
          subtitle:
              Text('${_span(e.start, e.end)} · ${_dur(e.duration)}'),
          onTap: () => _focusMove(e),
        );
    }
  }

  /// Snap the scrubber to the first point at/after [t].
  void _scrubTo(DateTime t) {
    final idx = _points.indexWhere((p) => !p.t.isBefore(t));
    if (idx >= 0) setState(() => _scrub = idx);
  }

  void _focusStay(Stay s) {
    _scrubTo(s.start);
    try {
      _map.move(LatLng(s.lat, s.lng), 16);
    } catch (_) {}
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
    setState(() => _timeline = HistoryTimeline.build(_points, _places));
  }

  void _focusMove(Move m) {
    // Snap the scrubber to the move's start and frame its path.
    _scrubTo(m.start);
    final coords = [for (final p in m.path) LatLng(p.lat, p.lng)];
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

  /// Let the user keep *less* history than the server does. Options are capped
  /// by the server's own policy (you can't keep more than it stores).
  Future<void> _retentionSettings() async {
    final current = await Prefs.historyLocalRetentionDays();
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
                color: o.value == current ? Brand.lichen : context.cairn.muted,
              ),
              title: Text(o.label),
              onTap: () => Navigator.pop(context, o),
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
