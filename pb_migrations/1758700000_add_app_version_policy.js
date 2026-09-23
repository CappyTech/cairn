/// <reference path="../pb_data/types.d.ts" />
// Adds an app-version policy to `server_config`, so a server operator can tell
// clients they're out of date:
//   - min_app_version:    below this, the app blocks with "Update Cairn" (use it
//                         before a breaking server change, e.g. sealed sender);
//   - latest_app_version: below this, the app shows a dismissible "update
//                         available" banner.
// Both are plain version names ("0.0.16"); empty = no policy. Public read like
// the rest of server_config (no user data); superuser-only writes.
//
// Idempotent and wrapped so a schema-shape difference can't halt startup.
migrate((app) => {
  try {
    const cfg = app.findCollectionByNameOrId("server_config");
    let changed = false;
    for (const name of ["min_app_version", "latest_app_version"]) {
      if (cfg.fields.getByName(name)) continue;
      cfg.fields.add(new TextField({ name: name, required: false, max: 32 }));
      changed = true;
    }
    if (changed) {
      app.save(cfg);
      console.log("[cairn] server_config: added app version policy fields");
    }
  } catch (e) {
    console.log("[cairn] add-app-version-policy migration skipped:", e);
  }
}, (app) => {
  try {
    const cfg = app.findCollectionByNameOrId("server_config");
    for (const name of ["min_app_version", "latest_app_version"]) {
      const f = cfg.fields.getByName(name);
      if (f) cfg.fields.removeById(f.id);
    }
    app.save(cfg);
  } catch (_) {}
});
