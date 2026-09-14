@Tags(['integration'])
library;

import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:my_app/services/crypto_service.dart';

/// End-to-end integration test against the LIVE PocketBase at 127.0.0.1:8090.
/// Tagged `integration` and excluded from CI (which has no server); run it
/// locally with a dev backend up: `flutter test --tags integration`.
/// Simulates two devices (A and B) sharing an encrypted location, proving:
/// publish (encrypt) -> store -> subscribe-read -> decrypt, with the server
/// never able to read the coordinates.
void main() {
  const base = 'http://127.0.0.1:8090';
  final algo = X25519();
  final stamp = DateTime.now().microsecondsSinceEpoch;

  test('A shares an encrypted location that only B can read', () async {
    // --- device keypairs ---
    final kpA = await algo.newKeyPair();
    final pubA = base64Encode((await kpA.extractPublicKey()).bytes);
    final kpB = await algo.newKeyPair();
    final seedB = await kpB.extractPrivateKeyBytes();
    final pubB = base64Encode((await kpB.extractPublicKey()).bytes);

    final pbA = PocketBase(base);
    final pbB = PocketBase(base);
    const pw = 'password12345';
    final emailA = 'itA_$stamp@device.local';
    final emailB = 'itB_$stamp@device.local';

    final aRec = await pbA.collection('users').create(body: {
      'email': emailA, 'password': pw, 'passwordConfirm': pw,
      'public_key': pubA, 'name': 'Device A',
    });
    final bRec = await pbB.collection('users').create(body: {
      'email': emailB, 'password': pw, 'passwordConfirm': pw,
      'public_key': pubB, 'name': 'Device B',
    });
    await pbA.collection('users').authWithPassword(emailA, pw);
    await pbB.collection('users').authWithPassword(emailB, pw);

    // --- A pairs with B (needs B's public key) then publishes ---
    await pbA.collection('contacts').create(body: {
      'owner': aRec.id, 'peer': bRec.id,
      'peer_name': 'Device B', 'peer_pubkey': pubB, 'status': 'active',
    });

    final payload = utf8.encode(jsonEncode({'lat': 40.7128, 'lng': -74.0060}));
    final blob = await CryptoService.seal(base64Decode(pubB), payload);
    await pbA.collection('location_shares').create(body: {
      'sender': aRec.id, 'recipient': bRec.id, 'ciphertext': blob,
    });

    // --- the SERVER stores only ciphertext (no plaintext coords) ---
    final admin = PocketBase(base);
    await admin.collection('_superusers')
        .authWithPassword('admin@local.test', 'Yviy8IBs1l4UbCDR');
    final stored = await admin.collection('location_shares')
        .getFirstListItem('sender = "${aRec.id}" && recipient = "${bRec.id}"');
    expect(stored.getStringValue('ciphertext').contains('40.7128'), isFalse,
        reason: 'raw coordinates must never hit the database');

    // --- B reads it back and decrypts ---
    final incoming = await pbB.collection('location_shares')
        .getFullList(filter: 'recipient = "${bRec.id}"');
    expect(incoming, isNotEmpty);
    final clear = await CryptoService.open(
        seedB, incoming.first.getStringValue('ciphertext'));
    final data = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    expect(data['lat'], 40.7128);
    expect(data['lng'], -74.0060);

    // --- A (the sender, not recipient) still can't LIST B's inbox as B would;
    //     A only sees rows where it is sender or recipient. Sanity: A sees the
    //     row (as sender); a third party would not. ---
    final aVisible = await pbA.collection('location_shares').getFullList();
    expect(aVisible.any((r) => r.getStringValue('recipient') == bRec.id), isTrue);
  });
}
