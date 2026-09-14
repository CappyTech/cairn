import 'dart:convert';
import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'auth_service.dart';
import 'crypto_service.dart';

/// What to do with a contact link when we (re)learn a peer's public key.
enum ContactKeyAction {
  /// No link yet — create it (trust-on-first-use).
  createNew,

  /// Adopt the key and mark the contact healthy (unchanged key, or a key
  /// re-confirmed in person).
  refresh,

  /// The key changed and we only heard it from the server — flag it for
  /// in-person re-verification and keep the old, verified key.
  keyChanged,
}

/// QR pairing: connect to a select person by scanning their code.
///
/// - Your QR carries only YOUR public info (id, name, public key).
/// - Scanning someone creates your own `contacts` row and posts a
///   `pair_requests` row aimed at them, so their app can reciprocate.
class PairingService {
  /// The JSON string encoded into this device's QR code. The name travels in the
  /// QR (scanned in person, never via the server) — plaintext here is fine.
  static Future<String> myQrPayload() async {
    final u = AuthService.currentUser!;
    return jsonEncode({
      'v': 1,
      'id': u.id,
      'n': await AuthService.displayName(),
      'k': u.getStringValue('public_key'),
    });
  }

  /// Decrypt a stored (encrypted-to-self) contact name for display.
  static Future<String> decryptName(String cipher) async {
    if (cipher.isEmpty) return 'Unnamed device';
    try {
      return await CryptoService.openSealedText(cipher);
    } catch (_) {
      return 'Unnamed device';
    }
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
      trusted: true, // scanned in person → this key is authentic
    );
    // Send MY name to them encrypted to THEIR key — only they can read it.
    final myName = await AuthService.displayName();
    await pb.collection('pair_requests').create(body: {
      'target': theirId,
      'from': me.id,
      'from_name': await CryptoService.sealTextFor(theirKey, myName),
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
      // from_name is encrypted to me — decrypt, then store it encrypted-to-self.
      final name = await decryptName(r.getStringValue('from_name'));
      await _ensureContact(
        ownerId: me.id,
        peerId: r.getStringValue('from'),
        peerName: name,
        peerKey: r.getStringValue('from_pubkey'),
        trusted: false, // relayed by the server → don't trust a changed key
      );
      await pb.collection('pair_requests').delete(r.id);
    }
  }

  /// This device's own contacts (owner = me), i.e. the people I've paired with.
  static Future<List<RecordModel>> myContacts() async {
    final me = AuthService.currentUser!;
    return pb.collection('contacts').getFullList(
      filter: 'owner = "${me.id}"',
      sort: 'created', // peer_name is now ciphertext, so can't sort on it
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

  /// Decide what to do with a contact link when a peer's public key arrives.
  ///
  /// A key that only reached us over the server ([trusted] == false) must never
  /// silently replace one we verified in person: a compromised server could
  /// swap it to read our shares. So a *changed* key from that channel is flagged
  /// ([ContactKeyAction.keyChanged]) rather than adopted. A key from an in-person
  /// QR scan ([trusted] == true), an unchanged key, or trust-on-first-use are
  /// all safe to adopt.
  ///
  /// Pure and side-effect-free so it can be unit-tested without a server.
  static ContactKeyAction decideKeyAction({
    required bool exists,
    required String storedKey,
    required String incomingKey,
    required bool trusted,
  }) {
    if (!exists) return ContactKeyAction.createNew;
    if (trusted || storedKey.isEmpty || storedKey == incomingKey) {
      return ContactKeyAction.refresh;
    }
    return ContactKeyAction.keyChanged;
  }

  static Future<void> _ensureContact({
    required String ownerId,
    required String peerId,
    required String peerName,
    required String peerKey,
    required bool trusted,
  }) async {
    final existing = await pb.collection('contacts').getFullList(
      filter: 'owner = "$ownerId" && peer = "$peerId"',
    );
    final current = existing.isEmpty ? null : existing.first;
    final action = decideKeyAction(
      exists: current != null,
      storedKey: current?.getStringValue('peer_pubkey') ?? '',
      incomingKey: peerKey,
      trusted: trusted,
    );

    switch (action) {
      case ContactKeyAction.keyChanged:
        // Keep the verified key untouched — only raise the flag so the UI can
        // warn and prompt an in-person re-scan.
        await pb.collection('contacts')
            .update(current!.id, body: {'status': 'key_changed'});
      case ContactKeyAction.refresh:
        // Don't touch `precision` on update — keep the user's per-contact choice.
        await pb.collection('contacts').update(current!.id, body: {
          'owner': ownerId,
          'peer': peerId,
          // Store the peer's name encrypted-to-self — only I can read it back.
          'peer_name': await CryptoService.sealTextForSelf(peerName),
          'peer_pubkey': peerKey,
          'status': 'active',
        });
      case ContactKeyAction.createNew:
        await pb.collection('contacts').create(body: {
          'owner': ownerId,
          'peer': peerId,
          'peer_name': await CryptoService.sealTextForSelf(peerName),
          'peer_pubkey': peerKey,
          'status': 'active',
          'precision': 'precise',
        });
    }
  }

  /// Set how precisely I share with a contact: 'precise', 'approximate', or
  /// 'off' (paused). Pausing also clears any location currently shared to them.
  static Future<void> setPrecision(String contactId, String peerId,
      String precision) async {
    await pb.collection('contacts').update(contactId, body: {'precision': precision});
    if (precision == 'off') {
      final me = AuthService.currentUser!;
      for (final s in await pb.collection('location_shares').getFullList(
          filter: 'sender = "${me.id}" && recipient = "$peerId"')) {
        await pb.collection('location_shares').delete(s.id);
      }
    }
  }
}
