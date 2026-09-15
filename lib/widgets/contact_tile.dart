import 'package:flutter/material.dart';
import '../theme/brand.dart';

/// One row in the contacts list. Purely presentational — it takes plain data
/// and callbacks (no services), so it renders identically in the app and in
/// widget tests.
///
/// Two shapes:
///  - normal: name + sharing-precision subtitle + a precision/remove menu;
///  - [keyChanged]: a warning card (the contact's key changed and isn't
///    re-verified) with "Re-scan to verify" and "Remove".
class ContactTile extends StatelessWidget {
  final String name;

  /// 'precise' | 'approximate' | 'off' | '' (empty == precise).
  final String precision;

  /// Global "approximate only" switch — coarsens everyone when on.
  final bool approxOnly;

  /// The contact's key changed and hasn't been re-verified in person.
  final bool keyChanged;

  final void Function(String precision) onSetPrecision;
  final VoidCallback onRemove;
  final VoidCallback onRescan;

  const ContactTile({
    super.key,
    required this.name,
    required this.precision,
    required this.approxOnly,
    required this.keyChanged,
    required this.onSetPrecision,
    required this.onRemove,
    required this.onRescan,
  });

  static String precLabel(String p) => switch (p) {
        'approximate' => 'Sharing approximate (~1 km)',
        'off' => 'Sharing paused',
        _ => 'Sharing precise',
      };

  /// The avatar initial. Guards against an empty name (e.g. a contact paired
  /// from a crafted QR/invite whose name was blank) so indexing never throws.
  static String initial(String name) {
    final t = name.trim();
    return t.isEmpty ? '?' : t[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    if (keyChanged) return _keyChanged(context);

    final paused = precision == 'off';
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text(initial(name))),
        title: Text(name),
        subtitle: Text(
          approxOnly && !paused
              ? 'Sharing approximate (global setting)'
              : precLabel(precision),
          style: TextStyle(
              fontSize: 12,
              color:
                  paused ? Theme.of(context).colorScheme.error : Brand.stone),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => v == 'remove' ? onRemove() : onSetPrecision(v),
          itemBuilder: (context) => [
            _precItem('precise', 'Precise', Icons.gps_fixed),
            _precItem('approximate', 'Approximate (~1 km)', Icons.blur_on),
            _precItem('off', 'Pause sharing', Icons.pause_circle_outline),
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

  PopupMenuItem<String> _precItem(String value, String label, IconData icon) {
    final selected =
        precision == value || (value == 'precise' && precision.isEmpty);
    return PopupMenuItem(
      value: value,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: selected ? const Icon(Icons.check, size: 18) : null,
      ),
    );
  }

  Widget _keyChanged(BuildContext context) {
    final err = Theme.of(context).colorScheme.error;
    return Card(
      color: err.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.gpp_maybe, color: err),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "$name's security key changed. This can happen if they reinstalled "
              'or switched devices — but it could also mean someone is '
              'impersonating them. Sharing is paused until you re-scan their code '
              'in person.',
              style: TextStyle(fontSize: 12, color: err),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: onRescan,
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('Re-scan to verify'),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: onRemove, child: const Text('Remove')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
