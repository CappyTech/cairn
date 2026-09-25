import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'crypto_service.dart';
import 'history_service.dart';

/// Road-snapped trip lines kept on this device, so History doesn't ask a
/// router again for a trip it already snapped. The file is sealed to me like
/// the history itself; on the web the cache lives in memory only.
abstract final class SnapCache {
  /// Most trips kept; the least recently used go first.
  static const maxEntries = 300;

  static final LinkedHashMap<String, List<LatLng>> _lines = LinkedHashMap();
  static Future<void>? _loading;
  static Timer? _saveTimer;

  /// Identifies one trip's snap: whose, when, how many fixes (a trip that
  /// gained fixes since is snapped again) and the mode it was matched for.
  /// Pure.
  static String keyFor(String subject, Move m) =>
      '$subject|${m.start.millisecondsSinceEpoch}|'
      '${m.end.millisecondsSinceEpoch}|${m.path.length}|${m.mode.name}';

  static Future<List<LatLng>?> get(String key) async {
    await _load();
    final line = _lines.remove(key);
    if (line != null) _lines[key] = line; // most recently used
    return line;
  }

  static Future<void> put(String key, List<LatLng> line) async {
    await _load();
    _lines.remove(key);
    _lines[key] = line;
    while (_lines.length > maxEntries) {
      _lines.remove(_lines.keys.first);
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  /// JSON for [lines], coordinates to ~10 cm. Pure.
  static String encode(Map<String, List<LatLng>> lines) => jsonEncode({
        for (final e in lines.entries)
          e.key: [
            for (final c in e.value)
              [
                double.parse(c.latitude.toStringAsFixed(6)),
                double.parse(c.longitude.toStringAsFixed(6))
              ]
          ]
      });

  /// The lines in [json]; entries that don't parse are skipped. Pure.
  static Map<String, List<LatLng>> decode(String json) {
    final out = <String, List<LatLng>>{};
    try {
      for (final e in (jsonDecode(json) as Map<String, dynamic>).entries) {
        try {
          out[e.key] = [
            for (final c in e.value as List)
              LatLng(((c as List)[0] as num).toDouble(),
                  (c[1] as num).toDouble())
          ];
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  static Future<File?> _file() async {
    if (kIsWeb) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/snap_cache.sealed');
    } catch (_) {
      return null;
    }
  }

  static Future<void> _load() => _loading ??= () async {
        try {
          final f = await _file();
          if (f == null || !await f.exists()) return;
          final clear = await CryptoService.openSealedText(await f.readAsString());
          _lines.addAll(decode(clear));
        } catch (_) {/* unreadable → start empty */}
      }();

  static Future<void> _save() async {
    try {
      final f = await _file();
      if (f == null) return;
      await f.writeAsString(await CryptoService.sealTextForSelf(encode(_lines)));
    } catch (_) {/* best-effort */}
  }
}
