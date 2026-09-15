import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/nickname_service.dart';

/// The name shown for a contact: a local nickname wins over the contact's own
/// name, which wins over a safe fallback. Pure precedence, unit-tested.
void main() {
  group('NicknameService.resolveName', () {
    test('a set nickname overrides their own name', () {
      expect(
          NicknameService.resolveName(alias: 'Mum', peerName: 'Alice'), 'Mum');
    });

    test('no nickname falls back to their own name', () {
      expect(NicknameService.resolveName(alias: null, peerName: 'Alice'),
          'Alice');
      expect(
          NicknameService.resolveName(alias: '', peerName: 'Alice'), 'Alice');
    });

    test('a blank/whitespace nickname is ignored', () {
      expect(NicknameService.resolveName(alias: '   ', peerName: 'Alice'),
          'Alice');
    });

    test('nickname is trimmed', () {
      expect(NicknameService.resolveName(alias: '  Work  ', peerName: 'Alice'),
          'Work');
    });

    test('both empty → safe fallback (never an empty string)', () {
      expect(NicknameService.resolveName(alias: '', peerName: ''),
          'Unnamed device');
      expect(NicknameService.resolveName(alias: null, peerName: '   '),
          'Unnamed device');
    });
  });
}
