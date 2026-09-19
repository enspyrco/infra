# Sensor types for the health-check pilot

**Status:** design, not yet built. Pilot for the deploy inversion (claude-tasks#4580).
**Scope:** `scripts/health-check.sh` only — one component, deliberately. Not the ten
watchers, not backup/restore, not `deploy-to.sh`.

The success criterion for the pilot as a whole is *"the box runs an artifact whose identity
we can read back."* This document covers the other half: the type vocabulary that makes the
bug class uncompilable rather than caught.

## The defect, stated precisely

`health-check.sh` is event-driven on CHANGE. Its diff is two lines:

```bash
for k in "${!issues[@]}"; do [ -n "${prev[$k]:-}" ] || new_msgs+=("${issues[$k]}"); done
for k in "${!prev[@]}";   do [ -n "${issues[$k]:-}" ] || resolved_keys+=("$k");     done
```

Membership in `issues` is **one bit**, and it is asked to hold **three facts**: the issue is
active, the issue is clear, or the sensor could not look. The third collapses into the second,
so a blind sensor emits `✅ Resolved` for something still broken and clears its state, after
which the real breakage can never re-alert.

This is a cardinality mismatch between the representation and the world — the same defect as
`${mem_total:-0}`, one altitude up, living in a hash-table membership test instead of a
parameter default.

The current script already knows: lines 193-200 synthesise fake issue keys
(`"<b>$k</b>: state UNKNOWN"`) to smuggle a third state through a two-state channel. That
workaround is the specification for the type.

## Vocabulary

### 1. Two state types of different sizes

```dart
enum KeyState   { active, clear, unknown }  // what a census yields
enum KnownState { active, clear }           // what the state file holds
```

The asymmetry is the invariant. There is no constructor that writes `unknown` to the state
file, so *blind cannot be persisted as resolved* — not because a reviewer checked, but because
the write does not typecheck. `prev` is therefore always two-valued.

Carry-forward becomes a total function rather than the loop at lines 193-200:
`unknown` persists the prior `KnownState` unchanged.

### 2. The transition table is the alert policy

Six cases; an exhaustive `switch` refuses to compile if one is missing.

| prev \ now | `active` | `clear` | `unknown` |
|---|---|---|---|
| **active** | silent | `✅ resolved` | silent; persist `active` |
| **clear**  | `🚨 new` | silent | silent; persist `clear` |

`✅` appears exactly once and is unreachable from `unknown`. That is the whole load-bearing
requirement, discharged by the compiler.

### 3. Census: presence is free, absence is earned

```dart
sealed class Census {
  Iterable<IssueKey> get observedActive;  // always safe: enumerating what you SAW
  KeyState stateOf(IssueKey k);           // the only way to ask about absence
}

final class FullCensus    extends Census { /* absent            => clear   */ }
final class PartialCensus extends Census { /* absent & covered  => clear
                                              absent & !covered => unknown */ }
final class BlindCensus   extends Census { /* everything        => unknown */ }
```

The raw set is never public, so the membership test that caused this is unreachable.

`PartialCensus` is constructible **only** from a per-item enumeration, never from a declared
coverage set — you cannot claim coverage you did not enumerate:

```dart
PartialCensus.from(Map<IssueKey, bool> observed, BlindReason why)  // covered = observed.keys
```

### 4. BlindReason is closed

```dart
sealed class BlindReason { }
final class ProbeFailed          extends BlindReason { final int exitCode; final String stderr; }
final class RequiredFieldMissing extends BlindReason { final List<MeminfoField> missing; }
final class RosterShortfall      extends BlindReason { final Set<String> unmeasured; }
final class ProbeTimedOut        extends BlindReason { final Duration after; }
```

The class is closed; `stderr` stays a `String` because it genuinely is free-form text — a
payload, not an identity. `MeminfoField` is an enum.

Reasons **do not compose across sensors.** Each blind sensor raises its own
`healthcheck:<sensor>` key carrying its own reason. There is no merged string because there is
no merged thing.

### 5. Required-field validation lives in the value type's constructor

```dart
final class MemStats {
  final int totalKb, availableKb, swapTotalKb, swapFreeKb;  // non-nullable, no defaults
}
```

A half-populated `MemStats` is unconstructible. Parsing returns `Reading<MemStats>` — a whole
one, or `Blind(RequiredFieldMissing([...]))`. The `MemAvailable`-missing false ALARM (reports
100% used) and the empty-file false ALL-CLEAR (key silently resolves) stop being two bugs and
become one unreachable state.

## Measured: what `df` actually does at our call site

The branch comment at `scripts/health-check.sh:56-62` asserts that `df` exits non-zero on one
unreadable mount while printing the rest. **That is true of `df`, and false of this call site.**
Measured 2026-09-19, GNU coreutils 9.7, `debian:stable-slim` on `linux/arm64`:

```bash
mkdir -p /parent/mnt; mount -t tmpfs none /parent/mnt; chmod 000 /parent
setpriv --reuid=65534 --regid=65534 --clear-groups df -h --output=pcent,target ...
```

| arm | invocation | exit | stdout | the unreadable mount |
|---|---|---|---|---|
| **A** | `df` with no path args — **what this script runs** | **0** | every other row | **silently omitted** |
| B | `df /parent/mnt` | 1 | empty | error on stderr |
| C | `df / /parent/mnt` | 1 | the good rows | error on stderr |

The mount is present in `/proc/self/mountinfo` and absent from `df`'s output, with a zero exit
and clean stderr. So the real failure mode at this call site is **a complete-looking roster
that is silently one row short** — not a non-zero exit.

Consequence for the design, and it is the reason this document exists: keying `Partial` off the
exit status would have produced `FullCensus` for arm A, hence `clear`, hence `✅ RECOVERY` for a
filesystem we can no longer see. That is PR #198's headline defect reborn inside the type
system, because the type deferred to the exit code exactly as the bash did.

**Coverage must be derived by comparing two independently-sourced rosters, never by reading the
instrument's own status:**

```
domain  = mounts in /proc/self/mountinfo (fstype-filtered)   what SHOULD be measurable
covered = mounts df actually printed                          what WAS measured
unknown = domain \ covered                                    no exit status involved
```

`FullCensus` for disk is then the degenerate case where the two rosters agree, not the case the
exit code declares.

## Which cases each sensor can honestly construct

The case-count per sensor is a statement about **how much epistemic access that sensor has.**

| sensor | independent domain | cases it can construct |
|---|---|---|
| disk | `/proc/self/mountinfo` | `Full` \| `Partial` \| `Blind` |
| memory / swap | the declared required-field set | `Full` \| `Blind` |
| container | **none** | `Full` \| `Blind` |

Docker is the honest gap: if `docker ps -a` returns exit 0 with a short roster, nothing on the
box can contradict it, so a `PartialCensus` constructor for containers could not be populated
truthfully and must not exist. The only candidate independent roster is the set of services
declared across the compose files — which is a declared-vs-running claim of a different kind.
Out of scope for the pilot; file a follow-up.

Stating this limitation in the type is the point. The alternative is four sensors that look
uniformly trustworthy and are not.

## Migration

The existing state file is a flat list of active keys. Reading each line as
`KnownState.active` is exactly correct, so the format change is free.

## Open questions

1. **Does the persisted state carry `asOf`** — the time of the last *actual* observation?
   Without it, a sensor blind for nine days is indistinguishable from one blind for an hour and
   the carried-forward `active` ages silently. Absent timestamp on migration reads as
   "unknown vintage", which is itself honest.
2. **Does blindness stay an issue key on the same diff, or get its own channel?** Riding the
   same diff buys change-suppression for free (a chronically blind sensor alerts once, not
   hourly). Against: "the instrument is broken" and "the box is broken" are different
   severities to a human at 3am.

## Related

- `memory/project_dart_pilot_deploy_inversion.md` — the pilot's decision and cross-compile recipe
- `memory/concept_cardinality_mismatch_representation_vs_world.md` — the frame
- `memory/concept_empty_result_is_two_facts.md` — the class this eliminates
- PR #198 — the bash hardening this may supersede
