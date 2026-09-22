# 🗿 Cairn — Roadmap

A living plan for where Cairn goes next. It's grounded in the code as it
stands today, and ordered by a simple rule: **anything that protects users or
their data comes before anything that adds surface area.**

Cairn's promise is in the README — *private, end-to-end encrypted location
sharing with the few you trust* — and every item below is judged against it.
This is a direction, not a contract; issues and PRs are where specifics live.

---

## Where we are today

| Area | Status |
|---|---|
| **App** | Flutter, Android only (iOS not yet built) |
| **Backend** | Self-hosted PocketBase; ships as one Docker image (server + web build + `pb_migrations/`) |
| **Identity** | On-device X25519 keypair *is* the account; PocketBase login derived from it silently. No email/phone/password. |
| **E2E encryption** | Sealed box — ephemeral X25519 + ChaCha20-Poly1305, HKDF key bound to both public keys. Locations encrypted per recipient; display names encrypted-to-self. |
| **Pairing** | In-person QR scan; a `pair_requests` row lets the other side reciprocate. |
| **Sharing** | Per-contact precision (precise / ~1 km / paused) + a global "approximate only" switch. |
| **Background** | Android foreground service, publishes every 2 min. |
| **Recovery** | 24-word BIP39 phrase encodes the seed; restore rebuilds the same account. |
| **Delete** | In-app account delete cascades to contacts, shares, and pair requests. |
| **CI/CD** | `release.yml`: push to `main` → build web + server image → deploy over SSH; tag `vX.Y.Z` → signed `.aab` to Play internal track. |

### Known limits, stated plainly
- **iOS is unbuilt**, and the background isolate is Android-only — `onIosBackground` is effectively a no-op, so there is no real iOS background sharing yet.
- **Routing metadata is visible to the server**: public keys, who is paired with whom, and timestamps (`last_seen`). This is acknowledged in the README as a future goal.
- **Reciprocal pairing trusts a server-relayed key.** The scanner reads the peer's real key from the QR in person; the *scanned* side takes `from_pubkey` from the `pair_requests` row it receives — a key it never verified in person. *(Now mitigated: a request signed with the QR nonce is verified and a tampered key is rejected; a changed key is flagged. Remaining gap: unsigned (older-app) requests are still trust-on-first-use — see Phase 1.)*
- **No key rotation or revocation**: `peer_pubkey` is fixed at pairing; a compromised device key can't be rotated without re-pairing.
- **Single device per identity**: two devices restored from the same phrase share one account and would both publish as the same sender.
- **No automated test gate on PRs**: tests exist (`crypto`, `recovery`, `integration_share`) but `release.yml` doesn't run `flutter analyze` / `flutter test`.

---

## Phase 1 — Trust & correctness (next)

The things a privacy product cannot ship without.

- ✅ **Close the reciprocal-pairing trust gap** *(done)*. The QR carries a
  secret **nonce**; whoever scans it attaches an HMAC (keyed by that nonce) over
  their pairing request, binding their public key. The reciprocating side
  recomputes it: a request with a **tampered key is rejected**, and a request
  with **no MAC can no longer create a new contact** — it may only update an
  existing pairing (a changed key still flagged). So a compromised server can't
  MITM the un-scanned direction *or* inject a first pairing. Carried inside the
  already-encrypted `from_name`, so **no schema migration**. *Rollout note:* an
  older client that sends no MAC can no longer complete a *first* pairing with an
  updated device until it updates.
- ✅ **Contact key-change detection** *(done)*. A contact's public key arriving
  changed over the server is flagged (`status = 'key_changed'`) instead of
  silently adopted; the old verified key is kept, sharing to them is paused, and
  the app prompts an in-person re-scan to confirm.
- ✅ **CI test gate** *(done)*. `ci.yml` runs `flutter analyze` + `flutter test`
  on every PR and non-`main` branch. *(Optional next: add a
  `dart format --set-exit-if-changed` check.)*
- **Grow the test suite** *(ongoing)*. Covered so far: pairing decision + MAC
  verification, key-change detection, one-time invite expiry, the
  location-sharing logic (share action, payload coarsening, decrypt→parse round
  trip), and the first **widget tests** — the contacts row (`ContactTile`,
  extracted as a presentational widget) across its precise / approximate /
  paused / global-override / key-changed states. *Still want:* widget coverage
  of the other screens (which need a testability seam — their `initState` calls
  static services), and end-to-end coverage of the PocketBase-backed paths
  (currently only the `integration`-tagged test).
- **Abuse resistance on open endpoints** *(rate limiting added; verify on
  server)*. `users.create` and `pair_requests` are open by design (no account
  gate). A migration enables PocketBase's built-in rate limiter for
  `users:create` and `pair_requests:create` (with `trustedProxy` set for the
  real client IP behind Caddy). It's wrapped defensively so it can't halt
  startup, and was authored without a running PocketBase — **confirm it applied
  and tune the limits in the Admin UI after deploy.** **Unsolicited pairing is
  already closed** at the app layer: `processPendingRequests()` only creates a
  contact for a request carrying a valid proof-of-scan MAC, so an injected
  request can't add itself without having scanned the target's QR — this rate
  limit just blunts junk `pair_requests`/account floods at the write layer.

## Phase 2 — Platform reach

- **iOS build & release.** Build the existing `ios/` project (needs a Mac /
  macOS CI runner), wire signing, and add an App Store lane alongside the
  Android Play lane in CI.
- **Real iOS background sharing.** `flutter_background_service` doesn't give
  iOS meaningful background location — evaluate significant-location-change /
  region monitoring, or a platform-channel CLLocationManager path.
- ✅ **Battery-aware background strategy (Android)** *(done)*. The background
  isolate now picks its cadence + GPS accuracy from the **battery level /
  charging state** (`backgroundStrategy` in `services/bg_strategy.dart`, unit
  tested): 2 min / high while healthy or charging, 5 min / medium at ≤35%, 10 min
  / medium at ≤15%. *Deliberately battery-driven, not movement-driven* — a
  "back off when still" strategy would reintroduce the movement-timing leak that
  Phase 3 closed, whereas battery level isn't location-correlated. *Still open:*
  the same for iOS (needs the iOS background path first).
- **Web hardening or scoping.** The web build authenticates with the same
  key-in-`flutter_secure_storage` model, which is far weaker in a browser.
  Decide whether web stays a read-only/admin surface or gets an explicitly
  documented weaker trust tier.

## Phase 3 — Metadata privacy (the north star)

Delivering on the README's stated future goal. **Design:
[`docs/metadata-privacy.md`](docs/metadata-privacy.md)** — threat model, what
the server sees today, the PocketBase authz tension that shapes the design, and
a phased plan. Key finding (§3.1): sealed sender is *not* a trivial standalone —
removing `sender` breaks the update/delete authz rules, so it needs the same
capability-token core as the mailbox model. So the safe first step was timing.

- ✅ **Minimise timestamp leakage** *(first piece done)*. Foreground publishing
  is now on a **fixed 30 s cadence** instead of per-movement, so the server can
  no longer read movement/activity timing off `location_shares.updated`. Still
  open: constant cadence while the app is closed; coarsening record `updated`.
  (`last_seen` is deliberately kept — it powers the admin dashboard.)
- **Reduce the social graph the server can see.** Blinded / rotating routing
  identifiers so `contacts` / `location_shares` don't expose who-shares-with-whom.
  This is the hard part: PocketBase's access rules are written over those
  relations, so it needs capability-based authz (design a token once; sealed
  sender + mailbox + contact handles all build on it). Validate against a staging
  PocketBase before it touches prod — the migrations are breaking.
- **Sealed sender.** Hide the `sender` field on `location_shares` (signed sender
  id inside the ciphertext) — gated on the capability-authz work above.

## Phase 4 — Resilience & multi-device

- **Key rotation & revocation.** A protocol to rotate a device key and notify
  contacts, plus a way to revoke a lost device.
- **Multi-device support.** Today one identity = one device. Support linking a
  second device (sub-keys or per-device keys under one account) so publishing
  as the same `sender` from two devices doesn't collide.
- **Forward secrecy for stored blobs.** Location shares are upserted (only the
  latest row persists), which already limits exposure; evaluate whether a
  ratchet is worth it given that model.

## Phase 5 — Product polish

- ✅ **Remote pairing invites** *(done)*. For contacts who aren't nearby, "My
  code" can copy/share a **one-time, 24h-expiring** invite (recipient uses
  Scan → "Paste instead"). It carries a fresh single-use secret — not the
  permanent QR nonce — so an intercepted invite pairs at most once and then
  dies, unlike a leaked permanent code. *Note:* remote pairing trusts the
  channel you send it over for the peer's key authenticity; in-person QR
  remains the strongest option.
- ✅ **Efficient publish path** *(done)*. `publish()` now fetches all my
  outgoing shares in one query and keys them by recipient, replacing the
  per-contact `getFullList` (O(contacts) reads → 1). A pure `shareOpFor`
  decides create/update/delete/none per contact; writes are unchanged.
- ✅ **Places & geofence alerts** *(done)*. Named places (Home, Work…) with a
  radius, synced **encrypted-to-self** (`places` collection holds one sealed
  blob per place — the server never reads a name, coordinate, or radius). A
  contact inside a place is labelled "at Home" on the map, and an on-device
  monitor fires a **local** notification (via `NotificationService`) when a
  contact arrives at or leaves a place — evaluated from the already-decrypted
  shares, so the server learns nothing new. Works in the foreground (an
  app-lifetime monitor) and while closed (the background isolate checks each
  tick). First sighting is seeded silently so opening the app never fires a
  spurious "arrived". *Deploy note:* the `places` collection is added by
  `pb_migrations/1758300000_add_places.js` — verify in the Admin UI after
  deploy that it exists with owner-only rules (authored without a running
  PocketBase, like the rate-limit migration). `services/places_service.dart`,
  `services/geofence_monitor.dart`, `screens/places_screen.dart`.
- ✅ **Location history & trips** *(done)*. A day-bucketed trail of where I and
  my contacts have been, in a new owner-scoped `location_history` collection —
  one **encrypted-to-self** blob per `(subject, day)`, so the server never reads
  a coordinate. History is only ever MY observations (my own GPS fixes + the
  locations contacts already share with me), re-encrypted to myself, so I gain
  nothing I couldn't already read live; `location_shares` stays upserted.
  Points are sampled (time/distance) and buffered on-device, then flushed into
  the daily blob. The History screen picks a person + day and shows the
  breadcrumb path on the map, a scrubbable timeline, and **trips** derived from
  the trail + your Places ("Home → Work, 08:15–08:47"), with per-person clear.
  *Metadata note:* `subject`/`day` are plaintext so the app can fetch the right
  daily row — this exposes no more than `contacts`/`last_seen` already do;
  blinding the routing graph is the separate Phase 3 work. *Deploy note:* the
  collection is added by `pb_migrations/1758400000_add_location_history.js` —
  verify owner-only rules + the `(owner, subject, day)` unique index in the
  Admin UI after deploy. `services/history_service.dart`,
  `screens/history_screen.dart`.
- ✅ **History retention & consent** *(done)*. History is kept **full by
  default**, but the server operator can advertise a retention window via the
  new public `server_config` collection (`history_retention_days`, 0 = keep
  all). On first connect to a server the user is shown that policy and history
  **only syncs if they agree** (declining leaves Places/geofence working, just
  no history trail; a changed policy re-prompts). A local setting lets the user
  keep *less* than the server does, and the client prunes to the smaller of the
  two. Enforcement is on both sides: the client prunes to the effective window,
  and a **server-side daily cron** (`pb_hooks/history_prune.pb.js`) authoritatively
  deletes `location_history` rows older than the server's window (by the plaintext
  `day`, never reading ciphertext) — so the policy holds even for a user who never
  reopens the app. *Deploy note:* `pb_migrations/1758500000_add_server_config.js`
  creates the collection + a default record — set the window in the Admin UI
  (Collections → `server_config`); the Dockerfile now ships `pb_hooks/`.
  `services/history_policy.dart`.
- **Notifications that respect privacy.** Push/local notifications for pair
  requests and "contact went stale" without leaking content through the server.
- **Contact management UX.** ✅ *Rename contacts done* — a local, per-device
  nickname (`services/nickname_service.dart`) overrides the contact's own name
  across the list and the map; kept entirely off the server and separate from
  their `peer_name`, so a re-scan won't clobber it. ✅ *Per-contact controls
  done* — on-device toggles (`services/contact_prefs_service.dart`, default on)
  to stop recording a contact's **history** or firing **place alerts** for
  them, from the contact row's menu; the geofence monitor honours both each
  tick, and they're dropped on unpair. ✅ *Last-seen/stale state done* — each
  contact row shows a freshness chip (Live / Xm / Xh / Xd ago / No location
  yet) from their most recent share, via the shared pure `Presence.describe`
  (`services/presence.dart`); it ticks up on a timer. *Still want:* a friendlier
  pairing flow.
- **Map & sharing UX.** Presence/staleness affordances, precision indicators on
  the map, and clearer per-contact controls.
- ✅ **Shared location label** *(done)*. A short status a sender broadcasts with
  their location so contacts see where they are ("Alice — Hotel") without
  recreating the place. Sourced from a manual status or from one of your own
  places marked "show name to contacts when I'm here" (`Place.shareLabel`,
  opt-in). It rides the existing per-recipient **E2E-encrypted** `location_shares`
  blob (`lbl` field) — no new collection, and the server reads nothing. On the
  map, a sender's own label wins over the local "at <my place>" hint.
  `LocationSharingService.labelForPosition`.
- ✅ **Shared pins** *(done)*. Persistent pins one user shares with chosen
  contacts ("meet me here" / "where I'm staying") that stay on the recipient's
  map. New `shared_places` collection: each row's `ciphertext` is sealed to the
  **recipient's** key (server can't read it); the sharer keeps a self-addressed
  copy to manage/revoke and to see it on their own devices, and a plaintext
  `group` id ties the per-recipient copies together for one-tap revoke. Share a
  place from the Places list → pick contacts; received pins render as distinct
  markers ("Alice · Grand Hotel"); a Shared-pins screen lists what you shared
  (with revoke) and what's shared with you. `services/shared_places_service.dart`,
  `screens/shared_pins_screen.dart`. *Deploy note:*
  `pb_migrations/1758600000_add_shared_places.js` — verify owner/recipient rules
  in the Admin UI after deploy.

---

## Guiding principles

1. **The server is untrusted.** Anything it can read is a leak to design out,
   not a convenience to lean on.
2. **In-person trust is the anchor.** Pairing happens face to face; the protocol
   should never quietly downgrade that to server-relayed trust.
3. **Ship less, verified.** New surface area waits behind tests and a green CI.
4. **No accounts, no tracking.** Keep identity on-device and the data footprint
   minimal.

---

*This roadmap is a starting point for discussion — reorder freely, and turn any
line into an issue when it's ready to be worked.*
