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
# a `--` comment, or ANY `\<letter>` psql meta-command). That is strictly
# stronger than "near the end" — it does not care about distance at all — and it
# removes the tension the window created:
#
#   - Trailer growth is free in BOTH dimensions: any number of trailer lines,
#     and any psql meta-command, known or not. The meta test is deliberately
#     `\` + a letter rather than a list of `\restrict`/`\unrestrict`, because a
#     list would re-commit the original sin one level up — `\unrestrict` is
#     itself a trailer that did not exist before 15.17, and freezing the tokens
#     we happen to have observed is a line count wearing a grammar's clothes
#     (cage-match #157 r2, Tesla). There is no cliff left, so there is no
#     number and no token list to re-tune on the box.
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
    # The header match is deliberately loose: `toupper` covers FROM STDIN case
    # variation, and matching a substring rather than anchoring at `stdin;$`
    # survives a `WITH (...)` suffix. A COPY header we fail to recognise fails
    # OPEN (its rows would be judged as top-level lines), so this test is kept
    # wider than the shape pg_dump emits today.
    !seen && /^COPY / && toupper($0) ~ / FROM STDIN/ { incopy = 1; next }
    incopy && $0 == "\\." { incopy = 0; next }
    incopy                { next }
    $0 == marker          { seen = 1; junk = 0; next }
    seen {
      # Footer shape: blank, a "--" comment, or ANY psql meta-command.
      #
      # The meta-command test is `\` + a letter, NOT a list of the commands that
      # exist today. Listing them would repeat the mistake this file exists to
      # fix: `\unrestrict` did not exist before pg_dump 15.17, and it is exactly
      # what broke the 5-line window. A grammar frozen to the tokens currently
      # observed is a line count in another costume — the next new trailer
      # command would set junk, fail every backup, and the caller would delete
      # the dump. Anything starting `\<letter>` is psql plumbing, not dump body.
      if ($0 == "" || $0 ~ /^--/ || $0 ~ /^\\[a-zA-Z]/) next
      junk = 1
    }
    END { exit (seen && !junk) ? 0 : 1 }
  ' "$f"
}
