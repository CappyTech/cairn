import 'package:flutter/material.dart';
import '../services/shared_places_service.dart';
import '../theme/brand.dart';

/// Manage shared pins: what I've shared (with revoke) and what contacts have
/// shared with me.
class SharedPinsScreen extends StatefulWidget {
  const SharedPinsScreen({super.key});

  @override
  State<SharedPinsScreen> createState() => _SharedPinsScreenState();
}

class _SharedPinsScreenState extends State<SharedPinsScreen> {
  List<SharedPin> _mine = [];
  List<SharedPin> _withMe = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<SharedPin> mine = [];
    List<SharedPin> withMe = [];
    try {
      mine = await SharedPlacesService.mineShared();
    } catch (_) {}
    try {
      withMe = await SharedPlacesService.sharedWithMe();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _mine = mine;
        _withMe = withMe;
        _loading = false;
      });
    }
  }

  Future<void> _revoke(SharedPin p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop sharing "${p.name}"?'),
        content: const Text(
            'It will be removed from your contacts\' maps. This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Stop sharing')),
        ],
      ),
    );
    if (ok != true) return;
    await SharedPlacesService.revoke(p.group);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shared pins')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _header('Shared by me'),
                  if (_mine.isEmpty)
                    _empty('You haven\'t shared any pins yet. Share a place '
                        'from the Places list to put it on a contact\'s map.')
                  else
                    ..._mine.map(_mineTile),
                  const SizedBox(height: 16),
                  _header('Shared with me'),
                  if (_withMe.isEmpty)
                    _empty('No pins shared with you yet.')
                  else
                    ..._withMe.map(_withMeTile),
                ],
              ),
            ),
    );
  }

  Widget _header(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Text(t, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _empty(String t) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text(t,
            style: TextStyle(color: context.cairn.muted, fontSize: 13)),
      );

  Widget _mineTile(SharedPin p) {
    final n = p.recipientIds.length;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Color(0x228FA35D),
          child: Icon(Icons.push_pin, color: context.cairn.ink),
        ),
        title: Text(p.name),
        subtitle: Text('Shared with $n contact${n == 1 ? '' : 's'}'),
        trailing: TextButton(
          onPressed: () => _revoke(p),
          child: const Text('Stop'),
        ),
      ),
    );
  }

  Widget _withMeTile(SharedPin p) => Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: Color(0x228FA35D),
            child: Icon(Icons.push_pin, color: context.cairn.ink),
          ),
          title: Text(p.name),
          subtitle: Text(
            [
              'from ${p.sharerName.isEmpty ? 'a contact' : p.sharerName}',
              if (p.note != null) p.note!,
            ].join(' · '),
          ),
        ),
      );
}
