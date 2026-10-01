import 'prefs.dart';

/// "Pause sharing for a while": while paused, every contact is treated as
/// paused — my shares are deleted and none are sent — until the pause runs
/// out or I resume. Stored on the device only, so the background service
/// (its own isolate) reads the same answer; my own History keeps recording.
class SharingPause {
  SharingPause._();

  /// Stands in for "until I resume".
  static final forever = DateTime.utc(9999);

  /// When the pause ends, or null when sharing normally. A pause that has
  /// run out reads as null.
  static Future<DateTime?> until({DateTime? now}) async {
    final raw = await Prefs.sharingPausedUntil();
    final t = raw == null ? null : DateTime.tryParse(raw);
    return active(t, now ?? DateTime.now()) ? t : null;
  }

  static Future<bool> isPaused({DateTime? now}) async =>
      await until(now: now) != null;

  /// Pause until [until] ([forever] = until I resume).
  static Future<void> pauseUntil(DateTime until) =>
      Prefs.setSharingPausedUntil(until.toUtc().toIso8601String());

  static Future<void> resume() => Prefs.setSharingPausedUntil(null);

  /// Is a pause ending at [until] still on at [now]? Pure — unit-tested.
  static bool active(DateTime? until, DateTime now) =>
      until != null && now.isBefore(until);

  /// 8 am tomorrow, local time: "until tomorrow".
  static DateTime tomorrowMorning(DateTime now) =>
      DateTime(now.year, now.month, now.day + 1, 8);

  /// When the pause ends, in words: "until you resume", "until 15:40",
  /// "until tomorrow, 08:00". [time] formats a clock time for the locale.
  static String describe(DateTime until, DateTime now,
      {required String Function(DateTime) time}) {
    if (!until.isBefore(forever)) return 'until you resume';
    final end = until.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(end.year, end.month, end.day);
    final days = day.difference(today).inHours ~/ 24; // DST-safe enough
    if (days <= 0) return 'until ${time(end)}';
    if (days == 1) return 'until tomorrow, ${time(end)}';
    return 'until ${end.day}/${end.month}, ${time(end)}';
  }
}
