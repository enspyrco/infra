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
# ends: marker, `--`, blank, `\unrestrict …`, blank — the marker sitting EXACTLY
# at the edge of a 5-line window (measured on 149.118.69.221, 2026-08-12 and
# 2026-08-20). One more trailer line from any future pg_dump would have failed
# EVERY postgres backup, and the callers `rm -f` a dump that fails validation.
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
# a `--` comment, or a psql backslash command that is not a known-dangerous
# one). That is strictly stronger than "near the end" — it does not care about
# distance at all — and it removes the tension the window created:
#
#   - Trailer growth is free in BOTH dimensions: any number of trailer lines,
#     and any UNKNOWN psql command. The meta test is a bare leading backslash
#     rather than a list of `\restrict`/`\unrestrict`, because a list would
#     re-commit the original sin one level up — `\unrestrict` is itself a
#     trailer that did not exist before 15.17, and freezing the tokens we happen
#     to have observed is a line count wearing a grammar's clothes (cage-match
#     #157 r2, Tesla). There is no cliff left, so there is no number and no
#     token list to re-tune on the box.
#   - The one exception runs the OTHER way, and exists to prevent a regression:
#     a small set of known-dangerous psql commands (`\!`, `\i`, `\o`, `\copy`,
#     `\gexec`, `\q`, …) is NOT footer-shaped. Pure "any backslash" was more
#     permissive than the window it replaced — appending `\! cmd` to a real
#     footer pushed the marker to the 6th-from-last line, so `tail -n5` rejected
#     that dump and it never reached psql (cage-match #157 r7, Tesla; measured).
#     Note the direction: unknown tokens stay ACCEPTED, so no cliff is created;
#     only names dangerous TODAY are refused. This restores parity with the
#     window. It is NOT a replay-safety guard — see the note by that clause.
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
# MEASURED AGAINST THE REAL CORPUS (2026-08-21), not just fixtures. Both live
# dumps in imagineering-cc/imagineering-backups were run through this guard and
# the old `tail -n5` one; both accept both, so this is not a behaviour change on
# real data. The two probes that matter:
#
#   kanbn.sql   4075 lines: 32 COPY headers / 32 `\.` terminators, 1 line equal
#               to the marker, 4 lines after it, 0 dollar-quoted bodies.
#   outline.sql 5486 lines: 39 COPY headers / 39 `\.` terminators, 1 line equal
#               to the marker, 4 lines after it, 4 dollar-quoted bodies.
#
# Headers and terminators BALANCE exactly, so the COPY latch never opens
# spuriously on real data — the "a stray COPY header swallows the real footer
# and the caller deletes a complete backup" failure (cage-match #157 r4, Tesla)
# does not occur in this corpus. And "4 lines after the marker" independently
# confirms the founding measurement: `tail -n5` was passing by exactly one line.
#
# Both halves of the dollar-quote risk were then measured separately, because
# they fail in OPPOSITE directions and only one had been checked:
#   - a MARKER inside a $$ body would fake a footer (fail open),
#   - a COPY HEADER inside a $$ body would latch with no `\.` to close it,
#     swallow the real footer, and make the caller delete a COMPLETE dump
#     (fail closed — the more destructive of the two).
# outline has 4 dollar-quote delimiters and ZERO COPY headers inside them;
# kanbn has none at all. So the surface is live but currently unoccupied in
# both directions. It is a residual, not a defect — and not a hypothetical.
#
# RESIDUAL, stated honestly: the COPY filter only covers COPY data. A
# marker-shaped line can sit outside any COPY block — inside a dollar-quoted
# function body (`CREATE FUNCTION ... $$ ... $$`), or inside a multi-line string
# literal under `--inserts` — and if the dump is truncated right after it, with
# nothing but blank/comment/meta lines following, it passes. Note this reaches
# the DEFAULT `pg_dump <db>` path via dollar-quoting; it is NOT confined to
# `--inserts` (cage-match #157 r2, Tesla). Closing it needs real dollar-quote
# state tracking. This is a much narrower aperture than any tail window, and it
# is not a closed one.
PG_DUMP_COMPLETION_MARKER='-- PostgreSQL database dump complete'

# pg_dump_is_complete <file>
# 0 if the file ends with a complete pg_dump footer; non-zero otherwise
# (truncated, empty, missing, marker absent, or non-footer content after it).
pg_dump_is_complete() {
  local f=${1:-}
  [ -n "$f" ] && [ -s "$f" ] || return 1
  # Single pass, O(1) memory. `seen` is reset by each qualifying marker, so an
  # earlier marker-shaped line followed by real body does not poison a genuine
  # footer later in the file.
  awk -v marker="$PG_DUMP_COMPLETION_MARKER" '
    # COPY data blocks are user content — a row inside one is never a footer
    # marker, however exactly it matches. The block ends at the lone "\." line.
    #
    # `!seen` is load-bearing, not decoration: awk tries rules in source order,
    # so without it a COPY block appearing AFTER the marker would match here,
    # set incopy, and have its data skipped instead of counted as junk (a
    # concatenated or partially-overwritten file). Gating on !seen makes the
    # post-marker rule below the only one that can see those lines.
    #
    # The header match is deliberately loose: case-insensitive FROM STDIN, and a
    # substring rather than an anchor at `stdin;$` so a `WITH (...)` suffix still
    # latches. A COPY header we fail to recognise fails OPEN (its rows would be
    # judged as top-level lines), so this test is kept wider than the shape
    # pg_dump emits today.
    #
    # Spelled as a per-character class rather than toupper(): toupper is a
    # LOCALE function, and under a Turkish locale "i" uppercases to a dotted
    # capital, so "stdin" would never match "STDIN" and the latch would never
    # close (cage-match #157 r6, Tesla). Measured as NOT biting on this awk, but
    # cron locale is an environment input — the same class as the env knob this
    # file deleted — so the dependency is removed rather than relied upon.
    !seen && /^COPY / && /[ ][Ff][Rr][Oo][Mm][ ]+[Ss][Tt][Dd][Ii][Nn]/ { incopy = 1; next }
    incopy && $0 == "\\." { incopy = 0; next }
    incopy                { next }
    # Resetting junk here defines the semantic deliberately: the LAST top-level
    # marker is the footer, and only what follows IT must be footer-shaped.
    # The alternative (never reset, so any junk after any marker is fatal) was
    # considered and rejected — it would break the "genuine footer after an
    # earlier lookalike" case, which is the same shape as the concatenated-file
    # case Carnot raised (cage-match #157 r4). They are indistinguishable from
    # the bytes, so this picks the reading that keeps real dumps valid and
    # documents the cost: a file with real SQL between two markers is accepted
    # as complete. This function answers "is this a whole dump", nothing more —
    # whether a dump is SAFE to replay is a separate question owned by
    # _validate_pg_dump, and completeness must never be read as a safety claim.
    #
    # NB: this awk program lives in a single-quoted shell string, so an
    # apostrophe anywhere in these comments would CLOSE the string and hand the
    # rest of the program to bash. Keep them apostrophe-free.
    $0 == marker          { seen = 1; junk = 0; next }
    seen {
      # Footer shape: blank, a "--" comment, or ANY psql backslash command.
      #
      # The meta test is a bare leading backslash, NOT a list of the commands
      # that exist today, and not `\` + a letter either. Listing them repeats
      # the mistake this file exists to fix: `\unrestrict` did not exist before
      # pg_dump 15.17 and is exactly what broke the 5-line window. A grammar
      # frozen to observed tokens is a line count in another costume. `[a-zA-Z]`
      # was still that freeze one notch looser — it happens to admit
      # `\unrestrict` because `u` is a letter, but would reject `\;` or `\!`
      # (cage-match #157 r4, Tesla). A leading backslash is psql plumbing;
      # nothing in a dump BODY starts one at column 0 except a COPY
      # terminator, which is handled above.
      # Leading whitespace tolerated: a future pretty-printer that indents the
      # trailer must not fail every backup (cage-match #157 r7, Tesla).
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*--/) next
      if ($0 ~ /^[[:space:]]*\\/) {
        # NO-REGRESSION CLAUSE. Accepting any backslash line buys trailer
        # headroom, but it must not make this guard MORE PERMISSIVE than the
        # `tail -n5` window it replaces. It did: appending `\! cmd` after a
        # 15.17 footer pushes the marker to the 6th-from-last line, so the old
        # window REJECTED that dump as truncated and it never reached psql —
        # while a pure "any backslash is footer-shaped" rule ACCEPTS it, on both
        # the write and read paths (cage-match #157 r7, Tesla; measured, and my
        # own round-6 claim that the exposure was "entirely pre-existing" was
        # tested only with the command in the BODY, where it is).
        #
        # So the known-dangerous psql commands are explicitly NOT footer-shaped.
        # This is a denylist, and a denylist is what got frozen three times in
        # this file already — but the direction of the freeze is what matters:
        # an UNKNOWN token stays ACCEPTED (headroom preserved, no cliff), and
        # only names that are dangerous TODAY are refused. A future psql verb
        # is therefore permitted by this guard, exactly as `\unrestrict` needed
        # to be. Closing that remaining gap needs the whole-file, COPY-aware
        # parser tracked separately; this clause only restores parity with the
        # window, it is NOT a replay-safety guard and must not be read as one.
        #
        # Token boundary is "not a letter", not whitespace: psql does not
        # require a separator, so `\i/etc/passwd` is a real include (Tesla).
        # `!` needs no boundary since it is not a letter, so `\!id` is caught.
        if ($0 ~ /^[[:space:]]*\\!/) { junk = 1; next }
        if ($0 ~ /^[[:space:]]*\\(i|ir|o|w|g|e|s|c|q|copy|gexec|gset|include|include_relative|lo_import|lo_export|out|write|edit|quit|connect)([^a-zA-Z]|$)/) { junk = 1; next }
        next
      }
      junk = 1
    }
    END { exit (seen && !junk) ? 0 : 1 }
  ' < "$f"
  # Fed on stdin rather than as an argv filename so a path beginning with "-"
  # can never be parsed as an awk option (cage-match #157 r4, Tesla). Callers
  # pass absolute paths today; this removes the class rather than relying on
  # that staying true.
}
