import 'dart:async' show TimeoutException;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'services/pb_client.dart';
import 'services/auth_service.dart';
import 'services/background_share.dart';
import 'screens/home_screen.dart';
import 'widgets/restart_widget.dart';
import 'widgets/server_settings_dialog.dart';
import 'theme/brand.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initPocketBase();
  // Background sharing is mobile-only; ignore where unsupported (web/desktop).
  if (!kIsWeb) {
    try {
      await BackgroundShare.init();
    } catch (_) {}
  }
  runApp(const RestartWidget(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cairn',
      debugShowCheckedModeBanner: false,
      theme: Brand.theme(),
      home: const AuthGate(),
    );
  }
}

/// Signs the device in on launch (creating its identity the first time), then
/// shows the app. No login screen — the device's key is the identity.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late Future<void> _signIn;

  @override
  void initState() {
    super.initState();
    _signIn = _run();
  }

  /// Sign in, but don't hang forever on an unreachable or black-hole address
  /// (a wrong IP that silently drops packets). A timeout surfaces a clear error
  /// with a way to fix the server address.
  Future<void> _run() => AuthService.signInWithDevice().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException(
            "Couldn't reach the server in time. Check the address is correct "
            'and the server is running.'),
      );

  void _retry() => setState(() => _signIn = _run());

  /// Let the user fix a bad server address from the error screen and restart —
  /// otherwise a saved-but-broken URL bricks every launch (Home, where Server
  /// settings lives, is never reached).
  Future<void> _changeServer() async {
    final changed = await showServerSettingsDialog(context);
    if (changed && mounted) await RestartWidget.restart(context);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _signIn,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 48),
                    const SizedBox(height: 12),
                    const Text("Couldn't start up.",
                        textAlign: TextAlign.center),
                    const SizedBox(height: 4),
                    Text(
                        kIsWeb
                            ? 'Opening over http:// on a non-localhost address '
                                'blocks browser crypto. Use the installed app, '
                                'or open via https/localhost.\n\n${snapshot.error}'
                            : 'Check the server is running and the address in '
                                'Settings is correct.\n\n${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton(
                            onPressed: _retry, child: const Text('Retry')),
                        OutlinedButton.icon(
                          onPressed: _changeServer,
                          icon: const Icon(Icons.dns, size: 18),
                          label: const Text('Change server'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return const HomeScreen();
      },
    );
  }
}
