# Continuwuity backup & restore — design + evidence

Status: **in build** (branch `harden/continuwuity-media-restore`). Replaces the
manual `ldb`-guidance stub in `restore_continuwuity` with an automated, validated,
**DB-only DISASTER-RECOVERY** restore: reconstruct the DB from the backup onto a
box with no live data, validate it boots offline, then start it. It is deliberately
**not** a hot-swap-over-a-running-server tool — a real recovery happens on a fresh/
dead box, so there is no live DB to preserve and no swap/rollback machinery is
needed. It **fails closed** if a DB already exists or continuwuity is running, so it
can never clobber a healthy homeserver. (Earlier revisions on this branch built an
atomic-swap-over-live design with rescue + rollback; that was deleted once we
established the only real use is dead-box recovery — see git history.)

## What we protect, and why (the decision behind this)

Continuwuity is a **bridge hub**: it links Signal/WhatsApp/Telegram/Discord chats
into Matrix and hosts a couple of bots. Almost nothing in it *originates* there.
Ranked by "if it vanished, could you get it back?":

| What | Where | Irreplaceable? |
|------|-------|----------------|
| **Server signing key** (federation identity) | in RocksDB | **YES — the only one.** ~KB, but see below |
| Accounts, tokens, device/E2E keys | in RocksDB | No — users re-login/re-verify |
| Rooms, memberships, message history | in RocksDB | Mostly no — a *mirror*; source chats live in the bridged apps |
| Bridge links | in RocksDB | No — re-auth each bridge |
| **Media** (~948 MB, 2755 blobs) | filesystem `media/` | No — re-fetchable federation cache + bridge-replicated |

The signing key is the only unrecoverable thing — but continuwuity **welds it into
RocksDB** and exposes no export/import (upstream has an abandoned
`bad-attempt-at-extracting-homeserver-signing-key` branch). So the only way to hold
the key is to back up the DB. Conveniently the DB is also the *small* half
(~100 MB) and gives a clean identity-preserving restore.

**Decision: back up the RocksDB only. Do NOT back up media** — it is disposable
cache. This is the existing `backup_continuwuity` behaviour (unchanged); the work
here is the restore + making a media-less restore boot cleanly.

## Media-less restore boots via `prune_missing_media`

A DB restored without its media crashes continuwuity's startup media integrity
check (`Failed to verify media integrity: I/O error`). Fix: `prune_missing_media =
true` (set permanently in `docker-compose.yml`) — startup prunes the dangling media
refs from the DB and boots clean. Requirement: the `media/` **dir must exist**
(empty is fine); a missing dir is a hard I/O error, missing *files* are pruned.
**Verified against the real production DB**: reconstruct → empty `media/` →
`prune_missing_media=true` → `Opened database sequence=136357634` → `Services
startup complete`, all 2755 dangling refs pruned.

## Why dead-box DR (and why the swap machinery is gone)

The one thing worth protecting — the signing key — is only ever needed back when
the server/disk has **died** and we're rebuilding from scratch. In that situation
there is no running homeserver and no live database to preserve. So the restore
doesn't swap a new DB in underneath a live server or roll anything back; it just
reconstructs the DB onto an **empty** volume and starts it.

The volume stays on the **root layout** (`CONTINUWUITY_DATABASE_PATH=/var/lib/
continuwuity`) — no `db/` subdir, so no one-time migration to deploy. The subdir
existed only to make an atomic *swap* possible, and there is no swap.

The safety that the old rescue/rollback provided ("don't lose the live DB if the
restore fails") is replaced by a **fail-closed guard**: the restore refuses to run
if continuwuity is running OR a DB already exists in the volume. It can't clobber a
healthy homeserver because it won't touch a non-empty volume at all.

## Restore design (`restore_continuwuity`)

1. `fetch_backups`; require `continuwuity.tar.gz.age`. Read `MATRIX_SERVER_NAME`
   from `~/apps/matrix/.env` (needed for the validate-boot).
2. **Safety guard (fail-closed):** refuse if the `continuwuity` container is
   running, or if the volume already holds a DB (root `CURRENT`/`*.sst`, or a
   leftover `db/` subdir). To deliberately replace an existing DB, the operator
   stops the server and clears the volume first — a conscious, logged act.
3. Typed-consent gate (`restore-continuwuity`) — irreversible.
4. **Reconstruct** the RocksDB tree **directly into the (empty) volume root**:
   - Decrypt+extract the backup to a scratch dir. **Sentinel**: assert `meta/`,
     `shared_checksum/*.sst`, and `private/<id>/CURRENT` present — a truncated tar
     aborts here.
   - Strip the `_s<session>_<size>` suffix off every `shared_checksum/*.sst`
     (names are already `%06d`-padded — re-`printf %06d` hits busybox **octal** on
     e.g. `000824`); copy `private/<latest-id>/*`. Verified byte-identical to
     `ldb restore`. Fail-closed on an SST filenumber collision.
   - `mkdir` an **empty** `media/` (so prune, not crash).
5. **Validate** (fail-closed): boot `continuwuity:latest` against the reconstructed
   tree, `--network none` (a broken/wrong-identity DB can never federate before
   we bless it), `prune_missing_media=true`, real `MATRIX_SERVER_NAME`. Success is
   a CHORD: `Services startup complete` **and** a non-zero RocksDB `sequence`. ANSI
   stripped at capture + here-string matching (pipefail-safe). Clean `docker stop`
   (SIGTERM) so the DB closes before the real server opens it.
6. **Start** the real server (`docker compose up -d continuwuity`) and verify the
   same chord on its logs since start. On failure: loud error naming the likely
   cause (on-disk compose lacking the prune flag, or wrong `MATRIX_SERVER_NAME`) —
   nothing to roll back, the box was empty; inspect + re-run.

**Deploy-order gate:** the `prune_missing_media=true` compose change must be
deployed to the host BEFORE a restore is run — otherwise the real `docker compose
up` uses an on-disk compose lacking the flag and crash-loops on the media check.
Deploy `matrix` (compose) before exercising the restore.

**Named tradeoff — `prune_missing_media` is permanent, not restore-only.** A
media-less restore's real boot uses the on-disk compose, so the flag can't be a
restore-only injection. Consequence (accepted under media-as-cache): a transient
real-media I/O miss on a NORMAL restart prunes those refs. Low consequence — media
is re-fetchable cache — but it is a steady-state behavior change, not only a DR
path.

## How the facts were established (local, zero prod load)

Verified against the **real 99 MB production backup**, decrypted locally and booted
under the real `continuwuity:latest` image on Colima. Each test exposed the next
layer's wrong assumption:

1. Handoff premise wrong — `restore_continuwuity`'s `rm -rf` hit the *disposable*
   staging volume, not live.
2. `ldb restore` exists (RocksDB 9.10) — prior "it doesn't" was wrong; unneeded.
3. Shell-merge reconstruction == real BackupEngine restore (`sequence=136357634`).
   `sequence=0` first seen was a Colima empty-bind-mount artifact, not a bug.
4. Backup is media-less → media integrity crash → led to the "what are we even
   protecting?" analysis above → DB-only + `prune_missing_media`.

## Known pre-existing issue (separate from this change): backup repo bloat

The backup repo is **4.37 GB**, of which current files are only ~122 MB. The rest
is **45 daily `archive-*` tags**: `prune_repo_history_if_needed` collapses history
when the repo exceeds 300 MB but first pins the old history in an `archive-DATE`
tag "for recoverability" — and the 101 MB **encrypted** (undeltable) continuwuity
blob is a fresh 101 MB object every day, so every day trips the prune, mints a tag,
and GitHub never GCs tagged commits. Growth ≈ 100 MB/day, unbounded. The prune
meant to *stop* bloat is *causing* it.

**Partially fixed here.** This PR adds `ARCHIVE_TAG_RETENTION` (default 7) to
`prune_repo_history_if_needed`, so the prune now self-trims to the newest N archive
tags each run — the runaway can't recur. The one-time reclaim of the 38 already-stale
tags was done out-of-band (kept the newest 7; GitHub's GC of the ~3.8 GB is lazy).
**Still tracked as #32** (the *structural* fix): move the continuwuity DB blob off
git entirely to **object storage** (20 GB free on OCI, unused) with lifecycle
expiry — the right home for daily binary snapshots. The restore logic here is
agnostic to where the blob is stored.

Known residual (pre-existing, not introduced here; → #32): the archive tag name is
day-granular (`archive-$DATE`), so a second prune on the same UTC day collides on
`git tag` and the function returns after a local orphan commit — self-heals on the
next run's re-clone, but the object-storage move should retire the whole tag scheme.

## Deploy

`restore.sh` is manual-DR-only. The `prune_missing_media` compose change ships with
the next `deploy-to.sh 149.118.69.221 matrix` (a continuwuity restart). Fold in the
pending #140 postgres-swap deploy on `scripts`.
