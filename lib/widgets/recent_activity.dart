import 'package:flutter/material.dart';
import '../screens/history_screen.dart';
import '../screens/places_screen.dart';
import '../services/auth_service.dart';
import '../services/history_service.dart';
import '../services/places_service.dart';
import '../theme/brand.dart';
import 'travel_mode_ui.dart';

/// When I was last at a saved place: the local [day] key and the time I left
/// (or the latest fix, if I'm still there).
typedef PlaceVisit = ({String day, DateTime at});

/// Home's "Places" and "History" sections: my most recently visited places and
/// my last few trips, each with "View all". Both come from one pass over recent
/// History, so Home loads it once. Tap a place to edit it, a trip to open it in
/// History.
class RecentActivity extends StatefulWidget {
  /// Bump to reload (Home's pull-to-refresh).
  final int reloadToken;
  const RecentActivity({super.key, this.reloadToken = 0});

  /// How many places and trips to show, and how many days back to look.
  static const count = 3;
  static const maxDays = 7;

  /// Up to [n] of [places], most recently visited first; places with no visit
  /// in [visits] follow in their saved order. Pure.
  static List<Place> recentPlaces(
      List<Place> places, Map<String, PlaceVisit> visits, int n) {
    final visited = places.where((p) => visits.containsKey(p.id)).toList()
      ..sort((a, b) => visits[b.id]!.at.compareTo(visits[a.id]!.at));
    return [
      ...visited,
      ...places.where((p) => !visits.containsKey(p.id)),
    ].take(n).toList();
  }

  /// The latest stay in each saved place across [timeline] (one day's). Pure.
  static Map<String, DateTime> lastStays(List<TimelineEntry> timeline) => {
        for (final s in timeline.whereType<Stay>())
          if (s.place != null && s.place!.id.isNotEmpty) s.place!.id: s.end,
      };

  @override
  State<RecentActivity> createState() => _RecentActivityState();
}

class _RecentActivityState extends State<RecentActivity> {
  bool _loaded = false;
  List<Place> _places = [];
  Map<String, PlaceVisit> _visits = {};
  List<({String day, Move move})> _trips = [];
  int _gen = 0; // drops a load that finished after a newer one

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RecentActivity old) {
    super.didUpdateWidget(old);
    if (old.reloadToken != widget.reloadToken) _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final me = AuthService.currentUser;
    if (me == null) return;
    var places = <Place>[];
    final visits = <String, PlaceVisit>{};
    final trips = <({String day, Move move})>[];
    try {
      places = await PlacesService.list();
      final days = await HistoryService.availableDays(me.id); // newest first
      for (final day in days.take(RecentActivity.maxDays)) {
        final timeline = HistoryTimeline.build(
            HistoryTimeline.usable(await HistoryService.loadDay(me.id, day)),
            places);
        // Newest day first, so the first visit seen to a place is its latest.
        RecentActivity.lastStays(timeline).forEach(
            (id, at) => visits.putIfAbsent(id, () => (day: day, at: at)));
        final moves = HistoryTimeline.latestMoves(
            timeline, RecentActivity.count - trips.length);
        trips.addAll([for (final m in moves) (day: day, move: m)]);
        final placesDone = places.every((p) => visits.containsKey(p.id));
        if (trips.length >= RecentActivity.count && placesDone) break;
      }
    } catch (_) {/* offline or no history — show what we have */}
    if (!mounted || gen != _gen) return;
    setState(() {
      _loaded = true;
      _places = places;
      _visits = visits;
      _trips = trips;
    });
  }

  Future<void> _openHistory({String? day, DateTime? tripStart}) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                HistoryScreen(initialDay: day, initialTripStart: tripStart)));
    _load(); // History may have been pruned or cleared
  }

  Future<void> _openPlaces() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const PlacesScreen()));
    _load();
  }

  Future<void> _editPlace([Place? place]) async {
    final saved = await Navigator.push<bool>(context,
        MaterialPageRoute(builder: (_) => PlaceEditorScreen(place: place)));
    if (saved == true) _load();
  }

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

  static String? _route(Move m) => switch ((m.from?.name, m.to?.name)) {
        (final String a, final String b) => '$a → $b',
        (null, final String b) => 'to $b',
        (final String a, null) => 'from $a',
        _ => null,
      };

  Widget _tripTile(({String day, Move move}) t) {
    final m = t.move;
    final route = _route(m);
    return ListTile(
      leading: Icon(m.mode.icon, color: m.mode.color),
      title: Text(
          [
            '${m.mode.label} · ${_dist(m.distanceMeters)}',
            ?route,
          ].join(' · '),
          overflow: TextOverflow.ellipsis),
      subtitle: Text(
          '${HistoryScreen.dayLabel(t.day)} · ${_hm(m.start)} · ${_dur(m.duration)}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openHistory(day: t.day, tripStart: m.start),
    );
  }

  Widget _placeTile(Place p) {
    final v = _visits[p.id];
    return ListTile(
      leading: const Icon(Icons.place_outlined),
      title: Text(p.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(v == null
          ? 'No visits this week'
          : 'Last here ${HistoryScreen.dayLabel(v.day)} · ${_hm(v.at)}'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _editPlace(p),
    );
  }

  /// A muted one-liner for an empty section, optionally tappable.
  Widget _emptyTile(IconData icon, String text, {VoidCallback? onTap}) =>
      ListTile(
        leading: Icon(icon, color: context.cairn.muted),
        title: Text(text, style: TextStyle(color: context.cairn.muted)),
        onTap: onTap,
      );

  Widget _section(String title, VoidCallback viewAll, List<Widget> rows) =>
      Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton(onPressed: viewAll, child: const Text('View all')),
              ],
            ),
            const SizedBox(height: 4),
            Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              color: context.cairn.card,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: context.cairn.outline)),
              child: Column(children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  rows[i],
                ],
              ]),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final places =
        RecentActivity.recentPlaces(_places, _visits, RecentActivity.count);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('Places', _openPlaces, [
          if (places.isEmpty)
            _emptyTile(Icons.add_location_alt_outlined, 'Add a place',
                onTap: _editPlace)
          else
            ...places.map(_placeTile),
        ]),
        _section('History', _openHistory, [
          if (_trips.isEmpty)
            _emptyTile(Icons.route_outlined, 'No trips in the last week')
          else
            ..._trips.map(_tripTile),
        ]),
      ],
    );
  }
}
