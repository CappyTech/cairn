import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'crypto_service.dart';
import 'prefs.dart';

/// "The device is the sign-in." No email/password screen — the app derives its
/// identity from the on-device keypair and authenticates silently.
class AuthService {
  static bool get isLoggedIn => pb.authStore.isValid;
  static RecordModel? get currentUser => pb.authStore.record;

  /// Ensure this device is signed in. Creates the account on first ever launch,
  /// then just logs in on every launch after. Safe to call repeatedly.
  static Future<void> signInWithDevice() async {
    final id = await CryptoService.ensureIdentity();

    // If we think we're already signed in, confirm the session is still real
    // (the account could have been removed, or the server reset). If not,
    // drop it and re-authenticate below.
    if (pb.authStore.isValid) {
      try {
        await pb.collection('users').authRefresh();
        return;
      } catch (_) {
        pb.authStore.clear();
      }
    }

    try {
      await pb.collection('users').authWithPassword(id.email, id.password);
    } on ClientException catch (e) {
      // 400 = no such account yet → create it, then authenticate.
      if (e.statusCode == 400) {
        await pb.collection('users').create(body: {
          'email': id.email,
          'password': id.password,
          'passwordConfirm': id.password,
          'emailVisibility': false,
          'public_key': id.publicKey,
          // Name is stored encrypted-to-self — the server can't read it.
          'name': await CryptoService.sealTextForSelf('New device'),
        });
        await pb.collection('users').authWithPassword(id.email, id.password);
        await Prefs.setName('New device');
      } else {
        rethrow;
      }
    }
  }

  /// My display name — read from on-device storage; if absent (e.g. after a
  /// restore), recover it from the encrypted-to-self copy on the server.
  static Future<String> displayName() async {
    final local = await Prefs.name();
    if (local != null && local.isNotEmpty) return local;
    final enc = pb.authStore.record?.getStringValue('name') ?? '';
    if (enc.isNotEmpty) {
      try {
        final n = await CryptoService.openSealedText(enc);
        await Prefs.setName(n);
        return n;
      } catch (_) {}
    }
    return 'New device';
  }

  /// Permanently delete this account. Removes the user record (which cascades
  /// to its contacts, shares and pair requests), clears the session, and wipes
  /// the on-device key so the app starts fresh.
  static Future<void> deleteAccount() async {
    final me = pb.authStore.record;
    if (me != null) {
      try {
        await pb.collection('users').delete(me.id);
      } catch (_) {}
    }
    pb.authStore.clear();
    await CryptoService.wipeIdentity();
  }

  /// Update my display name. Stored plaintext on-device and encrypted-to-self on
  /// the server (so the server never sees the readable name).
  static Future<void> setDisplayName(String name) async {
    await Prefs.setName(name);
    final user = pb.authStore.record;
    if (user == null) return;
    await pb.collection('users')
        .update(user.id, body: {'name': await CryptoService.sealTextForSelf(name)});
  }
}
