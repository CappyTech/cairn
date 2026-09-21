import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Per-contact toggles for the local features that would otherwise apply to
/// everyone: whether to record THIS contact's location history, and whether
/// their movements raise geofence (place) alerts.
///
/// Both default ON. Kept on-device only (like nicknames) — they're my private
/// choice about how I treat a contact, never sent to the server, and don't
/// follow a recovery-phrase restore.
class ContactControls {
  final bool history; // record this contact's trail into location_history
  final bool alerts; // fire arrive/leave alerts for this contact

  const ContactControls({this.history = true, this.alerts = true});

  ContactControls copyWith({bool? history, bool? alerts}) => ContactControls(
        history: history ?? this.history,
        alerts: alerts ?? this.alerts,
      );

  Map<String, dynamic> toJson() => {'h': history, 'a': alerts};

  /// Absent fields default to ON, so an older/partial entry never silently
  /// disables a feature.
  static ContactControls fromJson(Map<String, dynamic> j) => ContactControls(
        history: j['h'] != false,
        alerts: j['a'] != false,
      );
}

/// On-device store of [ContactControls], keyed by the peer's user id.
class ContactPrefsService {
  static const _storage = FlutterSecureStorage();
  static const _key = 'contact_controls_v1';

  /// The controls for [peerId] from an already-loaded [map], defaulting to
  /// both-on when absent. Pure, so it's unit-tested and cheap to call per tick.
  static ContactControls resolve(
          Map<String, ContactControls> map, String peerId) =>
      map[peerId] ?? const ContactControls();

  /// All per-contact controls, keyed by peer id. Empty if none set or the store
  /// is unreadable/corrupt.
  static Future<Map<String, ContactControls>> all() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) =>
          MapEntry(k, ContactControls.fromJson(v as Map<String, dynamic>)));
    } catch (_) {
      return {};
    }
  }

  static Future<ContactControls> forId(String peerId) async =>
      resolve(await all(), peerId);

  static Future<void> _write(Map<String, ContactControls> map) async {
    await _storage.write(
      key: _key,
      value: jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  static Future<void> setHistory(String peerId, bool on) async {
    final map = await all();
    map[peerId] = resolve(map, peerId).copyWith(history: on);
    await _write(map);
  }

  static Future<void> setAlerts(String peerId, bool on) async {
    final map = await all();
    map[peerId] = resolve(map, peerId).copyWith(alerts: on);
    await _write(map);
  }

  /// Forget a contact's controls (call when unpairing), so a re-paired stranger
  /// doesn't inherit them.
  static Future<void> remove(String peerId) async {
    final map = await all();
    if (map.remove(peerId) != null) await _write(map);
  }
}
