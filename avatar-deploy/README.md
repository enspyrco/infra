# avatar-deploy

The deploy and rollback substrate for the two avatar sites on the shared Sydney box.

| Site | URL | App dir on box | Port | Deploy unit |
|---|---|---|---|---|
| dreamfinder-avatar | df.imagineering.cc | `~/apps/dreamfinder-avatar` | 3015 | image (source baked in) |
| lyra-avatar | lyra.imagineering.cc | `~/apps/lyra-avatar` | 3017 | src TREE (compose bind-mounts `./src:/app`) |

Consumers live in `imagineering-cc/dreamfinder-avatar` and `imagineering-cc/lyra-avatar`;
both vendor `enspyrco/avatar-engine` as an `engine/` subtree.

## Status: this directory is NOT yet authoritative

Read this before trusting anything here.

These files are a **tracked copy** of what currently lives in `~/bin/` and `~/.ssh/` on
`ssh imagineering` (149.118.69.221). **The box is still the source of truth.** Nothing
deploys from this repo. Editing a file here changes nothing in production until someone
copies it up by hand.

That inversion is the actual problem and it is the next piece of work — see
"Where this is going" below. Until it lands, the honest description of this directory is:
a snapshot that makes the substrate reviewable, not a substrate that runs.

**If you change something on the box, mirror it here in the same session.** A tracked copy
that silently drifts is worse than no copy, because it invites people to read it as truth.
`bin/verify-matches-box.sh` exists to catch exactly that drift.

## Why it was imported

For roughly a year this path had no repo, no review and no history — ~370 lines of bash
hand-edited in place on a production host. The import is a response to four things that
happened, all traceable to that:

- **lyra ran a month unpatched.** `~/.ssh/config` had no `github-lyra` block, so every
  fetch on the box died at name resolution and `~/apps/lyra-avatar/src` sat frozen at
  `2e3f109` (2026-07-14). Nothing in any repo recorded the alias→key map, which is
  precisely why its absence was invisible for a month.
- **An untracked gate reopened a live vulnerability.** `docker logs --since 3m` was used
  as a proxy for "this boot". A no-op deploy (cached image → no recreate) returned an
  empty window, the gate declared a contract violation, and the auto-rollback reverted
  production onto a 4-week-old image with the path-traversal auth bypass still in it.
  `df.imagineering.cc/avatars/../server.js` served 200 for ~10 minutes. It was caught by a
  human noticing `docker ps` said "Up 5 minutes".
- **Four more defects went into these scripts in a single afternoon** — stale gate vectors
  that would have rolled lyra back, a shell-quoting crash, and a self-overwriting rollback
  anchor. None exotic. All four would have been caught by review.
- **A fifth defect was found by the import itself, within minutes.** A trailing `#` comment
  swallowed `echo "image=$IMG"`, silently dropping the image identity from every lyra
  release record. `shellcheck` flags it for free as `SC2034: IMG appears unused` — see the
  git history of `bin/deploy-lyra-avatar.sh` for the before and after.

## Layout

```
avatar-deploy/
├── bin/
│   ├── deploy-dreamfinder-avatar.sh    4 gates, auto-rollback on any failure
│   ├── deploy-lyra-avatar.sh           5 gates, incl. in-container allowlist assert
│   ├── rollback-dreamfinder-avatar.sh  QUAD rollback: image + env + compose + worker
│   ├── rollback-lyra-avatar.sh         QUAD rollback: TREE first, then image + env + worker
│   └── verify-matches-box.sh           drift check: repo vs ~/bin and ~/.ssh on the box
└── ssh/
    ├── config                          github-dreamfinder alias + Include config.d/*
    └── config.d/                       github-lyra, and the two backup aliases
```

`ssh/` carries **no key material** — hostnames, usernames and `IdentityFile` *paths* only.
The keys themselves stay on the box and are not in this repo.

## Installing to the box

There is no automation for this yet; that is the point of the next section. By hand:

```bash
# from the repo root
scp avatar-deploy/bin/*.sh imagineering:~/bin/
scp avatar-deploy/ssh/config imagineering:~/.ssh/config
scp avatar-deploy/ssh/config.d/* imagineering:~/.ssh/config.d/
ssh imagineering 'chmod 700 ~/bin/*.sh && chmod 600 ~/.ssh/config ~/.ssh/config.d/*'

# then confirm the box matches the repo
./avatar-deploy/bin/verify-matches-box.sh
```

## What stays on the box (deliberately)

State and secrets, never source:

| Path | What |
|---|---|
| `~/apps/*/DEPLOY_SHA` | the pinned deploy target |
| `~/apps/*/BOOT_CONTRACT` | the exact expected boot-banner line |
| `~/apps/*/.env` | secrets |
| `~/demo-freeze/`, `~/lyra-freeze/` | rollback anchors (`PREV_SHA`, `env.file`, compose) and `deployed.txt` |
| `~/.ssh/*-deploy` | the private keys the aliases point at |

## Where this is going

1. ~~Import verbatim so the substrate is reviewable.~~ (this PR)
2. **Invert the direction of authority.** Deploy the scripts *from CI* so the repo is the
   source and the box is downstream. Until that lands, every improvement to the deploy path
   is another artisanal edit — including the ones in this PR.
3. **Alerting.** There is currently none on either site. The regression above was caught by
   eyeball. The first canary is an off-box `curl --path-as-is` probe of
   `/avatars/../server.js` and `/avatars/%252e%252e/server.js` on both hosts, expecting 303.
   It must run **off-loopback**: `LOCALHOST_IPS` in `lib/scope.js` grants base scope, so a
   probe from the box returns 200 and reads as a false green. A probe holding a privilege
   the real caller lacks does not measure the real path.

## Known-live inherited defects (found by review, deliberately NOT fixed here)

These came in with the verbatim import and are still live on the box. Each is
deferred on purpose, with the reason — not overlooked. They are tracked as tasks.

- **Neither deploy script has a rollback trap.** `rollback()` is defined after the
  cutover, and the scripts run under `set -euo pipefail`. A failure in the *gate
  scaffolding* itself (a `docker inspect` name mismatch, an unexpected `StartedAt`
  shape, a compose service rename) exits the script without ever calling
  `rollback()` — after `docker compose up -d` has already gone live. Gate *logic*
  failures roll back; gate *scaffolding* failures leave the new release running
  unverified. Fixing this means arming an `ERR` trap that fires a rollback path
  that has never been rehearsed, which is the same shape as the incident that
  started all this. It waits for the rehearsal.
- **dreamfinder's worker-registration gate is lower-bound only** (`-ge 1`), while
  lyra enforces both bounds and rolls back on a ghost worker. Two registrations
  pass green on dreamfinder and dispatch load-balances across duplicates. Same
  reasoning as above: aligning it arms a new auto-rollback trigger pre-rehearsal.
  The misleading "exactly-one" comment is corrected in this PR; the gate is not.
- **The shellcheck action is pinned to `@master`.** `ludeeus/action-shellcheck@master`
  now lints the scripts that can roll production onto a vulnerable image, on a
  floating ref. Real supply-chain exposure, but it is the existing convention for
  every shellcheck step in this repo (`./scripts`, `./cd-bus`), so pinning only the
  new one would be worse than either consistent state. Repo-wide decision, not this
  PR's — tracked separately.
- **`Host github-lyra` points at `IdentityFile ~/.ssh/embodied-lyra-deploy`.** Fossil
  naming from before the repo rename, on a load-bearing key path. Renaming the key
  is a box mutation, not a repo change, and at 3am a mismatched name reads as a
  config bug rather than as history. Left as-is, named here so it doesn't surprise.
- **`dreamfinder-avatar-app:pre-engine` is a one-way ratchet.** The anchor is only
  tagged if absent, which correctly refuses to clobber a good freeze but means the
  script cannot tell a *poisoned* anchor from a blessed one — and a poisoned anchor
  is exactly what served a live auth bypass for ten minutes on 2026-08-10. It was
  repointed by hand. A name-immortal anchor should become content-addressed, which
  is properly part of inverting the authority (step 2 below).

`flip-brain-api.sh` was imported and then **deleted** rather than deferred: it
`cd`s to `~/apps/embodied-dreamfinder` and execs `~/bin/deploy-embodied-dreamfinder.sh`,
and neither path exists on the box any more. Under `set -e` it dies on line 4. A
break-glass tool that cannot break glass is worse than no tool, because someone
reaches for it in an emergency. Its history is in this repo if it's ever wanted back.

## Known-unrehearsed

**Both rollback paths changed on 2026-08-10 and neither has ever been run.** dreamfinder's
`pre-engine` image anchor was repointed (the old one predated the security fix and reopened
a live hole when it fired); lyra's rollback is a different shape entirely, restoring the src
tree rather than the image. Rolling either back is safe with respect to the traversal hole —
both anchors carry the fix and were checked on 2026-08-10 — but "safe" is not "rehearsed".
