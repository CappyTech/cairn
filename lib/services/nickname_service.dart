import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Local, per-contact nicknames ("Mum", "Work"). These are MY private label for
/// a contact and live only on this device — they never touch the server and are
/// kept separate from the contact's own `peer_name` (which they choose and which
/// a re-scan overwrites), so renaming a contact and re-pairing don't fight.
///
/// Keyed by the peer's user id. Being local-only, nicknames don't follow a
/// recovery-phrase restore — a reasonable trade for keeping them entirely
/// off the server.
class NicknameService {
  static const _storage = FlutterSecureStorage();
  static const _key = 'contact_nicknames_v1';

  /// The display name to show for a contact: a set nickname wins, else their
  /// own decrypted name, else a safe fallback. Pure, so it's unit-tested and
  /// can be reused anywhere a contact name is rendered.
  static String resolveName({String? alias, required String peerName}) {
    final a = alias?.trim() ?? '';
    if (a.isNotEmpty) return a;
    final n = peerName.trim();
    return n.isNotEmpty ? n : 'Unnamed device';
  }

  /// All nicknames, keyed by peer id. Empty if none set or the store is
  /// unreadable/corrupt.
  static Future<Map<String, String>> all() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  /// Set (or clear, when [alias] is blank) the nickname for [peerId].
  static Future<void> set(String peerId, String alias) async {
    final map = await all();
    final trimmed = alias.trim();
    if (trimmed.isEmpty) {
      map.remove(peerId);
    } else {
      map[peerId] = trimmed;
    }
    await _storage.write(key: _key, value: jsonEncode(map));
  }

  /// Remove the nickname for [peerId] (falls back to their own name).
  static Future<void> remove(String peerId) => set(peerId, '');
}
