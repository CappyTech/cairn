/// <reference path="../pb_data/types.d.ts" />
// Adds `shared_places`: pins one user deliberately shares with specific
// contacts ("meet me here" / "where I'm staying"), which the recipient keeps on
// their map even when the sharer isn't there. Unlike `places` (private to you),
// these are addressed to a contact.
//
// PRIVACY: each row's `ciphertext` is sealed to the RECIPIENT's key (like
// `location_shares`), so only they can read the pin's name/coords. The sharer
// also stores a self-addressed copy (recipient == owner) so they can manage and
// revoke what they shared, and see it on their own other devices. Rows carry a
// plaintext `group` id (a random token) so all per-recipient copies of one pin
// can be found and revoked together; it reveals nothing about the pin.
//
// Rules: readable by the owner or the recipient; only the owner can create /
// change / delete. Not upserted — a user may share many pins.
//
// Authored without a running PocketBase (like the other cairn migrations) —
// idempotent and wrapped so a schema-shape difference can't halt startup.
migrate((app) => {
  try {
    try {
      app.findCollectionByNameOrId("shared_places");
      console.log("[cairn] shared_places already exists — skipping");
      return;
    } catch (_) {
      // not found → create it
    }

    const users = app.findCollectionByNameOrId("users");

    const shared = new Collection({
      type: "base",
      name: "shared_places",
      listRule: "@request.auth.id = owner.id || @request.auth.id = recipient.id",
      viewRule: "@request.auth.id = owner.id || @request.auth.id = recipient.id",
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
          type: "relation",
          name: "recipient",
          required: true,
          maxSelect: 1,
          minSelect: 0,
          cascadeDelete: true,
          collectionId: users.id,
        },
        {
          // Random id tying together the per-recipient copies of one shared pin.
          type: "text",
          name: "group",
          required: true,
          min: 0,
          max: 64,
        },
        {
          // Sealed to the recipient's key: JSON { name, lat, lng, note }.
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

    shared.addIndex("idx_shared_places_owner_group", false, "`owner`, `group`", "");
    app.save(shared);
    console.log("[cairn] shared_places collection created (owner/recipient scoped)");
  } catch (e) {
    console.log("[cairn] add-shared_places migration skipped:", e);
  }
}, (app) => {
  try {
    const shared = app.findCollectionByNameOrId("shared_places");
    app.delete(shared);
  } catch (e) {
    console.log("[cairn] add-shared_places down-migration skipped:", e);
  }
});
