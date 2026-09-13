import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'crypto_service.dart';

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
          'name': 'New device',
        });
        await pb.collection('users').authWithPassword(id.email, id.password);
      } else {
        rethrow;
      }
    }
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

  /// Update the editable display name that contacts will see.
  static Future<void> setDisplayName(String name) async {
    final user = pb.authStore.record;
    if (user == null) return;
    await pb.collection('users').update(user.id, body: {'name': name});
    await pb.collection('users').authRefresh();
  }
}
