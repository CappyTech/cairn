import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import '../services/app_update_service.dart';
import '../theme/brand.dart';

/// Wraps the signed-in app and tells the user when Cairn is out of date:
///  - required: replaces the app with a blocking "Update Cairn" screen;
///  - recommended: a dismissible banner ("Later" hides it for this session);
///  - a Play background download that finished: a "Restart to update" prompt.
///
/// Checks on start and whenever the app returns to the foreground. The web
/// build is served fresh by the server, so it skips all of this.
class UpdateGate extends StatefulWidget {
  final Widget child;
  const UpdateGate({super.key, required this.child});

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  UpdateNeed _need = UpdateNeed.none;
  AppUpdateInfo? _play;
  String _current = '';
  bool _bannerShown = false;
  bool _bannerDismissed = false; // "Later" — until the app is next launched
  bool _restartOffered = false;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<InstallStatus>? _installSub;

  bool get _playHasUpdate =>
      _play?.updateAvailability == UpdateAvailability.updateAvailable;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;
    _lifecycle = AppLifecycleListener(onResume: _check);
    _check();
  }

  @override
  void dispose() {
    if (!kIsWeb) _lifecycle.dispose();
    _installSub?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    _current = await AppUpdateService.currentVersion();
    final policy = await AppUpdateService.fetchPolicy();
    _play = await AppUpdateService.checkPlay();
    if (!mounted) return;
    final need = AppUpdateService.evaluate(
      current: _current,
      policy: policy,
      playUpdateAvailable: _playHasUpdate,
      playPriority: _play?.updatePriority ?? 0,
    );
    setState(() => _need = need);

    // Play guidance: resume an immediate update the user left mid-way.
    if (_play?.updateAvailability ==
        UpdateAvailability.developerTriggeredUpdateInProgress) {
      unawaited(InAppUpdate.performImmediateUpdate().catchError((_) =>
          AppUpdateResult.inAppUpdateFailed));
    }
    if (_play?.installStatus == InstallStatus.downloaded) _offerRestart();

    if (need == UpdateNeed.recommended) {
      _showBanner();
    } else {
      _hideBanner();
    }
  }

  void _showBanner() {
    if (_bannerShown || _bannerDismissed) return;
    _bannerShown = true;
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.system_update_outlined, color: Brand.slate),
        content: const Text('A new version of Cairn is available.'),
        actions: [
          TextButton(
            onPressed: () {
              _bannerDismissed = true;
              _hideBanner();
            },
            child: const Text('Later'),
          ),
          TextButton(
            onPressed: () {
              _hideBanner();
              _update(immediate: false);
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  void _hideBanner() {
    if (!_bannerShown) return;
    _bannerShown = false;
    ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
  }

  /// A background (flexible) download finished — installing needs a restart,
  /// which Play does when we call completeFlexibleUpdate().
  void _offerRestart() {
    if (_restartOffered || !mounted) return;
    _restartOffered = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Update downloaded.'),
        duration: const Duration(days: 1), // stays until acted on
        action: SnackBarAction(
          label: 'Restart',
          onPressed: () => InAppUpdate.completeFlexibleUpdate().catchError((_) {}),
        ),
      ),
    );
  }

  /// Update through Play when it can (immediate = full-screen, flexible =
  /// download in the background), else open the store listing.
  Future<void> _update({required bool immediate}) async {
    final play = _play;
    if (play != null && _playHasUpdate) {
      try {
        if (immediate && play.immediateUpdateAllowed) {
          await InAppUpdate.performImmediateUpdate();
          return;
        }
        if (play.flexibleUpdateAllowed) {
          _installSub ??= InAppUpdate.installUpdateListener.listen((s) {
            if (s == InstallStatus.downloaded) _offerRestart();
          });
          await InAppUpdate.startFlexibleUpdate();
          return;
        }
      } catch (_) {
        // fall through to the store
      }
    }
    await AppUpdateService.openStore();
  }

  @override
  Widget build(BuildContext context) {
    if (_need == UpdateNeed.required) {
      return _UpdateRequired(
        current: _current,
        onUpdate: () => _update(immediate: true),
      );
    }
    return widget.child;
  }
}

/// Blocks the app: this version is no longer supported.
class _UpdateRequired extends StatelessWidget {
  final String current;
  final VoidCallback onUpdate;
  const _UpdateRequired({required this.current, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CairnMark(size: 56),
                const SizedBox(height: 24),
                Text('Update Cairn to keep sharing',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                Text(
                  'This version${current.isEmpty ? '' : ' ($current)'} is no '
                  "longer supported, so it can't share with your contacts. "
                  'Update to the latest version to carry on.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Brand.stone),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onUpdate,
                  icon: const Icon(Icons.system_update),
                  label: const Text('Update'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
