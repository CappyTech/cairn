import 'pb_client.dart';
import 'prefs.dart';
import 'history_service.dart';

/// Outcome of evaluating the current server's history-retention policy.
enum HistoryPolicyState {
  /// The user must be asked to agree (never asked, or the policy changed).
  needsConsent,

  /// Agreed — recording is on and history is pruned to the effective window.
  enabled,

  /// Declined for the current policy — recording stays off.
  disabled,
}

/// Ties the server's advertised retention policy to the user's consent and the
/// client-side pruning. History only records/syncs to a server whose policy the
/// user has agreed to; the operator sets the window (`server_config`), the user
/// may tighten it locally, and the client enforces the smaller of the two.
class HistoryPolicy {
  /// The server's advertised retention (days; 0 = keep all) from the last
  /// [evaluate]. Shown in the consent prompt and settings.
  static int serverDays = 0;

  /// Read cached consent (enabling recording optimistically so it works before
  /// the network resolves), then fetch the live policy and decide.
  static Future<({HistoryPolicyState state, int serverDays})> evaluate() async {
    final server = serverUrl;
    final cached = await Prefs.historyConsent(server);
    if (cached != null && !cached.declined) {
      HistoryService.recordingEnabled = true; // optimistic from cache
    }

    final days = await HistoryService.fetchServerRetentionDays();
    serverDays = days;
    final stored = await Prefs.historyConsent(server);

    if (HistoryService.consentNeeded(serverDays: days, stored: stored)) {
      HistoryService.recordingEnabled = false; // pending (re)consent
      return (state: HistoryPolicyState.needsConsent, serverDays: days);
    }
    if (stored!.declined) {
      HistoryService.recordingEnabled = false;
      return (state: HistoryPolicyState.disabled, serverDays: days);
    }
    HistoryService.recordingEnabled = true;
    await _pruneToEffective();
    return (state: HistoryPolicyState.enabled, serverDays: days);
  }

  /// Record the user's agreement to the current [days] policy and start syncing.
  /// How long this server keeps history, in words — shared by onboarding and
  /// the Home re-consent dialog so they always say the same thing.
  static String retentionText(int days) => days <= 0
      ? 'This server keeps your location history for as long as you use it '
          '(no automatic deletion).'
      : 'This server keeps your location history for $days '
          '${days == 1 ? 'day' : 'days'}, then deletes it automatically.';

  static Future<void> agree(int days) async {
    serverDays = days;
    await Prefs.setHistoryConsent(
        serverUrl, HistoryConsent(days: days, declined: false));
    HistoryService.recordingEnabled = true;
    await _pruneToEffective();
  }

  /// Record that the user declined the current [days] policy; history stays off.
  static Future<void> decline(int days) async {
    serverDays = days;
    await Prefs.setHistoryConsent(
        serverUrl, HistoryConsent(days: days, declined: true));
    HistoryService.recordingEnabled = false;
  }

  /// For the background service, which runs in its own isolate with its own
  /// (off) copy of [HistoryService.recordingEnabled] and can't ask the user
  /// anything: record only if they agreed to this server's policy and it
  /// hasn't changed since. Cheap; call it every tick so a decline in the app
  /// takes effect on the next one.
  static Future<void> refreshForBackground() async {
    final stored = await Prefs.historyConsent(serverUrl);
    final days = stored == null || stored.declined
        ? null
        : await HistoryService.tryFetchServerRetentionDays();
    HistoryService.recordingEnabled = HistoryService.backgroundRecordingAllowed(
        stored: stored, serverDays: days);
  }

  /// Re-prune after the user changes their local override.
  static Future<void> applyLocalChange() => _pruneToEffective();

  /// The effective window now (server ∧ local override).
  static Future<int> effectiveDays() async {
    final local = await Prefs.historyLocalRetentionDays();
    return HistoryService.effectiveRetentionDays(serverDays, local);
  }

  static Future<void> _pruneToEffective() async {
    await HistoryService.pruneOldDays(await effectiveDays());
  }
}
