import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/crypto_service.dart';
import 'package:my_app/services/location_sharing_service.dart';

/// Covers the pure decision/parsing logic behind location sharing (the parts
/// that don't need a live PocketBase): per-contact share action, payload
/// building/coarsening, and decoding a decrypted payload back into a
/// ContactLocation — including a real encrypt→decrypt→parse round trip.
void main() {
  group('shareActionFor', () {
    test('a key-changed contact is skipped (never re-shared blindly)', () {
      // Even with an otherwise-sharing precision, key_changed wins.
      expect(
        LocationSharingService.shareActionFor(
            precision: 'precise', status: 'key_changed', approxOnly: false),
        ShareAction.skip,
      );
    });

    test('paused (off) clears and skips', () {
      expect(
        LocationSharingService.shareActionFor(
            precision: 'off', status: 'active', approxOnly: false),
        ShareAction.clearAndSkip,
      );
    });

    test('precise → sendPrecise', () {
      expect(
        LocationSharingService.shareActionFor(
            precision: 'precise', status: 'active', approxOnly: false),
        ShareAction.sendPrecise,
      );
    });

    test('per-contact approximate → sendApproximate', () {
      expect(
        LocationSharingService.shareActionFor(
            precision: 'approximate', status: 'active', approxOnly: false),
        ShareAction.sendApproximate,
      );
    });

    test('global approxOnly coarsens an otherwise-precise contact', () {
      expect(
        LocationSharingService.shareActionFor(
            precision: 'precise', status: 'active', approxOnly: true),
        ShareAction.sendApproximate,
      );
    });

    test('empty precision defaults to precise', () {
      expect(
        LocationSharingService.shareActionFor(
            precision: '', status: '', approxOnly: false),
        ShareAction.sendPrecise,
      );
    });
  });

  group('coarse', () {
    test('rounds to ~2 dp', () {
      expect(LocationSharingService.coarse(2.348), closeTo(2.35, 1e-9));
      expect(LocationSharingService.coarse(2.342), closeTo(2.34, 1e-9));
      expect(LocationSharingService.coarse(-0.1278), closeTo(-0.13, 1e-9));
    });
  });

  group('buildPayload', () {
    test('precise keeps exact coords and accuracy', () {
      final p = LocationSharingService.buildPayload(
          lat: 51.5074,
          lng: -0.1278,
          accuracy: 5.0,
          approximate: false,
          ts: 'T');
      expect(p['lat'], 51.5074);
      expect(p['lng'], -0.1278);
      expect(p['acc'], 5.0);
      expect(p['approx'], isFalse);
      expect(p['ts'], 'T');
    });

    test('approximate coarsens coords and drops accuracy', () {
      final p = LocationSharingService.buildPayload(
          lat: 51.5074,
          lng: -0.1278,
          accuracy: 5.0,
          approximate: true,
          ts: 'T');
      expect(p['lat'], closeTo(51.51, 1e-9));
      expect(p['lng'], closeTo(-0.13, 1e-9));
      expect(p['acc'], isNull);
      expect(p['approx'], isTrue);
    });
  });

  group('contactLocationFrom', () {
    final data = {
      'lat': 51.5074,
      'lng': -0.1278,
      'acc': 5.0,
      'approx': false,
      'ts': '2026-01-01T00:00:00.000Z',
    };

    test('parses fields', () {
      final loc = LocationSharingService.contactLocationFrom(
        senderId: 'alice',
        name: 'Alice',
        data: data,
        updatedIso: '2026-01-01T00:00:00.000Z',
      );
      expect(loc.senderId, 'alice');
      expect(loc.name, 'Alice');
      expect(loc.lat, 51.5074);
      expect(loc.lng, -0.1278);
      expect(loc.accuracy, 5.0);
      expect(loc.approximate, isFalse);
    });

    test('empty name falls back to Unnamed device', () {
      final loc = LocationSharingService.contactLocationFrom(
          senderId: 'x', name: '', data: data, updatedIso: 'bad-date');
      expect(loc.name, 'Unnamed device');
    });

    test('null accuracy and approx=true are handled', () {
      final loc = LocationSharingService.contactLocationFrom(
        senderId: 'x',
        name: 'X',
        data: {'lat': 1.0, 'lng': 2.0, 'acc': null, 'approx': true},
        updatedIso: '2026-01-01T00:00:00.000Z',
      );
      expect(loc.accuracy, isNull);
      expect(loc.approximate, isTrue);
    });
  });

  test('end-to-end: build → encrypt → decrypt → parse round-trips', () async {
    final algo = X25519();
    final bob = await algo.newKeyPair();
    final bobSeed = await bob.extractPrivateKeyBytes();
    final bobPub = (await bob.extractPublicKey()).bytes;

    final payload = LocationSharingService.buildPayload(
        lat: 40.7128, lng: -74.0060, accuracy: 8.0, approximate: false, ts: 'T');
    final blob = await CryptoService.seal(bobPub, utf8.encode(jsonEncode(payload)));

    final clear = await CryptoService.open(bobSeed, blob);
    final decoded = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    final loc = LocationSharingService.contactLocationFrom(
      senderId: 'alice',
      name: 'Alice',
      data: decoded,
      updatedIso: '2026-01-01T00:00:00.000Z',
    );

    expect(loc.lat, 40.7128);
    expect(loc.lng, -74.0060);
    expect(loc.accuracy, 8.0);
    expect(loc.approximate, isFalse);
  });
}
