import 'dart:convert';
import 'package:bip39/bip39.dart' as bip39;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The device's derived identity: everything needed to *be* this user.
///
/// - [publicKey] is shared with others (via the server + pairing QR).
/// - [email] / [password] are synthetic PocketBase credentials, derived from
///   the key so the app can authenticate silently. The user never sees them.
class DeviceIdentity {
  final String publicKey;
  final String email;
  final String password;
  const DeviceIdentity(this.publicKey, this.email, this.password);
}

/// Owns this device's keypair — the root of both its IDENTITY and its
/// end-to-end encryption. The PRIVATE seed never leaves the phone (OS keystore
/// / keychain). Everything else is derived deterministically from it.
class CryptoService {
  static const _storage = FlutterSecureStorage();
  static const _privKeyName = 'x25519_private_seed';
  static final X25519 _algo = X25519();
  static final Sha256 _sha256 = Sha256();

  /// 32-byte private seed, created once on first launch.
  static Future<List<int>> _seed() async {
    final stored = await _storage.read(key: _privKeyName);
    if (stored != null) return base64Decode(stored);
    final keyPair = await _algo.newKeyPair();
    final seed = await keyPair.extractPrivateKeyBytes();
    await _storage.write(key: _privKeyName, value: base64Encode(seed));
    return seed;
  }

  /// Permanently forget this device's identity (used when deleting the
  /// account). Without a saved recovery phrase this is irreversible.
  static Future<void> wipeIdentity() async =>
      _storage.delete(key: _privKeyName);

  /// This device's base64 public key.
  static Future<String> ensurePublicKey() async {
    final keyPair = await _algo.newKeyPairFromSeed(await _seed());
    final pub = await keyPair.extractPublicKey();
    return base64Encode(pub.bytes);
  }

  /// Builds the full identity (public key + synthetic login) from the key.
  static Future<DeviceIdentity> ensureIdentity() async {
    final seed = await _seed();
    final keyPair = await _algo.newKeyPairFromSeed(seed);
    final pub = await keyPair.extractPublicKey();
    final pubB64 = base64Encode(pub.bytes);

    // Email = first 12 bytes of sha256(publicKey) as hex → always valid.
    final digest = await _sha256.hash(pub.bytes);
    final idHex = digest.bytes
        .sublist(0, 12)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final email = '$idHex@device.local';

    // Password = HKDF(seed) with an auth-specific label, so it's distinct from
    // the raw encryption key. Deterministic → the device can always re-auth.
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(seed),
      nonce: utf8.encode('where-app-salt-v1'),
      info: utf8.encode('pocketbase-auth'),
    );
    final password = base64Encode(await derived.extractBytes());

    return DeviceIdentity(pubB64, email, password);
  }

  // ---------------------------------------------------------------------------
  // End-to-end encryption ("sealed box"): encrypt a message TO a recipient's
  // public key so that ONLY their private key can open it. The sender uses a
  // throwaway ephemeral keypair, so the ciphertext reveals nothing about them.
  // Output blob = JSON { epk, n(once), ct(iphertext), m(ac) }, all base64.
  // ---------------------------------------------------------------------------
  static final Cipher _cipher = Chacha20.poly1305Aead();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Future<SecretKey> _deriveKey(
      SecretKey shared, List<int> epk, List<int> recipientPub) {
    // Bind the key to both public keys so a blob can't be replayed elsewhere.
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('where-e2e-v1'),
      info: [...epk, ...recipientPub],
    );
  }

  /// Encrypt [message] for the recipient identified by their raw public key.
  static Future<String> seal(List<int> recipientPub, List<int> message) async {
    final recipient = SimplePublicKey(recipientPub, type: KeyPairType.x25519);
    final ephemeral = await _algo.newKeyPair();
    final epk = (await ephemeral.extractPublicKey()).bytes;
    final shared = await _algo.sharedSecretKey(
        keyPair: ephemeral, remotePublicKey: recipient);
    final key = await _deriveKey(shared, epk, recipientPub);
    final box = await _cipher.encrypt(message, secretKey: key);
    return jsonEncode({
      'epk': base64Encode(epk),
      'n': base64Encode(box.nonce),
      'ct': base64Encode(box.cipherText),
      'm': base64Encode(box.mac.bytes),
    });
  }

  /// Decrypt a [blob] addressed to the holder of [seed] (a 32-byte private key).
  static Future<List<int>> open(List<int> seed, String blob) async {
    final data = jsonDecode(blob) as Map<String, dynamic>;
    final epk = base64Decode(data['epk'] as String);
    final myKeyPair = await _algo.newKeyPairFromSeed(seed);
    final myPub = (await myKeyPair.extractPublicKey()).bytes;
    final shared = await _algo.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(epk, type: KeyPairType.x25519),
    );
    final key = await _deriveKey(shared, epk, myPub);
    final box = SecretBox(
      base64Decode(data['ct'] as String),
      nonce: base64Decode(data['n'] as String),
      mac: Mac(base64Decode(data['m'] as String)),
    );
    return _cipher.decrypt(box, secretKey: key);
  }

  /// Convenience wrappers using base64 keys / this device's stored key.
  static Future<String> sealFor(String recipientPubB64, List<int> message) =>
      seal(base64Decode(recipientPubB64), message);

  static Future<List<int>> openSealed(String blob) async =>
      open(await _seed(), blob);

  // ---------------------------------------------------------------------------
  // Recovery phrase (BIP39). The 32-byte private seed IS the identity, so we
  // encode it as a 24-word phrase the user can write down. Restoring the phrase
  // on any device rebuilds the exact same identity (same keys, same account).
  // ---------------------------------------------------------------------------
  static String _toHex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _fromHex(String h) =>
      [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

  // Pure (testable) conversions between a 32-byte seed and its phrase.
  static String phraseFromSeed(List<int> seed) =>
      bip39.entropyToMnemonic(_toHex(seed));

  static List<int> seedFromPhrase(String phrase) {
    final norm = _normalise(phrase);
    if (!bip39.validateMnemonic(norm)) {
      throw 'That recovery phrase is not valid — check the words and order.';
    }
    return _fromHex(bip39.mnemonicToEntropy(norm));
  }

  /// The 24-word recovery phrase for this device's current identity.
  static Future<String> recoveryPhrase() async =>
      phraseFromSeed(await _seed());

  static bool isValidPhrase(String phrase) =>
      bip39.validateMnemonic(_normalise(phrase));

  /// Replace this device's identity with the one the phrase encodes.
  /// Throws if the phrase is invalid. Caller must then re-authenticate.
  static Future<void> restoreFromPhrase(String phrase) async {
    final seed = seedFromPhrase(phrase);
    await _storage.write(key: _privKeyName, value: base64Encode(seed));
  }

  static String _normalise(String phrase) =>
      phrase.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  // Text helpers for metadata (e.g. display names) so the server stores only
  // ciphertext. "ForSelf" encrypts to this device's own key, so only I can read
  // it back — used to keep my contacts' names private from the server.
  static Future<String> sealTextFor(String recipientPubB64, String text) =>
      sealFor(recipientPubB64, utf8.encode(text));

  static Future<String> sealTextForSelf(String text) async =>
      sealFor(await ensurePublicKey(), utf8.encode(text));

  static Future<String> openSealedText(String blob) async =>
      utf8.decode(await openSealed(blob));
}
