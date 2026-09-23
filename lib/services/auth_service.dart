import 'package:pocketbase/pocketbase.dart';
import 'pb_client.dart';
import 'crypto_service.dart';
import 'invite_service.dart';
import 'prefs.dart';

/// Thrown when an account for this device already exists on the server but its
/// derived credentials don't open it — e.g. the on-device key doesn't match the
/// account (a stale key, or a key-derivation change between app versions). The
/// user-facing fix is to restore the right recovery phrase, or delete the
/// account and start fresh. We surface this as a clear, actionable message
/// rather than the raw server error the startup screen would otherwise show.
class DeviceAccountMismatch implements Exception {
  const DeviceAccountMismatch();

  @override
  String toString() =>
      "This device's key doesn't match its account on this server. "
      'Restore your recovery phrase to sign back in, or delete the account '
      'to start fresh.';
}

/// "The device is the sign-in." No email/password screen — the app derives its
/// identity from the on-device keypair and authenticates silently.
class AuthService {
  static bool get isLoggedIn => pb.authStore.isValid;
  static RecordModel? get currentUser => pb.authStore.record;

  /// True when a `users.create` failed *because the account already exists*
  /// (the email-uniqueness rule), as opposed to any other validation error.
  /// PocketBase reports this as a 400 with
  /// `response.data.email.code == 'validation_not_unique'`.
  static bool isEmailTakenError(Object error) {
    if (error is! ClientException || error.statusCode != 400) return false;
    final data = error.response['data'];
    if (data is! Map) return false;
    final email = data['email'];
    return email is Map && email['code'] == 'validation_not_unique';
  }

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
      return;
    } on ClientException catch (e) {
      // A 400 here is ambiguous: usually "no account yet" (first launch), but
      // PocketBase also returns 400 when an account exists and the credentials
      // didn't open it. Anything else (network down, server error) is a real
      // failure the user needs to see — don't mask it by trying to register.
      if (e.statusCode != 400) rethrow;
    }

    // Assume first launch and create the account — with the name chosen in
    // onboarding, if there is one.
    final chosen = await Prefs.name();
    final name = (chosen == null || chosen.isEmpty) ? 'New device' : chosen;
    try {
      await pb.collection('users').create(body: {
        'email': id.email,
        'password': id.password,
        'passwordConfirm': id.password,
        'emailVisibility': false,
        'public_key': id.publicKey,
        // Name is stored encrypted-to-self — the server can't read it.
        'name': await CryptoService.sealTextForSelf(name),
      });
      await Prefs.setName(name);
    } on ClientException catch (e) {
      // The account already existed. That's expected in two cases we can
      // recover from by simply signing in below: a race with our own other
      // isolate (the background service creating it first), or a returning
      // device whose credentials *do* match. Any other create error is real.
      if (!isEmailTakenError(e)) rethrow;
    }

    // Authenticate — whether we just created the account or it already existed.
    // If it exists but our derived credentials don't match it, this 400s again;
    // report that as an actionable state instead of a raw "not unique" error.
    try {
      await pb.collection('users').authWithPassword(id.email, id.password);
    } on ClientException catch (e) {
      if (e.statusCode == 400) throw const DeviceAccountMismatch();
      rethrow;
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
    await InviteService.clear();
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
