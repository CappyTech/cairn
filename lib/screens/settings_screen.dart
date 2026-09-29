import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/auth_service.dart';
import '../services/background_share.dart';
import '../services/notification_service.dart';
import '../services/pb_client.dart';
import '../services/prefs.dart';
import '../services/sound_service.dart';
import '../theme/brand.dart';
import '../theme/theme_controller.dart';
import '../widgets/motion_settings_tiles.dart';
import '../widgets/restart_widget.dart';
import '../widgets/server_settings_dialog.dart';
import 'admin_screen.dart';
import 'backup_screen.dart';

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
/// You (name, backup), Speed & direction, App (appearance, layout, server,
/// about) — plus
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

  static const _themeInfo = {
    ThemeMode.system: (Icons.brightness_auto_outlined, 'Match system'),
    ThemeMode.light: (Icons.light_mode_outlined, 'Light'),
    ThemeMode.dark: (Icons.dark_mode_outlined, 'Dark'),
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

  Future<void> _chooseTheme() async {
    final current = ThemeController.mode.value;
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Appearance'),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(context, v),
            child: Column(
              children: [
                for (final e in _themeInfo.entries)
                  RadioListTile<ThemeMode>(
                    value: e.key,
                    secondary: Icon(e.value.$1),
                    title: Text(e.value.$2),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    await ThemeController.set(picked);
    if (mounted) setState(() {});
  }

  /// Each alert's sound, to listen to, and the way to change or mute them:
  /// they're per-channel, so the phone's notification settings own them.
  Future<void> _alertSounds() => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Alert sounds'),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final k in AlertKind.values)
                ListTile(
                  title: Text(k.name),
                  subtitle: Text(k.description,
                      style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.play_circle_outline),
                  onTap: () => SoundService.previewAlert(k.channel),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: BackgroundShare.openAppSettings,
              child: const Text('Change in phone settings'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done')),
          ],
        ),
      );

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
          header('Speed, direction & battery'),
          const MotionSettingsTiles(),
          header('Sounds'),
          FutureBuilder<bool>(
            future: SoundService.enabled(),
            builder: (context, snap) => SwitchListTile(
              secondary: const Icon(Icons.volume_up_outlined),
              title: const Text('Sound effects'),
              subtitle: const Text(
                  'Short sounds when you connect with someone or save '
                  'something. Follows your ringer.'),
              value: snap.data ?? true,
              onChanged: (v) async {
                await SoundService.setEnabled(v);
                if (v) SoundService.play(UiSound.tick);
                if (mounted) setState(() {});
              },
            ),
          ),
          item(Icons.notifications_active_outlined, 'Alert sounds',
              _alertSounds,
              subtitle: 'Arrivals, departures, quiet contacts, new contacts'),
          header('App'),
          item(_themeInfo[ThemeController.mode.value]!.$1, 'Appearance',
              _chooseTheme,
              subtitle: _themeInfo[ThemeController.mode.value]!.$2),
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
