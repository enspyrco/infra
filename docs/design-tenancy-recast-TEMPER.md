# TEMPER.md — tenancy recast for outline/ + kanbn/

**Overall verdict:** RECAST
**Struck:** dt-tenancy, 2026-09-10. Families seated: **Maxwell + Kelvin + Carnot + Tesla (4/4)**. Wu/Kimi disabled.
**Target:** `docs/design-tenancy-recast.md` (which itself supersedes PR #178)

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | The reframe is right and the options are wrong — all three keep deploy-to.sh's rsync model inside a frame Nick overturned for Caddy hours earlier. |
| Kelvin (Gemini) | **DISSOLVE** | Solves tenancy by pretending it doesn't exist; conflates a logical data partition with a physical deployment target. |
| Carnot (GPT) | RECAST | Correctly finds #178 parameterised the wrong layer, then appeals to current topology without proving topology is policy. The missing axis is AUTHORITY. |
| Tesla (Grok) | RECAST | A 1:1 tenant→host mapping is a resistor, not an identity; the night the mapping breaks is the night this elegance rings itself to glass. |

One DISSOLVE is a strong finding to fold, not a kill (≥2 required). **Overall: RECAST.**

## Fatal flaws (deduped, most-severe first)

1. **The premise is a weather report sold as a load-bearing wall.** "Tenants never share a host" was MEASURED, not DECLARED. Raised independently by all four. — **RESOLVED BY RULING:** Nick, 2026-09-10, chose neither arm: *question the deploy layer* (see 2).

2. **Wrong option-frame — A/B/C are three ways to parameterise `deploy-to.sh`'s rsync-from-working-tree.** The org standard is a versioned image pulled from a registry, and staging from a git object is what makes shipping uncommitted bytes structurally impossible rather than merely detectable. Nick had ruled substrate-first for melb's Caddy hours before this design was written. (Maxwell) — **RULING: adopt this. Option D is the frame.**

3. **Failover is the future input option A structurally FORBIDS.** (Tesla, unique) Ports 3012/9010/3013 are free on melb only because melb is empty; they are the same three Sydney binds. When Sydney dies, surviving-host restore **is** two tenants on one host — the exact state A deletes machinery for — and a HOST allowlist refuses the only remaining box. *"Recover is the verb A amputates."*

4. **Three axes, not two.** (Tesla) IDENTITY (URL, secrets, buckets, data volumes) / PLACEMENT (which host, ports) / FAILURE-DOMAIN (what moves together when a box dies). The design's own framing question — TENANT or HOST — is a 2 where the problem has 3. Deleting the tenant column because it currently equals the host column deletes the distinguisher.

5. **Option A does NOT kill finding 4.** (Tesla) Names/project/ports/dirs are same-host collisions. `OUTLINE_URL`, `SECRET_KEY`, `S3_ENDPOINT`, buckets are IDENTITY and collide across oceans. Two hosts sharing one `secrets.yaml` is one tenant wearing two faces. *"A exiles the second tenant and calls the silence isolation."*

6. **A's HOST allowlist is B's `tenants.yaml` with one unnamed row.** (Tesla) The hand-curated-config-drifts scar applies to A too; it just has nowhere to sit until row two arrives, when you pay B's cost plus A's postponed rewrite.

7. **Dropping `${TENANT}` does not answer the identity question, it hides it in the leftover literals.** (Tesla) Someone's names/ports/secrets still get written into the file. Keep imagineering's and melb boots a doppelgänger; write enspyr's and the repo forks away from the only live stacks.

8. **A host allowlist inherits the defect it replaces** unless stated otherwise: `${VAR:-default}` overridability and `rsync --delete` upstream of the guard. Changing the noun fixes neither. (Maxwell, Carnot)

9. **`restore.sh` deferred is a designed lie.** (Tesla, Carnot) Deploy moving dirs while restore points at `~/apps/outline` / `~/apps/kanbn` — neither of which exists — is a data-loss design, not an open question. claude-tasks#2.

10. **Trust defaults inherited under the green-field spell.** (Tesla, Carnot) `mc anonymous set download` copied to melb ships a public Outline/Kan.bn as the house style of a new city. Green-field means the ports are free, not that the defaults are decisions.

11. **Sydney exile is split-brain, not "differently stuck."** (Tesla) Declaring live imagineering stacks out of scope makes Melbourne reproducible and Sydney folklore. #3842 must be re-homed, not orphaned.

12. **No second-deploy story.** (Maxwell) Every option is a first-install narrative; `rsync --delete` into a directory holding a running stack with live Postgres volumes is the actual steady state.

## What holds

- The two-tier diagnosis (implementation defects vs the data-layer design defect) — all four agree it is why #178 must not be patched.
- Tesla's fix-interaction trap, carried as a design constraint: the broken remote interpolation is an accidental safety catch; repairing it alone arms the dangerous path.
- The data layer (secrets, buckets, public URL) was always the real tenancy. Any recast that does not make it explicit is #178 with less interpolation.
- Recording the compose header's claim as FALSE rather than softening it.

## Disposition

**RECAST — round 1 of ≤3.** Nick's ruling resolves flaw 1 by reframing: the deploy LAYER is the question, not the tenant/host axis. That ruling does **not** dissolve flaws 3–7 — option D changes how bytes reach the box; Tesla's three axes govern what identity those bytes carry. Both must be answered in v2.

v2 must contain, before any candidate:
- the deploy mechanism as ruled: versioned image from a registry, config git-deployed, no rsync-from-working-tree
- the three axes split explicitly: identity / placement / failure-domain
- a required **3am section**: surviving-host failover, staging on the same box, second tenant. For each: what the tool does, what it refuses, where the data goes, which ports move. "Redo the design" is not an answer.
- binding constraints: allowlists are plain assignments; no destructive step precedes a satisfied guard; `restore.sh` bound to the same path function in the same change; bucket ACL an explicit yes/no for Melbourne.
