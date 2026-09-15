/// Pure presence/staleness logic, split out so the "who just went quiet"
/// decision is unit-testable without a widget, a clock, or a server.
///
/// A contact is "stale" when their most recent share is older than [staleAfter].
/// The two helpers below drive edge-triggered notifications: fire once when a
/// contact crosses into stale, and re-arm when they come back fresh — so a
/// contact who stays offline doesn't re-notify on every tick.
class Presence {
  static const staleAfter = Duration(minutes: 15);

  /// Peer ids that are stale as of [now] but not already in [alreadyNotified]
  /// — i.e. the ones that JUST went stale and should trigger one alert.
  static Set<String> newlyStale({
    required Map<String, DateTime> updatedById,
    required Set<String> alreadyNotified,
    required DateTime now,
    Duration threshold = staleAfter,
  }) {
    final out = <String>{};
    updatedById.forEach((id, updated) {
      final isStale = now.difference(updated) >= threshold;
      if (isStale && !alreadyNotified.contains(id)) out.add(id);
    });
    return out;
  }

  /// Ids in [alreadyNotified] that are fresh again as of [now] — clear these so
  /// the contact can alert again next time they go quiet. Includes ids that
  /// have disappeared from [updatedById] (e.g. contact removed).
  static Set<String> freshAgain({
    required Map<String, DateTime> updatedById,
    required Set<String> alreadyNotified,
    required DateTime now,
    Duration threshold = staleAfter,
  }) {
    return alreadyNotified.where((id) {
      final updated = updatedById[id];
      if (updated == null) return true; // gone → drop from the notified set
      return now.difference(updated) < threshold;
    }).toSet();
  }
}
