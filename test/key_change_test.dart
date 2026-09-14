import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/pairing_service.dart';

/// Detecting a contact's public key changing is the guard against a
/// compromised server silently swapping the key it relays to us. These test
/// the pure decision at the heart of that (no server needed).
void main() {
  group('PairingService.decideKeyAction', () {
    test('no existing contact → create it (trust-on-first-use)', () {
      expect(
        PairingService.decideKeyAction(
          exists: false,
          storedKey: '',
          incomingKey: 'KEY_A',
          trusted: false,
        ),
        ContactKeyAction.createNew,
      );
    });

    test('same key over the server → refresh (no false alarm)', () {
      expect(
        PairingService.decideKeyAction(
          exists: true,
          storedKey: 'KEY_A',
          incomingKey: 'KEY_A',
          trusted: false,
        ),
        ContactKeyAction.refresh,
      );
    });

    test('CHANGED key over the server → flag it, keep the old key', () {
      expect(
        PairingService.decideKeyAction(
          exists: true,
          storedKey: 'KEY_A',
          incomingKey: 'KEY_EVE',
          trusted: false,
        ),
        ContactKeyAction.keyChanged,
      );
    });

    test('changed key confirmed in person (QR scan) → refresh (adopt it)', () {
      expect(
        PairingService.decideKeyAction(
          exists: true,
          storedKey: 'KEY_A',
          incomingKey: 'KEY_A2',
          trusted: true,
        ),
        ContactKeyAction.refresh,
      );
    });

    test('empty stored key → refresh (nothing verified to protect yet)', () {
      expect(
        PairingService.decideKeyAction(
          exists: true,
          storedKey: '',
          incomingKey: 'KEY_A',
          trusted: false,
        ),
        ContactKeyAction.refresh,
      );
    });
  });

  // An unsigned pairing request (no proof-of-scan MAC) must never create a new
  // contact — otherwise anyone could inject themselves, and a server could swap
  // a key on first pair. It may still update an existing pairing.
  group('PairingService.applyCreatePolicy', () {
    test('unsigned request for an unknown contact is dropped', () {
      expect(
        PairingService.applyCreatePolicy(ContactKeyAction.createNew, false),
        isNull,
      );
    });

    test('a signed/in-person request may create a new contact', () {
      expect(
        PairingService.applyCreatePolicy(ContactKeyAction.createNew, true),
        ContactKeyAction.createNew,
      );
    });

    test('updates to existing contacts pass through regardless', () {
      expect(
        PairingService.applyCreatePolicy(ContactKeyAction.refresh, false),
        ContactKeyAction.refresh,
      );
      expect(
        PairingService.applyCreatePolicy(ContactKeyAction.keyChanged, false),
        ContactKeyAction.keyChanged,
      );
    });
  });
}
