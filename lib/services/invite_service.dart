import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'auth_service.dart';
import 'crypto_service.dart';

/// Remote pairing: a one-time invite code you can send to someone who isn't
/// nearby (copy/paste or share sheet), instead of an in-person QR scan.
///
/// Each invite carries a FRESH single-use secret (not the persistent QR nonce),
/// stored on this device with a short expiry. When the recipient pairs, their
/// request's proof-MAC is keyed by that secret; we verify it and consume the
/// invite. So an intercepted invite is near-useless: it works once and times
/// out — unlike the permanent QR code, whose nonce would keep working forever
/// if it leaked over a messaging channel.
class InviteService {
  static const _storage = FlutterSecureStorage();
  static const _storeKey = 'pending_invites_v1';

  /// How long a remote invite stays valid.
  static const ttl = Duration(hours: 24);

  /// Pure: keep only invites that haven't expired as of [now]. Unit-tested.
  static List<Map<String, dynamic>> pruneExpired(
      List<Map<String, dynamic>> invites, DateTime now) {
    return [
      for (final inv in invites)
        if (DateTime.tryParse(inv['exp'] as String? ?? '')?.isAfter(now) ??
            false)
          inv,
    ];
  }

  static Future<List<Map<String, dynamic>>> _load() async {
    final raw = await _storage.read(key: _storeKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Map<String, dynamic>> invites) =>
      _storage.write(key: _storeKey, value: jsonEncode(invites));

  /// Create a fresh single-use invite and return the code payload (a JSON
  /// string the recipient pastes into Scan → "Paste instead"). Same shape as
  /// the QR payload, but `s` is a one-time token rather than the QR nonce.
  static Future<String> createInvite() async {
    final u = AuthService.currentUser!;
    final token = CryptoService.randomTokenB64();
    final now = DateTime.now().toUtc();
    final invites = pruneExpired(await _load(), now)
      ..add({'t': token, 'exp': now.add(ttl).toIso8601String()});
    await _save(invites);
    return jsonEncode({
      'v': 2,
      'id': u.id,
      'n': await AuthService.displayName(),
      'k': u.getStringValue('public_key'),
      's': token,
      'r': 1, // remote (one-time) invite
    });
  }

  /// Verify [mac] over [message] against any live invite; on a match, consume
  /// that invite (single-use) and return true. Expired invites are pruned.
  static Future<bool> verifyAndConsume(String message, String mac) async {
    final now = DateTime.now().toUtc();
    final invites = pruneExpired(await _load(), now);
    for (final inv in invites) {
      final expected = await CryptoService.hmacBase64(
          base64Decode(inv['t'] as String), message);
      if (CryptoService.macEquals(mac, expected)) {
        invites.remove(inv);
        await _save(invites); // consume it
        return true;
      }
    }
    await _save(invites); // persist any pruning
    return false;
  }

  /// Forget all pending invites (used when deleting the account).
  static Future<void> clear() => _storage.delete(key: _storeKey);
}
