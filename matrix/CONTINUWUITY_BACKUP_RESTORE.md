# Continuwuity backup & restore — design + evidence

Status: **in build** (branch `harden/continuwuity-media-restore`). Replaces the
manual `ldb`-guidance stub in `restore_continuwuity` with an automated, validated,
**DB-only** restore with completion-oracle rollback (not single-rename atomic — a
volume root can't be renamed; see the swap step for the exact recovery guarantee).

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

## Volume topology: the DB lives in a `db/` SUBDIR (not the volume root)

`CONTINUWUITY_DATABASE_PATH=/var/lib/continuwuity/db` — the RocksDB tree +
`media/` sit in a `db/` subdirectory of the `continuwuity_data` volume, **not at
the volume root**. This is the single design decision that makes restore/rollback
a **single atomic directory rename** instead of a per-file promote with ordering
guarantees. Work dirs (`db-staging`, `db.rescue-<ts>`) are then *siblings* of
`db/`, entirely outside `database_path`, so they can never coexist inside the tree
RocksDB opens (the old root layout needed dotfile-exclusion `find` filters
everywhere precisely because the work dirs polluted the DB directory).

**One-time migration** from the old root layout:
`scripts/migrate-continuwuity-topology.sh` (idempotent, fail-closed, refuses to run
while continuwuity is up). It relocates the root DB tree into `db/`. This MUST run
**before** the new compose starts continuwuity — on the new path an empty `db/`
looks like a fresh homeserver and continuwuity would mint a NEW signing key.

## Restore design (`restore_continuwuity`)

Build the replacement **inside the live volume** (same filesystem → real atomic
`mv`), never touch live bytes until a validated replacement exists, keep the old
DB as a timestamped rescue.

1. `fetch_backups`; require `continuwuity.tar.gz.age`. Read `MATRIX_SERVER_NAME`
   from `~/apps/matrix/.env` (needed for the validate-boot).
2. Typed-consent gate (`restore-continuwuity`) — irreversible.
   **Topology guard (fail-closed):** assert `db/CURRENT` exists — refuse on the old
   root layout and point at the migration script.
3. **Stage** into `continuwuity_data/db-staging/` (sibling of `db/`; live still running):
   - Decrypt+extract the RocksDB backup to a scratch dir. **Sentinel**: assert
     `meta/`, `shared_checksum/*.sst`, and `private/<id>/CURRENT` present — a
     truncated tar aborts here, live untouched.
   - Reconstruct: strip the `_s<session>_<size>` suffix off every
     `shared_checksum/*.sst` (names are already `%06d`-padded — re-`printf %06d`
     hits busybox **octal** on e.g. `000824`), copy `private/<latest-id>/*`.
     Verified byte-identical to `ldb restore`.
   - `mkdir` an **empty** `media/` (so prune, not crash).
4. **Validate** (fail-closed): boot `continuwuity:latest`, `--network none`,
   `prune_missing_media=true`, real `MATRIX_SERVER_NAME`, timeout. Success =
   `Services startup complete` and no `fresh database`/panic/`Failed to verify
   media`/`Corruption`. Exact prod image = real RocksDB (no `ldb` version-skew —
   `ldb checkconsistency` is rejected by continuwuity's newer OPTIONS keys). Clean
   `docker stop` (SIGTERM) so the staged DB closes before promotion.
5. **Swap** (two atomic dir renames): stop continuwuity; `mv db db.rescue-<ts>`
   then `mv db-staging db`; completeness-gate the promoted `db/` on
   `CURRENT` + `media/` + ≥1 SST. Because `db/` is a self-contained subdir, the
   install is a single `rename(2)` — no per-file promote, no CURRENT-ordering, no
   dotfile hazard, no merge onto remnants. The only window is the microscopic gap
   *between* the two renames where `db/` momentarily doesn't exist; a crash there
   leaves `db.rescue-<ts>` intact and recovery is one `mv` (spelled out in the
   error). On any failure the rescue is moved straight back. Keep the rescue tree.
   (This dissolves the CURRENT-last ordering + completion-oracle rollback that
   cage-match #141 rounds 3–5 spent hardening — the complexity was a symptom of
   the DB living at the volume root, fixed here by moving it down one level.)
6. **Restart**; loud error + rescue path on restart failure.

**Deploy-order gate:** the `prune_missing_media=true` compose change must be
deployed to the host BEFORE a media-less restore is run — otherwise the post-swap
`docker compose start` uses an on-disk compose lacking the flag and crash-loops on
the media check. Deploy `matrix` (compose) before exercising the restore.

**Named tradeoff — `prune_missing_media` is permanent, not restore-only.** It has to
be: a media-less restore's *real* post-swap boot uses the on-disk compose, so the
flag can't be a restore-only injection. Consequence (accepted under media-as-cache):
a transient real-media I/O miss on a NORMAL restart prunes those refs. Low
consequence — media is re-fetchable cache — but it is a steady-state behavior
change, not only a DR path.

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
