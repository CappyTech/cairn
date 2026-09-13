import 'dart:convert';
import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'auth_service.dart';
import 'pairing_service.dart';
import 'crypto_service.dart';

/// A decrypted location received from a paired contact.
class ContactLocation {
  final String senderId;
  final String name;
  final double lat;
  final double lng;
  final double? accuracy;
  final DateTime updated; // when they last shared (= presence signal)

  ContactLocation({
    required this.senderId,
    required this.name,
    required this.lat,
    required this.lng,
    this.accuracy,
    required this.updated,
  });
}

/// Publishes my encrypted location to contacts and receives theirs.
class LocationSharingService {
  /// Encrypt my position for each paired contact and upsert their share row.
  static Future<void> publish({
    required double lat,
    required double lng,
    double? accuracy,
  }) async {
    final me = AuthService.currentUser;
    if (me == null) return;
    final contacts = await PairingService.myContacts();
    final payload = utf8.encode(jsonEncode({
      'lat': lat,
      'lng': lng,
      'acc': accuracy,
      'ts': DateTime.now().toUtc().toIso8601String(),
    }));

    for (final c in contacts) {
      final peerId = c.getStringValue('peer');
      final peerKey = c.getStringValue('peer_pubkey');
      if (peerId.isEmpty || peerKey.isEmpty) continue;
      final blob = await CryptoService.sealFor(peerKey, payload);
      final body = {'sender': me.id, 'recipient': peerId, 'ciphertext': blob};
      final existing = await pb.collection('location_shares').getFullList(
          filter: 'sender = "${me.id}" && recipient = "$peerId"');
      if (existing.isNotEmpty) {
        await pb.collection('location_shares').update(existing.first.id, body: body);
      } else {
        await pb.collection('location_shares').create(body: body);
      }
    }
    // Presence heartbeat (best-effort).
    try {
      await pb.collection('users').update(me.id,
          body: {'last_seen': DateTime.now().toUtc().toIso8601String()});
    } catch (_) {}
  }

  /// Load + decrypt every location shared TO me, then keep it live.
  /// [onUpdate] is called with the current map of senderId -> ContactLocation.
  /// Returns an unsubscribe function.
  static Future<Future<void> Function()> subscribe(
      void Function(Map<String, ContactLocation>) onUpdate) async {
    final me = AuthService.currentUser!;
    final byId = <String, ContactLocation>{};

    // Map senderId -> display name from my contacts.
    final names = <String, String>{};
    for (final c in await PairingService.myContacts()) {
      names[c.getStringValue('peer')] = c.getStringValue('peer_name');
    }

    Future<void> ingest(RecordModel r) async {
      final sender = r.getStringValue('sender');
      // Only show people who are still my contacts (drops removed/unpaired ones
      // even if they keep sending).
      if (!names.containsKey(sender)) return;
      try {
        final clear = await CryptoService.openSealed(r.getStringValue('ciphertext'));
        final data = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
        byId[sender] = ContactLocation(
          senderId: sender,
          name: names[sender]?.isNotEmpty == true
              ? names[sender]!
              : 'Unnamed device',
          lat: (data['lat'] as num).toDouble(),
          lng: (data['lng'] as num).toDouble(),
          accuracy: (data['acc'] as num?)?.toDouble(),
          updated: DateTime.tryParse(r.getStringValue('updated'))?.toLocal() ??
              DateTime.now(),
        );
      } catch (_) {
        // Undecryptable (not for me / bad data) — ignore.
      }
    }

    for (final r in await pb
        .collection('location_shares')
        .getFullList(filter: 'recipient = "${me.id}"')) {
      await ingest(r);
    }
    onUpdate(Map.of(byId));

    return pb.collection('location_shares').subscribe('*', (e) async {
      final rec = e.record;
      if (rec == null || rec.getStringValue('recipient') != me.id) return;
      if (e.action == 'delete') {
        byId.remove(rec.getStringValue('sender'));
      } else {
        await ingest(rec);
      }
      onUpdate(Map.of(byId));
    });
  }
}
