/// <reference path="../pb_data/types.d.ts" />
// Adds `rev` to `location_history`: a per-row revision number used for
// compare-and-swap writes, so two writers appending to the same daily blob
// can't silently drop each other's points. (The app and its background
// service on one phone, or two phones on one account, both read-merge-write
// the same row.) `pb_hooks/history_rev.pb.js` enforces it.
//
// Idempotent and wrapped like the other migrations. Existing rows start at 0.
migrate((app) => {
  try {
    const history = app.findCollectionByNameOrId("location_history");
    if (history.fields.getByName("rev")) {
      console.log("[cairn] location_history.rev already exists — skipping");
      return;
    }
    history.fields.add(new NumberField({
      name: "rev",
      required: false,
      onlyInt: true,
      min: 0,
    }));
    app.save(history);
    console.log("[cairn] location_history.rev added");
  } catch (e) {
    console.log("[cairn] add-history-rev migration skipped:", e);
  }
}, (app) => {
  try {
    const history = app.findCollectionByNameOrId("location_history");
    history.fields.removeByName("rev");
    app.save(history);
  } catch (e) {
    console.log("[cairn] add-history-rev down-migration skipped:", e);
  }
});
