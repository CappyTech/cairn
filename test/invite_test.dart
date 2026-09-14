import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/crypto_service.dart';
import 'package:my_app/services/invite_service.dart';
import 'package:my_app/services/pairing_service.dart';

/// One-time remote invites: an intercepted code should be near-useless because
/// it expires and only pairs once. These cover the expiry pruning and that a
/// request signed with an invite token verifies (the consume step needs
/// on-device storage, so it's exercised at runtime, not here).
void main() {
  final now = DateTime.utc(2026, 1, 1, 12, 0, 0);
  Map<String, dynamic> invite(String token, DateTime exp) =>
      {'t': token, 'exp': exp.toIso8601String()};

  group('InviteService.pruneExpired', () {
    test('drops expired invites, keeps live ones', () {
      final live = invite('LIVE', now.add(const Duration(hours: 1)));
      final expired = invite('OLD', now.subtract(const Duration(minutes: 1)));
      final kept = InviteService.pruneExpired([live, expired], now);
      expect(kept, [live]);
    });

    test('treats a malformed expiry as expired', () {
      final bad = {'t': 'X', 'exp': 'not-a-date'};
      expect(InviteService.pruneExpired([bad], now), isEmpty);
    });

    test('empty in, empty out', () {
      expect(InviteService.pruneExpired([], now), isEmpty);
    });
  });

  group('invite token MAC', () {
    test('a request signed with the invite token verifies against it', () async {
      final token = CryptoService.randomTokenB64();
      final msg = PairingService.pairMacMessage(
          fromId: 'alice', targetId: 'bob', fromPubkey: 'ALICE_KEY');
      final sent =
          await CryptoService.hmacBase64(base64OfToken(token), msg);
      final expected =
          await CryptoService.hmacBase64(base64OfToken(token), msg);
      expect(CryptoService.macEquals(sent, expected), isTrue);
    });

    test('a different token does not verify', () async {
      final msg = PairingService.pairMacMessage(
          fromId: 'alice', targetId: 'bob', fromPubkey: 'ALICE_KEY');
      final sent = await CryptoService.hmacBase64(
          base64OfToken(CryptoService.randomTokenB64()), msg);
      final other = await CryptoService.hmacBase64(
          base64OfToken(CryptoService.randomTokenB64()), msg);
      expect(CryptoService.macEquals(sent, other), isFalse);
    });
  });
}

/// Invite tokens are base64 strings; the MAC is keyed by their raw bytes.
List<int> base64OfToken(String token) => base64Decode(token);
