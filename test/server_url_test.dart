import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/services/pb_client.dart';

/// A bad server address must be rejected before it's saved — otherwise it
/// persists and bricks the next launch. These pin what counts as valid.
void main() {
  group('isValidServerUrl', () {
    test('accepts http/https with a host (and optional port/path)', () {
      expect(isValidServerUrl('https://cairn.cappylabs.uk'), isTrue);
      expect(isValidServerUrl('http://192.168.1.5:8090'), isTrue);
      expect(isValidServerUrl('http://127.0.0.1:8090'), isTrue);
      expect(isValidServerUrl('https://example.com/pb'), isTrue);
      expect(isValidServerUrl('  https://example.com  '), isTrue); // trimmed
    });

    test('rejects a bare host/IP with no scheme', () {
      expect(isValidServerUrl('192.168.1.5:8090'), isFalse);
      expect(isValidServerUrl('localhost:8090'), isFalse);
      expect(isValidServerUrl('cairn.cappylabs.uk'), isFalse);
    });

    test('rejects a non-http scheme', () {
      expect(isValidServerUrl('ftp://example.com'), isFalse);
      expect(isValidServerUrl('ws://example.com'), isFalse);
    });

    test('rejects empty, whitespace, and gibberish', () {
      expect(isValidServerUrl(''), isFalse);
      expect(isValidServerUrl('   '), isFalse);
      expect(isValidServerUrl('blag ip'), isFalse);
      expect(isValidServerUrl('http://'), isFalse); // no host
    });
  });
}
