# Handoff: infra tab — pick up in the new home (2026-07-28)

This repo was **`imagineering-cc/imagineering-infra`** until 2026-07-28. It is now
**`enspyrco/infra`** at `~/git/orgs/enspyrco/infra`. This handoff is the pickup point.

## Why the rename

North star (was living only in Nick's head, now captured): **one place to manage all
infra, and a single `nick@` user per box** — not the current `ubuntu@` + `nick@` split.
`enspyrco/infra` becomes the one home; the boxes get normalised to `nick`-primary.

## Migration status — both phases DONE (2026-07-28)

**Phase 1 (local, reversible) ✓**
- Local dir `orgs/imagineering/imagineering-infra` → `orgs/enspyrco/infra`
- 3 git worktrees removed (2 open PRs captured as tasks; 1 was already merged)
- Memory project dir → slug `-Users-nick-git-orgs-enspyrco-infra`; MEMORY.md live
- 18 consolidation `memory-path.txt` repointed; wake-up protocol resolves the new home
- Task label `project:imagineering-infra` → `project:infra` (20 issues followed)

**Phase 2 (GitHub, irreversible) ✓**
- Transferred + renamed → `enspyrco/infra`; local `origin` repointed; fetch verified
- Preflight was clean: workflows use no secrets, no repo secrets/webhooks/deploy keys
- **Deploys are pull-based** (cd-bus systemd timers `git pull` on the boxes). Old-URL
  pulls keep working via GitHub's transfer redirect — so nothing broke — but the boxes'
  remotes still say `imagineering-cc/imagineering-infra` until the sweep updates them.

## First task = the sweep (find the stragglers)

The rename left prose/path/remote references pointing at the old name in several places.
See the "sweep" task. Scope:
- **Boxes' git remotes** → `enspyrco/infra` (currently redirect-covered, not yet updated),
  then verify a `cd-poll` actually fires (the terminal deploy observable).
- **Repo-internal prose** (CLAUDE.md, READMEs, the GitHub description still say
  "imagineering-infra"/"imagineering.cc") — now correct to rename since GitHub matches.
- **Other repos' docs** referencing the old local path: xero, adventures-in/tech_world,
  hardware-freedom/SUPERBRIDGE.md, imagineering/sessions. Cosmetic, cross-project.

## Open workstreams (the rest of the north star — NOT yet planned)

1. **enspyr `ubuntu@` → `nick@` migration** — grounded plan already exists at
   `~/git/orgs/aiko/aiko-chat-island/HANDOFF-to-infra-tab.md`. Premises verified live
   2026-07-28 (multi-tenant box, `echo` group shared, nick idle since Jun 3, etc.).
   Two gates it names: (a) **fresh DB backup immediately pre-cutover** — latest is
   `aiko.db.precutover-20260711-064747`, ~17 days old; (b) the **`echo` group work is
   co-owned** by adarsha/meghana — a HUMAN coordination blocker, not a solo step.
2. **xdeca decommission** (ensure backups fresh → stop) — colocated on the Sydney box
   (149.118.69.221), shares caddy. Kill it *before* folding its infra in; its dir
   becomes `archive/`, not a live subdir.
3. **Other boxes' `nick@` status** — Sydney/imagineering already nick-primary (reference
   end-state). enspyr in-flight (#1). Robin's box (`robins-oci`, 207.211.145.30) still
   `ubuntu@`; ant colony untouched.

## Decisions still open
- **Label name coupling**: label is `project:infra` (forced by repo basename `infra`) —
  generic. A distinctive `project:enspyrco-infra` would require basename `enspyrco-infra`.
  Left as `project:infra`; flag if you want it changed (restore key = basename).

## Do NOT touch
- The `CANDEIRA` OCI profile / `oci_api_key_candeira.pem` is **intentional consented
  break-glass** access to Javier's account — see `reference_oci_candeira_breakglass.md`.
  Do not "helpfully" revoke it.
