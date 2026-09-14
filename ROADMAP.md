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

- ✅ **Close the reciprocal-pairing trust gap** *(mostly done)*. The QR now
  carries a secret **nonce**; whoever scans it attaches an HMAC (keyed by that
  nonce) over their pairing request, binding their public key. The reciprocating
  side recomputes it and **rejects a request whose key was tampered with** — so a
  compromised server can no longer MITM the un-scanned direction. Carried inside
  the already-encrypted `from_name`, so **no schema migration**. *Remaining:* a
  request with **no** MAC (older app) is still accepted trust-on-first-use; once
  clients have rolled over, require a valid MAC to fully close first-pair and
  block injection (below).
- ✅ **Contact key-change detection** *(done)*. A contact's public key arriving
  changed over the server is flagged (`status = 'key_changed'`) instead of
  silently adopted; the old verified key is kept, sharing to them is paused, and
  the app prompts an in-person re-scan to confirm.
- ✅ **CI test gate** *(done)*. `ci.yml` runs `flutter analyze` + `flutter test`
  on every PR and non-`main` branch. *(Optional next: add a
  `dart format --set-exit-if-changed` check.)*
- **Grow the test suite.** Pairing decision + MAC verification and key-change
  detection are now covered; still want precision/pause behaviour, the
  subscribe/ingest path in `LocationSharingService`, and widget tests for the
  core screens.
- **Abuse resistance on open endpoints.** `users.create` and `pair_requests`
  are open by design (no account gate). Add rate limiting / basic anti-spam at
  the reverse proxy or via PocketBase hooks. **Unsolicited pairing:**
  `processPendingRequests()` still adds a contact from an unsigned inbound
  request (trust-on-first-use); requiring a valid pairing MAC (once rolled out)
  closes this — an injected request can't produce one without having scanned
  the target's QR.

## Phase 2 — Platform reach

- **iOS build & release.** Build the existing `ios/` project (needs a Mac /
  macOS CI runner), wire signing, and add an App Store lane alongside the
  Android Play lane in CI.
- **Real iOS background sharing.** `flutter_background_service` doesn't give
  iOS meaningful background location — evaluate significant-location-change /
  region monitoring, or a platform-channel CLLocationManager path.
- **Battery-aware background strategy (Android + iOS).** The fixed 2-minute
  timer is simple but wasteful when stationary. Move toward distance-filtered
  or significant-change updates; back off when still.
- **Web hardening or scoping.** The web build authenticates with the same
  key-in-`flutter_secure_storage` model, which is far weaker in a browser.
  Decide whether web stays a read-only/admin surface or gets an explicitly
  documented weaker trust tier.

## Phase 3 — Metadata privacy (the north star)

Delivering on the README's stated future goal.

- **Reduce the social graph the server can see.** Investigate blinded or
  rotating routing identifiers so `contacts` / `location_shares` don't expose
  who-shares-with-whom in the clear.
- **Minimise timestamp leakage.** `last_seen` and record `updated` times are a
  presence side-channel; consider coarsening, client-derived presence, or
  dropping the server heartbeat.
- **Sealed sender.** Explore hiding the `sender` field from the server on
  `location_shares`, so only the recipient learns who a blob is from.

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

- **Efficient publish path.** `publish()` does per-contact `getFullList` +
  update/create — O(N) round trips per tick. Batch the reads and consider a
  single upsert call per contact.
- **Notifications that respect privacy.** Push/local notifications for pair
  requests and "contact went stale" without leaking content through the server.
- **Contact management UX.** Rename contacts, see last-seen/stale state clearly,
  and a friendlier pairing flow.
- **Map & sharing UX.** Presence/staleness affordances, precision indicators on
  the map, and clearer per-contact controls.

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
