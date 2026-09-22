import 'dart:convert';
import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'auth_service.dart';
import 'pairing_service.dart';
import 'crypto_service.dart';
import 'nickname_service.dart';
import 'places_service.dart';
import 'prefs.dart';

/// A decrypted location received from a paired contact.
class ContactLocation {
  final String senderId;
  final String name;
  final double lat;
  final double lng;
  final double? accuracy;
  final bool approximate; // sender shared a rounded (coarse) position
  final String? label; // a status the SENDER chose to broadcast ("Hotel")
  final DateTime updated; // when they last shared (= presence signal)

  ContactLocation({
    required this.senderId,
    required this.name,
    required this.lat,
    required this.lng,
    this.accuracy,
    this.approximate = false,
    this.label,
    required this.updated,
  });
}

/// What to do for one contact on a publish tick.
enum ShareAction {
  /// Don't touch this contact (e.g. their key changed and isn't re-verified).
  skip,

  /// Stop sharing and delete any location already shared to them (paused).
  clearAndSkip,

  /// Share a precise position.
  sendPrecise,

  /// Share a coarsened (~1 km) position.
  sendApproximate,
}

/// The database write to perform for one contact this tick.
enum ShareOp { none, create, update, delete }

/// Publishes my encrypted location to contacts and receives theirs.
class LocationSharingService {
  /// Round to ~2 decimal places (~1.1 km) for "approximate" sharing.
  static double coarse(double v) => (v * 100).roundToDouble() / 100;

  /// What to do for one contact this tick, given their per-contact `precision`
  /// and `status`, and the global "approximate only" switch. Pure — unit-tested.
  static ShareAction shareActionFor({
    required String precision,
    required String status,
    required bool approxOnly,
  }) {
    // Key changed and not re-verified: don't publish to a key we don't trust
    // (existing shares stay as-is, under the old key).
    if (status == 'key_changed') return ShareAction.skip;
    // Paused: stop sharing and clear any location already shared to them.
    if (precision == 'off') return ShareAction.clearAndSkip;
    return (approxOnly || precision == 'approximate')
        ? ShareAction.sendApproximate
        : ShareAction.sendPrecise;
  }

  /// Given a contact's [action] and whether a share row to them already exists,
  /// the database write to perform. Pure — unit-tested.
  static ShareOp shareOpFor(ShareAction action, bool hasExistingShare) {
    switch (action) {
      case ShareAction.skip:
        return ShareOp.none;
      case ShareAction.clearAndSkip:
        return hasExistingShare ? ShareOp.delete : ShareOp.none;
      case ShareAction.sendPrecise:
      case ShareAction.sendApproximate:
        return hasExistingShare ? ShareOp.update : ShareOp.create;
    }
  }

  /// The location payload to encrypt for a contact. When [approximate], the
  /// position is coarsened (~1 km) and accuracy is dropped. Pure.
  static Map<String, dynamic> buildPayload({
    required double lat,
    required double lng,
    double? accuracy,
    required bool approximate,
    required String ts,
    String? label,
  }) {
    return {
      'lat': approximate ? coarse(lat) : lat,
      'lng': approximate ? coarse(lng) : lng,
      'acc': approximate ? null : accuracy,
      'approx': approximate,
      'ts': ts,
      // A short status the sender broadcasts (e.g. "Hotel"); omitted when none.
      if (label != null && label.isNotEmpty) 'lbl': label,
    };
  }

  /// The label to broadcast for my current position: a manual [manualStatus]
  /// wins, else the name of the first contact-visible place I'm inside, else
  /// null. Pure — unit-tested.
  static String? labelForPosition({
    String? manualStatus,
    required List<Place> places,
    required double lat,
    required double lng,
  }) {
    final s = manualStatus?.trim() ?? '';
    if (s.isNotEmpty) return s;
    for (final p in places) {
      if (p.shareLabel && PlacesService.isInside(p, lat, lng)) return p.name;
    }
    return null;
  }

  /// Build a [ContactLocation] from a decrypted payload [data]. Pure.
  static ContactLocation contactLocationFrom({
    required String senderId,
    required String name,
    required Map<String, dynamic> data,
    required String updatedIso,
  }) {
    return ContactLocation(
      senderId: senderId,
      name: name.isNotEmpty ? name : 'Unnamed device',
      lat: (data['lat'] as num).toDouble(),
      lng: (data['lng'] as num).toDouble(),
      accuracy: (data['acc'] as num?)?.toDouble(),
      approximate: data['approx'] == true,
      label: (data['lbl'] as String?)?.trim().isNotEmpty == true
          ? (data['lbl'] as String).trim()
          : null,
      updated: DateTime.tryParse(updatedIso)?.toLocal() ?? DateTime.now(),
    );
  }

  /// Encrypt my position for each paired contact and upsert their share row.
  /// Precision is decided PER CONTACT (their `precision`: precise / approximate /
  /// off), with a global "approximate only" master-switch that coarsens everyone.
  static Future<void> publish({
    required double lat,
    required double lng,
    double? accuracy,
  }) async {
    final me = AuthService.currentUser;
    if (me == null) return;
    final approxOnly = await Prefs.approxOnly();
    final contacts = await PairingService.myContacts();
    final ts = DateTime.now().toUtc().toIso8601String();

    // The status to broadcast this tick: a manual status, else a contact-visible
    // place I'm inside. Computed once (same for every recipient).
    String? label;
    try {
      label = labelForPosition(
        manualStatus: await Prefs.sharedStatus(),
        places: await PlacesService.list(),
        lat: lat,
        lng: lng,
      );
    } catch (_) {/* no places / offline — just omit the label */}

    // Fetch all my outgoing shares once, keyed by recipient, instead of a
    // per-contact query. One read replaces the previous O(contacts) reads.
    final existingByRecipient = <String, RecordModel>{};
    for (final s in await pb.collection('location_shares').getFullList(
        filter: 'sender = "${me.id}"')) {
      existingByRecipient[s.getStringValue('recipient')] = s;
    }

    for (final c in contacts) {
      final peerId = c.getStringValue('peer');
      final peerKey = c.getStringValue('peer_pubkey');
      if (peerId.isEmpty || peerKey.isEmpty) continue;

      final action = shareActionFor(
        precision: c.getStringValue('precision'),
        status: c.getStringValue('status'),
        approxOnly: approxOnly,
      );
      final existing = existingByRecipient[peerId];
      final op = shareOpFor(action, existing != null);

      switch (op) {
        case ShareOp.none:
          break;
        case ShareOp.delete:
          await pb.collection('location_shares').delete(existing!.id);
          existingByRecipient.remove(peerId);
        case ShareOp.create:
        case ShareOp.update:
          final payload = utf8.encode(jsonEncode(buildPayload(
            lat: lat,
            lng: lng,
            accuracy: accuracy,
            approximate: action == ShareAction.sendApproximate,
            ts: ts,
            label: label,
          )));
          final blob = await CryptoService.sealFor(peerKey, payload);
          final body = {
            'sender': me.id,
            'recipient': peerId,
            'ciphertext': blob
          };
          if (op == ShareOp.update) {
            await pb.collection('location_shares').update(existing!.id, body: body);
          } else {
            await pb.collection('location_shares').create(body: body);
          }
      }
    }

    // Presence heartbeat (best-effort).
    try {
      await pb.collection('users').update(me.id, body: {'last_seen': ts});
    } catch (_) {}
  }

  /// Resolve each contact's display name (local nickname wins over their own
  /// decrypted name), keyed by peer id — so map labels and alerts match the
  /// contacts list.
  static Future<Map<String, String>> _resolveNames() async {
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

  /// Decrypt one share row and, if it's from a current contact, store it in
  /// [byId] keyed by sender.
  static Future<void> _ingestInto(Map<String, ContactLocation> byId,
      Map<String, String> names, RecordModel r) async {
    final sender = r.getStringValue('sender');
    if (!names.containsKey(sender)) return; // not a current contact
    try {
      final clear =
          await CryptoService.openSealed(r.getStringValue('ciphertext'));
      final data = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      byId[sender] = contactLocationFrom(
        senderId: sender,
        name: names[sender] ?? '',
        data: data,
        updatedIso: r.getStringValue('updated'),
      );
    } catch (_) {
      // Undecryptable — ignore.
    }
  }

  /// One-shot: load + decrypt every location currently shared TO me. Used by the
  /// background isolate (which evaluates geofences per tick without holding a
  /// realtime subscription open).
  static Future<Map<String, ContactLocation>> fetchOnce() async {
    final me = AuthService.currentUser;
    if (me == null) return {};
    final names = await _resolveNames();
    final byId = <String, ContactLocation>{};
    for (final r in await pb
        .collection('location_shares')
        .getFullList(filter: 'recipient = "${me.id}"')) {
      await _ingestInto(byId, names, r);
    }
    return byId;
  }

  /// Load + decrypt every location shared TO me, then keep it live.
  /// Returns an unsubscribe function.
  static Future<Future<void> Function()> subscribe(
      void Function(Map<String, ContactLocation>) onUpdate) async {
    final me = AuthService.currentUser!;
    final byId = <String, ContactLocation>{};

    // Resolve display names once, so map labels match the contacts list.
    final names = await _resolveNames();

    Future<void> ingest(RecordModel r) => _ingestInto(byId, names, r);

    for (final r in await pb
        .collection('location_shares')
        .getFullList(filter: 'recipient = "${me.id}"')) {
      await ingest(r);
    }
    onUpdate(Map.of(byId));

    return pb.collection('location_shares').subscribe('*', (e) async {
      final rec = e.record;
      if (rec == null || rec.getStringValue('recipient') != me.id) return;
      if (e.action == 'delete') {
        byId.remove(rec.getStringValue('sender'));
      } else {
        await ingest(rec);
      }
      onUpdate(Map.of(byId));
    });
  }
}
