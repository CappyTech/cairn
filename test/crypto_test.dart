import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/crypto_service.dart';

void main() {
  final algo = X25519();

  test('sealed box round-trips: recipient can decrypt', () async {
    final bob = await algo.newKeyPair();
    final bobSeed = await bob.extractPrivateKeyBytes();
    final bobPub = (await bob.extractPublicKey()).bytes;

    final message = utf8.encode('{"lat":51.5074,"lng":-0.1278}');
    final blob = await CryptoService.seal(bobPub, message);
    final opened = await CryptoService.open(bobSeed, blob);

    expect(utf8.decode(opened), '{"lat":51.5074,"lng":-0.1278}');
  });

  test('a different recipient CANNOT decrypt', () async {
    final bob = await algo.newKeyPair();
    final bobPub = (await bob.extractPublicKey()).bytes;
    final eve = await algo.newKeyPair();
    final eveSeed = await eve.extractPrivateKeyBytes();

    final blob = await CryptoService.seal(bobPub, utf8.encode('secret'));
    expect(() => CryptoService.open(eveSeed, blob), throwsA(anything));
  });

  test('tampered ciphertext is rejected', () async {
    final bob = await algo.newKeyPair();
    final bobSeed = await bob.extractPrivateKeyBytes();
    final bobPub = (await bob.extractPublicKey()).bytes;

    final blob = await CryptoService.seal(bobPub, utf8.encode('secret'));
    final data = jsonDecode(blob) as Map<String, dynamic>;
    // Flip a byte in the ciphertext.
    final ct = base64Decode(data['ct'] as String);
    ct[0] = ct[0] ^ 0xFF;
    data['ct'] = base64Encode(ct);

    expect(() => CryptoService.open(bobSeed, jsonEncode(data)), throwsA(anything));
  });
}
