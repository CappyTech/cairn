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

  /// Whether this contact's location history is being recorded, and whether
  /// their movements raise place alerts (both default on). Local, per-contact.
  final bool historyOn;
  final bool alertsOn;

  /// Freshness chip: how recently they shared (e.g. "Live", "5m ago", "No
  /// location yet") and the dot colour for it. Null hides the chip.
  final String? presenceLabel;
  final Color? presenceColor;

  final void Function(String precision) onSetPrecision;
  final VoidCallback onRemove;
  final VoidCallback onRescan;
  final VoidCallback onRename;
  final VoidCallback? onToggleHistory;
  final VoidCallback? onToggleAlerts;

  /// Tapping the row (e.g. to centre the map on them). Null = not tappable.
  final VoidCallback? onTap;

  const ContactTile({
    super.key,
    required this.name,
    required this.precision,
    required this.approxOnly,
    required this.keyChanged,
    required this.onSetPrecision,
    required this.onRemove,
    required this.onRescan,
    required this.onRename,
    this.historyOn = true,
    this.alertsOn = true,
    this.presenceLabel,
    this.presenceColor,
    this.onToggleHistory,
    this.onToggleAlerts,
    this.onTap,
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
        onTap: onTap,
        leading: CircleAvatar(child: Text(initial(name))),
        title: Text(name),
        subtitle: Text(
          approxOnly && !paused
              ? 'Sharing approximate (global setting)'
              : precLabel(precision),
          style: TextStyle(
              fontSize: 12,
              color:
                  paused ? Theme.of(context).colorScheme.error : context.cairn.muted),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (presenceLabel != null) _presenceChip(context),
            PopupMenuButton<String>(
          onSelected: (v) => switch (v) {
            'rename' => onRename(),
            'remove' => onRemove(),
            'history' => onToggleHistory?.call(),
            'alerts' => onToggleAlerts?.call(),
            _ => onSetPrecision(v),
          },
          itemBuilder: (context) => [
            _precItem('precise', 'Precise', Icons.gps_fixed),
            _precItem('approximate', 'Approximate (~1 km)', Icons.blur_on),
            _precItem('off', 'Pause sharing', Icons.pause_circle_outline),
            const PopupMenuDivider(),
            // Local per-contact toggles. Trailing switch reflects current state.
            _toggleItem(context, 'history', 'Record history', Icons.history, historyOn),
            _toggleItem(context,
                'alerts', 'Place alerts', Icons.notifications_active_outlined,
                alertsOn),
            const PopupMenuDivider(),
            const PopupMenuItem(
                value: 'rename',
                child: ListTile(
                    leading: Icon(Icons.drive_file_rename_outline),
                    title: Text('Rename'))),
            const PopupMenuItem(
                value: 'remove',
                child: ListTile(
                    leading: Icon(Icons.person_remove), title: Text('Remove'))),
          ],
            ),
          ],
        ),
      ),
    );
  }

  /// Small freshness pill: a coloured dot + label (e.g. "Live", "5m ago").
  Widget _presenceChip(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                  color: presenceColor ?? context.cairn.muted, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(presenceLabel!,
                style: TextStyle(fontSize: 11, color: context.cairn.muted)),
          ],
        ),
      );

  PopupMenuItem<String> _toggleItem(BuildContext context,
      String value, String label, IconData icon, bool on) {
    return PopupMenuItem(
      value: value,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: Icon(
          on ? Icons.toggle_on : Icons.toggle_off,
          color: on ? Brand.lichen : context.cairn.muted,
          size: 26,
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
