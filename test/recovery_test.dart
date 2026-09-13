import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/crypto_service.dart';

/// The recovery phrase must losslessly round-trip the identity: a lost phone
/// restored from the phrase must produce the exact same keys.
void main() {
  final algo = X25519();

  test('seed -> phrase -> seed is lossless (same identity)', () async {
    final kp = await algo.newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    final originalPub = base64Encode((await kp.extractPublicKey()).bytes);

    final phrase = CryptoService.phraseFromSeed(seed);
    expect(phrase.split(' ').length, 24);

    final restored = CryptoService.seedFromPhrase(phrase);
    expect(restored, equals(seed));

    // ...and the restored seed rebuilds the same public key.
    final restoredKp = await algo.newKeyPairFromSeed(restored);
    final restoredPub = base64Encode((await restoredKp.extractPublicKey()).bytes);
    expect(restoredPub, originalPub);
  });

  test('an invalid phrase is rejected', () {
    expect(() => CryptoService.seedFromPhrase('not a real phrase at all'),
        throwsA(anything));
    expect(CryptoService.isValidPhrase('not a real phrase'), isFalse);
  });

  test('phrase is case/whitespace tolerant', () async {
    final kp = await algo.newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    final phrase = CryptoService.phraseFromSeed(seed);
    final messy = '  ${phrase.toUpperCase().replaceAll(' ', '   ')}  ';
    expect(CryptoService.seedFromPhrase(messy), equals(seed));
  });
}
