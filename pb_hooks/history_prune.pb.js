/// <reference path="../pb_data/types.d.ts" />
// Server-side enforcement of the location-history retention policy.
//
// The client prunes its own history to the agreed window, but that only runs
// when a client runs. This scheduled job makes the SERVER authoritative: it
// deletes `location_history` rows older than the operator's advertised window
// (`server_config.history_retention_days`), so the promise "this server keeps
// history for N days" holds even for a user who never opens the app again.
//
// Privacy-safe: it prunes by the plaintext `day` field only (never reads the
// encrypted `ciphertext`). 0 (or missing config) = keep everything → no-op.
// Runs daily at 03:00 (server time). Wrapped so a bad tick logs and moves on.
//
// NOTE: PocketBase runs each hook handler in an isolated JS runtime, so file-
// scope helpers are NOT visible inside the callback — all logic lives inline
// here on purpose. The cutoff-day boundary mirrors the client's
// HistoryService.daysToPrune so server and client agree.
cronAdd("cairnHistoryPrune", "0 3 * * *", () => {
  try {
    // The server's advertised retention window (days; 0/absent = keep all).
    let keep = 0;
    try {
      const cfg = $app.findFirstRecordByFilter("server_config", "id != ''");
      const v = cfg.getInt("history_retention_days");
      keep = v > 0 ? v : 0;
    } catch (e) {
      keep = 0; // no config → keep everything
    }
    if (keep <= 0) return;

    // The oldest day still inside a `keep`-day window ending today (inclusive);
    // rows with `day` before this are pruned.
    const now = new Date();
    const c = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
    c.setUTCDate(c.getUTCDate() - (keep - 1));
    const mm = String(c.getUTCMonth() + 1).padStart(2, "0");
    const dd = String(c.getUTCDate()).padStart(2, "0");
    const cutoff = `${c.getUTCFullYear()}-${mm}-${dd}`;

    let deleted = 0;
    for (;;) {
      const batch = $app.findRecordsByFilter(
        "location_history",
        "day < {:cutoff}",
        "day",
        200,
        0,
        { cutoff: cutoff }
      );
      if (!batch.length) break;
      for (const r of batch) {
        $app.delete(r);
        deleted++;
      }
      if (batch.length < 200) break;
    }
    if (deleted > 0) {
      $app.logger().info("[cairn] history prune", "deleted", deleted, "cutoff", cutoff);
    }
  } catch (e) {
    $app.logger().error("[cairn] history prune failed", "error", String(e));
  }
});
