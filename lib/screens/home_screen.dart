import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
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
import '../theme/theme_controller.dart';

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
  bool _bgEnabled = false;
  bool _approxOnly = false;
  bool _activityAlerts = true; // notify on new pairing / contact going quiet
  String _status = ''; // my broadcast status label ("Hotel"); '' = none

  bool get _bgSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    if (_bgSupported) {
      _bgEnabled = await BackgroundShare.isEnabled();
    }
    _approxOnly = await Prefs.approxOnly();
    _activityAlerts = await Prefs.activityAlerts();
    _status = await Prefs.sharedStatus() ?? '';
    _myName = await AuthService.displayName();
    if (mounted) setState(() {});
    // Watch for contacts arriving at / leaving my places, app-wide (not just on
    // the map). Safe to call repeatedly — it starts a single subscription.
    GeofenceMonitor.instance.start();
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
    final kept = days <= 0
        ? 'This server keeps your location history for as long as you use it '
            '(no automatic deletion).'
        : 'This server keeps your location history for $days '
            '${days == 1 ? 'day' : 'days'}, then deletes it automatically.';
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
            const Text(
              'Shown to your contacts next to your location, end-to-end '
              'encrypted. Clear it any time.',
              style: TextStyle(color: Brand.stone, fontSize: 12),
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
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _unsub?.call();
    _presenceTimer?.cancel();
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

  /// Light / dark / follow the phone. Applies immediately and is remembered.
  Future<void> _appearance() async {
    const options = [
      (ThemeMode.system, 'Match system', Icons.brightness_auto_outlined),
      (ThemeMode.light, 'Light', Icons.light_mode_outlined),
      (ThemeMode.dark, 'Dark', Icons.dark_mode_outlined),
    ];
    final current = ThemeController.mode.value;
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Appearance'),
        children: [
          for (final (mode, label, icon) in options)
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              trailing: mode == current
                  ? const Icon(Icons.check, color: Brand.lichen)
                  : null,
              onTap: () => Navigator.pop(context, mode),
            ),
        ],
      ),
    );
    if (picked != null) await ThemeController.set(picked);
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

  Widget _contactTile(RecordModel c) {
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
            const Text(
              'A private label kept only on this device — they won\'t see it. '
              'Clear it to use the name they chose.',
              style: TextStyle(color: Brand.stone, fontSize: 12),
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
    if (mounted) setState(() => _bgEnabled = enabled);
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

  @override
  Widget build(BuildContext context) {
    final name = _myName;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CairnMark(size: 22),
            const SizedBox(width: 8),
            Text('cairn',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600, letterSpacing: -0.5)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'name':
                  _editName();
                case 'places':
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const PlacesScreen()));
                case 'history':
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const HistoryScreen()));
                case 'backup':
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const BackupScreen()));
                case 'appearance':
                  _appearance();
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
                  value: 'places',
                  child: ListTile(
                      leading: Icon(Icons.place_outlined),
                      title: Text('Places'))),
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
                  value: 'appearance',
                  child: ListTile(
                      leading: Icon(Icons.brightness_6_outlined),
                      title: Text('Appearance'))),
              const PopupMenuItem(
                  value: 'server',
                  child: ListTile(
                      leading: Icon(Icons.dns),
                      title: Text('Server settings'))),
              const PopupMenuItem(
                  value: 'about',
                  child: ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('About'))),
              if (isAdminView)
                const PopupMenuItem(
                    value: 'admin',
                    child: ListTile(
                        leading: Icon(Icons.admin_panel_settings),
                        title: Text('Admin dashboard'))),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
            context, MaterialPageRoute(builder: (_) => const MapScreen())),
        icon: const Icon(Icons.map),
        label: const Text('Map'),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Hi, $name 👋',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 2),
            const Text('Your location, for the few you trust.',
                style: TextStyle(color: Brand.stone)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const QrScreen())),
                    icon: const Icon(Icons.qr_code_2),
                    label: const Text('My code'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _openScan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan'),
                  ),
                ),
              ],
            ),
            if (_bgSupported) ...[
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: SwitchListTile(
                  value: _bgEnabled,
                  onChanged: _toggleBg,
                  secondary: const Icon(Icons.share_location),
                  title: const Text('Share in the background'),
                  subtitle: Text(
                    _bgEnabled
                        ? 'On — your location keeps updating when the app is closed.'
                        : 'Off — you only share while the app is open.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: SwitchListTile(
                value: _approxOnly,
                onChanged: (v) async {
                  await Prefs.setApproxOnly(v);
                  if (mounted) setState(() => _approxOnly = v);
                },
                secondary: const Icon(Icons.blur_on),
                title: const Text('Share approximate location only'),
                subtitle: Text(
                  _approxOnly
                      ? 'On — everyone sees a rough area (~1 km), overriding per-contact settings.'
                      : 'Off — precision is set per contact below.',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: SwitchListTile(
                value: _activityAlerts,
                onChanged: (v) async {
                  await Prefs.setActivityAlerts(v);
                  if (mounted) setState(() => _activityAlerts = v);
                },
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('Activity alerts'),
                subtitle: Text(
                  _activityAlerts
                      ? 'On — a local alert when a new contact connects or a '
                          'contact goes quiet. Composed on your phone; nothing '
                          'is sent to the server.'
                      : 'Off — no pairing or contact-quiet alerts.',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.label_outline),
                title: const Text('Status'),
                subtitle: Text(
                  _status.isEmpty
                      ? 'Off — set a label (e.g. "Hotel") to show contacts where you are.'
                      : 'Contacts see: "$_status"',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: _status.isEmpty
                    ? const Icon(Icons.edit_outlined)
                    : IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Clear status',
                        onPressed: () => _setStatus(''),
                      ),
                onTap: _editStatus,
              ),
            ),
            const SizedBox(height: 24),
            Text('People (${_contacts.length})',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_contacts.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(
                    'No one yet.\nTap "My code" and have someone scan it,\n'
                    'or "Scan" their code.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            else
              ..._contacts.map(_contactTile),
          ],
        ),
      ),
    );
  }
}
