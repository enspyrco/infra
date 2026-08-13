# Rollback rehearsal — task #12

**Status:** designed 2026-08-11, not yet executed.
**Why:** every hardened trigger in `deploy-*.sh` routes failure into a rollback path
that has never been executed, on either script, ever. Triggers hardened, weapon
unfired. This document is the falsifier.

**Done when:** a real rollback has run end-to-end on *each* script and been observed
landing in a coherent, previously-shipped state — verified by a human spoken turn,
not by "the rollback command exited 0".

---

## Preflight findings (measured on the box 2026-08-11 09:1x AEST, read-only)

These change the rehearsal's shape. Each is a fact, with the command that produced it.

### F1 — the box is not running the scripts we hardened

All four md5s differ between `~/bin` on the box and `avatar-deploy/bin` in this repo:

| script | box | repo |
|---|---|---|
| `rollback-dreamfinder-avatar.sh` | `e36dc109…` (1262 B, Jul 21) | `f49aad86…` (~3.6 KB) |
| `rollback-lyra-avatar.sh` | `1406cf39…` (2722 B, Aug 10) | `47282aea…` (~7.6 KB) |
| `deploy-dreamfinder-avatar.sh` | `51c59918…` | `a42a7165…` |
| `deploy-lyra-avatar.sh` | `2f12aa21…` | `28fa65ae…` |

Rehearsing what is on the box rehearses scripts with 32 known defects that we intend
to delete. **Install the two rollback scripts before rehearsing** (see step 1).
This is not the script-hardening the sequencing forbade — no new fixes are written;
it makes the artifact under test be the artifact we intend to keep. Rollback scripts
are inert until invoked. Deploy scripts are **left alone**.

### F2 — lyra's env/compose legs are currently no-ops

```
9ac0039d82ce4ae4f55502367624748c  ~/lyra-freeze/env.file
9ac0039d82ce4ae4f55502367624748c  ~/apps/lyra-avatar/.env
e9d839b1678091f09a3d278087408d67  ~/lyra-freeze/docker-compose.yml
e9d839b1678091f09a3d278087408d67  ~/apps/lyra-avatar/docker-compose.yml
```

Identical. Legs 3a/3b will `cp` a file onto a byte-identical file and print
`restored`. **A green lyra rehearsal does not prove those legs work** — they pass
because they have nothing to do. Same survivorship shape as the drift checker whose
GREEN path had never fired. Cap the claim at what was crossed: lyra proves legs 1, 2
and 4 only.

### F3 — dreamfinder's freeze tuple is incoherent, and it is measurable now

`~/demo-freeze` holds two different eras in one directory:

| file | value | era |
|---|---|---|
| `src.commit` | `2ba90a4` | Jul 15 |
| `env.file` | md5 `db593372…` | Jul 15 |
| `docker-compose.yml` | md5 `f48813b9…` | Jul 21 |
| `image.id` | `sha256:e3d1251f…` | = `pre-engine-insecure-archived-20260810` |
| `deployed.txt` | `sha=20f6955`, `env_md5=c1df026b…` | **Aug 10 — the CURRENT deploy** |

Two consequences:

1. `deployed.txt` describes the release we are *on*, not the release we would roll
   *to*. The rollback script never reads it, so this is a trap for a human reading
   the freeze dir mid-incident, not for the script.
2. **`image.id` and the image the script retags are different images.** The script
   retags `dreamfinder-avatar-app:pre-engine` = `fcbff177…`; the recorded frozen
   image is `e3d1251f…`. The freeze's own record of leg 1 does not match leg 1.

So a dreamfinder rollback assembles: image `fcbff177` + env from Jul 15 + compose
from Jul 21 + an override file that does not currently exist. **Whether that
quadruple ever shipped together is unknown.** This is the predicted freeze-tuple
defect, no longer hypothetical. Expect it to surface during step 4; decide
fix-or-document at the time, do not fix it mid-rehearsal.

### F4 — the dreamfinder forward path is asymmetric

`~/apps/dreamfinder-avatar/` has **no** `docker-compose.override.yml` today (it was
renamed to `docker-compose.lyra.yml.was-override`). The rollback **creates** one, and
`docker compose` auto-loads `docker-compose.override.yml` by name.

Rolling forward therefore requires **deleting a file**, not just copying files back.
A naive "restore the backups" roll-forward leaves a stale override silently in play.
This is why step 0 exists.

### F5 — what is sound

- Both image anchors are non-degenerate: `pre-engine` (`fcbff177`) ≠ `latest`
  (`322662df`); `pre-traversal-fix` (`f19c1076`) ≠ `latest` (`b4d302a2`). Neither
  retag is a silent no-op.
- Both running containers match their `latest` tag — no tag-vs-running drift.
- lyra `PREV_SHA` = `ee347d6` is reachable in `~/apps/lyra-avatar/src` and **is** the
  security-fix commit. Rolling lyra back does not reopen the traversal hole.
- lyra `src` is detached at `4a04138`, working tree clean apart from untracked
  `.ssh/` (the deploy key). `git checkout` does not touch untracked files.
- Confirmed the bake-vs-bindmount asymmetry the scripts assume: dreamfinder is
  `build: context: ./src` with **no** `./src:/app` mount (source baked into the
  image); lyra mounts `- ./src:/app` (the tree is what runs). Neither is a proxy for
  the other — rehearse both.

---

## Blast radius

Shared Sydney OCI host also running xdeca, imagineering, matrix, outline, kanbn.
The rehearsal touches only:

- `~/apps/lyra-avatar/` and `~/apps/dreamfinder-avatar/` (two compose projects)
- docker tags `lyra-avatar-app:latest`, `dreamfinder-avatar-app:latest`
- the `lyra-avatar` and `dreamfinder-avatar` containers

Caddy is **not** touched; routing stays up throughout, so a failed rollback shows as
a 502 on two hostnames, not a host-wide outage. Both sites are public and
low-traffic; run it in the morning window.

---

## Procedure

### Step 0 — forward freeze (do this first, it is the escape hatch)

Capture the tuple we are on now, so roll-forward is a restore and not a
reconstruction. Additive, reversible, mutates nothing live.

```bash
ssh imagineering '
F=~/forward-freeze-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$F"/{lyra,df}
# lyra
cp ~/apps/lyra-avatar/.env               "$F/lyra/env.file"
cp ~/apps/lyra-avatar/docker-compose.yml "$F/lyra/docker-compose.yml"
git -C ~/apps/lyra-avatar/src rev-parse HEAD > "$F/lyra/SHA"
docker inspect -f "{{.Image}}" lyra-avatar > "$F/lyra/image.id"
# dreamfinder
cp ~/apps/dreamfinder-avatar/.env               "$F/df/env.file"
cp ~/apps/dreamfinder-avatar/docker-compose.yml "$F/df/docker-compose.yml"
ls ~/apps/dreamfinder-avatar/docker-compose.override.yml >/dev/null 2>&1 \
  && echo present > "$F/df/OVERRIDE_WAS_PRESENT" || echo absent > "$F/df/OVERRIDE_WAS_PRESENT"
docker inspect -f "{{.Image}}" dreamfinder-avatar > "$F/df/image.id"
echo "$F"; find "$F" -type f | sort'
```

**EXECUTED 2026-08-11 09:15 AEST. Freeze dir: `~/forward-freeze-20260810T231526Z`**
(the box clock is UTC; that is the same moment). All four gate values matched.

Expected: `lyra/SHA` = `4a041386eb80584ccb5ee284abcdedaa0f01a8dd`,
`df/OVERRIDE_WAS_PRESENT` = `absent`, `lyra/image.id` = `sha256:b4d302a2…`,
`df/image.id` = `sha256:322662df…`.

**Gate:** if any of those four differ from the values above, stop — the box moved
since preflight and the rest of this document is stale.

### Step 1 — install the two rollback scripts (F1)

```bash
ssh imagineering 'cp ~/bin/rollback-lyra-avatar.sh        ~/bin/rollback-lyra-avatar.sh.bak-prerehearsal
                  cp ~/bin/rollback-dreamfinder-avatar.sh ~/bin/rollback-dreamfinder-avatar.sh.bak-prerehearsal'
scp avatar-deploy/bin/rollback-lyra-avatar.sh        imagineering:bin/
scp avatar-deploy/bin/rollback-dreamfinder-avatar.sh imagineering:bin/
ssh imagineering 'chmod +x ~/bin/rollback-*.sh && md5sum ~/bin/rollback-*.sh && bash -n ~/bin/rollback-lyra-avatar.sh && bash -n ~/bin/rollback-dreamfinder-avatar.sh && echo SYNTAX-OK'
```

**Gate:** box md5s must equal `47282aea…` (lyra) and `f49aad86…` (dreamfinder), and
both must pass `bash -n`. Deploy scripts stay untouched.

### Step 2 — BASELINE voice canary (Nick's hands) — **before any rollback**

This is the load-bearing ordering choice. Without a known-good baseline, a failed
post-rollback turn is ambiguous between "the rollback broke it" and "it was already
broken". Nothing has ever exercised a real voice turn on either site.

| # | who | what | pass criterion |
|---|---|---|---|
| 2a | Nick | laptop → https://lyra.imagineering.cc, speak a turn | she answers audibly, on topic, once |
| 2b | Nick | laptop → https://df.imagineering.cc, speak a turn | same |
| 2c | Nick | phone on **cellular** (not wifi) → both sites | same, different network path |

I will be tailing both containers while he talks:

```bash
ssh imagineering 'docker logs -f --tail 0 lyra-avatar' &
ssh imagineering 'docker logs -f --tail 0 dreamfinder-avatar' &
```

Watching for: exactly one `registered worker`, STT transcript arriving, brain
response, TTS frames out. Record the observed per-turn latency — it is the baseline
the post-rollback turn is compared against.

**Gate:** if a baseline turn fails, **stop the rehearsal**. A rollback rehearsal on a
site that cannot answer a turn produces an uninterpretable result. Fixing the turn
becomes the session instead.

### Step 3 — lyra rollback (smaller blast, cleaner anchors — go first)

The release we are escaping is the current one; the sacrificial release is
`4a04138`. No need to manufacture a bad deploy — rolling from a real, live release
to a real, previously-shipped one is the honest test.

```bash
ssh imagineering '~/bin/rollback-lyra-avatar.sh'
```

Expected banner sequence: leg 0 preflight silent → `leg 1 src -> ee347d6 …` →
`leg 2 image -> pre-traversal-fix` → `leg 3a/3b restored` → `health OK` →
`leg 4 worker registrations since container boot (…): 1`.

**Observe and write down, per leg:**

| leg | claim | how it is falsified |
|---|---|---|
| 1 tree | `git -C src rev-parse HEAD` = `ee347d6` | it is not |
| 2 image | `docker inspect -f '{{.Image}}' lyra-avatar` = `f19c1076…` | it is `b4d302a2` (retag or recreate did not take) |
| 3a/3b | — | **cannot be falsified today, F2.** Record as NOT PROVEN, do not report green |
| 4 worker | exactly `1` | `0` (dead) or `≥2` (ghost) |
| — boot anchor | window reads `since container boot (<ts>)` | reads `last 2m (FALLBACK…)` → the `StartedAt` guard is firing, itself a finding |

**Then the real gate — 3f: Nick speaks a turn at lyra.imagineering.cc on the
rolled-back release.** Exit 0 is not the criterion. Landing in a coherent,
previously-shipped state is.

### Step 4 — roll lyra forward

```bash
ssh imagineering 'set -e
  git -C ~/apps/lyra-avatar/src checkout -q 4a041386eb80584ccb5ee284abcdedaa0f01a8dd
  docker tag lyra-avatar-app:post-traversal-fix lyra-avatar-app:latest
  cd ~/apps/lyra-avatar && docker compose up -d --no-build --force-recreate
  sleep 10; curl -sf localhost:3017/api/health >/dev/null && echo HEALTH-OK'
```

env/compose need no restore (F2 — they were never changed). **Gate:** `git rev-parse
HEAD` = `4a04138`, container image = `b4d302a2…`, health OK, then **Nick speaks one
more turn** to confirm forward is as good as baseline.

### Step 5 — dreamfinder rollback (the one that will probably find the bug)

```bash
ssh imagineering '~/bin/rollback-dreamfinder-avatar.sh'
```

Same per-leg observation table, plus the three F3/F4 specifics:

- does the restored `.env` (md5 `db593372…`) still satisfy the pre-engine image's
  required variables, or does the container come up missing config?
- the created `docker-compose.override.yml` — confirm compose actually loaded it
  (`docker compose config | grep -A2 volumes`), because it is invisible in the
  command line
- `~/apps/dreamfinder-avatar/src` stays at `20f6955` while the running image is
  `pre-engine`. **DEPLOY_SHA and the src tree will lie about what is running.**
  Record it; it is a real operator trap, not a rollback failure.

**Then Nick speaks a turn at df.imagineering.cc on the rolled-back release.**

If the site cannot answer a turn on the rolled-back state, that is **the finding of
the day** — the recovery path does not recover — and it goes straight to a task.
Do not fix it in place.

### Step 6 — roll dreamfinder forward

```bash
ssh imagineering 'set -e
  F=<the forward-freeze dir from step 0>
  cp "$F/df/env.file"               ~/apps/dreamfinder-avatar/.env
  cp "$F/df/docker-compose.yml"     ~/apps/dreamfinder-avatar/docker-compose.yml
  rm -f ~/apps/dreamfinder-avatar/docker-compose.override.yml   # F4 — asymmetric
  docker tag dreamfinder-avatar-app:post-engine dreamfinder-avatar-app:latest
  cd ~/apps/dreamfinder-avatar && docker compose up -d --no-build --force-recreate
  sleep 10; curl -sf localhost:3015/api/health >/dev/null && echo HEALTH-OK'
```

**Gate:** `.env` md5 = `c1df026b…`, compose md5 = `79361adc…`, no
`docker-compose.override.yml` present, container image = `322662df…`, health OK, and
**a final spoken turn on each site**.

---

## Rules for the day

1. **If you spot a bug in the deploy scripts, log it, do not fix it.** That is
   Kelvin's concession biting; every polishing round deepens the sunk cost in a
   system we intend to replace.
2. **The rehearsal must not become the incident.** Every step has a roll-forward,
   and step 0 is what makes them possible. If a roll-forward gate fails, stop and
   restore from the forward freeze before continuing.
3. **Cap every claim at what was crossed.** lyra proves legs 1/2/4; it does *not*
   prove 3a/3b (F2). Say so in the write-up.
4. **Non-loopback re-probe.** `lib/scope.js` grants `LOCALHOST_IPS` base scope, so an
   on-box `curl` returns 200 for everything. Any auth/traversal claim after the
   rehearsal must be probed from off-box with `--path-as-is`.
5. **Exit 0 is not the gate.** The gate is a human hearing an answer.
