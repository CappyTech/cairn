import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/auth_service.dart';
import '../services/pb_client.dart';
import '../services/prefs.dart';
import '../theme/brand.dart';
import '../widgets/motion_settings_tiles.dart';
import '../widgets/restart_widget.dart';
import '../widgets/server_settings_dialog.dart';
import 'admin_screen.dart';
import 'backup_screen.dart';
import 'history_screen.dart';
import 'places_screen.dart';

/// Ask for a new display name and save it. Returns the new name, or null if
/// cancelled. Shared by Settings and Home's "Set your name" link.
Future<String?> showEditNameDialog(BuildContext context, String current) async {
  final controller = TextEditingController(text: current);
  final newName = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Your display name'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
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
  if (newName == null || newName.isEmpty) return null;
  await AuthService.setDisplayName(newName);
  return newName;
}

/// Everything that used to live in Home's overflow menu, grouped:
/// You (name, backup), Speed & direction, Places & history, App (layout,
/// server, about) — plus
/// the admin dashboard for admins. Home reloads name and layout on return.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _name = '';
  HomeLayout _layout = HomeLayout.refined;
  String _version = '';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final name = await AuthService.displayName();
    final layout = await Prefs.homeLayout();
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _name = name;
      _layout = layout;
      _version = info.version;
    });
  }

  void _open(Widget screen) => Navigator.push(
      context, MaterialPageRoute(builder: (_) => screen));

  Future<void> _editName() async {
    final n = await showEditNameDialog(context, _name);
    if (n != null && mounted) setState(() => _name = n);
  }

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

  Future<void> _serverSettings() async {
    final changed = await showServerSettingsDialog(context);
    if (changed && mounted) await RestartWidget.restart(context);
  }

  Future<void> _about() async {
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

  @override
  Widget build(BuildContext context) {
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(text,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: context.cairn.muted)),
        );
    Widget item(IconData icon, String title, VoidCallback onTap,
            {String? subtitle}) =>
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          header('You'),
          item(Icons.person_outline, 'Name', _editName,
              subtitle: _name.isEmpty ? null : _name),
          item(Icons.key_outlined, 'Backup & restore',
              () => _open(const BackupScreen()),
              subtitle: 'Your recovery phrase'),
          header('Speed & direction'),
          const MotionSettingsTiles(),
          header('Places & history'),
          item(Icons.place_outlined, 'Places',
              () => _open(const PlacesScreen())),
          item(Icons.history, 'History', () => _open(const HistoryScreen()),
              subtitle: 'Trips, how long to keep them, travel detection'),
          header('App'),
          item(Icons.dashboard_customize_outlined, 'Home layout', _chooseLayout,
              subtitle: _layoutInfo[_layout]!.$2),
          item(Icons.dns_outlined, 'Server', _serverSettings,
              subtitle: Uri.tryParse(serverUrl)?.host),
          item(Icons.info_outline, 'About', _about,
              subtitle: _version.isEmpty ? null : 'Version $_version'),
          if (isAdminView) ...[
            header('Admin'),
            item(Icons.admin_panel_settings_outlined, 'Admin dashboard',
                () => _open(const AdminScreen())),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
