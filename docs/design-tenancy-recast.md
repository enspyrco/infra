# Recast: what is a "tenant" for outline/ and kanbn/?

Status: DESIGN, un-struck. Supersedes the approach in PR #178 (open, REQUEST_CHANGES from all four cage-match reviewers).
Date: 2026-09-10. Context: claude-tasks#3849 (stand up Kan.bn + Outline on enspyr-melb), #3842, #3670.

## The problem, as actually found

`outline/docker-compose.yml` and `kanbn/docker-compose.yml` hard-coded one tenant's identity
(`img-outline`, `img-kanbn`, ports 3012/9010/3013). `scripts/deploy-to.sh` guarded them with a
prohibition-plus-override (`OUTLINE_DEPLOY_OVERRIDE=1`).

PR #178 replaced the prohibition with an allowlist (`REPO_OWNED_TENANTS`) and parameterised every
host-global identifier on `${TENANT}`. Four cross-family reviewers found it unshippable. The
findings sort into two tiers.

**Tier 1 — implementation defects (fixable in the diff):**

1. `TENANT` and the ports are asserted in the LOCAL shell, never written into the rsynced `.env`
   and never exported remotely, so `docker compose` dies on the box. Every control run was local;
   none crossed the ssh boundary. (Maxwell, Carnot, Tesla)
2. `REPO_OWNED_TENANTS="${REPO_OWNED_TENANTS:-enspyr}"` is call-site overridable, while its own
   refusal text says "deliberately, in a commit, not as an env var at the call site". The override
   this PR exists to delete was reintroduced one line under the comment congratulating its removal.
   (Maxwell, Carnot, Tesla)
3. `rsync --delete` runs BEFORE the remote compose can fail, so the destructive act precedes the
   fuse. Combined with (2), `TENANT=imagineering` resolves `~/apps/${TENANT}-outline` to the LIVE
   production directory. Blast radius went UP in that PR, not down. (Tesla)

**Tier 2 — the design defect (NOT fixable in the diff):**

4. Both deploy functions decrypt the SAME `outline/secrets.yaml` / `kanbn/secrets.yaml` for every
   tenant: one `OUTLINE_URL`, one `SECRET_KEY`, one `S3_ENDPOINT`. Buckets stay `outline`,
   `kanbn-avatars`, `kanbn-attachments`. Volumes and networks borrow isolation only from compose's
   implicit project-name prefix. Tesla: *"Containers will not collide. The tenants will."*

The compose header asserts "two tenants can run from this one file without colliding." That claim
is FALSE. Tenancy was parameterised at the IDENTIFIER layer and not at the DATA layer.

**And a fix-interaction trap** (Tesla): the broken remote interpolation in (1) is currently an
ACCIDENTAL SAFETY CATCH. Fixing (1) alone — the obvious one-liner, which two reviewers proposed —
makes the dangerous path in (2)+(3) actually work. Do not fix 1 without 2 and 3.

## The reframe this design proposes

Measured 2026-09-10, and it may dissolve most of the above:

- `imagineering` runs on **Sydney only** (`~/apps/imagineering-outline`, `~/apps/imagineering-kanbn`).
- `enspyr` is destined for **Melbourne only**, which is green-field: no outline/kanbn dirs, and
  ports **3012, 3013, 9010 are all free**.
- There is no host on which two tenants are deployed, and none planned.

Every collision class PR #178 guards against — container names, compose project, published ports,
remote directories — is a **same-host** collision. If tenants never share a host, the entire
parameterisation is machinery for a state that does not occur.

So the load-bearing question is not "how do we parameterise tenants?" but:

> **Is the real axis TENANT, or is it HOST?**

## Candidate designs

**A. Host-scoped authority (subtractive).** Drop `${TENANT}` entirely. Keep the compose files
single-identity. Replace the tenant allowlist with a HOST allowlist: this repo is authoritative for
the stacks on enspyr-melb; Sydney's hand-managed stacks are not this file's business. Deploy refuses
any host not on the list. Ports stay literal because they are free on the only box we deploy to.
- Pro: smallest surface; no `.env` plumbing; no port-teaching error messages; kills findings 1-4 at once.
- Con: a genuine second tenant on ONE box later needs this work redone.
- Open: does it leave #3842 (reconcile Sydney) any better off, or just differently stuck?

**B. Tenant manifest as single source of truth.** A committed `tenants.yaml`: name → host, ports,
secrets path, bucket prefix, public URL. deploy-to.sh reads it; compose interpolates from it.
Per-tenant secrets files (`outline/secrets.enspyr.yaml`).
- Pro: makes the DATA layer explicit — the thing #178 got wrong. Adding a tenant is one committed row.
- Con: most machinery; a manifest is exactly the "hand-curated config outside the running system"
  shape this org has been burned by before. Who reconciles it against reality?

**C. Separate stack directories per tenant.** `outline-enspyr/`, keep `outline/` as imagineering's.
- Pro: zero interpolation, zero shared-secret risk, trivially readable.
- Con: duplication; a fix to one must be remembered in the other — the drift-gate-as-monument shape.

## Questions this design does NOT answer

- Whether one-tenant-per-host is a fact we are choosing or an accident we are ratifying. If Nick
  intends multiple tenants per box later, A is wrong today.
- Whether `restore.sh` (which points at `~/apps/outline` and `~/apps/kanbn`, neither of which
  exists — claude-tasks#2) should be reconciled in the same change. Deploy and restore disagreeing
  about where data lives is how a backup becomes fiction.
- Whether the melb blockers (nick not in the `docker` group; Caddy is a host systemd unit, not the
  containerised stack) belong in this design or are separate.
- Whether MinIO's `mc anonymous set download` on outline/kanbn buckets — pre-existing, and copied
  per tenant under B or C — is acceptable, or a public bucket inherited as a default rather than a
  decision.
