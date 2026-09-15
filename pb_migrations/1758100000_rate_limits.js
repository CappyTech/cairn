/// <reference path="../pb_data/types.d.ts" />
// Abuse resistance: enable PocketBase's built-in rate limiter for the two
// open, abuse-prone endpoints — account creation (users:create) and pairing
// requests (pair_requests:create), which have permissive create rules by
// design (no account gate).
//
// NOTE — authored without a running PocketBase, so VERIFY after deploy:
//  1. Admin UI → Settings → confirm rate limiting is ON and both rules exist.
//  2. Cairn runs behind Caddy. PocketBase must use the forwarded client IP,
//     or every request looks like it comes from Caddy (one shared bucket).
//     This sets trustedProxy to read X-Forwarded-For; confirm request logs
//     show real client IPs. If they don't, the limits apply globally — the
//     conservative values below still won't block realistic legit volume, but
//     tune once per-client IPs are confirmed.
//  3. Tune maxRequests / duration to taste.
//
// The whole thing is wrapped in try/catch: if any field shape differs on this
// PocketBase version, it logs and no-ops instead of halting server startup —
// worst case the limits simply don't apply (fail-safe, never fail-closed).
migrate((app) => {
  try {
    const settings = app.settings();

    // Use the real client IP from Caddy, not the proxy's own address, so the
    // limiter buckets per client rather than lumping everyone together.
    settings.trustedProxy.headers = ["X-Forwarded-For"];
    settings.trustedProxy.useLeftmostIP = false;

    settings.rateLimits.enabled = true;
    settings.rateLimits.rules = [
      { label: "users:create", maxRequests: 20, duration: 60, audience: "" },
      { label: "pair_requests:create", maxRequests: 60, duration: 60, audience: "" },
    ];

    app.save(settings);
    console.log("[cairn] rate limits enabled (users:create, pair_requests:create)");
  } catch (e) {
    console.log("[cairn] rate-limit migration skipped, left disabled:", e);
  }
}, (app) => {
  try {
    const settings = app.settings();
    settings.rateLimits.enabled = false;
    settings.rateLimits.rules = [];
    settings.trustedProxy.headers = [];
    app.save(settings);
  } catch (e) {
    console.log("[cairn] rate-limit down-migration skipped:", e);
  }
});
