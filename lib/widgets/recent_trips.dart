import 'package:flutter/material.dart';
import '../screens/history_screen.dart';
import '../services/auth_service.dart';
import '../services/history_service.dart';
import '../services/places_service.dart';
import '../theme/brand.dart';
import 'travel_mode_ui.dart';

/// Home's "Recent trips": my last few trips from History, newest first. Tap
/// one to open it in History; "See all" opens History. Hidden while loading
/// and when there are none (e.g. history is off), so it never nags.
class RecentTrips extends StatefulWidget {
  /// Bump to reload (Home's pull-to-refresh).
  final int reloadToken;
  const RecentTrips({super.key, this.reloadToken = 0});

  /// How many trips to show, and how many days back to look for them.
  static const count = 3;
  static const maxDays = 7;

  @override
  State<RecentTrips> createState() => _RecentTripsState();
}

class _RecentTripsState extends State<RecentTrips> {
  List<({String day, Move move})> _trips = [];
  int _gen = 0; // drops a load that finished after a newer one

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RecentTrips old) {
    super.didUpdateWidget(old);
    if (old.reloadToken != widget.reloadToken) _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final me = AuthService.currentUser;
    if (me == null) return;
    final trips = <({String day, Move move})>[];
    try {
      final places = await PlacesService.list();
      final days = await HistoryService.availableDays(me.id);
      for (final day in days.take(RecentTrips.maxDays)) {
        final pts = HistoryTimeline.usable(
            await HistoryService.loadDay(me.id, day));
        final moves = HistoryTimeline.latestMoves(
            HistoryTimeline.build(pts, places),
            RecentTrips.count - trips.length);
        trips.addAll([for (final m in moves) (day: day, move: m)]);
        if (trips.length >= RecentTrips.count) break;
      }
    } catch (_) {/* offline or no history — show what we have */}
    if (!mounted || gen != _gen) return;
    setState(() => _trips = trips);
  }

  Future<void> _open({String? day, DateTime? tripStart}) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                HistoryScreen(initialDay: day, initialTripStart: tripStart)));
    _load(); // History may have been pruned or cleared
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

  Widget _tile(({String day, Move move}) t) {
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
      onTap: () => _open(day: t.day, tripStart: m.start),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_trips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Recent trips',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              TextButton(onPressed: () => _open(), child: const Text('See all')),
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
              for (var i = 0; i < _trips.length; i++) ...[
                if (i > 0)
                  const Divider(height: 1, indent: 16, endIndent: 16),
                _tile(_trips[i]),
              ],
            ]),
          ),
        ],
      ),
    );
  }
}
