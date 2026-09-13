import 'dart:convert';
import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'auth_service.dart';

/// QR pairing: connect to a select person by scanning their code.
///
/// - Your QR carries only YOUR public info (id, name, public key).
/// - Scanning someone creates your own `contacts` row and posts a
///   `pair_requests` row aimed at them, so their app can reciprocate.
class PairingService {
  /// The JSON string encoded into this device's QR code.
  static String myQrPayload() {
    final u = AuthService.currentUser!;
    return jsonEncode({
      'v': 1,
      'id': u.id,
      'n': u.getStringValue('name'),
      'k': u.getStringValue('public_key'),
    });
  }

  /// Handle a scanned QR payload: create my side of the link and notify them.
  /// Returns the paired person's display name.
  static Future<String> pairFromPayload(String raw) async {
    final me = AuthService.currentUser!;
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw 'That QR code is not a valid invite.';
    }
    final theirId = data['id'] as String?;
    final theirName = (data['n'] ?? '') as String;
    final theirKey = data['k'] as String?;
    if (theirId == null || theirKey == null) {
      throw 'That QR code is not a valid invite.';
    }
    if (theirId == me.id) throw "That's your own code 🙂";

    await _ensureContact(
      ownerId: me.id,
      peerId: theirId,
      peerName: theirName,
      peerKey: theirKey,
    );
    await pb.collection('pair_requests').create(body: {
      'target': theirId,
      'from': me.id,
      'from_name': me.getStringValue('name'),
      'from_pubkey': me.getStringValue('public_key'),
    });
    return theirName.isEmpty ? 'their device' : theirName;
  }

  /// Someone scanned MY code → create the mirror contact and clear the request.
  /// Call on app open and whenever a realtime request arrives.
  static Future<void> processPendingRequests() async {
    final me = AuthService.currentUser!;
    final reqs = await pb.collection('pair_requests').getFullList();
    for (final r in reqs) {
      await _ensureContact(
        ownerId: me.id,
        peerId: r.getStringValue('from'),
        peerName: r.getStringValue('from_name'),
        peerKey: r.getStringValue('from_pubkey'),
      );
      await pb.collection('pair_requests').delete(r.id);
    }
  }

  /// This device's own contacts (owner = me), i.e. the people I've paired with.
  static Future<List<RecordModel>> myContacts() async {
    final me = AuthService.currentUser!;
    return pb.collection('contacts').getFullList(
      filter: 'owner = "${me.id}"',
      sort: 'peer_name',
    );
  }

  /// Unpair: remove this contact from my side and stop sharing my location to
  /// them (deletes my contact row + my outgoing shares to them). Their own copy
  /// only they can remove.
  static Future<void> removeContact(String peerId) async {
    final me = AuthService.currentUser!;
    for (final c in await pb.collection('contacts').getFullList(
        filter: 'owner = "${me.id}" && peer = "$peerId"')) {
      await pb.collection('contacts').delete(c.id);
    }
    for (final s in await pb.collection('location_shares').getFullList(
        filter: 'sender = "${me.id}" && recipient = "$peerId"')) {
      await pb.collection('location_shares').delete(s.id);
    }
  }

  static Future<void> _ensureContact({
    required String ownerId,
    required String peerId,
    required String peerName,
    required String peerKey,
  }) async {
    final existing = await pb.collection('contacts').getFullList(
      filter: 'owner = "$ownerId" && peer = "$peerId"',
    );
    final body = {
      'owner': ownerId,
      'peer': peerId,
      'peer_name': peerName,
      'peer_pubkey': peerKey,
      'status': 'active',
    };
    if (existing.isNotEmpty) {
      await pb.collection('contacts').update(existing.first.id, body: body);
    } else {
      await pb.collection('contacts').create(body: body);
    }
  }
}
