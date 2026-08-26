#!/bin/bash
# Completion-marker guard for pg_dump plain-text output.
#
# A complete pg_dump ends with the EXACT line '-- PostgreSQL database dump
# complete'. Checking for it is what stops a truncated dump (ENOSPC, killed
# container, dropped connection) being gzipped and committed over a good
# backup — pg_dump's own exit code is not enough, because piping it into gzip
# masks it behind gzip's status.
#
# WHY THIS IS A STRUCTURAL CHECK AND NOT A TAIL WINDOW
# The guard was `tail -n5 | grep -qxF` inline at three call sites, and pg_dump
# 15.17 appends a `\unrestrict <token>` trailer AFTER the marker, so a real dump
# ends: marker, `--`, blank, `\unrestrict …`, blank — exactly 4 lines follow the
# marker, making it the 5th-from-last line, the last one a 5-line window could
# see (measured on 149.118.69.221 2026-08-12 and 2026-08-20, and against the
# live dumps 2026-08-21). One more trailer line from any future pg_dump would
# have failed EVERY postgres backup, and the callers `rm -f` a dump that fails
# validation.
#
# The obvious fix is a bigger window. It is the wrong fix, because a line count
# is a PROXY for the property we actually want, and the proxy is wrong in both
# directions at once:
#
#   too small -> a grown trailer pushes the marker out; every backup dies.
#   too large -> the marker no longer has to be in the FOOTER, so a dump
#                truncated mid-body can pass by containing the marker text as a
#                whole line in its data. Outline is a wiki: a document whose
#                body is the literal line '-- PostgreSQL database dump complete'
#                is a thing a user can type. Widening 5 -> 50 would have grown
#                that forgery aperture tenfold (cage-match #157, Tesla).
#
# So the window is gone. We assert the PROPERTY instead: the marker exists
# OUTSIDE any COPY data block, and every line after it is footer-shaped (blank,
# a `--` comment, or a psql backslash command). That is strictly stronger than
# "near the end" — it does not care about distance at all — and it removes the
# tension the window created:
#
#   - Trailer growth is free in BOTH dimensions: any number of trailer lines,
#     and any psql command, known or not. The meta test is a bare leading
#     backslash rather than a list of `\restrict`/`\unrestrict`, because a list
#     would re-commit the original sin one level up — `\unrestrict` is itself a
#     trailer that did not exist before 15.17, and freezing the tokens we happen
#     to have observed is a line count wearing a grammar's clothes (cage-match
#     #157 r2, Tesla). There is no cliff left: no number, no token list to
#     re-tune on the box.
#   - Body text can no longer forge the footer. A marker-shaped row inside a
#     COPY block is never counted, and real dump body after a marker is not
#     footer-shaped, so it fails.
#   - There is no knob. The old `${PG_DUMP_TAIL_WINDOW:-50}` was overridable
#     from the environment and unset by every caller and test in the tree — an
#     unused input whose only reachable effect was weakening a safety check
#     (a `+`-prefixed value is POSIX `tail -n +N`: read from line N to EOF,
#     i.e. a whole-file scan — the exact class that already bit this repo's
#     archive-tag retention). Deleted rather than validated.
#   - There is no pipeline, so the `grep -q` early-exit SIGPIPE trap under a
#     caller's `set -o pipefail` cannot fire here.
#
# WHAT THIS FUNCTION DOES NOT DO — and why a denylist was tried and removed.
# Round 7 of the review added a small denylist here so that known-dangerous psql
# commands (`\!`, `\i`, `\o`, …) were not footer-shaped, on the grounds that
# accepting any backslash line made this guard more permissive than the window
# it replaced. That is true, and it is still true. But the denylist could not be
# made to work, because completeness needs two CONTRADICTORY things from an
# UNKNOWN token: accept it (headroom, so a future pg_dump trailer cannot fail
# every backup) and refuse it if it is dangerous (safety). Round 8 measured the
# consequence: closing the gap opened a cliff. Matching `\gexec` by prefix also
# matched a hypothetical `\gexec2` and would DELETE a valid backup, while
# `\ef`/`\ev`/`\gx` still rode through. Every round moved the seam, neither side
# closed.
#
# The harms are not symmetric, so the tie breaks toward never destroying a good
# dump: a false REJECT deletes a backup, which is the exact catastrophe this
# file exists to prevent, whereas the remaining gap leaves a pre-existing and
# essentially unreachable exposure unimproved. So completeness answers "is this
# a whole dump" and NOTHING else — the split the section above states, which the
# round-7 clause violated by putting a safety check inside a headroom guard.
#
# Replay safety belongs to a whole-file, COPY-aware check in restore.sh, where
# an ALLOWLIST is correct because failing closed is the right direction on a
# destructive path. Tracked as its own task; do not re-add a denylist here.
#
# MEASURED AGAINST THE REAL CORPUS (2026-08-21), not just fixtures. Both live
# dumps in imagineering-cc/imagineering-backups were run through this guard and
# the old `tail -n5` one; both accept both, so this is not a behaviour change on
# real data. The probes that matter:
#
#   kanbn.sql   4075 lines: 32 COPY headers / 32 terminators, 1 line equal to
#               the marker, 4 lines after it, 0 dollar-quoted bodies.
#   outline.sql 5486 lines: 39 COPY headers / 39 terminators, 1 line equal to
#               the marker, 4 lines after it, 4 dollar-quoted bodies.
#
# Headers and terminators BALANCE exactly, so the COPY latch never opens
# spuriously on real data — the "a stray COPY header swallows the real footer
# and the caller deletes a complete backup" failure (cage-match #157 r4, Tesla)
# does not occur in this corpus. And "4 lines after the marker" independently
# confirms the founding measurement.
#
# Both halves of the dollar-quote risk were measured separately, because they
# fail in OPPOSITE directions and only one had been checked:
#   - a MARKER inside a $$ body would fake a footer (fail open),
#   - a COPY HEADER inside a $$ body would latch with no terminator to close it,
#     swallow the real footer, and make the caller delete a COMPLETE dump
#     (fail closed — the more destructive of the two).
# outline has 4 dollar-quote delimiters and ZERO COPY headers inside them;
# kanbn has none at all. Live surface, currently unoccupied in both directions.
#
# RESIDUALS, stated honestly:
#   1. The COPY filter only covers COPY data. A marker-shaped line can sit
#      outside any COPY block — inside a dollar-quoted function body, or a
#      multi-line string literal under `--inserts` — and if the dump is
#      truncated right after it, with only footer-shaped lines following, it
#      passes. This reaches the DEFAULT `pg_dump <db>` path via dollar-quoting;
#      it is NOT confined to `--inserts`. Closing it needs dollar-quote state.
#   2. A psql command appended after a real footer is accepted here, where the
#      old 5-line window rejected it (because the extra line pushed the marker
#      out). See the denylist note above for why that is deliberate, and where
#      the real fix belongs.
PG_DUMP_COMPLETION_MARKER='-- PostgreSQL database dump complete'

# pg_dump_is_complete <file>
# 0 if the file ends with a complete pg_dump footer; non-zero otherwise
# (truncated, empty, missing, marker absent, or non-footer content after it).
pg_dump_is_complete() {
  local f=${1:-}
  [ -n "$f" ] && [ -s "$f" ] || return 1
  # Single pass, O(1) memory.
  #
  # NB: this awk program lives in a single-quoted shell string, so an apostrophe
  # anywhere in these comments would CLOSE the string and hand the rest of the
  # program to bash, leaving this function UNDEFINED — and an undefined function
  # is silent and non-zero, so it impersonates a clean rejection. Keep them
  # apostrophe-free; test-pg-dump-guard.sh has a positive control for exactly
  # this (cage-match #157 r4).
  awk -v marker="$PG_DUMP_COMPLETION_MARKER" '
    # Strip a trailing CR before anything compares a whole line. The terminator
    # test below is exact, so on a CRLF dump incopy would stay latched, seen
    # would never set, and the caller would DELETE a complete backup while
    # logging "truncated" (cage-match #157 r8, Tesla; measured). pg_dump does
    # not emit CR, but these dumps travel through a git repo.
    { sub(/\r$/, "") }

    # COPY data blocks are user content — a row inside one is never a footer
    # marker, however exactly it matches. The block ends at the lone terminator.
    #
    # `!seen` is load-bearing, not decoration: awk tries rules in source order,
    # so without it a COPY block appearing AFTER the marker would match here,
    # set incopy, and have its data skipped instead of counted as junk (a
    # concatenated or partially-overwritten file). Gating on !seen makes the
    # post-marker rule below the only one that can see those lines.
    #
    # The header match is deliberately loose, and spelled as a per-character
    # class rather than toupper(): toupper is a LOCALE function, and under a
    # Turkish locale the letter i does not uppercase to ASCII I, so stdin would
    # never match STDIN and the latch would never close (cage-match #157 r6).
    # An unrecognised COPY header fails OPEN, so this stays wider than the shape
    # pg_dump emits today.
    !seen && /^COPY / && /[ ][Ff][Rr][Oo][Mm][ ]+[Ss][Tt][Dd][Ii][Nn]/ { incopy = 1; next }
    incopy && $0 == "\\." { incopy = 0; next }
    incopy                { next }

    # Surrounding space tolerated so a future pretty-printer cannot make every
    # backup look truncated. Still whole-line anchored, so a longer data line
    # merely CONTAINING the marker text cannot match.
    #
    # Resetting junk here defines the semantic deliberately: the LAST top-level
    # marker is the footer, and only what follows IT must be footer-shaped. The
    # alternative (never reset) breaks the "genuine footer after an earlier
    # lookalike" case, which is byte-identical to the concatenated-file case
    # (cage-match #157 r4, Carnot). This keeps real dumps valid and documents
    # the cost in the header.
    $0 ~ ("^[[:space:]]*" marker "[[:space:]]*$") { seen = 1; junk = 0; next }

    seen {
      # Footer shape: blank, a "--" comment, or ANY psql backslash command.
      # ANY, with no denylist — see the header for why one was tried and removed.
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*--/ || $0 ~ /^[[:space:]]*\\/) next
      junk = 1
    }
    END { exit (seen && !junk) ? 0 : 1 }
  ' < "$f"
  # Fed on stdin rather than as an argv filename so a path beginning with "-"
  # can never be parsed as an awk option (cage-match #157 r4, Tesla).
}

# ---------------------------------------------------------------------------
# SCHEMA PRESENCE — a SEPARATE predicate, deliberately not folded into the one
# above. The header's rule is that completeness must not double as safety; that
# is about one GATE serving two contradictory demands, not about one file
# holding two independent questions. "Is this a whole dump" and "does this dump
# contain a schema" are orthogonal: a dump of a wiped database is perfectly
# complete and perfectly useless. Both live here so the write and read sides
# cannot drift apart, which is the bug this function exists to fix.
#
# WHY THE WRITE SIDE NEEDS THIS AT ALL
# restore.sh refused a schemaless dump; backup.sh happily STORED one. That
# asymmetry manufactures a backup the restore path will categorically reject —
# discovered at DR time, which is the worst possible moment. Worse, storing it
# overwrites the good copy in the working tree and logs "Backup complete!".
# This repo has already lived that failure once: outline and kanbn failed every
# night for 40 nights while the live outline DB held 93 documents and its backup
# held 0 bytes (see the FAILED_SERVICES alert block in backup.sh).
#
# The harms are asymmetric and they point the other way from the completeness
# guard, which is why the answer differs. There, a false reject DESTROYED a good
# dump, so it broke toward accepting. Here a false reject at backup time only
# fails the run: the Telegram alert fires and `backup_to_github` never runs (it
# is `&&`-chained), so YESTERDAY's good backup survives untouched. Refusing
# costs one noisy night; accepting costs the backup.
#
# ANCHORED AND COPY-AWARE, unlike the `grep -q 'CREATE TABLE'` it replaces.
# That grep matched the string ANYWHERE, including inside COPY data — the exact
# forgery class the completeness guard was rewritten to eliminate, left standing
# one check below it on the DESTRUCTIVE path. Measured on the live corpus
# (2026-08-26): outline.sql 39 unanchored / 39 anchored / 0 inside COPY data,
# kanbn.sql 32 / 32 / 0. So anchoring is not a behaviour change on real dumps —
# the surface is live but currently unoccupied, and outline is a wiki, so a
# document body is content a user can type.
#
# Case-sensitive on the keyword, matching what pg_dump actually emits. A
# case-insensitive match would fail OPEN (more ways to satisfy "has schema"),
# and this predicate guards a destructive path where closed is the right
# direction. A hand-written lowercase dump is refused on purpose.
#
# RESIDUAL: shares residual 1 above — a top-level `CREATE TABLE` inside a
# dollar-quoted function body would count. Closing it needs dollar-quote state,
# tracked as its own task; it is a fail-OPEN gap on a check that is itself a
# second line of defence, so it does not gate this change.

# pg_dump_has_schema <file>
# 0 if the dump declares at least one table OUTSIDE any COPY data block.
pg_dump_has_schema() {
  local f=${1:-}
  [ -n "$f" ] && [ -s "$f" ] || return 1
  awk '
    { sub(/\r$/, "") }
    # Same COPY latch as pg_dump_is_complete, and same loose header match for
    # the same locale reason (toupper is locale-dependent; under a Turkish
    # locale stdin never matches STDIN and the latch never closes).
    /^COPY / && /[ ][Ff][Rr][Oo][Mm][ ]+[Ss][Tt][Dd][Ii][Nn]/ { incopy = 1; next }
    incopy && $0 == "\\." { incopy = 0; next }
    incopy { next }
    /^[[:space:]]*CREATE TABLE/ { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' < "$f"
  # stdin, not argv, so a path beginning with "-" is never an awk option.
}
