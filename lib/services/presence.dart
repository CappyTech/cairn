/// Pure presence/staleness logic, split out so the "who just went quiet"
/// decision is unit-testable without a widget, a clock, or a server.
///
/// A contact is "stale" when their most recent share is older than [staleAfter].
/// The two helpers below drive edge-triggered notifications: fire once when a
/// contact crosses into stale, and re-arm when they come back fresh — so a
/// contact who stays offline doesn't re-notify on every tick.
/// How fresh a contact's last shared location is, for at-a-glance UI.
enum PresenceLevel { live, recent, stale, old, never }

class Presence {
  static const staleAfter = Duration(minutes: 15);

  /// A level + short human label for a contact whose last share was [updated]
  /// (null = never shared), as of [now]. Pure, so the contacts list and map can
  /// share one definition and it's unit-testable without a clock.
  static ({PresenceLevel level, String label}) describe({
    required DateTime? updated,
    required DateTime now,
  }) {
    if (updated == null) return (level: PresenceLevel.never, label: 'No location yet');
    final age = now.difference(updated);
    if (age.inMinutes < 2) return (level: PresenceLevel.live, label: 'Live');
    if (age.inMinutes < 15) {
      return (level: PresenceLevel.recent, label: '${age.inMinutes}m ago');
    }
    if (age.inHours < 24) {
      return (level: PresenceLevel.stale, label: '${age.inHours}h ago');
    }
    return (level: PresenceLevel.old, label: '${age.inDays}d ago');
  }

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

  /// One pass of the edge-triggered stale decision, folding [freshAgain] +
  /// [newlyStale] into a single pure step so the foreground (map screen) and
  /// the background isolate run *identical* logic over one shared, persisted
  /// state — the only way they don't double-fire or disagree.
  ///
  /// - [toNotify]: contacts that JUST crossed into stale and should alert now.
  /// - [nextNotified]: the notified-set to persist (fresh-again ids dropped,
  ///   newly-stale ids added).
  /// - [nextSeeded]: always true — record that a baseline now exists.
  ///
  /// On the **first ever** pass ([seeded] == false) nothing is notified:
  /// contacts already quiet when alerts were first switched on (or on a fresh
  /// install / new server) are adopted as the baseline, not reported as if they
  /// "just" went quiet. They're still tracked, so they re-arm normally once
  /// they come back and go quiet again.
  static ({Set<String> toNotify, Set<String> nextNotified, bool nextSeeded})
      reconcile({
    required Map<String, DateTime> updatedById,
    required Set<String> alreadyNotified,
    required bool seeded,
    required DateTime now,
    Duration threshold = staleAfter,
  }) {
    final carried = alreadyNotified.difference(freshAgain(
      updatedById: updatedById,
      alreadyNotified: alreadyNotified,
      now: now,
      threshold: threshold,
    ));
    final newly = newlyStale(
      updatedById: updatedById,
      alreadyNotified: carried,
      now: now,
      threshold: threshold,
    );
    if (!seeded) {
      // Adopt everything currently stale as the baseline; alert on none of it.
      return (
        toNotify: <String>{},
        nextNotified: carried.union(newly),
        nextSeeded: true,
      );
    }
    return (
      toNotify: newly,
      nextNotified: carried.union(newly),
      nextSeeded: true,
    );
  }
}
