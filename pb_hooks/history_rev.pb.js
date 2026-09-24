/// <reference path="../pb_data/types.d.ts" />
// Compare-and-swap for `location_history` updates.
//
// Each daily blob is read, merged and written back whole by the client, and
// more than one writer can do that at once: the app and its background
// service on one phone, or two phones on one account. Without a check, the
// later write silently drops the earlier one's points.
//
// So every row carries a `rev` number. A client updating a row sends the rev
// it read plus one; if the stored rev has moved on since, the update is
// refused with 409 and the client re-reads, re-merges and tries again. The
// check and the save run in one transaction (PocketBase serialises write
// transactions), so two writers can't both pass it. An update that sends no
// rev (an older app) is let through but still bumps rev, so newer clients
// notice it.
//
// Privacy-safe: it only reads/writes the plaintext `rev`, never the ciphertext.
// NOTE: each hook handler runs in an isolated JS runtime, so all logic is
// inline.
onRecordUpdateRequest((e) => {
  const body = e.requestInfo().body || {};
  const sent = body["rev"];
  e.app.runInTransaction((txApp) => {
    const current = txApp.findRecordById("location_history", e.record.id);
    const next = current.getInt("rev") + 1;
    if (sent === undefined || sent === null || sent === "") {
      e.record.set("rev", next); // older client: allow, but mark the change
    } else if (Number(sent) !== next) {
      throw new ApiError(409, "History row changed since it was read; re-read and retry.");
    }
    e.app = txApp;
    e.next();
  });
}, "location_history");
