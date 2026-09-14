<div align="center">

# 🗿 Cairn

**Private, end-to-end encrypted location sharing with the few you trust.**

A calmer, more private, self-hosted alternative to mainstream location trackers.
By [CappyLabs](https://cairn.cappylabs.uk).

</div>

---

Cairn lets you share your live location with the specific people you choose, and
see theirs on a map. Your location — and even your display name — are
**end-to-end encrypted**, so the server relays them but **cannot read them**.

## Why Cairn

- **Private by design** — location and display name are end-to-end encrypted (X25519 + ChaCha20-Poly1305). The server can't read them.
- **No account, no tracking** — no email, phone, or password. Your identity is a key generated on your device. No ads, no analytics, nothing sold.
- **You stay in control** — pair by scanning a QR code, and set exactly how precisely you share with each person.

## Features

- 🔒 **End-to-end encrypted location** — only your chosen contacts can decrypt it.
- 📷 **QR pairing** — connect in person; only people you show your code to can pair. Not nearby? Send a **one-time invite code** (copy/paste or share) that expires in 24 hours.
- 🗺️ **Live map** on OpenStreetMap.
- 🎯 **Per-contact precision** — precise, approximate (~1 km), or paused, per person; plus a global "approximate only" switch.
- 🌙 **Background sharing** (optional) — keeps sharing while the app is closed.
- 🔑 **24-word recovery phrase** — back up and restore your identity.
- 🗑️ **Delete anytime** — remove your account and all its data from within the app.

## What the server *can* and *can't* see

| Data | Server can read? |
|---|---|
| Location | ❌ No — end-to-end encrypted |
| Display name | ❌ No — end-to-end encrypted |
| Public keys, who's paired with whom, timestamps | ✅ Yes (pseudonymous routing metadata) |

Hiding the routing metadata (the social graph) would need a metadata-private
protocol — a future goal.

## How it works

- **App:** Flutter (Android; iOS pending a Mac to build).
- **Backend:** self-hosted [PocketBase](https://pocketbase.io) — auth, realtime, and per-record access rules. It stores only ciphertext for locations and names.
- **Identity:** an on-device X25519 keypair *is* the account; PocketBase credentials are derived from it silently.

## Self-hosting

The app works against the default server, or run your own:

```bash
# on your server (Docker)
docker compose up -d          # see deploy/docker-compose.yml
```

The `Dockerfile` builds an image = PocketBase + the web build + schema
migrations (`pb_migrations/`), so a fresh server comes up fully configured. A
reverse proxy (e.g. Caddy) terminates HTTPS in front of it. Point the app at
your server in **Settings → Server address**.

## Development

```bash
flutter pub get
flutter run                                   # defaults to the production backend
flutter run --dart-define=PB_URL=http://10.0.2.2:8090   # local backend (emulator)
flutter test
```

Build a release:

```bash
flutter build appbundle --release   # signed via android/key.properties (CI provides it)
```

## CI/CD

GitHub Actions (`.github/workflows/release.yml`):

- **push to `main`** → build web → push `ghcr.io/cappytech/cairn-server` → deploy to the edge over SSH.
- **push a tag `vX.Y.Z`** → build a signed `.aab` (version from the tag), attach it as an artifact, and upload to Google Play (internal track) with release notes from `distribution/whatsnew/`.

## Privacy

- [Privacy policy](https://cairn.cappylabs.uk/privacy)
- [Delete your data](https://cairn.cappylabs.uk/delete)

---

<div align="center"><em>Cairn — your location, for the few you trust.</em></div>
