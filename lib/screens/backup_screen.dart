import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/crypto_service.dart';
import '../services/auth_service.dart';
import '../services/background_share.dart';
import '../services/pb_client.dart';
import '../widgets/restart_widget.dart';
import '../theme/brand.dart';

/// Back up the device identity as a 24-word recovery phrase, or restore one.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  List<String>? _words; // revealed phrase
  final _restoreCtrl = TextEditingController();
  String? _restoreError;
  bool _busy = false;

  @override
  void dispose() {
    _restoreCtrl.dispose();
    super.dispose();
  }

  Future<void> _reveal() async {
    final phrase = await CryptoService.recoveryPhrase();
    setState(() => _words = phrase.split(' '));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _words!.join(' ')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recovery phrase copied')));
    }
  }

  Future<void> _deleteIdentity() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this identity?'),
        content: const Text(
            'This permanently deletes your account and removes you from '
            'everyone you\'re paired with. Unless you saved your recovery '
            'phrase, it cannot be undone. The app will start fresh.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (isMobile) {
      try {
        await BackgroundShare.disable();
      } catch (_) {}
    }
    await AuthService.deleteAccount();
    if (mounted) await RestartWidget.restart(context);
  }

  Future<void> _restore() async {
    setState(() => _restoreError = null);
    final phrase = _restoreCtrl.text;
    if (!CryptoService.isValidPhrase(phrase)) {
      setState(() => _restoreError =
          'That doesn\'t look like a valid 24-word recovery phrase.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace this identity?'),
        content: const Text(
            'Restoring will switch this device to the identity in that phrase. '
            'The current identity on this device will be replaced.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await CryptoService.restoreFromPhrase(phrase);
      pb.authStore.clear(); // drop the old device session
      if (mounted) await RestartWidget.restart(context); // re-auth as restored
    } catch (e) {
      if (mounted) setState(() => _restoreError = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- Backup ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: const [
                    Icon(Icons.vpn_key, size: 18),
                    SizedBox(width: 8),
                    Text('Your recovery phrase',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'These 24 words ARE your identity. Write them down and keep '
                    'them somewhere safe and private. Anyone with them can '
                    'become you; without them, a lost or wiped phone means a '
                    'lost identity.',
                    style: TextStyle(color: context.cairn.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  if (_words == null)
                    FilledButton.icon(
                      onPressed: _reveal,
                      icon: const Icon(Icons.visibility),
                      label: const Text('Reveal recovery phrase'),
                    )
                  else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.cairn.sheet,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: context.cairn.outline),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < _words!.length; i++)
                            Text('${i + 1}. ${_words![i]}',
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 13)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        OutlinedButton.icon(
                            onPressed: _copy,
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('Copy')),
                        const SizedBox(width: 8),
                        TextButton(
                            onPressed: () => setState(() => _words = null),
                            child: const Text('Hide')),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // ---- Restore ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: const [
                    Icon(Icons.restore, size: 18),
                    SizedBox(width: 8),
                    Text('Restore from a phrase',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'Moving to a new phone? Paste your 24-word phrase to bring '
                    'your identity (and contacts) back.',
                    style: TextStyle(color: context.cairn.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _restoreCtrl,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      hintText: 'word1 word2 word3 …',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_restoreError != null) ...[
                    const SizedBox(height: 8),
                    Text(_restoreError!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 13)),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _busy ? null : _restore,
                    icon: _busy
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.restore),
                    label: const Text('Restore this identity'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // ---- Danger zone ----
          Card(
            color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: const [
                    Icon(Icons.warning_amber, size: 18),
                    SizedBox(width: 8),
                    Text('Danger zone',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'Delete this identity and remove yourself from everyone. '
                    'Irreversible without your recovery phrase.',
                    style: TextStyle(color: context.cairn.muted, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _deleteIdentity,
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error),
                    icon: const Icon(Icons.delete_forever, size: 18),
                    label: const Text('Delete this identity'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
