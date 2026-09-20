/// <reference path="../pb_data/types.d.ts" />
// Adds the `location_history` collection: a per-user, day-bucketed trail of
// where the owner and their contacts have been, used for the History / Trips
// view.
//
// PRIVACY: each row holds ONE end-to-end-encrypted blob (`ciphertext`, sealed
// to the owner's own key) containing that day's breadcrumb points for one
// subject. The server never reads a coordinate. Rows are owner-scoped: only the
// owner can read or write their own history.
//
// `subject` (the observed user's id — the owner, or a paired contact) and `day`
// (UTC date) are kept in plaintext ONLY so the app can fetch the right daily
// row without downloading everything. This exposes no more than the server
// already sees: the pairing graph lives in `contacts` and freshness in
// `last_seen`. Blinding that routing metadata is the separate Phase 3 work, not
// this feature's job. The coordinates themselves stay encrypted.
//
// Only-what-I-can-see: history is always the OWNER's observations (my own GPS,
// plus the locations a contact already shares with me), re-encrypted to myself.
// I never gain data I couldn't already read live.
//
// Authored without a running PocketBase (like the rate-limit / places
// migrations) — defensive: idempotent and wrapped so a schema-shape difference
// can't halt startup. VERIFY in the Admin UI after deploy.
migrate((app) => {
  try {
    try {
      app.findCollectionByNameOrId("location_history");
      console.log("[cairn] location_history already exists — skipping");
      return;
    } catch (_) {
      // not found → create it
    }

    const users = app.findCollectionByNameOrId("users");

    const history = new Collection({
      type: "base",
      name: "location_history",
      listRule: "@request.auth.id = owner.id",
      viewRule: "@request.auth.id = owner.id",
      createRule: "@request.auth.id = owner.id",
      updateRule: "@request.auth.id = owner.id",
      deleteRule: "@request.auth.id = owner.id",
      fields: [
        {
          type: "relation",
          name: "owner",
          required: true,
          maxSelect: 1,
          minSelect: 0,
          cascadeDelete: true,
          collectionId: users.id,
        },
        {
          // The observed user's id: the owner's own id, or a paired contact's.
          type: "text",
          name: "subject",
          required: true,
          min: 0,
          max: 50,
        },
        {
          // UTC calendar day, "YYYY-MM-DD".
          type: "text",
          name: "day",
          required: true,
          min: 0,
          max: 10,
        },
        {
          // Sealed-to-self JSON: { points: [{ lat, lng, t, a? }, …] }.
          type: "text",
          name: "ciphertext",
          required: true,
          min: 0,
          max: 2000000,
        },
        { type: "autodate", name: "created", onCreate: true, onUpdate: false },
        { type: "autodate", name: "updated", onCreate: true, onUpdate: true },
      ],
    });

    // One row per (owner, subject, day) — the daily blob we append to.
    history.addIndex(
      "idx_history_owner_subject_day",
      true,
      "`owner`, `subject`, `day`",
      ""
    );

    app.save(history);
    console.log("[cairn] location_history collection created (owner-scoped)");
  } catch (e) {
    console.log("[cairn] add-location_history migration skipped:", e);
  }
}, (app) => {
  try {
    const history = app.findCollectionByNameOrId("location_history");
    app.delete(history);
  } catch (e) {
    console.log("[cairn] add-location_history down-migration skipped:", e);
  }
});
