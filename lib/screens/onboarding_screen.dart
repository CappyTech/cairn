import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/crypto_service.dart';
import '../services/history_policy.dart';
import '../services/location_service.dart';
import '../services/notification_service.dart';
import '../services/pb_client.dart';
import '../services/prefs.dart';
import '../theme/brand.dart';
import '../widgets/restart_widget.dart';
import '../widgets/server_settings_dialog.dart';
import 'qr_screen.dart';
import 'scan_screen.dart';

enum _Step {
  welcome,
  restore,
  privacy,
  name,
  location,
  notifications,
  history,
  firstPerson,
}

/// First-run onboarding, shown before any account exists so that restoring
/// from a recovery phrase or choosing a self-hosted server happens first (no
/// throwaway account is left behind). The account is created at the name step,
/// with that name. Each permission is explained on its own page before the
/// system prompt, and "Not now" is remembered so Home doesn't prompt unasked.
///
/// Calls [onDone] once finished; the caller then shows Home.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step _step = _Step.welcome;
  bool _restored = false; // came in via a recovery phrase
  bool _busy = false;
  String? _error;
  int _historyDays = 0;
  final _name = TextEditingController();
  final _phrase = TextEditingController();

  static bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void dispose() {
    _name.dispose();
    _phrase.dispose();
    super.dispose();
  }

  void _go(_Step step) => setState(() {
        _step = step;
        _error = null;
      });

  Future<void> _changeServer() async {
    final changed = await showServerSettingsDialog(context);
    if (changed && mounted) await RestartWidget.restart(context);
  }

  /// Create (or, after a restore, sign in to) the account.
  Future<bool> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.signInWithDevice();
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is DeviceAccountMismatch
            ? "This device's key doesn't match its account on this server."
            : "Couldn't reach the server. Check your connection, or the "
                'server address, and try again.');
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitName() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name');
      return;
    }
    await Prefs.setName(name);
    if (await _signIn() && mounted) _go(_Step.location);
  }

  Future<void> _submitPhrase() async {
    final phrase = _phrase.text.trim();
    if (!CryptoService.isValidPhrase(phrase)) {
      setState(() => _error =
          "That doesn't look like a valid 24-word recovery phrase.");
      return;
    }
    await CryptoService.restoreFromPhrase(phrase);
    _restored = true;
    if (await _signIn() && mounted) _go(_Step.location);
  }

  Future<void> _location({required bool allow}) async {
    await Prefs.setLocationDeferred(!allow);
    if (allow) {
      try {
        await LocationService.ensureReady(); // shows the system prompt
      } catch (_) {/* refused — Home shows the "not sharing" notice */}
    }
    if (!mounted) return;
    if (_mobile) {
      _go(_Step.notifications);
    } else {
      await _toHistory(); // no notification step on the web
    }
  }

  Future<void> _notifications({required bool allow}) async {
    if (allow) {
      await NotificationService.requestPermission();
    } else {
      await Prefs.setNotificationsDeferred(true);
    }
    await _toHistory();
  }

  /// Ask about history only if this server's policy still needs an answer.
  Future<void> _toHistory() async {
    final result = await HistoryPolicy.evaluate();
    if (!mounted) return;
    if (result.state == HistoryPolicyState.needsConsent) {
      _historyDays = result.serverDays;
      _go(_Step.history);
    } else {
      _afterHistory();
    }
  }

  Future<void> _history({required bool keep}) async {
    if (keep) {
      await HistoryPolicy.agree(_historyDays);
    } else {
      await HistoryPolicy.decline(_historyDays);
    }
    _afterHistory();
  }

  // A restored account already has its people, so skip "add your first".
  void _afterHistory() => _restored ? _finish() : _go(_Step.firstPerson);

  Future<void> _addFirst(Widget screen) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    _finish();
  }

  Future<void> _finish() async {
    await Prefs.setOnboardingDone();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: switch (_step) {
            _Step.welcome => _welcome(),
            _Step.restore => _restore(),
            _Step.privacy => _privacy(),
            _Step.name => _nameStep(),
            _Step.location => _page(
                icon: Icons.my_location,
                title: 'Share your location',
                body: 'Cairn shares your location with your contacts while '
                    'the app is open. You can turn on background sharing '
                    'later.',
                primary: ('Allow location', () => _location(allow: true)),
                secondary: ('Not now', () => _location(allow: false)),
              ),
            _Step.notifications => _page(
                icon: Icons.notifications_none,
                title: 'Stay in the loop',
                body: 'Know when someone connects, goes quiet, or reaches a '
                    'place.',
                primary: (
                  'Allow notifications',
                  () => _notifications(allow: true)
                ),
                secondary: ('Not now', () => _notifications(allow: false)),
              ),
            _Step.history => _page(
                icon: Icons.history,
                title: 'Keep location history?',
                body: '${HistoryPolicy.retentionText(_historyDays)}\n\n'
                    "It's end-to-end encrypted — only you can read it. You "
                    'can change or clear it any time.',
                primary: ('Keep history', () => _history(keep: true)),
                secondary: ('Not now', () => _history(keep: false)),
              ),
            _Step.firstPerson => _firstPerson(),
          },
        ),
      ),
    );
  }

  // --- Pages ------------------------------------------------------------------

  Widget _welcome() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        const Center(child: CairnMark(size: 88)),
        const SizedBox(height: 16),
        Text('cairn',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w600, letterSpacing: -1)),
        const SizedBox(height: 8),
        const Text('Your location, for the few you trust.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Brand.stone, fontSize: 16)),
        const Spacer(),
        FilledButton(
          onPressed: () => _go(_Step.privacy),
          child: const Text('Get started'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => _go(_Step.restore),
          child: const Text('I have a recovery phrase'),
        ),
        TextButton(
          onPressed: _changeServer,
          child: Text('Using your own server? · ${Uri.parse(serverUrl).host}'),
        ),
      ],
    );
  }

  Widget _privacy() {
    Widget point(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Brand.lichen),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
            ],
          ),
        );
    return _frame(
      back: _Step.welcome,
      icon: Icons.shield_outlined,
      title: 'Private by design',
      content: Column(
        children: [
          point(Icons.people_outline,
              'Only people you pair with can see where you are.'),
          point(Icons.lock_outline,
              "Your location is end-to-end encrypted — the server can't read "
                  'it.'),
          point(Icons.qr_code_2,
              "You pair in person, by scanning each other's code."),
        ],
      ),
      actions: [
        FilledButton(
            onPressed: () => _go(_Step.name), child: const Text('Next')),
      ],
    );
  }

  Widget _nameStep() {
    return _frame(
      back: _Step.privacy,
      icon: Icons.person_outline,
      title: 'What should people call you?',
      body: 'Only your contacts see this, and it’s encrypted too.',
      content: TextField(
        controller: _name,
        autofocus: true,
        enabled: !_busy,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submitName(),
        decoration: const InputDecoration(
            hintText: 'Your name', border: OutlineInputBorder()),
      ),
      actions: [
        FilledButton(
          onPressed: _busy ? null : _submitName,
          child: _busy ? const _Spinner() : const Text('Continue'),
        ),
        if (_error != null && !_error!.startsWith('Enter'))
          TextButton(
              onPressed: _changeServer,
              child: const Text('Change server')),
      ],
    );
  }

  Widget _restore() {
    return _frame(
      back: _Step.welcome,
      icon: Icons.key_outlined,
      title: 'Restore your account',
      body: 'Enter your 24-word recovery phrase, with spaces between words.',
      content: TextField(
        controller: _phrase,
        enabled: !_busy,
        minLines: 3,
        maxLines: 5,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: const InputDecoration(
            hintText: 'word1 word2 word3 …', border: OutlineInputBorder()),
      ),
      actions: [
        FilledButton(
          onPressed: _busy ? null : _submitPhrase,
          child: _busy ? const _Spinner() : const Text('Restore'),
        ),
      ],
    );
  }

  Widget _firstPerson() {
    return _frame(
      icon: Icons.group_add_outlined,
      title: 'Add your first person',
      body: 'Show them your code, or scan theirs. You can do this any time '
          'from Home.',
      actions: [
        FilledButton(onPressed: _finish, child: const Text('Skip for now')),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _addFirst(const QrScreen()),
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Show your code'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _addFirst(const ScanScreen()),
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan their code'),
        ),
      ],
    );
  }

  /// A permission-style page: explanation, a primary action and "Not now".
  Widget _page({
    required IconData icon,
    required String title,
    required String body,
    required (String, VoidCallback) primary,
    required (String, VoidCallback) secondary,
  }) {
    return _frame(
      icon: icon,
      title: title,
      body: body,
      actions: [
        FilledButton(onPressed: primary.$2, child: Text(primary.$1)),
        const SizedBox(height: 8),
        TextButton(onPressed: secondary.$2, child: Text(secondary.$1)),
      ],
    );
  }

  /// Shared layout: optional back arrow, icon, title, body, content, then the
  /// actions pinned to the bottom, with any error just above them.
  Widget _frame({
    _Step? back,
    required IconData icon,
    required String title,
    String? body,
    Widget? content,
    required List<Widget> actions,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: back == null || _busy
              ? const SizedBox(height: 48)
              : IconButton(
                  tooltip: 'Back',
                  onPressed: () => _go(back),
                  icon: const Icon(Icons.arrow_back),
                ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 24),
                Icon(icon, size: 40, color: Brand.lichen),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                if (body != null) ...[
                  const SizedBox(height: 8),
                  Text(body,
                      style: const TextStyle(color: Brand.stone, fontSize: 15)),
                ],
                if (content != null) ...[
                  const SizedBox(height: 24),
                  content,
                ],
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 12),
        ],
        ...actions,
      ],
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
}
