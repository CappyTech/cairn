/// <reference path="../pb_data/types.d.ts" />
// Adds the `places` collection: a user's named locations (Home, Work…) used for
// on-device geofence alerts ("Alice arrived at Home").
//
// PRIVACY: the server stores ONE end-to-end-encrypted blob per place
// (`ciphertext`, sealed to the owner's own key). It never sees a place's name,
// coordinates, or radius — those are decrypted only on the owner's device. Rows
// are owner-scoped: only the owner can read or write their own places. Geofence
// evaluation (is contact X inside place Y?) happens entirely on-device from the
// already-decrypted location shares, so this collection adds no location
// metadata the server could read.
//
// Authored like the rate-limit migration — without a running PocketBase — so it
// is defensive: idempotent (skips if the collection already exists) and wrapped
// so a schema-shape difference can't halt server startup. VERIFY after deploy in
// the Admin UI that `places` exists with owner-only rules.
migrate((app) => {
  try {
    // Idempotent: if a prior run (or import) already created it, do nothing.
    try {
      app.findCollectionByNameOrId("places");
      console.log("[cairn] places collection already exists — skipping");
      return;
    } catch (_) {
      // not found → create it below
    }

    const users = app.findCollectionByNameOrId("users");

    const places = new Collection({
      type: "base",
      name: "places",
      // Owner-only: a place is private to the account that created it.
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
          // Sealed-to-self JSON: { name, lat, lng, radius, alerts }.
          type: "text",
          name: "ciphertext",
          required: true,
          min: 0,
          max: 100000,
        },
        { type: "autodate", name: "created", onCreate: true, onUpdate: false },
        { type: "autodate", name: "updated", onCreate: true, onUpdate: true },
      ],
    });

    app.save(places);
    console.log("[cairn] places collection created (owner-scoped, E2E blob)");
  } catch (e) {
    console.log("[cairn] add-places migration skipped:", e);
  }
}, (app) => {
  // Down: remove the collection if present.
  try {
    const places = app.findCollectionByNameOrId("places");
    app.delete(places);
  } catch (e) {
    console.log("[cairn] add-places down-migration skipped:", e);
  }
});
