# Handoff — Cairn server work on the edge VPS (PocketBase)

**For:** a Claude Code (or human) session running **on the edge box**, where the
PocketBase container actually runs. **Why:** the app repo's CI/dev environment
has no PocketBase and no Flutter toolchain, so a batch of work was designed but
**not executed** because it needs a live server to validate against. That's what
this handoff is for. Nothing here should be run blind against production —
**stage and validate first** (see Ground rules).

---

## 0. Context in one paragraph

Cairn is E2E-encrypted location sharing. App = Flutter (Android). Backend =
self-hosted **PocketBase 0.40.1** (`Dockerfile` pins `PB_VERSION=0.40.1`),
shipped as `ghcr.io/cappytech/cairn-server` (PocketBase + the built web app +
`pb_migrations/`). CI builds/pushes the image on push to `main` and deploys to
this box over SSH. Content (location, display name) is encrypted; the server
only relays ciphertext + routing metadata. Repo: `CappyTech/cairn`.

## 1. Environment facts

- **Compose dir:** `/docker/cairn-server/` (`deploy/docker-compose.yml` in the repo).
- **Container:** `cairn-pocketbase`, image `ghcr.io/cappytech/cairn-server:latest`.
- **Data:** the `./pb_data` volume is the **only** persistent state (SQLite +
  settings + uploaded files). **Back it up before touching anything.**
- **Network:** no public port; Caddy fronts it on the external `edge` network
  (`cairn.cappylabs.uk` → `reverse_proxy cairn-pocketbase:8090`).
- **Admin UI:** `https://cairn.cappylabs.uk/_/` (needs a PocketBase superuser).
- **PocketBase CLI:** `docker compose exec pocketbase /pb/pocketbase <cmd>` —
  always check `... <cmd> --help`, subcommands vary by version.
- **Migrations** in `pb_migrations/` run automatically on container start.
- **Deploy:** `cd /docker/cairn-server && docker compose pull && docker compose up -d`.

## 2. Ground rules (read before doing anything)

1. **Back up `pb_data` first.** Prefer PocketBase's own backup (Admin UI →
   Settings → Backups, or the CLI), or: `docker compose stop pocketbase && cp -a
   pb_data pb_data.bak.$(date +%F-%H%M) && docker compose start pocketbase`.
2. **Stage, don't experiment on prod.** For any schema/migration/hook work,
   stand up a **throwaway PocketBase** (see Task C) with a *copy* of `pb_data`
   (or empty), validate there, and only then let it reach prod via the normal
   `main` → deploy path.
3. **Migrations auto-run on start** — a broken migration can stop the server
   booting. Test every candidate migration on staging first.
4. **Breaking changes need a coordinated client rollout.** Anything that changes
   the `location_shares` / `contacts` shape breaks app clients still on the old
   build. Don't merge those to `main` until the app change ships too.
5. **Code changes still go through the repo.** Land migrations/hooks/app changes
   as PRs on `CappyTech/cairn` (branch off `main`), not by hand-editing files in
   the container.

## 3. Task A — Verify & tune the rate limiter *(from PR #7)*

`pb_migrations/1758100000_rate_limits.js` was authored **without a running
PocketBase** and wrapped in try/catch so it can't halt startup — so it may have
silently no-op'd. Verify it actually applied:

1. Admin UI → **Settings** → confirm rate limiting is **enabled** and the two
   rules exist: `users:create` (20/60s) and `pair_requests:create` (60/60s).
2. Confirm **`trustedProxy`** is set to read `X-Forwarded-For`, and that request
   logs show **real client IPs**, not Caddy's container IP. If they show Caddy's
   IP, the limits bucket globally — fix the trusted-proxy config (and check how
   Caddy sets `X-Forwarded-For`) or the limiter is near-useless.
3. Tune the numbers to real traffic. If the migration didn't apply at all,
   set the rules by hand in the Admin UI (and open a follow-up to fix the
   migration shape for the version).

## 4. Task B — Rotate the superuser password *(GitHub issue #3)*

A PocketBase **superuser** email+password was committed in
`test/integration_share_test.dart` (removed from source, but **still in git
history** → treat as compromised).

1. Identify the real superuser account(s): Admin UI → your admins list, or
   `docker compose exec pocketbase /pb/pocketbase superuser --help` then list.
2. **Rotate**: generate a strong new password (store it in your secret manager,
   never in the repo) and update the account —
   `docker compose exec pocketbase /pb/pocketbase superuser update <email> <newpass>`
   (verify the exact subcommand: `create` / `update` / `upsert`).
3. If the leaked account was `admin@local.test` and it only ever existed on a
   dev box, confirm it does **not** exist on prod; delete it if it does.
4. Optional, secondary: scrub the value from git history (`git filter-repo`) —
   a coordinated force-push; rotation above is the actual fix, history-scrub is
   cleanup. Then close issue #3.

## 5. Task C — Metadata-privacy schema work *(4a / 4b / 4d)*

Design is in **`docs/metadata-privacy.md`** (read §3.1 first). The key finding:
dropping `sender` from `location_shares` (sealed sender) **breaks the
`update`/`delete` access rules**, so it needs a **capability token** (opaque
`row_key` proven via a PocketBase hook, or an append-only inbox the recipient
prunes) — the same core as the mailbox model (4b) and contact handles (4d).
This is exactly the work that needs a live PocketBase to build and validate.

Suggested approach on this box:
1. **Stand up staging:** run a second PocketBase from the same image on a
   throwaway volume, e.g.
   `docker run --rm -p 8091:8090 -v "$PWD/pb_stage:/pb/pb_data" ghcr.io/cappytech/cairn-server:latest /pb/pocketbase serve --http=0.0.0.0:8090`
   (or a copy of prod `pb_data` to test the migration against real shapes).
2. **Prototype the capability authz** (the update/delete hook, or append-only +
   prune) on `location_shares`, and the **sealed-sender** change (drop `sender`,
   move a signed sender id into the ciphertext). Exercise it with `curl` against
   `:8091` — create/read/update/delete as two different users, confirm a
   non-owner can't overwrite/delete.
3. Only once it holds on staging, turn it into a migration + the matching **app
   client change**, land both as PRs, and roll out in lockstep (the migration is
   breaking for old clients).
4. `4b` (unlinkable mailboxes) and `4d` (contact handles) build on the same
   capability — prototype inbox-id derivation/rotation + the realtime
   subscription story on staging before committing.

## 6. Also flag / reconcile

- **Timing-privacy regression:** PR #10 made the map publish on a **fixed 30 s
  cadence** (privacy: hides movement timing). As of `main` @ `839845a`,
  `lib/screens/map_screen.dart` `_onPosition` **calls `_publish(p)` again on
  every movement**, which re-introduces the per-movement leak while the
  heartbeat comment still claims timing is hidden. Decide intentionally: keep
  fixed-cadence (remove the per-movement `_publish`) or drop the privacy claim
  (fix the comment). Right now the code and its comment disagree.

## 7. Key files & references

- `docs/metadata-privacy.md` — the design + the §3.1 authz finding.
- `pb_migrations/` — schema/settings migrations (run on start); newest is the
  rate-limit one.
- `cairn-collections.json` — canonical collection schema.
- `deploy/docker-compose.yml`, `Dockerfile` — how the server is built/run.
- `ROADMAP.md` — where each item stands.
- GitHub issue **#3** — the credential rotation (keep it open until rotated).

## 8. Reporting back

Land server/app changes as PRs on `CappyTech/cairn` off `main`; note in each PR
what was validated on staging. Update `ROADMAP.md` / `docs/metadata-privacy.md`
as items land. For rotation and rate-limit verification, a short note on issue
#3 / the roadmap is enough — those are ops actions, not code.
