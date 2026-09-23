import 'dart:async';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, setEquals;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pocketbase/pocketbase.dart';
import '../services/pb_client.dart';
import '../services/auth_service.dart';
import '../services/pairing_service.dart';
import '../services/background_share.dart';
import '../services/notification_service.dart';
import '../services/nickname_service.dart';
import '../services/contact_prefs_service.dart';
import '../services/geofence_monitor.dart';
import '../services/history_policy.dart';
import '../services/location_sharing_service.dart';
import '../services/presence.dart';
import '../services/prefs.dart';
import '../services/foreground_share.dart';
import 'qr_screen.dart';
import 'scan_screen.dart';
import 'map_screen.dart';
import 'places_screen.dart';
import 'history_screen.dart';
import 'admin_screen.dart';
import 'backup_screen.dart';
import '../widgets/background_share_ux.dart';
import '../widgets/restart_widget.dart';
import '../widgets/contact_tile.dart';
import '../widgets/server_settings_dialog.dart';
import '../theme/brand.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<RecordModel> _contacts = [];
  final Map<String, String> _names = {}; // contact id -> decrypted peer name
  Map<String, ContactControls> _controls = {}; // peer id -> local toggles
  Map<String, DateTime> _lastSeen = {}; // peer id -> when they last shared to me
  Timer? _presenceTimer; // re-render time-based freshness labels
  String _myName = 'New device';
  bool _loading = true;
  Future<void> Function()? _unsub;
  // Live feed of contacts' shares to me, so freshness ("Live", "5m ago")
  // tracks reality instead of the last manual refresh. Re-made when the set of
  // contacts changes (the feed only follows contacts known when it starts).
  Future<void> Function()? _unsubShares;
  Set<String> _sharesFor = {};
  bool _bgEnabled = false;
  bool _approxOnly = false;
  bool _activityAlerts = true; // notify on new pairing / contact going quiet
  String _status = ''; // my broadcast status label ("Hotel"); '' = none
  HomeLayout _layout = HomeLayout.refined;
  // Wide layout: the people list points the side-by-side map at someone.
  final _mapFocus = ValueNotifier<String?>(null);
  static const _wideBreakpoint = 700.0;
  // Background sharing was switched off because its notification was hidden.
  bool _bgHidden = false;
  late final AppLifecycleListener _lifecycle;

  bool get _bgSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _init();
  }

  Future<void> _init() async {
    if (_bgSupported) {
      await _loadBgState();
    }
    _approxOnly = await Prefs.approxOnly();
    _activityAlerts = await Prefs.activityAlerts();
    _layout = await Prefs.homeLayout();
    _status = await Prefs.sharedStatus() ?? '';
    _myName = await AuthService.displayName();
    if (mounted) setState(() {});
    // Watch for contacts arriving at / leaving my places, app-wide (not just on
    // the map). Safe to call repeatedly — it starts a single subscription.
    GeofenceMonitor.instance.start();
    // Share my location whenever the app is open, not just on the map.
    ForegroundShare.instance.error.addListener(_onShareError);
    ForegroundShare.instance.start();
    _checkHistoryPolicy();
    // Freshness labels are time-based; re-render them periodically so "5m ago"
    // keeps counting up without needing new data.
    _presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    await _refresh();
    // Live: reciprocate the instant someone scans my code, and let the user
    // know a new contact connected (a local, content-free notification).
    _unsub = await pb.collection('pair_requests').subscribe('*', (e) async {
      final newlyPaired = await PairingService.processPendingRequests();
      if (await Prefs.activityAlerts()) {
        for (final name in newlyPaired) {
          await NotificationService.show(
            id: NotificationService.idFor('pair:$name:${DateTime.now()}'),
            title: 'New contact',
            body: "You're now connected with $name.",
          );
        }
      }
      await _refresh();
    });
  }

  /// On connecting to a server, honour its history-retention policy: sync
  /// location history only if the user agrees to how long it's kept. Re-prompts
  /// if the policy changed since they last answered.
  Future<void> _checkHistoryPolicy() async {
    final result = await HistoryPolicy.evaluate();
    if (!mounted || result.state != HistoryPolicyState.needsConsent) return;
    final days = result.serverDays;
    final kept = HistoryPolicy.retentionText(days);
    final agree = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.history),
        title: const Text('Keep location history?'),
        content: Text(
          '$kept\n\n'
          "Your history is end-to-end encrypted — only you can read it. It's "
          'used for the History & trips view. You can change or clear it any '
          'time, and you can keep less than the server does in History settings.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Agree')),
        ],
      ),
    );
    if (agree == true) {
      await HistoryPolicy.agree(days);
    } else {
      await HistoryPolicy.decline(days);
    }
  }

  Future<void> _setStatus(String v) async {
    await Prefs.setSharedStatus(v);
    if (mounted) setState(() => _status = v.trim());
  }

  Future<void> _editStatus() async {
    final controller = TextEditingController(text: _status);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set status'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  hintText: 'e.g. Hotel, Airport, Grandma\'s',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Text(
              'Shown to your contacts next to your location, end-to-end '
              'encrypted. Clear it any time.',
              style: TextStyle(color: context.cairn.muted, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (result != null) await _setStatus(result);
  }

  Future<void> _refresh() async {
    try {
      await PairingService.processPendingRequests();
      final contacts = await PairingService.myContacts();
      // A local nickname (if set) wins over the contact's own decrypted name.
      final nicks = await NicknameService.all();
      _controls = await ContactPrefsService.all();
      // Each contact's last-share time (freshness), from their shares to me.
      try {
        final locs = await LocationSharingService.fetchOnce();
        _lastSeen = {for (final e in locs.entries) e.key: e.value.updated};
      } catch (_) {/* offline — keep prior freshness */}
      _names.clear();
      for (final c in contacts) {
        final peerName =
            await PairingService.decryptName(c.getStringValue('peer_name'));
        _names[c.id] = NicknameService.resolveName(
            alias: nicks[c.getStringValue('peer')], peerName: peerName);
      }
      if (mounted) setState(() { _contacts = contacts; _loading = false; });
      await _followShares({for (final c in contacts) c.getStringValue('peer')});
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// (Re)start the live share feed for [peers], if not already following
  /// exactly them.
  Future<void> _followShares(Set<String> peers) async {
    if (!mounted || setEquals(peers, _sharesFor)) return;
    _sharesFor = peers; // claim first, so a concurrent refresh doesn't double up
    await _unsubShares?.call();
    _unsubShares = null;
    try {
      final unsub = await LocationSharingService.subscribe((byId) {
        if (!mounted) return;
        setState(() => _lastSeen = {
              for (final e in byId.entries) e.key: e.value.updated,
            });
      });
      if (mounted && setEquals(peers, _sharesFor)) {
        _unsubShares = unsub;
      } else {
        await unsub(); // screen gone, or superseded while subscribing
      }
    } catch (_) {
      _sharesFor = {}; // offline — let the next refresh retry
    }
  }

  /// Back in the foreground: the live feed may have missed updates while the
  /// app was suspended, so reload once, and re-check background sharing.
  Future<void> _onResume() async {
    await _recheckBg();
    await _refresh();
  }

  @override
  void dispose() {
    _unsub?.call();
    _unsubShares?.call();
    _presenceTimer?.cancel();
    _mapFocus.dispose();
    _lifecycle.dispose();
    ForegroundShare.instance.error.removeListener(_onShareError);
    ForegroundShare.instance.stop();
    super.dispose();
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _myName);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your display name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'What should contacts see?',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      await AuthService.setDisplayName(newName);
      _myName = newName;
      if (mounted) setState(() {});
    }
  }

  Future<void> _about() async {
    // Read the real version at runtime so it always matches the build (CI sets
    // it from the git tag / run number) instead of a hardcoded literal.
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'cairn',
      applicationVersion: 'Version ${info.version} (${info.buildNumber})',
      applicationIcon: const CairnMark(size: 40),
      applicationLegalese: 'Your location, for the few you trust.\n© CappyLabs',
      children: const [
        SizedBox(height: 12),
        Text('Private, self-hosted location sharing. Your location is '
            'end-to-end encrypted and shared only with the people you pair '
            'with by QR code.'),
      ],
    );
  }

  Future<void> _serverSettings() async {
    final changed = await showServerSettingsDialog(context);
    if (changed && mounted) await RestartWidget.restart(context);
  }

  static Color _presenceColor(PresenceLevel l) => switch (l) {
        PresenceLevel.live => Colors.green,
        PresenceLevel.recent => Colors.amber,
        PresenceLevel.stale => Colors.orange,
        PresenceLevel.old => Colors.grey,
        PresenceLevel.never => Brand.stone,
      };

  Widget _contactTile(RecordModel c, {bool focusable = false}) {
    final name = _names[c.id] ?? 'Unnamed device';
    final peerId = c.getStringValue('peer');
    final ctl = ContactPrefsService.resolve(_controls, peerId);
    final keyChanged = c.getStringValue('status') == 'key_changed';
    final pres = Presence.describe(updated: _lastSeen[peerId], now: DateTime.now());
    return ContactTile(
      name: name,
      precision: c.getStringValue('precision'),
      approxOnly: _approxOnly,
      keyChanged: keyChanged,
      historyOn: ctl.history,
      alertsOn: ctl.alerts,
      // Hide the freshness chip on the key-changed warning card (its own UI).
      presenceLabel: keyChanged ? null : pres.label,
      presenceColor: keyChanged ? null : _presenceColor(pres.level),
      onSetPrecision: (p) => _setPrecision(c, p),
      onRemove: () => _removeContact(peerId, name),
      onRescan: _openScan,
      onRename: () => _renameContact(c, name),
      onToggleHistory: () => _toggleContact(peerId, history: !ctl.history),
      onToggleAlerts: () => _toggleContact(peerId, alerts: !ctl.alerts),
      onTap: focusable
          ? () {
              _mapFocus.value = null; // re-tapping the same person re-centres
              _mapFocus.value = peerId;
            }
          : null,
    );
  }

  Future<void> _toggleContact(String peerId, {bool? history, bool? alerts}) async {
    if (history != null) await ContactPrefsService.setHistory(peerId, history);
    if (alerts != null) await ContactPrefsService.setAlerts(peerId, alerts);
    await _refresh();
  }

  Future<void> _renameContact(RecordModel c, String currentName) async {
    final peerId = c.getStringValue('peer');
    final controller = TextEditingController(text: currentName);
    final newAlias = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename contact'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                  hintText: 'e.g. Mum, Work', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Text(
              'A private label kept only on this device — they won\'t see it. '
              'Clear it to use the name they chose.',
              style: TextStyle(color: context.cairn.muted, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              // Empty string is a valid result: it clears the nickname.
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (newAlias == null) return; // dialog dismissed
    await NicknameService.set(peerId, newAlias);
    await _refresh();
  }

  Future<void> _setPrecision(RecordModel c, String precision) async {
    await PairingService.setPrecision(
        c.id, c.getStringValue('peer'), precision);
    await _refresh();
  }

  Future<void> _removeContact(String peerId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text(
            'You\'ll stop sharing your location with them and they\'ll leave '
            'your list. (They keep their own copy until they remove you.)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await PairingService.removeContact(peerId);
    await _refresh();
  }

  Future<void> _toggleBg(bool on) async {
    // The disclosure + permission flow lives in BackgroundShareUx, shared with
    // the map's own-marker sheet so both behave identically.
    final enabled = await BackgroundShareUx.toggle(context, on: on);
    if (mounted) {
      setState(() {
        _bgEnabled = enabled;
        if (enabled) _bgHidden = false;
      });
    }
  }

  /// Background sharing must never run without its notification being
  /// visible: switch it off if notifications were turned off since, and
  /// remember why so the home screen can say so.
  Future<void> _loadBgState() async {
    await BackgroundShare.stopIfHidden();
    _bgEnabled = await BackgroundShare.isEnabled();
    _bgHidden = await BackgroundShare.stoppedBecauseHidden();
  }

  Future<void> _recheckBg() async {
    if (!_bgSupported) return;
    await _loadBgState();
    if (mounted) setState(() {});
  }

  Future<void> _dismissBgHidden() async {
    await BackgroundShare.clearStoppedBecauseHidden();
    if (mounted) setState(() => _bgHidden = false);
  }

  void _onShareError() {
    if (mounted) setState(() {});
  }

  /// A warning shown when the app can't share because location is off or
  /// permission was refused — otherwise "sharing while open" would be untrue.
  Widget _locationProblem() {
    final err = ForegroundShare.instance.error.value;
    if (err == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          leading: const Icon(Icons.location_disabled),
          title: const Text("You're not sharing your location"),
          subtitle: Text(err, style: const TextStyle(fontSize: 12)),
          trailing: TextButton(
            onPressed: ForegroundShare.instance.retry,
            child: const Text('Retry'),
          ),
        ),
      ),
    );
  }

  /// Shown after background sharing was switched off because its
  /// notification couldn't be seen.
  Widget _bgHiddenNotice() {
    if (!_bgHidden || _bgEnabled) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: context.cairn.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.cairn.outline),
        ),
        child: ListTile(
          leading: const Icon(Icons.notifications_off_outlined),
          title: const Text('Background sharing was turned off'),
          subtitle: const Text(
            "Notifications are off for Cairn, so you couldn't see it was "
            'sharing. Turn them on to use it again.',
            style: TextStyle(fontSize: 12),
          ),
          onTap: BackgroundShare.openAppSettings,
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Dismiss',
            onPressed: _dismissBgHidden,
          ),
        ),
      ),
    );
  }

  Future<void> _openScan() async {
    final name = await Navigator.push<String>(
      context, MaterialPageRoute(builder: (_) => const ScanScreen()));
    await _refresh();
    if (name != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected with $name')));
    }
  }

  // --- Home layout ----------------------------------------------------------

  static const _layoutInfo = {
    HomeLayout.refined: (
      Icons.view_agenda_outlined,
      'Classic',
      'Greeting, sharing settings, then your people.'
    ),
    HomeLayout.people: (
      Icons.people_outline,
      'People first',
      'Your people fill the screen; sharing settings sit behind one pill.'
    ),
    HomeLayout.map: (
      Icons.map_outlined,
      'Map first',
      'The live map is home, with a pull-up panel of people and settings.'
    ),
  };

  Future<void> _chooseLayout() async {
    final picked = await showDialog<HomeLayout>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Home layout'),
        children: [
          RadioGroup<HomeLayout>(
            groupValue: _layout,
            onChanged: (v) => Navigator.pop(context, v),
            child: Column(
              children: [
                for (final e in _layoutInfo.entries)
                  RadioListTile<HomeLayout>(
                    value: e.key,
                    secondary: Icon(e.value.$1),
                    title: Text(e.value.$2),
                    subtitle: Text(e.value.$3,
                        style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null || picked == _layout) return;
    await Prefs.setHomeLayout(picked);
    if (mounted) setState(() => _layout = picked);
  }

  // --- Shared pieces ----------------------------------------------------------

  bool get _hasDefaultName => _myName == 'New device';

  Widget _brandTitle() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CairnMark(size: 22),
          const SizedBox(width: 8),
          Text('cairn',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600, letterSpacing: -0.5)),
        ],
      );

  Widget _menu() => PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'name':
              _editName();
            case 'layout':
              _chooseLayout();
            case 'places':
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PlacesScreen()));
            case 'history':
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const HistoryScreen()));
            case 'backup':
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const BackupScreen()));
            case 'server':
              _serverSettings();
            case 'about':
              _about();
            case 'admin':
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AdminScreen()));
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
              value: 'name',
              child: ListTile(
                  leading: Icon(Icons.edit), title: Text('Edit name'))),
          const PopupMenuItem(
              value: 'layout',
              child: ListTile(
                  leading: Icon(Icons.dashboard_customize_outlined),
                  title: Text('Home layout'))),
          const PopupMenuItem(
              value: 'places',
              child: ListTile(
                  leading: Icon(Icons.place_outlined), title: Text('Places'))),
          const PopupMenuItem(
              value: 'history',
              child: ListTile(
                  leading: Icon(Icons.history),
                  title: Text('History & trips'))),
          const PopupMenuItem(
              value: 'backup',
              child: ListTile(
                  leading: Icon(Icons.vpn_key),
                  title: Text('Backup & restore'))),
          const PopupMenuItem(
              value: 'server',
              child: ListTile(
                  leading: Icon(Icons.dns), title: Text('Server settings'))),
          const PopupMenuItem(
              value: 'about',
              child: ListTile(
                  leading: Icon(Icons.info_outline), title: Text('About'))),
          if (isAdminView)
            const PopupMenuItem(
                value: 'admin',
                child: ListTile(
                    leading: Icon(Icons.admin_panel_settings),
                    title: Text('Admin dashboard'))),
        ],
      );

  void _openQr() => Navigator.push(
      context, MaterialPageRoute(builder: (_) => const QrScreen()));

  void _openMap() => Navigator.push(
      context, MaterialPageRoute(builder: (_) => const MapScreen()));

  /// "Add person": show my code or scan theirs — one entry point for layouts
  /// that don't keep both buttons on screen.
  Future<void> _addPerson() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_2),
              title: const Text('Show your code'),
              subtitle: const Text('They scan it with their phone'),
              onTap: () => Navigator.pop(context, 'qr'),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Scan their code'),
              subtitle: const Text('Point your camera at their code'),
              onTap: () => Navigator.pop(context, 'scan'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'qr') _openQr();
    if (choice == 'scan') await _openScan();
  }

  /// One-line summary of how I'm sharing, e.g. "Sharing while open · precise".
  String _sharingSummary() {
    if (ForegroundShare.instance.error.value != null) {
      return 'Not sharing · location unavailable';
    }
    final when = _bgSupported && _bgEnabled ? 'in background' : 'while open';
    final how = _approxOnly ? 'approximate' : 'precise';
    final status = _status.isEmpty ? '' : ' · "$_status"';
    return 'Sharing $when · $how$status';
  }

  Future<void> _setApprox(bool v) async {
    await Prefs.setApproxOnly(v);
    if (mounted) setState(() => _approxOnly = v);
  }

  Future<void> _setActivityAlerts(bool v) async {
    await Prefs.setActivityAlerts(v);
    if (mounted) setState(() => _activityAlerts = v);
  }

  /// The sharing settings as compact rows. [after] runs once a change lands,
  /// so a bottom sheet hosting them can rebuild too.
  List<Widget> _sharingRows({VoidCallback? after}) {
    void done() {
      if (mounted) after?.call();
    }

    return [
      if (_bgSupported)
        SwitchListTile(
          value: _bgEnabled,
          onChanged: (v) async {
            await _toggleBg(v);
            done();
          },
          secondary: const Icon(Icons.share_location),
          title: const Text('Share in the background'),
          subtitle: Text(
              _bgEnabled
                  ? 'Keeps updating when the app is closed'
                  : 'Only while the app is open',
              style: const TextStyle(fontSize: 12)),
        ),
      SwitchListTile(
        value: _approxOnly,
        onChanged: (v) async {
          await _setApprox(v);
          done();
        },
        secondary: const Icon(Icons.blur_on),
        title: const Text('Approximate only'),
        subtitle: Text(
            _approxOnly
                ? 'Everyone sees a rough area (~1 km)'
                : 'Precision is set per person',
            style: const TextStyle(fontSize: 12)),
      ),
      SwitchListTile(
        value: _activityAlerts,
        onChanged: (v) async {
          await _setActivityAlerts(v);
          done();
        },
        secondary: const Icon(Icons.notifications_active_outlined),
        title: const Text('Activity alerts'),
        subtitle: Text(
            _activityAlerts
                ? 'New contacts and people going quiet; made on your phone'
                : 'No pairing or contact-quiet alerts',
            style: const TextStyle(fontSize: 12)),
      ),
      ListTile(
        leading: const Icon(Icons.label_outline),
        title: const Text('Status'),
        subtitle: Text(
            _status.isEmpty
                ? 'Show people a label, like "Hotel"'
                : 'People see "$_status"',
            style: const TextStyle(fontSize: 12)),
        trailing: _status.isEmpty
            ? const Icon(Icons.edit_outlined)
            : IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear status',
                onPressed: () async {
                  await _setStatus('');
                  done();
                },
              ),
        onTap: () async {
          await _editStatus();
          done();
        },
      ),
    ];
  }

  Widget _divided(List<Widget> rows) => Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
          rows[i],
        ],
      ]);

  Future<void> _sharingSheet() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheet) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _divided(_sharingRows(after: () => setSheet(() {}))),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );

  Widget _emptyPeople() => Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: context.cairn.card,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: context.cairn.outline)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _addPerson,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 28, horizontal: 16),
            child: Column(
              children: [
                Icon(Icons.group_add_outlined, size: 32),
                SizedBox(height: 8),
                Text('Add your first person',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                SizedBox(height: 4),
                Text('Show them your code, or scan theirs.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.cairn.muted)),
              ],
            ),
          ),
        ),
      );

  List<Widget> _people({bool focusable = false}) => [
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_contacts.isEmpty)
          _emptyPeople()
        else
          ..._contacts.map((c) => _contactTile(c, focusable: focusable)),
      ];

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  /// Warnings that belong above any layout's sharing controls.
  List<Widget> _notices() => [
        _locationProblem(),
        if (_bgSupported) _bgHiddenNotice(),
      ];

  /// One-line sharing summary; tap for the settings sheet.
  Widget _sharingPill() => Material(
          color: context.cairn.card,
          shape: StadiumBorder(side: BorderSide(color: context.cairn.outline)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: _sharingSheet,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                        color: Brand.lichen, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_sharingSummary(),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Icon(Icons.expand_more),
                ],
              ),
            ),
          ),
        );

  @override
  Widget build(BuildContext context) {
    // Wide screens (landscape phones, tablets, the web) get two panes,
    // whatever the chosen layout; the picker applies to portrait phones.
    if (MediaQuery.sizeOf(context).width >= _wideBreakpoint) return _wide();
    return _narrow();
  }

  Widget _narrow() => switch (_layout) {
        HomeLayout.refined => _refined(),
        HomeLayout.people => _peopleFirst(),
        HomeLayout.map => _mapFirst(),
      };

  // --- Wide: people and settings beside a live map ------------------------------

  Widget _wide() {
    return Scaffold(
      appBar: AppBar(
        title: _brandTitle(),
        actions: [
          IconButton(
              tooltip: 'Scan',
              onPressed: _openScan,
              icon: const Icon(Icons.qr_code_scanner)),
          _menu(),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 360,
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ..._notices(),
                  _sharingPill(),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                            _contacts.isEmpty
                                ? 'People'
                                : 'People · ${_contacts.length}',
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                      TextButton.icon(
                        onPressed: _addPerson,
                        icon: const Icon(Icons.person_add_alt_1, size: 18),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ..._people(focusable: true),
                ],
              ),
            ),
          ),
          VerticalDivider(width: 1, color: context.cairn.outline),
          Expanded(child: MapScreen(embedded: true, focus: _mapFocus)),
        ],
      ),
    );
  }

  // --- Classic: greeting, code/scan, grouped settings, people ----------------

  Widget _refined() {
    return Scaffold(
      appBar: AppBar(title: _brandTitle(), actions: [_menu()]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openMap,
        icon: const Icon(Icons.map),
        label: const Text('Map'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            Text(_hasDefaultName ? 'Hi 👋' : 'Hi, $_myName 👋',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 2),
            Text('Your location, for the few you trust.',
                style: TextStyle(color: context.cairn.muted)),
            if (_hasDefaultName)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: _editName,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Set your name'),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _openQr,
                    icon: const Icon(Icons.qr_code_2),
                    label: const Text('Your code'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openScan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ..._notices(),
            Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              color: context.cairn.card,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: context.cairn.outline)),
              child: _divided(_sharingRows()),
            ),
            const SizedBox(height: 24),
            _sectionTitle(_contacts.isEmpty
                ? 'People'
                : 'People (${_contacts.length})'),
            ..._people(),
          ],
        ),
      ),
    );
  }

  // --- People first: status pill, people list, add + map bar -----------------

  Widget _peopleFirst() {
    return Scaffold(
      appBar: AppBar(
        title: _brandTitle(),
        actions: [
          IconButton(
              tooltip: 'Scan',
              onPressed: _openScan,
              icon: const Icon(Icons.qr_code_scanner)),
          _menu(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _addPerson,
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add person'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _openMap,
                icon: const Icon(Icons.map_outlined),
                label: const Text('Map'),
              ),
            ],
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ..._notices(),
            _sharingPill(),
            const SizedBox(height: 20),
            _sectionTitle(_contacts.isEmpty
                ? 'People'
                : 'People · ${_contacts.length}'),
            ..._people(),
          ],
        ),
      ),
    );
  }

  // --- Map first: live map with a pull-up panel ------------------------------

  Widget _mapFirst() {
    return Scaffold(
      appBar: AppBar(title: _brandTitle(), actions: [_menu()]),
      body: LayoutBuilder(
        builder: (context, box) {
          const peek = 0.34;
          return Stack(
            children: [
              MapScreen(embedded: true, bottomInset: box.maxHeight * peek),
              DraggableScrollableSheet(
                initialChildSize: peek,
                minChildSize: 0.14,
                maxChildSize: 0.9,
                snap: true,
                builder: (context, scroll) => Material(
                  color: context.cairn.sheet,
                  elevation: 8,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(20)),
                  clipBehavior: Clip.antiAlias,
                  child: ListView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [
                      Center(
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 10),
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                              color: context.cairn.outline,
                              borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                      ..._notices(),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (_bgSupported)
                            FilterChip(
                              label: const Text('Background'),
                              selected: _bgEnabled,
                              onSelected: _toggleBg,
                            ),
                          FilterChip(
                            label: const Text('Approximate'),
                            selected: _approxOnly,
                            onSelected: _setApprox,
                          ),
                          FilterChip(
                            label: const Text('Alerts'),
                            selected: _activityAlerts,
                            onSelected: _setActivityAlerts,
                          ),
                          ActionChip(
                            avatar: Icon(
                                _status.isEmpty
                                    ? Icons.add
                                    : Icons.label_outline,
                                size: 18),
                            label: Text(_status.isEmpty ? 'Status' : _status),
                            onPressed: _editStatus,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                                _contacts.isEmpty
                                    ? 'People'
                                    : 'People · ${_contacts.length}',
                                style: Theme.of(context).textTheme.titleMedium),
                          ),
                          TextButton.icon(
                            onPressed: _addPerson,
                            icon: const Icon(Icons.person_add_alt_1, size: 18),
                            label: const Text('Add'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ..._people(),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
