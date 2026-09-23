# Design: Metadata privacy (Phase 3 "north star")

**Status:** draft for discussion · **Scope:** what the server learns *besides*
location/name content, and how to reduce it.

Cairn already end-to-end encrypts the two content fields the product cares
about — location and display name — so the server relays them but can't read
them. What it *can* still read is **routing metadata**: who is paired with
whom, who sends to whom, and when. This doc lays out what leaks today, the
options for closing it, and — the part that actually decides the design — why
PocketBase's access model makes the social-graph piece hard, plus a phased,
concrete recommendation.

This is a direction, not a commitment; each option lists its cost so we can
pick deliberately.

---

## 1. Threat model

Two adversaries, in increasing strength:

1. **Honest-but-curious server** — runs the real code, doesn't tamper, but logs
   and analyzes everything it legitimately stores/sees. This is the realistic
   default for a self-hosted relay and the primary target.
2. **Compromised / malicious server** — actively reads the DB, alters access
   rules, injects rows. Content stays safe (E2E), and pairing key-authenticity
   is already defended (QR-nonce MAC), but this adversary sees all metadata a
   curious server sees, plus anything the rules would have hidden from clients.

**Explicit non-goals** (accepted leakage, documented so we don't pretend
otherwise):

- **Network-layer metadata** (client IP → server) is a transport problem, not
  a schema one. Mitigating it needs Tor/VPN/oblivious transport; see §6.
- **Existence of an account.** The server always knows *some* pseudonymous
  identity exists and is active.
- A determined server correlating coarse timing across many accounts. Full
  defense against traffic analysis needs a different substrate (§5c).

---

## 2. What the server sees today

From the current schema (`cairn-collections.json`, `pb_migrations/`):

| Collection | Plaintext (server-readable) fields | Metadata it leaks |
|---|---|---|
| `users` | `public_key`, `last_seen`, `created/updated`, synthetic `email` | pseudonymous identity; presence/activity timing |
| `contacts` | `owner`→`peer` relations, `precision`, `status` | **the social graph** (who paired with whom), per-contact sharing mode |
| `location_shares` | `sender`→`recipient` relations, `ciphertext`, `updated` | **who shares to whom**, and *when* (update timing ≈ movement/activity) |
| `pair_requests` | `from`→`target` relations | who tried to pair with whom |

The content (`ciphertext`, encrypted `name`/`peer_name`) is opaque. Everything
in the "leaks" column is not. The headline leak is the **social graph** (the
relation fields), reinforced by **timing** (update cadence, `last_seen`).

---

## 3. The crux: PocketBase authz is relation-based

The obvious idea — "just don't store `sender`/`recipient`/`owner`/`peer`" —
collides with how PocketBase enforces access. Its per-record API rules are
written in terms of those very relations, e.g. `location_shares`:

```
listRule/viewRule: @request.auth.id = recipient.id || @request.auth.id = sender.id
```

The server *needs* to know the recipient to decide who may read a row. So any
scheme that hides the graph from the server must **move authorization off of
identity relations** and onto something the server can check without learning
the graph — a capability/token or an unlinkable address. That is the whole
design problem; the crypto for hiding content is the easy part.

This is why the options below split into "cheap, within PocketBase's model" and
"needs a different addressing model."

### 3.1 The authz that must move: not just create, but update/delete

A subtlety that bit the "sealed sender is cheap" plan (see 4a): `sender` isn't
only a routing hint — `location_shares` uses it to authorize **update and
delete**:

```
updateRule / deleteRule: @request.auth.id = sender.id
```

The sender upserts and deletes *its own* row every publish tick. Drop `sender`
and no field is left for a rule to say "only the original writer may modify this
row." Leaving update/delete open to any authenticated user is a
griefing/DoS hole (anyone could overwrite or wipe anyone's shares, and the
recipient would just see undecryptable garbage). So removing the sender identity
forces a **capability**: store an opaque, unguessable `row_key` (or a token
derived from the pairing secret) that the writer proves knowledge of to
update/delete. PocketBase can't express "prove knowledge of a secret" in a
list/view rule, so this needs a small **hook** (an `onRecordUpdateRequest` /
`onRecordDeleteRequest` check), or the row is treated as append-only and the
recipient prunes.

**Consequence:** sealed sender (4a) is therefore *not* a standalone field
removal — it shares the same capability-authz core as the mailbox model (4b) and
contact handles (4d). Only timing minimization (4c) is truly independent. Design
the capability token once and 4a/4b/4d all build on it.

---

## 4. Options

### 4a. Sealed sender *(high value; not as cheap as it first looks — see §3.1)*
Stop putting the sender's real id on `location_shares`. The recipient already
decrypts with their own key regardless of who sent it, and can identify the
sender from a signed field *inside* the ciphertext. Server keeps only
`recipient` (needed for delivery/authz) + `ciphertext`.

- **Hides:** who sends to a given recipient (halves the graph exposure on the
  hot collection).
- **Cost:** medium, once §3.1 is accounted for. Move sender identity into the
  encrypted blob; loosen the *create* rule (can't check `sender.id`) — accept
  that anyone may *write* to a recipient's inbox (rate-limited; recipient drops
  blobs that don't decrypt/verify, dedup by in-blob sender id). But
  **update/delete now need a capability** (opaque `row_key` + a hook, or an
  append-only inbox the recipient prunes), because there's no `sender` to
  authorize on — this is the real work, shared with 4b/4d.
- **PocketBase fit:** field removal + rule changes are easy; the capability
  check for update/delete needs a hook (or an append-only redesign).
- **Migration/rollout:** breaking. The migration drops a column and rewrites
  rules on the **production** DB, and old app clients that still send/read
  `sender` stop working until updated — so it needs a coordinated client
  rollout and a way to validate the migration before deploy (neither available
  in the authoring environment; do not ship blind).

### 4b. Unlinkable delivery addresses / mailbox model *(hard, closes the graph)*
Replace `recipient = <userId>` with an **opaque inbox address** that the server
can't map back to a user. At pairing (in person, already trusted), each side
gives the other a rotating set of delivery tokens / an inbox id derived from a
shared secret. Senders write to `inbox = <opaque>`; recipients poll their own
inboxes. The server sees writes to random-looking buckets, not `A→B`.

- **Hides:** the send graph itself, not just the sender field.
- **Cost:** high. Needs: a scheme to derive/rotate inbox ids from the pairing
  secret so both sides agree without the server linking them; authz becomes
  "holder of a capability token for this inbox may write/read," which
  PocketBase can approximate with rules over an opaque field but **loses the
  per-user ownership guarantee** — a compromised server (or a leaked token)
  can write to an inbox. Also complicates the realtime subscription (you
  subscribe to your inboxes, not `recipient = me`).
- **PocketBase fit:** partial. Doable with a custom collection + token check in
  a hook, but it's a real re-architecture, and rotation/subscription are fiddly.

### 4c. Timing minimization *(cheap, partial — first piece shipped)*
Blunt the "when" signal:
- ✅ **Fixed-cadence foreground publishing** *(done)*. The map used to publish
  on every ~10 m of movement, so the server could read movement vs. stillness
  off `location_shares.updated` cadence. It now publishes only on the fixed 30 s
  heartbeat (the background service was already a fixed 2 min), so server-visible
  write timing no longer tracks movement. The map still tracks own-position live
  and locally. Net: fewer writes while moving, so this is also a battery win.
  Foreground sharing has since moved out of the map into `ForegroundShare`: it
  now runs whenever the app is open (any screen), on the same fixed 30 s
  cadence, and stops as soon as the app is backgrounded.
- `last_seen` presence heartbeat — **deferred**: it powers the admin dashboard;
  the team chose to keep it (see roadmap). Revisit if the admin presence view
  is dropped.
- Further: optional **dummy/refresh** writes even when the app is closed to make
  cadence fully constant (costs battery/writes); coarsening record `updated`
  exposure (harder — it's a system field).

### 4d. Contact-graph hiding *(hard, tied to 4b)*
`contacts` is local-first (it's *my* list of *my* peers), but its rows still
name `owner`/`peer` to the server. Options: store the peer as an opaque handle
rather than a `users` relation, and keep the mapping only client-side
(encrypted-to-self). Interacts with 4b (delivery must then also use handles).

---

## 5. Recommended path

Phased, revised after the §3.1 finding — cheapest and safest first:

**5a — ✅ Fixed-cadence publishing *(done)*.** Decouples update timing from
movement; pure client change, no schema/authz. Shipped (see 4c). Optional cover
writes can follow if we want constant cadence while the app is closed.

**5b — Capability token, then sealed sender.** The §3.1 finding means sealed
sender is *not* the trivial first step it looked like — it needs the
capability-authz core (opaque `row_key` + an update/delete hook, or an
append-only inbox). Design and **validate the capability + migration against a
staging PocketBase** before it touches prod, and roll the client out in lockstep
(the migration is breaking). Once the capability exists, dropping `sender` and
signing it into the blob is the smaller part.

**5c — Unlinkable mailboxes (prototype behind a flag).** The real graph-hiding
step (4b/4d), built on the same capability from 5b. Prototype inbox-id
derivation + rotation + the realtime-subscription story on a throwaway
collection first. Treat the "compromised server / leaked token can write to an
inbox" property explicitly.

**Beyond:** true resistance to a server doing traffic analysis across all
accounts (correlating even opaque buckets by timing/size) is a research-grade
problem — it wants a mixnet / PIR / oblivious relay, which is out of scope for a
single PocketBase instance. Document it as the ceiling, not a near-term goal.

---

## 6. Network layer (separate track)

Even with a perfect schema, the server sees each client's **IP** and connection
timing. Closing that is a transport concern: support routing the PocketBase
connection over Tor/a VPN, or an oblivious relay. Worth a dedicated note; it is
independent of the schema work above and shouldn't block it.

---

## 7. First concrete step

Implement **5a (sealed sender)** as its own change:
1. `location_shares`: drop the `sender` relation; keep `recipient`, `ciphertext`.
2. Publisher seals `{lat,lng,…, from: <my id>, sig}` (sender identity + a
   signature the recipient can verify) to the recipient's key.
3. Loosen `createRule` (no `sender.id` check); recipient ingests only blobs it
   can decrypt, and derives the sender from the verified in-blob id.
4. Migration + client change; unit-test the seal/verify/dedup like the existing
   pairing/location tests.

That removes the single biggest routine metadata leak (who sends to whom on the
busy collection) without a re-architecture, and sets up the addressing rework
in 5c.
