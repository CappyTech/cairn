/// <reference path="../pb_data/types.d.ts" />
// Adds `server_config`: a public, read-only singleton the operator uses to
// advertise this server's policies to clients. Today it carries
// `history_retention_days` — how long location history is kept before it's
// pruned (0 = keep everything). The client reads this, asks the user to agree on
// first connect, and enforces it (client-side prune). The value is intentionally
// PUBLIC (read by anyone) so a client can show the policy before the user has
// any account state; it contains no user data.
//
// Only superusers can change it (write rules are null) — edit it in the Admin UI
// (Collections → server_config → the single record).
//
// Authored without a running PocketBase (like the other cairn migrations) —
// idempotent and wrapped so a schema-shape difference can't halt startup.
migrate((app) => {
  try {
    try {
      app.findCollectionByNameOrId("server_config");
      console.log("[cairn] server_config already exists — skipping");
      return;
    } catch (_) {
      // not found → create it
    }

    const cfg = new Collection({
      type: "base",
      name: "server_config",
      // Public read; writes are superuser-only (null rules).
      listRule: "",
      viewRule: "",
      createRule: null,
      updateRule: null,
      deleteRule: null,
      fields: [
        {
          type: "number",
          name: "history_retention_days",
          required: false,
          onlyInt: true,
          min: 0,
        },
        { type: "autodate", name: "created", onCreate: true, onUpdate: false },
        { type: "autodate", name: "updated", onCreate: true, onUpdate: true },
      ],
    });
    app.save(cfg);

    // Seed the single config record with the default policy: keep everything.
    const saved = app.findCollectionByNameOrId("server_config");
    const rec = new Record(saved);
    rec.set("history_retention_days", 0);
    app.save(rec);

    console.log("[cairn] server_config created (public read, default retention 0 = keep all)");
  } catch (e) {
    console.log("[cairn] add-server_config migration skipped:", e);
  }
}, (app) => {
  try {
    const cfg = app.findCollectionByNameOrId("server_config");
    app.delete(cfg);
  } catch (e) {
    console.log("[cairn] add-server_config down-migration skipped:", e);
  }
});
