import 'package:flutter/material.dart';
import '../services/admin_service.dart';
import '../theme/brand.dart';

/// Local-only admin dashboard: a friendly view of every device, connection,
/// encrypted share and pending pairing in the system.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _email = TextEditingController(text: 'admin@local.test');
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  AdminSnapshot? _data;

  @override
  void initState() {
    super.initState();
    if (AdminService.isLoggedIn) _refresh();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() { _busy = true; _error = null; });
    try {
      await AdminService.login(_email.text.trim(), _password.text);
      await _refresh();
    } catch (e) {
      setState(() => _error = 'Login failed. Check the admin password.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() { _busy = true; _error = null; });
    try {
      final data = await AdminService.load();
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- presence helpers -----------------------------------------------------
  static (Color, String) _presence(String isoOrEmpty) {
    final t = DateTime.tryParse(isoOrEmpty);
    if (t == null) return (Colors.grey, 'never');
    final age = DateTime.now().toUtc().difference(t.toUtc());
    if (age.inMinutes < 2) return (Colors.green, 'live');
    if (age.inMinutes < 15) return (Colors.amber, '${age.inMinutes}m');
    if (age.inHours < 24) return (Colors.orange, '${age.inHours}h');
    return (Colors.grey, '${age.inDays}d');
  }

  static String _ago(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '—';
    final age = DateTime.now().toUtc().difference(t.toUtc());
    if (age.inSeconds < 60) return '${age.inSeconds}s ago';
    if (age.inMinutes < 60) return '${age.inMinutes}m ago';
    if (age.inHours < 24) return '${age.inHours}h ago';
    return '${age.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    if (!AdminService.isLoggedIn) return _loginView();
    final data = _data;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Admin dashboard'),
          actions: [
            IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: _busy ? null : _refresh),
            IconButton(
                tooltip: 'Log out',
                icon: const Icon(Icons.logout),
                onPressed: () {
                  AdminService.logout();
                  setState(() => _data = null);
                }),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Devices'),
              Tab(text: 'Connections'),
              Tab(text: 'Location shares'),
              Tab(text: 'Pending pairs'),
            ],
          ),
        ),
        body: data == null
            ? (_error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 40),
                          const SizedBox(height: 8),
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(
                              onPressed: _refresh, child: const Text('Retry')),
                        ],
                      ),
                    ),
                  )
                : const Center(child: CircularProgressIndicator()))
            : Column(
                children: [
                  _statsHeader(data),
                  const Divider(height: 1),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _devices(data),
                        _connections(data),
                        _shares(data),
                        _pairs(data),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // --- login ----------------------------------------------------------------
  Widget _loginView() {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin dashboard')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.admin_panel_settings, size: 56),
                const SizedBox(height: 8),
                const Text('Sign in as the PocketBase admin to inspect '
                    'everything in the system.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 20),
                TextField(
                  controller: _email,
                  decoration: const InputDecoration(
                      labelText: 'Admin email', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  onSubmitted: (_) => _busy ? null : _login(),
                  decoration: const InputDecoration(
                      labelText: 'Admin password',
                      border: OutlineInputBorder()),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _login,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Connect'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- stats header ---------------------------------------------------------
  Widget _statsHeader(AdminSnapshot d) {
    final activeNow = d.users
        .where((u) => _presence(u.getStringValue('last_seen')).$2 == 'live')
        .length;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _stat('Devices', '${d.users.length}', Icons.smartphone,
              Brand.ink(context)),
          _stat('Active now', '$activeNow', Icons.bolt, Colors.green),
          _stat('Connections', '${d.contacts.length}', Icons.link, Colors.teal),
          _stat('Shares', '${d.shares.length}', Icons.lock, Colors.deepPurple),
          _stat('Pending pairs', '${d.pairs.length}', Icons.hourglass_bottom,
              Colors.orange),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, IconData icon, Color color) {
    return Container(
      width: 120,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 6),
          Text(value,
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  // --- tabs -----------------------------------------------------------------
  Widget _empty(String msg) =>
      Center(child: Text(msg, style: const TextStyle(color: Colors.grey)));

  Widget _devices(AdminSnapshot d) {
    if (d.users.isEmpty) return _empty('No devices yet.');
    return ListView(
      children: d.users.map((u) {
        final name = 'device ${u.id.length > 8 ? u.id.substring(0, 8) : u.id}';
        final (color, label) = _presence(u.getStringValue('last_seen'));
        final key = u.getStringValue('public_key');
        return ListTile(
          leading: CircleAvatar(
              child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?')),
          title: Text(name.isEmpty ? 'Unnamed' : name),
          subtitle: Text(
            'id ${u.id}\nkey ${key.isEmpty ? '—' : '${key.substring(0, key.length.clamp(0, 16))}…'}',
            style: const TextStyle(fontSize: 11),
          ),
          isThreeLine: true,
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.circle, size: 12, color: color),
              Text(label, style: TextStyle(color: color, fontSize: 11)),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _connections(AdminSnapshot d) {
    if (d.contacts.isEmpty) return _empty('No connections yet.');
    final names = d.names;
    return ListView(
      children: d.contacts.map((c) {
        final owner = names[c.getStringValue('owner')] ?? c.getStringValue('owner');
        final peer = names[c.getStringValue('peer')] ?? c.getStringValue('peer');
        return ListTile(
          leading: const Icon(Icons.link),
          title: Text('$owner  →  $peer'),
          subtitle: Text('status: ${c.getStringValue('status')}',
              style: const TextStyle(fontSize: 12)),
        );
      }).toList(),
    );
  }

  Widget _shares(AdminSnapshot d) {
    if (d.shares.isEmpty) return _empty('No location shares yet.');
    final names = d.names;
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Colors.deepPurple.withValues(alpha: 0.06),
          padding: const EdgeInsets.all(10),
          child: const Text(
            '🔒 Locations are end-to-end encrypted — even here they are only '
            'ciphertext. The server/admin cannot read coordinates.',
            style: TextStyle(fontSize: 12),
          ),
        ),
        Expanded(
          child: ListView(
            children: d.shares.map((s) {
              final sender =
                  names[s.getStringValue('sender')] ?? s.getStringValue('sender');
              final recip = names[s.getStringValue('recipient')] ??
                  s.getStringValue('recipient');
              final bytes = s.getStringValue('ciphertext').length;
              return ListTile(
                leading: const Icon(Icons.lock, color: Colors.deepPurple),
                title: Text('$sender  →  $recip'),
                subtitle: Text('🔒 encrypted · $bytes bytes',
                    style: const TextStyle(fontSize: 12)),
                trailing: Text(_ago(s.getStringValue('updated')),
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _pairs(AdminSnapshot d) {
    if (d.pairs.isEmpty) return _empty('No pending pair requests.');
    final names = d.names;
    return ListView(
      children: d.pairs.map((p) {
        final target =
            names[p.getStringValue('target')] ?? p.getStringValue('target');
        final from = names[p.getStringValue('from')] ?? p.getStringValue('from');
        return ListTile(
          leading: const Icon(Icons.hourglass_bottom, color: Colors.orange),
          title: Text('$from  →  $target'),
          subtitle: const Text('waiting for the target device to reciprocate',
              style: TextStyle(fontSize: 12)),
        );
      }).toList(),
    );
  }
}
