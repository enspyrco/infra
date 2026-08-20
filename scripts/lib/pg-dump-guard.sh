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
# a `--` comment, or a `\restrict`/`\unrestrict` psql meta-command). That is
# strictly stronger than "near the end" — it does not care about distance at
# all — and it removes the tension the window created:
#
#   - Trailer growth is now free. A future pg_dump can append any number of
#     comment/meta lines and the guard keeps passing. There is no cliff left to
#     fall off, so there is no number to re-tune on the box.
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
# RESIDUAL, stated honestly: a dump truncated at the exact byte after a
# marker-shaped line that sits OUTSIDE a COPY block (e.g. inside a multi-line
# string literal in an `--inserts` dump, with nothing but blank/comment lines
# following) still passes. Our backups are plain `pg_dump <db>` (COPY format),
# where that row is inside a COPY block and therefore ignored. This is a much
# narrower aperture than any tail window, not a closed one.
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
    /^COPY .* FROM stdin;$/ { incopy = 1; next }
    incopy && $0 == "\\."   { incopy = 0; next }
    incopy                  { next }
    $0 == marker            { seen = 1; junk = 0; next }
    seen {
      # Footer shape: blank, a "--" comment, or a psql \restrict/\unrestrict.
      if ($0 == "" || $0 ~ /^--/ || $0 ~ /^\\(un)?restrict([[:space:]]|$)/) next
      junk = 1
    }
    END { exit (seen && !junk) ? 0 : 1 }
  ' "$f"
}
