import 'dart:convert';
import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'auth_service.dart';
import 'crypto_service.dart';
import 'invite_service.dart';
import 'nickname_service.dart';

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

/// What to do with an incoming pairing request, based on its proof-of-scan MAC.
enum InboundPairDecision {
  /// A valid MAC — the sender scanned our QR in person and the server didn't
  /// tamper with their key. Reciprocate and trust the key.
  trusted,

  /// No MAC at all (an older app, or a QR without a nonce). May only UPDATE an
  /// existing pairing — never create a new contact (that would let anyone
  /// inject themselves, or a server swap a key on first pair). A changed key on
  /// an existing contact is still flagged for in-person re-verification.
  unverified,

  /// A MAC that's present but wrong — the key was tampered with in transit, or
  /// the request is forged. Drop it; create nothing.
  reject,
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
      'v': 2,
      'id': u.id,
      'n': await AuthService.displayName(),
      'k': u.getStringValue('public_key'),
      // Secret nonce: lets whoever scans this prove (via a MAC on their pairing
      // request) that they scanned us in person and that our key wasn't swapped.
      's': await CryptoService.pairingNonce(),
    });
  }

  /// The message a pairing MAC is computed over. Binds the request's sender,
  /// target, and the sender's public key, so none can be swapped undetected.
  static String pairMacMessage({
    required String fromId,
    required String targetId,
    required String fromPubkey,
  }) =>
      '$fromId|$targetId|$fromPubkey';

  /// Decrypt a stored (encrypted-to-self) contact name for display.
  static Future<String> decryptName(String cipher) async {
    if (cipher.isEmpty) return 'Unnamed device';
    try {
      final name = await CryptoService.openSealedText(cipher);
      // A blank name (e.g. paired from a QR/invite with an empty name) decrypts
      // fine but must not surface empty — callers render an avatar initial off
      // the first character.
      return name.isEmpty ? 'Unnamed device' : name;
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
    final theirNonce = data['s'] as String?;
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

    // Prove to them that I really scanned their QR (and that my key below
    // reached them untouched): MAC keyed by the nonce from their QR. Only
    // possible when their QR carried one (v2+).
    final myPubkey = me.getStringValue('public_key');
    String? mac;
    if (theirNonce != null && theirNonce.isNotEmpty) {
      mac = await CryptoService.hmacBase64(
        base64Decode(theirNonce),
        pairMacMessage(fromId: me.id, targetId: theirId, fromPubkey: myPubkey),
      );
    }

    // Send MY name (and the proof MAC) to them encrypted to THEIR key — only
    // they can read it.
    final myName = await AuthService.displayName();
    await pb.collection('pair_requests').create(body: {
      'target': theirId,
      'from': me.id,
      'from_name': await CryptoService.sealTextFor(
          theirKey, jsonEncode({'n': myName, 'm': ?mac})),
      'from_pubkey': myPubkey,
    });
    return theirName.isEmpty ? 'their device' : theirName;
  }

  /// Classify an incoming pairing request from whether it carried a MAC and
  /// whether that MAC verified. Pure, so it can be unit-tested without a server.
  static InboundPairDecision classifyInbound({
    required bool macPresent,
    required bool macValid,
  }) {
    if (!macPresent) return InboundPairDecision.unverified;
    return macValid ? InboundPairDecision.trusted : InboundPairDecision.reject;
  }

  /// Someone scanned MY code → create the mirror contact and clear the request.
  /// Call on app open and whenever a realtime request arrives.
  ///
  /// Returns the display names of contacts that were *newly* created by this
  /// pass (a verified reciprocation), so the caller can announce "you're now
  /// connected with X". Re-confirmations and key-change flags are not included.
  static Future<List<String>> processPendingRequests() async {
    final newlyPaired = <String>[];
    final me = AuthService.currentUser!;
    final myNonce = await CryptoService.pairingNonce();
    final reqs = await pb.collection('pair_requests').getFullList();
    for (final r in reqs) {
      final fromId = r.getStringValue('from');
      final fromPubkey = r.getStringValue('from_pubkey');
      // from_name is encrypted to me — decrypt to get their name and proof MAC.
      final decoded = await _decodeFromName(r.getStringValue('from_name'));

      final macPresent = decoded.mac != null && decoded.mac!.isNotEmpty;
      var macValid = false;
      if (macPresent) {
        final message = pairMacMessage(
            fromId: fromId, targetId: me.id, fromPubkey: fromPubkey);
        // Accept a MAC keyed by our persistent QR nonce (in-person scan)...
        final expected =
            await CryptoService.hmacBase64(base64Decode(myNonce), message);
        macValid = CryptoService.macEquals(decoded.mac!, expected);
        // ...or by a live one-time remote invite (consumed on match).
        if (!macValid) {
          macValid =
              await InviteService.verifyAndConsume(message, decoded.mac!);
        }
      }

      switch (classifyInbound(macPresent: macPresent, macValid: macValid)) {
        case InboundPairDecision.trusted:
          final action = await _ensureContact(
            ownerId: me.id,
            peerId: fromId,
            peerName: decoded.name,
            peerKey: fromPubkey,
            trusted: true, // MAC verified → key is authentic
          );
          if (action == ContactKeyAction.createNew) {
            newlyPaired.add(decoded.name);
          }
        case InboundPairDecision.unverified:
          await _ensureContact(
            ownerId: me.id,
            peerId: fromId,
            peerName: decoded.name,
            peerKey: fromPubkey,
            trusted: false,
            // No proof of scan: may only UPDATE an existing pairing, never
            // create a new contact (blocks self-injection and first-pair key
            // swaps). A changed key on an existing contact is still flagged.
            createIfMissing: false,
          );
        case InboundPairDecision.reject:
          // MAC present but wrong: tampered or forged. Drop it, add nothing.
          break;
      }
      await pb.collection('pair_requests').delete(r.id);
    }
    return newlyPaired;
  }

  /// Decrypt a pairing request's `from_name`, returning the sender's display
  /// name and (for v2+ requests) the proof MAC. Handles the legacy format
  /// where `from_name` was just the encrypted name.
  static Future<({String name, String? mac})> _decodeFromName(
      String blob) async {
    if (blob.isEmpty) return (name: 'Unnamed device', mac: null);
    final String clear;
    try {
      clear = await CryptoService.openSealedText(blob);
    } catch (_) {
      return (name: 'Unnamed device', mac: null); // undecryptable
    }
    try {
      final obj = jsonDecode(clear);
      if (obj is Map<String, dynamic>) {
        final n = obj['n'] as String?;
        return (
          name: (n != null && n.isNotEmpty) ? n : 'Unnamed device',
          mac: obj['m'] as String?,
        );
      }
    } catch (_) {
      // Not JSON → legacy plain-name format; fall through.
    }
    return (name: clear.isNotEmpty ? clear : 'Unnamed device', mac: null);
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
    // Drop any local nickname so it can't linger for a re-paired stranger.
    await NicknameService.remove(peerId);
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

  /// Gate [decideKeyAction] by whether we're allowed to create a *new* contact.
  /// An unsigned pairing request (no proof-of-scan MAC) passes
  /// [createIfMissing] == false, so a would-be new contact becomes `null`
  /// (dropped) — that's what stops anyone from injecting themselves into your
  /// list, and stops a first-pair key swap. Existing contacts are unaffected.
  /// Pure, so it's unit-tested.
  static ContactKeyAction? applyCreatePolicy(
      ContactKeyAction action, bool createIfMissing) {
    if (action == ContactKeyAction.createNew && !createIfMissing) return null;
    return action;
  }

  /// Returns the action actually applied (or null if the request was dropped),
  /// so callers can tell a brand-new pairing from a re-confirmation.
  static Future<ContactKeyAction?> _ensureContact({
    required String ownerId,
    required String peerId,
    required String peerName,
    required String peerKey,
    required bool trusted,
    bool createIfMissing = true,
  }) async {
    final existing = await pb.collection('contacts').getFullList(
      filter: 'owner = "$ownerId" && peer = "$peerId"',
    );
    final current = existing.isEmpty ? null : existing.first;
    final action = applyCreatePolicy(
      decideKeyAction(
        exists: current != null,
        storedKey: current?.getStringValue('peer_pubkey') ?? '',
        incomingKey: peerKey,
        trusted: trusted,
      ),
      createIfMissing,
    );
    if (action == null) return null; // unsigned request for unknown contact: drop

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
    return action;
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
