# Restoring the mautrix bridges

The four bridges are pinned by digest to `ghcr.io/enspyrco/mautrix-<bridge>`, our own
mirror of the upstream `dock.mau.dev` images. This file is the recovery path when a
normal `deploy matrix` cannot get those images.

Every claim here was tested on 2026-09-01 against the real box and registry. Where a
thing does **not** work, it says so — that is the point of the file.

## Why the mirror exists

Three of the four bridges were previously pinned to `dock.mau.dev` digests the registry
**no longer serves** (`no such manifest`, confirmed with `docker buildx imagetools
inspect` plus a zeroed-digest control). Those pins worked only while the local image
layer survived. A teardown + `docker image prune -a`, a disk rebuild, or a `docker load`
would have left nothing able to recreate the containers, even with the session volumes
intact. See claude-tasks#3728.

## Why the first deploy after the switch does not break

Changing a pin from `dock.mau.dev/...@sha256:` to `ghcr.io/enspyrco/...@sha256:` is a
change of *reference*, and an image satisfying the old reference does not automatically
satisfy the new one. That would normally mean the first deploy after the switch depends on
the operator having pulled the new refs out of band.

Here it is already discharged, and checked rather than assumed: the mirror was pushed
**from this box**, so its local store carries the GHCR repo-digests, and each was pulled
back by digest afterwards. Verified 2026-09-01 — all 4/4 new refs resolve locally
(`docker image inspect ghcr.io/enspyrco/mautrix-<bridge>@sha256:…`).

**On any other host this does not hold** and Path 1 or Path 2 below is required first.

## Path 1 — normal (the registry has them)

```sh
cd ~/apps/matrix && docker compose pull && docker compose up -d
```

**Precondition:** the packages are currently **private**, so a host needs
`docker login ghcr.io` (any account with read access to the `enspyrco` org) before its
first pull. Without that login the pull fails; `deploy_matrix` passes
`--ignore-pull-failures`, so the failure is **swallowed** and `up -d` then succeeds only
if that exact digest reference is already in the local image store. On a fresh host it
is not, and `up -d` fails.

> If the packages are made public (Package settings → Change visibility, which is
> web-UI only — there is no REST endpoint), this precondition disappears entirely and
> Path 1 works anonymously on any host.

## Path 2 — registry-independent (tarballs)

Tarballs live on the box at `/home/nick/backups/mautrix-images-20260901/` (680M, four
`.tar` files plus `MANIFEST.txt` recording every tag and digest).

> **KNOWN GAP, stated rather than implied: they are currently ON THE BOX ONLY.** A
> backstop stored on the disk it is insuring against is not yet a backstop — it covers a
> registry outage or a bad prune, and not the disk loss. Getting them off-box is tracked
> in claude-tasks (the established pattern for large binaries here is GitHub Release
> assets on the backups repo, see `reference_release_asset_backup_storage_tier.md`).

```sh
docker load -i mautrix-discord.tar
```

**What this does and does not restore — tested, not assumed:**

| | restored by `docker load`? |
|---|---|
| image bytes / layers | **yes** |
| the tag `ghcr.io/enspyrco/mautrix-discord:2026-05-12` | **yes** — the tarballs are saved *by tag* specifically so this survives |
| the digest `ghcr.io/enspyrco/mautrix-discord@sha256:9d9f…` | **NO** |

The compose file pins by **digest**, so a loaded image will **not** satisfy it. Verified
by reading the tarball's own `manifest.json`: an image saved by ID has `RepoTags: null`
and carries no repo digest at all. (These were re-saved by tag for exactly this reason.)

So Path 2 requires one temporary edit per bridge. **The full mapping is here so nothing
has to be reconstructed from prose during an outage:**

| service | replace this digest pin | with this tag |
|---|---|---|
| `mautrix-telegram` | `ghcr.io/enspyrco/mautrix-telegram@sha256:0a8e6fdd…` | `ghcr.io/enspyrco/mautrix-telegram:2026-06-17` |
| `mautrix-discord` | `ghcr.io/enspyrco/mautrix-discord@sha256:9d9f9b5f…` | `ghcr.io/enspyrco/mautrix-discord:2026-05-12` |
| `mautrix-whatsapp` | `ghcr.io/enspyrco/mautrix-whatsapp@sha256:197f9c34…` | `ghcr.io/enspyrco/mautrix-whatsapp:2026-06-18` |
| `mautrix-signal` | `ghcr.io/enspyrco/mautrix-signal@sha256:385668cb…` | `ghcr.io/enspyrco/mautrix-signal:2026-06-16` |

The same mapping, with full digests, is in `MANIFEST.txt` beside the tarballs.

```sh
cd ~/apps/matrix
for b in telegram discord whatsapp signal; do docker load -i "mautrix-$b.tar"; done
# edit matrix/docker-compose.yml per the table above, then:
docker compose up -d
```

Verified: a tag-only local reference is sufficient for `docker compose create` to create
the container from it. (`create` resolves and creates; it does not build.) **Restore the digest pin once the registry is reachable again** — the tag
is mutable and the pin is the whole point.

## Architecture limitation — read before restoring onto a different host

These mirrors are **single-platform `linux/arm64` manifests**, not multi-arch indexes.
Confirmed with `docker buildx imagetools inspect --raw`: `mediaType` is
`application/vnd.docker.distribution.manifest.v2+json` with no `manifests` array, because
they were pushed from the aarch64 box.

The upstream `dock.mau.dev` images they replace **were** multi-arch indexes. So this
mirror is correct and precise for the current host and **will not work on x86_64**. A
restore onto a different architecture cannot use these images at all, and for three of
the four the original multi-arch upstream digest is no longer served — it would have to
come from a newer upstream version, which is a bridge upgrade, not a restore.

If the fleet ever gains an x86_64 host, re-mirror as a proper multi-arch index.

## What to verify after any restore

A bridge that starts is not a bridge that works — it holds linked-account session state.

```sh
docker compose ps                      # all four Up
docker compose logs --tail 50 mautrix-discord | grep -i "error\|login\|bridge"
```

Then confirm in Matrix that an existing portal room still relays a message. A restore
that silently de-authenticates a link looks identical to success from the container's
point of view.
