import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import '../services/nickname_service.dart';
import '../services/pairing_service.dart';

/// A recipient chosen to share something with: their id and public key.
typedef ShareRecipient = ({String id, String pubKey});

/// Show a multi-select picker of the user's contacts and return the chosen
/// recipients, or null if the user cancelled or there was no one/nothing to
/// pick. Shared by the map's "share a pin here" flow and the Places "share with
/// contacts" flow so both look and behave identically.
///
/// Shows a "no contacts yet" snackbar (and returns null) when there's nobody to
/// share with. Guards every async gap with `context.mounted`.
Future<List<ShareRecipient>?> pickShareRecipients(
  BuildContext context, {
  required String title,
}) async {
  final List<RecordModel> contacts;
  try {
    contacts = await PairingService.myContacts();
  } catch (_) {
    return null;
  }
  if (!context.mounted) return null;
  if (contacts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No contacts to share with yet.')));
    return null;
  }
  final nicks = await NicknameService.all();
  // Build (id, pubKey, name), skipping any contact without a key.
  final options = <({String id, String pubKey, String name})>[];
  for (final c in contacts) {
    final peerId = c.getStringValue('peer');
    final pubKey = c.getStringValue('peer_pubkey');
    if (peerId.isEmpty || pubKey.isEmpty) continue;
    options.add((
      id: peerId,
      pubKey: pubKey,
      name: NicknameService.resolveName(
          alias: nicks[peerId],
          peerName:
              await PairingService.decryptName(c.getStringValue('peer_name'))),
    ));
  }
  if (!context.mounted) return null;

  final selected = <String>{};
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final o in options)
                CheckboxListTile(
                  value: selected.contains(o.id),
                  title: Text(o.name),
                  onChanged: (v) => setLocal(() =>
                      v == true ? selected.add(o.id) : selected.remove(o.id)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed:
                  selected.isEmpty ? null : () => Navigator.pop(context, true),
              child: const Text('Share')),
        ],
      ),
    ),
  );
  if (ok != true) return null;
  return [
    for (final o in options)
      if (selected.contains(o.id)) (id: o.id, pubKey: o.pubKey)
  ];
}
