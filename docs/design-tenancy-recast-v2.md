# Recast v2 — deploying Outline + Kan.bn to a second box

Status: DESIGN, un-struck (v1 was struck 4/4 → RECAST; see `design-tenancy-recast-TEMPER.md`).
Date: 2026-09-11. Supersedes `design-tenancy-recast.md` and PR #178.
Context: claude-tasks#3849, #3842, #3670, #3729, and claude-tasks#2 (restore paths).

## 0. The ruling this design is built on

**Nick, 2026-09-10.** Offered three arms — declare one-tenant-per-host as policy, expect
co-tenancy and build a manifest, or question the deploy layer — he chose the third:

> deploy the way the org says to: versioned image from a registry, config git-deployed, no
> rsync-from-working-tree.

v1's whole option set (A/B/C) argued about how to parameterise `deploy-to.sh`'s rsync. That was
the wrong frame and the ruling replaces it.

**What the ruling does NOT settle.** It governs how bytes reach a box. It says nothing about what
identity those bytes carry, and four reviewers found flaws in that layer which survive it intact.
Those are §2 and §5 below. Do not read the ruling as closing them.

## 1. What is already true (measured 2026-09-11, before designing anything)

- **The app images are already digest-pinned.** `outline@sha256:a750f764`, `kan@sha256:3509af72`,
  `kan-migrate@sha256:3296fd28`, `minio@sha256:14cea493`, `mc@sha256:a7fe349e`. Only
  `postgres:15-alpine` and `redis:7-alpine` are tag-pinned — that is claude-tasks#3729, not this
  design.
- **So the half of the ruling about images is already satisfied.** The thing that is rsynced from a
  working tree is the **compose file plus a generated `.env`** — configuration, not application
  code. That narrows this design considerably and it is worth saying out loud rather than
  re-solving a solved problem.
- **Caddy reaches every backend through a published host port**: `network_mode: host` plus 24
  `reverse_proxy localhost:<port>` lines. This is *why* ports are host-global, and it is the
  dependency for §4.
- imagineering runs on Sydney (`~/apps/imagineering-outline`, `~/apps/imagineering-kanbn`).
  Melbourne has no Outline/Kan.bn dirs; 3012, 3013, 9010 are free there.

## 2. Three axes, not one variable

PR #178's root error, in one line: **one `${TENANT}` variable was doing two different jobs.**

Tesla's strike named the missing dimension. There are three:

| Axis | What it governs | Collides when |
|---|---|---|
| **IDENTITY** | public URL, `SECRET_KEY`, postgres credentials, S3 endpoint + **bucket names**, data volumes | two deployments share them — **across oceans**, not just across a host |
| **PLACEMENT** | which host, which published ports, which Caddy route | two deployments land on the **same host** |
| **FAILURE-DOMAIN** | what moves together when a box dies | you need to place an identity somewhere it has never run |

Today identity and placement happen to be 1:1, which is exactly what made deleting one of them
feel like simplification. **A 1:1 correspondence between two quantities does not make them one
quantity** — it means you cannot currently tell them apart. Delete the column and you have deleted
the distinguisher.

This is also why v1's option A did not do what it claimed. Names/project/ports/dirs are PLACEMENT
collisions and A did remove them. `OUTLINE_URL`, `SECRET_KEY`, `S3_ENDPOINT` and the buckets are
IDENTITY, and two hosts sharing one `secrets.yaml` is one identity wearing two faces regardless of
how far apart the boxes are.

**So the recast is not "less parameterisation" — it is the same amount, split correctly:**

- keyed on **IDENTITY**: container names, compose project name, volume names, bucket namespace,
  secrets file, public URL, remote directory
- keyed on **PLACEMENT**: published ports, Caddy route, target host
- **`secrets.<identity>.yaml`**, never one shared file. This is the finding that made #178
  unshippable and it is the one thing that must not be lost in any further simplification.

## 3. The deploy mechanism (the ruling, made concrete)

Config reaches the box **from a git object, never the working tree**:

```
git archive <ref> outline/ | ssh $REMOTE 'tar -x -C ~/apps/<identity>-outline'
```

`git archive` cannot emit bytes no commit contains, so shipping uncommitted config becomes
**structurally impossible rather than merely detectable** — the property `--dirty` stamping only
reports after the fact. The existing provenance preflight in `deploy-to.sh` (which refuses a dirty
tree or a non-main ref) stays as a fast, friendly failure, but is no longer the only thing standing
between a scratch edit and production.

Secrets cannot live in git as plaintext, so the `.env` is still rendered at deploy time from
`secrets.<identity>.yaml` via SOPS. The **SOPS file is the git-derived artifact**; the `.env` is a
local, short-lived render of it. It must be written with `trap` cleanup — Kelvin's finding that
`deploy_outline`/`deploy_kanbn` leave a plaintext `.env` on abort while four other services in the
same script use a trap.

**Binding constraints on any implementation** (each is a flaw from the strike, stated as a rule):

1. Allowlists are **plain assignments**, never `${VAR:-default}`. #178's allowlist was overridable
   at the call site while its own error text forbade exactly that.
2. **No destructive step may precede a satisfied guard.** `rsync --delete` ran upstream of the
   remote fuse; the remote preflight (host identity, docker access, target dir, ports, secrets
   present, `compose config` valid) must complete *before* anything is written or removed.
3. **`restore.sh` moves in the same change.** It currently targets `~/apps/outline` and
   `~/apps/kanbn`, neither of which exists on the box. Deploy and restore disagreeing about where
   data lives is not an open question, it is a designed lie (claude-tasks#2).
4. **Second deploy, not just first.** Every step must be described against a directory that already
   holds a running stack with live Postgres volumes.

## 4. Dissolving the port collision (the subtraction worth having)

Ports are host-global **only because we publish them**. Caddy reaches backends via
`localhost:<port>` because it runs `network_mode: host`.

If Caddy instead joins each stack's docker network and proxies to the container by DNS name —
`reverse_proxy <identity>-outline:3000` — then **no host ports are published at all** and the
entire placement-collision class disappears. Two identities coexist on one box with zero port
negotiation, which is precisely the 3am case in §5.

**This is the strongest option and it has a real dependency**: it requires Caddy to be
containerised and attached to each network. On Sydney Caddy is `network_mode: host`; on Melbourne
it is a **host systemd unit** (`/etc/caddy/Caddyfile`), which cannot resolve container DNS at all.
Nick has already ruled that melb's Caddy config becomes repo-owned and git-deployed
(`project_melb_caddy_repo_owned.md`) — this design should be sequenced *after* that work, and may
change what it should look like.

**Fallback if Caddy stays as-is**: ports are a PLACEMENT property resolved from a committed
per-host table, not literals and not copied from an error message. #178's `${VAR:?}` messages
printed the live imagineering ports, teaching an operator the exact triad that collides.

## 5. The 3am section (required — "redo the design" is not an answer)

**5.1 Sydney dies; imagineering must come up on Melbourne.**
Melbourne is already running the enspyr identity. This is two identities on one host — the state v1
deleted machinery for, and which a host allowlist would refuse outright.
- Identity keying (§2) means container names, volumes, project and buckets do not collide.
- With §4 there are no published ports to collide either. Without §4, the placement table must have
  a second row for that host, prepared **before** the outage.
- Caddy on the surviving box must serve both hostnames — so the route is placement, not identity.
- **The allowlist must permit it.** A host allowlist that names only the intended box refuses the
  only remaining box. Whatever guard ships must have a documented, tested emergency placement path,
  or it is an availability hazard wearing safety's clothes.

**5.2 Staging Outline beside production on one box.** Same shape, no outage. Falls out of identity
keying for free — which is a good sign the axis split is right.

**5.3 A second real tenant.** Add an identity: new `secrets.<identity>.yaml`, new bucket namespace,
new URL, a placement row. No change to the compose files. **If adding a tenant requires editing
compose, the axes are still wrong.** That is the falsifiable test of this design.

## 6. Decisions that must be made, not inherited

- **MinIO bucket ACL.** The stacks run `mc anonymous set download` on the outline and kanbn buckets.
  Copied to Melbourne, that ships a public Outline/Kan.bn as the founding posture of a new box.
  Green-field means the ports are free, not that the defaults are decisions. **Default this design
  to private** until a stated requirement says otherwise.
- **Sydney's status.** Declaring the live imagineering stacks out of scope makes Melbourne
  reproducible and Sydney folklore. #3842 must be re-homed with an owner, not orphaned by this
  design's scope line.
- **Melbourne prerequisites are in scope or they are not.** `nick` is not in melb's `docker` group;
  Caddy there is a host unit. If this design claims to deploy to melb, it owns detecting both and
  failing loudly, or it is claiming an authority it does not have.

## 7. Open questions for Nick

1. **Is §4 (containerised Caddy, container-DNS routing, no published ports) in scope**, or does this
   design assume the current host-Caddy and use a placement table for ports? This is the single
   biggest fork left and it is sequenced behind the melb Caddy work either way.
2. **Which identities actually land on Melbourne?** claude-tasks#3794 proposes moving Recycled Sound
   to its own OCI tenancy — if that is the direction, one candidate audience is leaving rather than
   arriving, and this design should not carry weight for it.
3. **Does `enspyr` get its own `secrets.enspyr.yaml` now**, accepting that `outline/secrets.yaml`
   becomes `secrets.imagineering.yaml` and every Sydney deploy path must be updated in the same
   change? That rename is the moment the identity axis becomes real, and it touches live config.
