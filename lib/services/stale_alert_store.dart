import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'presence.dart';

/// Persisted, cross-isolate state for the "contact went quiet" alert.
///
/// The stale decision is edge-triggered: fire once when a contact crosses into
/// stale, stay silent until they come back and go quiet again. That needs a
/// memory of who's already been alerted — and it can't live in a single
/// screen's `State`, because both the map screen (foreground) and the
/// background isolate evaluate it. Two separate in-memory sets would double-fire
/// (the map alerts, then the isolate alerts the same contact) and forget
/// everything on restart.
///
/// So the set (plus a "seeded" flag, so the first-ever pass adopts a baseline
/// instead of alerting for everyone already quiet) lives in secure storage,
/// which both isolates share. The decision itself stays in the pure
/// [Presence.reconcile]; this class only loads/saves its state and applies it.
class StaleAlertStore {
  static const _storage = FlutterSecureStorage();
  static const _notifiedKey = 'stale_notified_v1';
  static const _seededKey = 'stale_seeded_v1';

  /// Load the persisted notified-set. Empty (and thus a fresh baseline) if
  /// unset or unreadable/corrupt.
  static Future<Set<String>> notified() async {
    final raw = await _storage.read(key: _notifiedKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as List).map((e) => e as String).toSet();
    } catch (_) {
      return {};
    }
  }

  /// Whether a baseline has been established. False on a fresh install / after
  /// a new server / the first time alerts are on, so [Presence.reconcile] knows
  /// not to alert for contacts that were already quiet.
  static Future<bool> seeded() async =>
      (await _storage.read(key: _seededKey)) == '1';

  /// Evaluate one pass against the persisted state and return the contacts that
  /// just went stale (to notify), persisting the next state. Shared verbatim by
  /// the map screen and the background isolate so they never disagree.
  static Future<Set<String>> evaluate({
    required Map<String, DateTime> updatedById,
    required DateTime now,
  }) async {
    final result = Presence.reconcile(
      updatedById: updatedById,
      alreadyNotified: await notified(),
      seeded: await seeded(),
      now: now,
    );
    await _save(result.nextNotified, result.nextSeeded);
    return result.toNotify;
  }

  static Future<void> _save(Set<String> notified, bool seeded) async {
    await _storage.write(
        key: _notifiedKey, value: jsonEncode(notified.toList()));
    await _storage.write(key: _seededKey, value: seeded ? '1' : '0');
  }

  /// Forget the baseline (e.g. when switching servers or signing out) so the
  /// next pass re-seeds instead of alerting for everyone already quiet.
  static Future<void> reset() async {
    await _storage.delete(key: _notifiedKey);
    await _storage.delete(key: _seededKey);
  }
}
