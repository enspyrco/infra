# TEMPER.md — recast v2 (round 2 of ≤3)

**Overall verdict:** RECAST — but the loop is BLOCKED, not iterating.
**Struck:** dt2, 2026-09-11. Families seated: **Maxwell + Kelvin + Carnot + Tesla (4/4)**.
**Target:** `design-tenancy-recast-v2.md`

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | Folded the axis finding honestly, then overclaimed its guarantee and sold a fail-loud→fail-silent trade as subtraction. |
| Kelvin (Gemini) | RECAST | "Mistakes a survey for a floor plan… a well-formatted delay." |
| Carnot (GPT) | RECAST | A real fold of v1's category errors, but the central mechanism is contingent on three owner decisions. |
| Tesla (Grok) | RECAST | "Identity split on paper, recovery still a caption." Folded the *words* of failover and amputated the verb again. |

**4/4 RECAST. Zero DISSOLVE — but Tesla attaches a condition: a round 3 that still asks these
questions should be DISSOLVED, because at that point the recast loop IS the delay.**

## What v2 genuinely folded (all four agree)

- Nick's ruling is the frame; the rsync A/B/C option-set is gone, not renamed.
- Identity vs placement is correctly named, with `secrets.<identity>.yaml` marked as the #178-killer.
- Co-tenancy is no longer structurally forbidden; the allowlist must have an emergency placement path.
- Binding rules: plain-assignment allowlists, no destructive step before a satisfied remote preflight.
- Bucket ACL defaults **private** — a decision, not a question.
- #3842 re-homed rather than orphaned; melb prerequisites accepted as in-scope obligations.
- Images measured as already digest-pinned, so the ruling's image half was not re-solved.

## Fatal flaws (deduped, most-severe first)

1. **THE DEEPEST: §5.1 folded the words of failover and amputated the verb again.** (Tesla, unique)
   Round 1's finding was not "name identity apart from placement" — it was *recover is the verb A
   amputates.* v2 grants permission and nametags. But at 3am the dead box holds the Postgres volumes
   and the MinIO disks; `git archive` ships **config**. Identity-keyed volume *names* on Melbourne
   are **"empty chalices with the right engraving"** — compose up, unique names, no port clash, a
   **blank Outline**. *Success-shaped failure.* No RPO, no off-box replica, no account of how the
   bits leave Sydney, no DNS cutover. Failure-domain is a third table row with no key, no file, no
   object: **two axes operationalized, the third captioned.**

2. **§4 introduces silent cross-tenant routing, and Tesla supplied the mechanism.** (Maxwell,
   Carnot, Tesla) Docker DNS resolves **service** names, not `container_name`. Both stacks declare
   service `outline`. One Caddy attached to `enspyr-outline` and `imagineering-outline` asking for
   `outline:3000` is **ambiguous — round-robin or first-match — a silent reverse-proxy into the
   other identity's cookies and buckets.** A port collision fails loudly at bind; this fails green.
   v2 called it "the subtraction worth having." It is a coupling moved into a quieter cavity.

3. **§3's "structurally impossible" is false at the identity layer.** (all four) `git archive`
   cannot emit uncommitted *compose*. The identity-bearing artifact is a SOPS render of a
   **working-tree** path — so **committed compose wearing uncommitted identity**, shipped through a
   side-channel the slogan does not cover. Weaker still: `<ref>` may be any local branch, so the
   provenance preflight remains the only real gate — the property v2 claimed to have made
   structural. Kelvin adds: `trap` cleanup is *procedural*, so an abort between render and trap
   leaves plaintext secrets on disk.

4. **§7's open questions are load-bearing; the design is contingent on them.** (all four) Q1 forks
   §5.1 into two incompatible nights. Q3 is worse — the document itself calls the rename "the moment
   the identity axis becomes real", then files that moment as a question. Kelvin: *"an engine that
   has never been fired."* Round 1 called a deferred restore a designed lie; v2 learned the *shape*
   of that finding and relocated the deferral into a more respectable numbered list.

5. **The falsifiable test is scoped to the artifact already known not to change.** (all four)
   "If adding a tenant requires editing a compose file" passes while the operator edits Caddy routes,
   network membership, DNS, SOPS keys, bucket namespaces and a placement table. Same optimisation as
   v1: less interpolation in compose, coupling living where grep is less likely to look.

6. **The axes lack an owning artifact.** (Carnot) No manifest/schema showing where each field lives
   and how compose consumes it ⇒ taxonomy, not design.

7. **No second-deploy transaction.** (Carnot, Maxwell) Named as a constraint; not specified.
   No atomicity, no release dir, no rollback target, no "Caddy route updated but app update failed".

## Disposition — STOP, do not run round 3

The panel is no longer finding new design flaws in the *mechanism*; three of four say the design
cannot be graded until two decisions exist, and Tesla warns a round 3 that still asks them is a
DISSOLVE. Continuing would be the loop reviewing its own repairs.

**Blocked on Nick, two rulings:**

- **Q1 — is containerised Caddy + container-DNS routing in scope?** Determines whether placement
  ports exist at all. *Tesla's recommendation: OUT of this design — it is a Caddy-architecture
  recast, and if ever done it needs a network-alias invariant (`<identity>-outline` as an alias,
  never a bare `outline` visible to one proxy on two networks).*
- **Q3 — does `outline/secrets.yaml` become `secrets.imagineering.yaml` now?** *Tesla's
  recommendation: not a question — do it in the same change as the first git-archive deploy, and
  refuse to ship until the live Sydney path reads the renamed file.*

**And one finding that needs no ruling, to fold on sight:**

- Bind SOPS to the same `<ref>` as `git archive` (`git show <ref>:…/secrets.<id>.yaml | sops -d`),
  never a working-tree path. Otherwise stop claiming "structurally impossible".
- Write 3am as **restore**, not as naming: where volumes live, what is off-box, RPO, the operator's
  actual commands, DNS cutover. **If the bits cannot leave a dead Sydney, say so** — then this
  design provides co-tenancy of already-present data, not failover, and must not be captioned as
  the latter.
