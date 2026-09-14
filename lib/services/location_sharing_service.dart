import 'dart:convert';
import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'auth_service.dart';
import 'pairing_service.dart';
import 'crypto_service.dart';
import 'prefs.dart';

/// A decrypted location received from a paired contact.
class ContactLocation {
  final String senderId;
  final String name;
  final double lat;
  final double lng;
  final double? accuracy;
  final bool approximate; // sender shared a rounded (coarse) position
  final DateTime updated; // when they last shared (= presence signal)

  ContactLocation({
    required this.senderId,
    required this.name,
    required this.lat,
    required this.lng,
    this.accuracy,
    this.approximate = false,
    required this.updated,
  });
}

/// Publishes my encrypted location to contacts and receives theirs.
class LocationSharingService {
  /// Round to ~2 decimal places (~1.1 km) for "approximate" sharing.
  static double _coarse(double v) => (v * 100).roundToDouble() / 100;

  /// Encrypt my position for each paired contact and upsert their share row.
  /// Precision is decided PER CONTACT (their `precision`: precise / approximate /
  /// off), with a global "approximate only" master-switch that coarsens everyone.
  static Future<void> publish({
    required double lat,
    required double lng,
    double? accuracy,
  }) async {
    final me = AuthService.currentUser;
    if (me == null) return;
    final approxOnly = await Prefs.approxOnly();
    final contacts = await PairingService.myContacts();
    final ts = DateTime.now().toUtc().toIso8601String();

    for (final c in contacts) {
      final peerId = c.getStringValue('peer');
      final peerKey = c.getStringValue('peer_pubkey');
      if (peerId.isEmpty || peerKey.isEmpty) continue;

      // Their key changed and hasn't been re-verified in person — don't publish
      // to a key we no longer trust. Existing shares stay under the old key.
      if (c.getStringValue('status') == 'key_changed') continue;

      final precision = c.getStringValue('precision');

      // Paused: stop sharing with them and clear any existing location.
      if (precision == 'off') {
        for (final s in await pb.collection('location_shares').getFullList(
            filter: 'sender = "${me.id}" && recipient = "$peerId"')) {
          await pb.collection('location_shares').delete(s.id);
        }
        continue;
      }

      final approximate = approxOnly || precision == 'approximate';
      final payload = utf8.encode(jsonEncode({
        'lat': approximate ? _coarse(lat) : lat,
        'lng': approximate ? _coarse(lng) : lng,
        'acc': approximate ? null : accuracy,
        'approx': approximate,
        'ts': ts,
      }));
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
      await pb.collection('users').update(me.id, body: {'last_seen': ts});
    } catch (_) {}
  }

  /// Load + decrypt every location shared TO me, then keep it live.
  /// Returns an unsubscribe function.
  static Future<Future<void> Function()> subscribe(
      void Function(Map<String, ContactLocation>) onUpdate) async {
    final me = AuthService.currentUser!;
    final byId = <String, ContactLocation>{};

    final names = <String, String>{};
    for (final c in await PairingService.myContacts()) {
      names[c.getStringValue('peer')] =
          await PairingService.decryptName(c.getStringValue('peer_name'));
    }

    Future<void> ingest(RecordModel r) async {
      final sender = r.getStringValue('sender');
      if (!names.containsKey(sender)) return; // not a current contact
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
          approximate: data['approx'] == true,
          updated: DateTime.tryParse(r.getStringValue('updated'))?.toLocal() ??
              DateTime.now(),
        );
      } catch (_) {
        // Undecryptable — ignore.
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
