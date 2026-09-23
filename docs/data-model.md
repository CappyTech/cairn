# Cairn data model — what's stored, encrypted, and synced

This is a contributor-facing map of Cairn's data: where each thing lives, what
the server can and can't read, and what follows you to a new device. The
guiding rule is **the server is untrusted** — anything it can read is a leak to
design out.

## Identity: your key *is* your account

There is no email/username/password you choose. On first launch the device
generates an **X25519 keypair**; the 32-byte private seed is kept in the OS
keystore (`flutter_secure_storage`) and encoded as the 24-word **recovery
phrase**. Everything else is derived from it:

- the **public key** (shared with contacts via the in-person pairing QR),
- a synthetic PocketBase **email + password** (derived from the key), so the app
  authenticates silently.

Restoring the recovery phrase on another device re-derives the *same* keypair →
the same login and the same decryption key. This is the whole "multi-device"
story: a second device isn't sync'd to the first, it simply *is* the same
identity. (Stated limit: one identity = one device for **publishing** your own
location — two devices sharing as the same sender would collide; see the
roadmap's Phase 4.)

See `services/crypto_service.dart`, `services/auth_service.dart`.

## Encryption

Two shapes, both via `services/crypto_service.dart` (sealed box: ephemeral
X25519 → HKDF-SHA256 → ChaCha20-Poly1305):

- **Encrypted to a contact** (`sealTextFor` / `sealFor`) — only that contact can
  open it. Used for the location you publish to each contact.
- **Encrypted to yourself** (`sealTextForSelf`) — only you can open it. Used for
  data the server must store but must not read: your contacts' display names,
  your **places**, and your **location history**.

## Collections (server-side)

| Collection | Owner/keys | What the server sees | What it can't read |
|---|---|---|---|
| `users` (auth) | you | public key, `last_seen` | — |
| `contacts` | `owner`, `peer` | who is paired with whom | `peer_name` (encrypted-to-self) |
| `location_shares` | `sender`→`recipient` | who shares with whom, timestamps | the `ciphertext` location (encrypted to the recipient); **upserted — only the latest row is kept** |
| `pair_requests` | `target`, `from` | a pending pairing | name/proof inside the encrypted `from_name` |
| `places` | `owner` | that you have N places, timestamps | name/lat/lng/radius (one encrypted-to-self `ciphertext` blob per place) |
| `location_history` | `owner` | `subject` (whose trail) + `day`, per-day | the day's breadcrumb points (encrypted-to-self `ciphertext`) |
| `server_config` | public read | the retention policy number, the app-version policy | — (it's not secret) |

Access rules enforce ownership (e.g. `location_shares` is readable only by its
sender/recipient; `places`/`location_history` only by the owner). The
`subject`/`day` on history are plaintext **only** so a client can fetch the
right daily row; blinding that routing metadata is the separate Phase 3 work
(`docs/metadata-privacy.md`).

## Places — how they reach another device

Places are **private to you** and **encrypted to yourself**, so:

1. Each place is one `ciphertext` blob in `places` (owner = you), sealing
   `{name, lat, lng, radius, alerts}`.
2. A device restored from your recovery phrase logs into the same account, reads
   the same `places` rows, and can decrypt them (same key). That's the sync.
3. The server never learns a place's name or location.

**Places are never shared with contacts.** The only place-adjacent thing a
contact influences is cosmetic and entirely local to your device: their shared
location is labelled "at Home" on your map and can trigger *your* geofence
alerts (`services/geofence_monitor.dart`). The contact doesn't know your place
names or that they tripped an alert.

Caveat: there is no realtime subscription on `places` — a place added on one
device appears on another when that screen reloads, and edits are last-write-
wins per row.

See `services/places_service.dart`.

## Location history & retention

`location_history` is a per-`(subject, day)` encrypted-to-self trail — always
*your own observations* (your GPS fixes + the locations contacts already share
with you), re-encrypted to yourself, so you never store data you couldn't
already read live. `location_shares` stays upserted; only these daily blobs
retain a trail.

Retention is **full by default** but the operator can advertise a window in
`server_config.history_retention_days`; the user must **agree on first connect**
before history syncs, and can keep *less* locally. Enforcement is on both sides:
the client prunes to the effective window, and a daily server cron
(`pb_hooks/history_prune.pb.js`) deletes rows past the window (by the plaintext
`day`, never reading ciphertext).

See `services/history_service.dart`, `services/history_policy.dart`.

## App updates

The app tells people when their copy is out of date, from two sources
(`services/app_update_service.dart`, `widgets/update_gate.dart`):

- **The server's policy**, set by the operator in the `server_config` record
  (Admin UI → Collections → server_config), as plain version names such as
  `0.0.16`:
  - `min_app_version`: anything older is blocked with an "Update Cairn to keep
    sharing" screen. Raise it *before* deploying a server change that older
    apps can't handle (e.g. the sealed-sender work in `metadata-privacy.md`),
    so they stop cleanly instead of failing silently.
  - `latest_app_version`: anything older gets a dismissible "A new version of
    Cairn is available" banner.

  Leave both empty for no policy. Invalid values are ignored rather than
  locking everyone out.
- **Google Play in-app updates**, for installs from Play: a newer build on Play
  shows the same banner, and "Update" downloads it in the background, then
  offers "Restart". A build uploaded with Play's in-app update priority of
  4 or 5 is treated as required: it gets the blocking screen and an immediate,
  full-screen update. The priority is set per release on upload (the
  `inAppUpdatePriority` input of the Play upload step, default 0).

The web app is served fresh by the server, so it skips these checks. Checks
run at launch and whenever the app returns to the foreground.

## On-device only (never synced)

Deliberately local — your private choices about how *this* device behaves. They
do **not** follow a recovery-phrase restore:

- **Contact nicknames** (`services/nickname_service.dart`)
- **Per-contact toggles** — record history / place alerts (`services/contact_prefs_service.dart`)
- **History retention consent + local override** (`services/prefs.dart`)
- Speed unit, "approximate only" master switch, background-sharing on/off, saved server URL.

## Quick reference: does it sync?

- **Syncs across your devices (same phrase):** places, location history, contacts, the location you publish. All encrypted; the server can't read the contents.
- **Stays on this device:** nicknames, per-contact toggles, retention consent/override, UI preferences.
- **Shared with a contact:** only your live location, encrypted to them (and only per your per-contact precision/pause settings).
