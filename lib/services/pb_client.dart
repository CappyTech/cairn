import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Single shared PocketBase client for the whole app.
late PocketBase pb;

/// The resolved backend URL currently in use (for display in settings).
String serverUrl = '';

const _storage = FlutterSecureStorage();
const _urlKey = 'pb_server_url';

/// The built-in default when the user hasn't set a custom server address.
/// - Android emulator reaches the host PC at 10.0.2.2.
/// - A real phone must instead use the PC's LAN IP (set it in Settings).
String platformDefaultUrl() {
  // The production backend is the default. Override for local dev with
  // `--dart-define=PB_URL=...` or the in-app Server settings.
  const production = 'https://cairn.cappylabs.uk';

  if (kIsWeb) {
    final host = Uri.base.host;
    // Local web dev: the app is served on :5000, the backend on :8090.
    if (host.isEmpty || host == 'localhost' || host == '127.0.0.1') {
      return 'http://127.0.0.1:8090';
    }
    // Served from a real domain (e.g. PocketBase's pb_public behind Caddy):
    // the API is same-origin, so reuse it.
    return Uri.base.origin;
  }

  // Native (Android/iOS/desktop) ships pointed at production.
  return production;
}

/// True when running as the local "admin/dev" view — the PC on localhost, or a
/// desktop build. Used to expose the in-app admin dashboard only there.
bool get isAdminView {
  if (kIsWeb) {
    final host = Uri.base.host;
    return host.isEmpty || host == 'localhost' || host == '127.0.0.1';
  }
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

/// Resolution order: a URL the user saved in Settings → a `--dart-define=PB_URL`
/// build flag → the platform default.
Future<String> _resolveUrl() async {
  final stored = await _storage.read(key: _urlKey);
  if (stored != null && stored.isNotEmpty) return stored;
  const fromEnv = String.fromEnvironment('PB_URL');
  if (fromEnv.isNotEmpty) return fromEnv;
  return platformDefaultUrl();
}

/// The user's saved server URL (empty if none set).
Future<String> savedServerUrl() async =>
    (await _storage.read(key: _urlKey)) ?? '';

Future<void> setServerUrl(String url) async =>
    _storage.write(key: _urlKey, value: url.trim());

Future<void> clearServerUrl() async => _storage.delete(key: _urlKey);

/// Creates the client and restores any saved login. Call again to rebuild the
/// client after the server URL changes.
Future<void> initPocketBase() async {
  serverUrl = await _resolveUrl();
  final initial = await _storage.read(key: 'pb_auth');
  final authStore = AsyncAuthStore(
    save: (data) async => _storage.write(key: 'pb_auth', value: data),
    initial: initial,
    clear: () async => _storage.delete(key: 'pb_auth'),
  );
  pb = PocketBase(serverUrl, authStore: authStore);
}
