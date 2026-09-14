import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/crypto_service.dart';
import 'package:my_app/services/pairing_service.dart';

/// The reciprocating side of a pairing only learns the other person's key from
/// the server, so a compromised server could swap it. A MAC keyed by the nonce
/// carried in the (in-person) QR lets that side detect the swap. These test the
/// decision and the MAC verification that back that.
void main() {
  group('PairingService.classifyInbound', () {
    test('no MAC → unverified (older app / nonce-less QR)', () {
      expect(
        PairingService.classifyInbound(macPresent: false, macValid: false),
        InboundPairDecision.unverified,
      );
    });

    test('valid MAC → trusted', () {
      expect(
        PairingService.classifyInbound(macPresent: true, macValid: true),
        InboundPairDecision.trusted,
      );
    });

    test('MAC present but invalid → reject (tampered / forged)', () {
      expect(
        PairingService.classifyInbound(macPresent: true, macValid: false),
        InboundPairDecision.reject,
      );
    });
  });

  group('pairing MAC verification', () {
    // Bob's QR nonce; Alice scanned it in person.
    final nonce = base64Decode(base64Encode(List<int>.generate(32, (i) => i)));

    Future<String> mac(String from, String target, String pubkey) =>
        CryptoService.hmacBase64(
          nonce,
          PairingService.pairMacMessage(
              fromId: from, targetId: target, fromPubkey: pubkey),
        );

    test('same inputs + same nonce verify equal', () async {
      final sent = await mac('alice', 'bob', 'ALICE_KEY');
      final expected = await mac('alice', 'bob', 'ALICE_KEY');
      expect(CryptoService.macEquals(sent, expected), isTrue);
    });

    test('a swapped public key breaks the MAC', () async {
      final sent = await mac('alice', 'bob', 'ALICE_KEY');
      final expected = await mac('alice', 'bob', 'ATTACKER_KEY');
      expect(CryptoService.macEquals(sent, expected), isFalse);
    });

    test('a different nonce (never scanned us) breaks the MAC', () async {
      final sent = await mac('alice', 'bob', 'ALICE_KEY');
      final otherNonce = List<int>.generate(32, (_) => 7);
      final forged = await CryptoService.hmacBase64(
        otherNonce,
        PairingService.pairMacMessage(
            fromId: 'alice', targetId: 'bob', fromPubkey: 'ALICE_KEY'),
      );
      expect(CryptoService.macEquals(sent, forged), isFalse);
    });

    test('macEquals is length- and content-sensitive', () {
      expect(CryptoService.macEquals('abc', 'abc'), isTrue);
      expect(CryptoService.macEquals('abc', 'abd'), isFalse);
      expect(CryptoService.macEquals('abc', 'ab'), isFalse);
    });
  });
}
