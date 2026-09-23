import 'package:flutter/material.dart';
import '../services/background_share.dart';

/// Shared UX for turning background location sharing on or off, including the
/// prominent disclosure Android policy requires *before* the permission prompt
/// and the "Allow all the time" settings hand-off on Android 11+.
///
/// Both the Home settings switch and the map's own-marker sheet drive it, so
/// they behave identically and the policy-sensitive copy lives in one place.
class BackgroundShareUx {
  /// Run the toggle flow for the requested [on] state and return the resulting
  /// enabled state, so the caller can update its own switch. Shows dialogs and
  /// snackbars via [context]; guards every async gap with `context.mounted`.
  static Future<bool> toggle(BuildContext context, {required bool on}) async {
    if (!on) {
      await BackgroundShare.disable();
      return false;
    }
    // Prominent disclosure must come before requesting the permission.
    if (!await _disclosure(context)) return false;
    if (!context.mounted) return false;
    final res = await BackgroundShare.enable();
    if (!context.mounted) return false;
    switch (res) {
      case BgEnableResult.enabled:
        return true;
      case BgEnableResult.needsAllTheTime:
        await _openAllTheTimeSettings(context);
        return false;
      case BgEnableResult.denied:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Location permission is needed to share.')));
        return false;
      case BgEnableResult.needsNotifications:
        await _openNotificationSettings(context);
        return false;
    }
  }

  /// Notifications are off, so the "Sharing your location" notification would
  /// be invisible. Explain, and send the user to turn them on.
  static Future<void> _openNotificationSettings(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.notifications_off_outlined),
        title: const Text('Turn on notifications first'),
        content: const Text(
          'While Cairn shares in the background it shows a permanent '
          'notification, so you always know your location is being shared. '
          "Notifications are off for Cairn, so you wouldn't see it.\n\n"
          'On the next screen, open Notifications and turn them on, then '
          'come back and switch this on.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open settings')),
        ],
      ),
    );
    if (go == true) await BackgroundShare.openAppSettings();
  }

  static Future<bool> _disclosure(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.my_location),
        title: const Text('Share your location in the background'),
        content: const Text(
          'Cairn collects location data to share your location with the '
          'contacts you have paired with, even when the app is closed or not '
          'in use.\n\n'
          'A permanent notification will show while this is on, and you can '
          'turn it off at any time. Your location stays end-to-end encrypted — '
          'only your chosen contacts can read it.\n\n'
          'To enable this, Android will next ask you to allow location '
          '"all the time".',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Allow')),
        ],
      ),
    );
    return ok == true;
  }

  /// Second-step guidance: on Android 11+ "Allow all the time" can only be set
  /// in system settings, so send the user there with clear instructions.
  static Future<void> _openAllTheTimeSettings(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.tune),
        title: const Text('One more step'),
        content: const Text(
          'To share while the app is closed, Android needs location set to '
          '"Allow all the time".\n\n'
          'On the next screen, open Permissions → Location and choose '
          '"Allow all the time", then come back and switch this on.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open settings')),
        ],
      ),
    );
    if (go == true) await BackgroundShare.openAppLocationSettings();
  }
}
