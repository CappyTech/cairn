import 'dart:convert';
import 'pb_client.dart';
import 'auth_service.dart';
import 'crypto_service.dart';
import 'nickname_service.dart';
import 'pairing_service.dart';

/// A pin one user has shared with a contact — a named point the recipient keeps
/// on their map even when the sharer isn't there ("meet me here" / "where I'm
/// staying"). Distinct from [Place], which is private to you.
class SharedPin {
  final String group; // ties the per-recipient copies together
  final String ownerId; // who shared it
  final String sharerName; // resolved display name of the owner (for received)
  final String name;
  final double lat;
  final double lng;
  final String? note;
  final List<String> recipientIds; // who I shared it with (for my own pins)

  const SharedPin({
    required this.group,
    required this.ownerId,
    this.sharerName = '',
    required this.name,
    required this.lat,
    required this.lng,
    this.note,
    this.recipientIds = const [],
  });

  /// The cleartext JSON sealed into each row. Pure.
  Map<String, dynamic> toPayload() => {
        'name': name,
        'lat': lat,
        'lng': lng,
        if (note != null && note!.isNotEmpty) 'note': note,
      };

  static SharedPin fromPayload(
    Map<String, dynamic> data, {
    required String group,
    required String ownerId,
    String sharerName = '',
    List<String> recipientIds = const [],
  }) =>
      SharedPin(
        group: group,
        ownerId: ownerId,
        sharerName: sharerName,
        name: (data['name'] as String?)?.trim().isNotEmpty == true
            ? (data['name'] as String).trim()
            : 'Shared pin',
        lat: (data['lat'] as num?)?.toDouble() ?? 0,
        lng: (data['lng'] as num?)?.toDouble() ?? 0,
        note: (data['note'] as String?)?.trim().isNotEmpty == true
            ? (data['note'] as String).trim()
            : null,
        recipientIds: recipientIds,
      );
}

/// Creates, reads, and revokes shared pins (`shared_places`). Each pin is sealed
/// to each recipient's key; the sharer also keeps a self-addressed copy so they
/// can manage/revoke it and see it on their own devices.
class SharedPlacesService {
  static const _collection = 'shared_places';

  /// Share a pin with [recipients] (each `(id, pubKey)`). Writes one row per
  /// recipient (sealed to them) plus a self-copy (sealed to me), all sharing a
  /// random `group`. Returns the group id.
  static Future<String> share({
    required String name,
    required double lat,
    required double lng,
    String? note,
    required List<({String id, String pubKey})> recipients,
  }) async {
    final me = AuthService.currentUser!;
    final group = CryptoService.randomTokenB64(12);
    final pin = SharedPin(
        group: group, ownerId: me.id, name: name, lat: lat, lng: lng, note: note);
    final json = jsonEncode(pin.toPayload());

    // Self-copy (sealed to me) — lets me list/revoke and see it on my devices.
    await pb.collection(_collection).create(body: {
      'owner': me.id,
      'recipient': me.id,
      'group': group,
      'ciphertext': await CryptoService.sealTextForSelf(json),
    });
    // One sealed copy per recipient.
    for (final r in recipients) {
      if (r.id == me.id || r.pubKey.isEmpty) continue;
      await pb.collection(_collection).create(body: {
        'owner': me.id,
        'recipient': r.id,
        'group': group,
        'ciphertext': await CryptoService.sealTextFor(r.pubKey, json),
      });
    }
    return group;
  }

  /// Pins other people have shared WITH me, decrypted, with the sharer's name.
  static Future<List<SharedPin>> sharedWithMe() async {
    final me = AuthService.currentUser;
    if (me == null) return [];
    final names = await _contactNames();
    final rows = await pb.collection(_collection).getFullList(
          filter: 'recipient = "${me.id}" && owner != "${me.id}"',
          sort: '-created',
        );
    final out = <SharedPin>[];
    for (final r in rows) {
      try {
        final clear =
            await CryptoService.openSealedText(r.getStringValue('ciphertext'));
        final ownerId = r.getStringValue('owner');
        out.add(SharedPin.fromPayload(
          jsonDecode(clear) as Map<String, dynamic>,
          group: r.getStringValue('group'),
          ownerId: ownerId,
          sharerName: names[ownerId] ?? 'A contact',
        ));
      } catch (_) {/* undecryptable — skip */}
    }
    return out;
  }

  /// Pins I have shared (from my self-copies), each with the recipient ids I
  /// shared it with, for a management/revoke view.
  static Future<List<SharedPin>> mineShared() async {
    final me = AuthService.currentUser;
    if (me == null) return [];
    // All my rows, to map group → recipients.
    final mine = await pb.collection(_collection).getFullList(
          filter: 'owner = "${me.id}"',
          sort: '-created',
        );
    final recipientsByGroup = <String, List<String>>{};
    for (final r in mine) {
      final g = r.getStringValue('group');
      final rec = r.getStringValue('recipient');
      if (rec != me.id) (recipientsByGroup[g] ??= []).add(rec);
    }
    final out = <SharedPin>[];
    for (final r in mine) {
      if (r.getStringValue('recipient') != me.id) continue; // self-copies only
      try {
        final clear =
            await CryptoService.openSealedText(r.getStringValue('ciphertext'));
        final g = r.getStringValue('group');
        out.add(SharedPin.fromPayload(
          jsonDecode(clear) as Map<String, dynamic>,
          group: g,
          ownerId: me.id,
          recipientIds: recipientsByGroup[g] ?? const [],
        ));
      } catch (_) {/* skip */}
    }
    return out;
  }

  /// Revoke a shared pin everywhere: delete every row (all recipients + my
  /// self-copy) for its [group].
  static Future<void> revoke(String group) async {
    final me = AuthService.currentUser;
    if (me == null) return;
    final rows = await pb.collection(_collection).getFullList(
          filter: 'owner = "${me.id}" && group = "$group"',
        );
    for (final r in rows) {
      await pb.collection(_collection).delete(r.id);
    }
  }

  /// Peer id → display name (nickname wins), for labelling received pins.
  static Future<Map<String, String>> _contactNames() async {
    final nicks = await NicknameService.all();
    final names = <String, String>{};
    for (final c in await PairingService.myContacts()) {
      final peerId = c.getStringValue('peer');
      names[peerId] = NicknameService.resolveName(
        alias: nicks[peerId],
        peerName:
            await PairingService.decryptName(c.getStringValue('peer_name')),
      );
    }
    return names;
  }
}
