#!/bin/bash
# Completion-marker guard for pg_dump plain-text output.
#
# A complete pg_dump ends with the EXACT line '-- PostgreSQL database dump
# complete'. Checking for it is what stops a truncated dump (ENOSPC, killed
# container, dropped connection) being gzipped and committed over a good
# backup — pg_dump's own exit code is not enough, because piping it into gzip
# masks it behind gzip's status.
#
# WHY THIS IS A LIB AND NOT `tail -n5` INLINE
# The guard used to be `tail -n5 | grep -qxF` duplicated at two call sites.
# pg_dump 15.17 appends a `\unrestrict <token>` trailer AFTER the marker, so a
# real dump now ends:
#
#     -6  --
#     -5  -- PostgreSQL database dump complete   <-- marker
#     -4  --
#     -3  (blank)
#     -2  \unrestrict 6Xol3Xh44vvkpCquztAFg4Dzln...
#     -1  (blank)
#
# The marker sits EXACTLY at the edge of a 5-line window — measured live on
# 149.118.69.221, 2026-08-12 and again 2026-08-20. One additional trailer line
# from any future pg_dump version pushes it out, at which point EVERY postgres
# backup fails validation and is deleted by the caller's `rm -f`. That is a
# silent total backup outage triggered by a routine upgrade, and it fails in
# the safe direction only in the sense that it refuses to store anything.
#
# TAIL_WINDOW is therefore sized for headroom, not for the current trailer
# count. It stays a bounded window rather than scanning the whole file because
# these dumps are ~15 MB and the guard runs nightly; a window also preserves
# the property that matters — the marker must be near the END, so a dump
# truncated mid-body cannot pass by containing the string somewhere in its data.
PG_DUMP_TAIL_WINDOW=${PG_DUMP_TAIL_WINDOW:-50}

PG_DUMP_COMPLETION_MARKER='-- PostgreSQL database dump complete'

# pg_dump_is_complete <file>
# 0 if the file ends with a complete pg_dump; non-zero otherwise (truncated,
# empty, missing, or marker absent from the tail window).
pg_dump_is_complete() {
  local f=${1:-}
  [ -n "$f" ] && [ -s "$f" ] || return 1
  # -qxF: whole-line, fixed-string. Anchoring on the full line (not a substring)
  # stops a data row that happens to contain the marker text from faking
  # completeness after a truncation.
  tail -n "$PG_DUMP_TAIL_WINDOW" "$f" \
    | grep -qxF -- "$PG_DUMP_COMPLETION_MARKER"
}
