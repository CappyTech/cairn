import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'services/pb_client.dart';
import 'services/auth_service.dart';
import 'services/background_share.dart';
import 'screens/home_screen.dart';
import 'widgets/restart_widget.dart';
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
    _signIn = AuthService.signInWithDevice();
  }

  void _retry() => setState(() => _signIn = AuthService.signInWithDevice());

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
                    FilledButton(onPressed: _retry, child: const Text('Retry')),
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
