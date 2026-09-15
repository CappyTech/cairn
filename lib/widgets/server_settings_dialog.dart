import 'package:flutter/material.dart';
import '../services/pb_client.dart';

/// Shows the "Server address" dialog and returns true if the address was
/// changed (saved or reset to default) — so the caller can rebuild the app onto
/// the new server. Used from both the Home screen menu AND the start-up error
/// screen, so a bad address is always recoverable (it can otherwise brick
/// launch: the app persists it, fails to sign in, and never reaches Home).
Future<bool> showServerSettingsDialog(BuildContext context) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => const _ServerSettingsDialog(),
  );
  return changed ?? false;
}

class _ServerSettingsDialog extends StatefulWidget {
  const _ServerSettingsDialog();

  @override
  State<_ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<_ServerSettingsDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await savedServerUrl();
    _controller.text = saved.isEmpty ? serverUrl : saved;
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _controller.text.trim();
    if (!isValidServerUrl(url)) {
      setState(() => _error =
          'Enter a full address including http:// or https:// — '
          'e.g. http://192.168.1.5:8090');
      return;
    }
    await setServerUrl(url);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _reset() async {
    await clearServerUrl();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Server address'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Currently: $serverUrl',
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enabled: !_loading,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: 'PocketBase URL',
              hintText: 'http://192.168.1.5:8090',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "On a real phone, use your PC's network address, not localhost. "
            'Include http:// or https://.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
            onPressed: _reset, child: const Text('Reset to default')),
        FilledButton(
            onPressed: _save, child: const Text('Save & restart')),
      ],
    );
  }
}
