import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import '../services/pb_client.dart';
import '../services/auth_service.dart';
import '../services/pairing_service.dart';
import '../services/background_share.dart';
import '../services/prefs.dart';
import 'qr_screen.dart';
import 'scan_screen.dart';
import 'map_screen.dart';
import 'admin_screen.dart';
import 'backup_screen.dart';
import '../widgets/restart_widget.dart';
import '../theme/brand.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<RecordModel> _contacts = [];
  final Map<String, String> _names = {}; // contact id -> decrypted peer name
  String _myName = 'New device';
  bool _loading = true;
  Future<void> Function()? _unsub;
  bool _bgEnabled = false;
  bool _approxOnly = false;

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
    _myName = await AuthService.displayName();
    if (mounted) setState(() {});
    await _refresh();
    // Live: reciprocate the instant someone scans my code.
    _unsub = await pb.collection('pair_requests').subscribe('*', (e) async {
      await PairingService.processPendingRequests();
      await _refresh();
    });
  }

  Future<void> _refresh() async {
    try {
      await PairingService.processPendingRequests();
      final contacts = await PairingService.myContacts();
      // Decrypt each contact's name (stored encrypted-to-self on the server).
      _names.clear();
      for (final c in contacts) {
        _names[c.id] =
            await PairingService.decryptName(c.getStringValue('peer_name'));
      }
      if (mounted) setState(() { _contacts = contacts; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _unsub?.call();
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

  void _about() {
    showAboutDialog(
      context: context,
      applicationName: 'cairn',
      applicationVersion: '0.1.0 (beta)',
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
    final controller = TextEditingController(
        text: (await savedServerUrl()).isEmpty ? serverUrl : await savedServerUrl());
    if (!mounted) return;
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Server address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Currently: $serverUrl',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'PocketBase URL',
                hintText: 'http://192.168.8.176:8090',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'On a real phone, use your PC\'s network address, not localhost.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save & restart')),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) {
      await setServerUrl(url);
      if (mounted) await RestartWidget.restart(context);
    }
  }

  static String _precLabel(String p) => switch (p) {
        'approximate' => 'Sharing approximate (~1 km)',
        'off' => 'Sharing paused',
        _ => 'Sharing precise',
      };

  Widget _contactTile(RecordModel c) {
    final name = _names[c.id] ?? 'Unnamed device';
    final prec = c.getStringValue('precision');
    final paused = prec == 'off';
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text(name[0].toUpperCase())),
        title: Text(name),
        subtitle: Text(
          _approxOnly && !paused
              ? 'Sharing approximate (global setting)'
              : _precLabel(prec),
          style: TextStyle(
              fontSize: 12,
              color: paused ? Theme.of(context).colorScheme.error : Brand.stone),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'remove') {
              _removeContact(c.getStringValue('peer'), name);
            } else {
              _setPrecision(c, v);
            }
          },
          itemBuilder: (context) => [
            _precItem('precise', 'Precise', Icons.gps_fixed, prec),
            _precItem('approximate', 'Approximate (~1 km)', Icons.blur_on, prec),
            _precItem('off', 'Pause sharing', Icons.pause_circle_outline, prec),
            const PopupMenuDivider(),
            const PopupMenuItem(
                value: 'remove',
                child: ListTile(
                    leading: Icon(Icons.person_remove), title: Text('Remove'))),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _precItem(
      String value, String label, IconData icon, String current) {
    final selected = current == value || (value == 'precise' && current.isEmpty);
    return PopupMenuItem(
      value: value,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: selected ? const Icon(Icons.check, size: 18) : null,
      ),
    );
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
    if (on) {
      final ok = await BackgroundShare.enable();
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Set location to "Allow all the time" in system settings to '
                  'share in the background.')));
        }
        return;
      }
    } else {
      await BackgroundShare.disable();
    }
    if (mounted) setState(() => _bgEnabled = on);
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
                  value: 'backup',
                  child: ListTile(
                      leading: Icon(Icons.vpn_key),
                      title: Text('Backup & restore'))),
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
