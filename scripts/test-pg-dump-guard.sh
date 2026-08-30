#!/bin/bash
# Tests for lib/pg-dump-guard.sh.
#
# Two failure classes, which a tail-window guard traded against each other and
# this structural guard does not (see the lib header):
#   TRAILER GROWTH  — pg_dump 15.17 already put the marker exactly 5 lines from
#                     EOF, so the old `tail -n5` passed by one line. One more
#                     trailer line would have failed EVERY postgres backup, and
#                     the callers delete a dump that fails validation.
#   FOOTER FORGERY  — a dump truncated mid-body whose data contains the marker
#                     as a whole line. Outline is a wiki; that line is content a
#                     user can type. Widening the window buys headroom by paying
#                     in forgery aperture, which is why the window is gone.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pg-dump-guard.sh
. "$SCRIPT_DIR/lib/pg-dump-guard.sh"

PASS=0
FAIL=0
# POSITIVE CONTROL for the harness itself. The awk program lives inside a
# single-quoted shell string, so one apostrophe in its comments closes the
# string and the file stops parsing — which really happened during review. That
# failure makes pg_dump_is_complete UNDEFINED, and an undefined function is
# silent and non-zero: it would sail through a "produces no stdout" assertion
# and read as a rejection everywhere else. Assert the lib parses and the
# function exists BEFORE any test trusts its answers.
if ! bash -n "$SCRIPT_DIR/lib/pg-dump-guard.sh" 2>/dev/null; then
  printf '  \033[0;31mFAIL\033[0m lib/pg-dump-guard.sh does not parse\n'; exit 1
fi
for _fn in pg_dump_is_complete pg_dump_has_schema; do
  if [ "$(type -t "$_fn")" != function ]; then
    printf '  \033[0;31mFAIL\033[0m %s is not defined after sourcing the lib\n' "$_fn"; exit 1
  fi
done
unset _fn
ok() { PASS=$((PASS + 1)); printf '  \033[0;32mok\033[0m %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# The old guard, kept as an executable regression witness — several tests below
# assert it FAILS where the new one succeeds (and, for forgery, that it PASSES
# where the new one correctly refuses).
oldguard() { tail -n5 "$1" | grep -qxF -- '-- PostgreSQL database dump complete'; }

# Body + a real COPY block + marker + N trailing trailer pairs.
make_dump() {
  local out=$1 trailers=$2 i
  { echo "-- PostgreSQL database dump"; echo "CREATE TABLE t (id int);"
    echo "COPY t (id) FROM stdin;"; echo "1"; echo "\\."
    echo "--"; echo "-- PostgreSQL database dump complete"; echo "--"; } > "$out"
  for ((i = 0; i < trailers; i++)); do echo "\\unrestrict tok$i" >> "$out"; echo "" >> "$out"; done
}

echo "== the REAL fixture shape (pg_dump 15.17, measured on the box) =="
# Exactly 4 lines follow the marker (--, blank, \unrestrict, blank), making it
# the 5th-from-last line — the last one `tail -n5` could see. Verified against
# the live kanbn.sql and outline.sql, not just transcribed.
printf -- '--\n-- PostgreSQL database dump complete\n--\n\n\\unrestrict QCYt5h0EDZIG3cZal9B\n\n' > "$TMP/real.sql"
pg_dump_is_complete "$TMP/real.sql" && ok "accepts a real 15.17 dump" || no "accepts a real 15.17 dump"

echo "== trailer growth is UNBOUNDED — no window left to fall off =="
# The old guard died at 2 pairs. There is no N at which the new one dies, so the
# upper fixture is deliberately absurd: if a cliff still existed, 200 finds it.
for n in 1 2 5 10 20 200; do
  make_dump "$TMP/t$n.sql" "$n"
  if pg_dump_is_complete "$TMP/t$n.sql"; then ok "accepts with $n trailer pair(s)"; else no "accepts with $n trailer pair(s)"; fi
done

echo "== REGRESSION PROOF: tail -n5 would have rejected these =="
broke=0
for n in 2 5 10 20 200; do oldguard "$TMP/t$n.sql" || broke=$((broke + 1)); done
[ "$broke" -eq 5 ] && ok "old tail -n5 guard rejects all 5 grown-trailer dumps (this is the bug)" \
                   || no "expected old guard to fail 5 fixtures, it failed $broke"

echo "== FOOTER FORGERY: a COPY row that IS the marker cannot fake completeness =="
# The case the old suite never asked (cage-match #157, Tesla). A wiki page whose
# body is exactly the marker line, in a dump killed immediately after that row.
# Under `tail -n5` the marker is the LAST line — squarely inside the window — so
# the old guard blesses a truncated dump. The structural guard ignores anything
# inside a COPY block, so it cannot be fooled by content at ANY distance.
{ echo "-- PostgreSQL database dump"; echo "CREATE TABLE d (body text);"
  echo "COPY d (body) FROM stdin;"; echo "an ordinary row"
  echo "-- PostgreSQL database dump complete"; } > "$TMP/forge.sql"
pg_dump_is_complete "$TMP/forge.sql" && no "rejects a marker-shaped COPY row at EOF" \
                                     || ok "rejects a marker-shaped COPY row at EOF"
oldguard "$TMP/forge.sql" && ok "old tail -n5 guard ACCEPTS the forgery (this is the aperture)" \
                          || no "expected old guard to accept the forgery fixture"

echo "== forgery mid-COPY, with body continuing after it, is also rejected =="
{ echo "-- PostgreSQL database dump"; echo "CREATE TABLE d (body text);"
  echo "COPY d (body) FROM stdin;"; echo "-- PostgreSQL database dump complete"
  echo "another row"; echo "and another"; } > "$TMP/forge2.sql"
pg_dump_is_complete "$TMP/forge2.sql" && no "rejects marker mid-COPY with body after" \
                                      || ok "rejects marker mid-COPY with body after"

echo "== an UNKNOWN psql meta-command trailer is accepted (no frozen token list) =="
# The r2 finding that reframed the guard a second time: allowing only
# \restrict/\unrestrict would freeze the tokens that exist TODAY, which is the
# exact mistake `tail -n5` made with the line count — \unrestrict itself did not
# exist before pg_dump 15.17. These fixtures stand in for whatever the next
# Postgres release appends. If any of them fails, the guard has a token cliff
# and a future release will delete every postgres backup.
i=0
for meta in '\set FOO bar' '\encoding UTF8' '\if false' '\unrestrict2 tok' '\somethingnobodyhasinventedyet x'; do
  i=$((i + 1))
  make_dump "$TMP/meta$i.sql" 1
  printf '%s\n\n' "$meta" >> "$TMP/meta$i.sql"
  if pg_dump_is_complete "$TMP/meta$i.sql"; then ok "accepts unknown trailer: $meta"
  else no "accepts unknown trailer: $meta"; fi
done

echo "== a COPY block AFTER the marker is junk, not skippable data =="
# Rule-order leak (cage-match #157 r2, Carnot): awk tries rules in source order,
# so without the `!seen` guard a post-marker COPY header would set incopy and
# have its rows skipped instead of counted as junk — a concatenated or
# partially-overwritten file would pass as complete.
make_dump "$TMP/copy-after.sql" 1
{ echo "COPY t (body) FROM stdin;"; echo "surprise data"; echo "\\."; } >> "$TMP/copy-after.sql"
pg_dump_is_complete "$TMP/copy-after.sql" && no "rejects a COPY block after the footer" \
                                          || ok "rejects a COPY block after the footer"

echo "== a COPY header with a WITH clause / uppercase STDIN still latches =="
# Fail-OPEN direction (cage-match #157 r2, Tesla): if the COPY header is not
# recognised, its rows are judged as top-level lines and the forgery aperture
# reopens. The matcher is deliberately looser than what pg_dump emits today.
for hdr in 'COPY d (body) FROM STDIN;' 'COPY d (body) FROM stdin WITH (FORMAT text);'; do
  { echo "-- PostgreSQL database dump"; echo "CREATE TABLE d (body text);"
    echo "$hdr"; echo "an ordinary row"
    echo "-- PostgreSQL database dump complete"; } > "$TMP/hdr.sql"
  pg_dump_is_complete "$TMP/hdr.sql" && no "rejects forgery under header: $hdr" \
                                     || ok "rejects forgery under header: $hdr"
done

echo "== non-footer content AFTER a genuine marker is rejected =="
# Truncation is not the only corruption: a concatenation accident or a partially
# overwritten file leaves real SQL past the footer. That is not a complete dump.
make_dump "$TMP/tail-junk.sql" 1
echo "SELECT 1;" >> "$TMP/tail-junk.sql"
pg_dump_is_complete "$TMP/tail-junk.sql" && no "rejects SQL after the footer" \
                                         || ok "rejects SQL after the footer"

echo "== a genuine footer LATER in the file still passes after an earlier lookalike =="
# `seen` must reset per marker: an early marker-shaped line outside a COPY block
# followed by real body must not poison a genuine footer at the end.
{ echo "-- PostgreSQL database dump"; echo "-- PostgreSQL database dump complete"
  echo "CREATE TABLE t (id int);"; echo "COPY t (id) FROM stdin;"; echo "1"; echo "\\."
  echo "--"; echo "-- PostgreSQL database dump complete"; echo "--"; } > "$TMP/late.sql"
pg_dump_is_complete "$TMP/late.sql" && ok "accepts a genuine footer after an earlier lookalike" \
                                    || no "accepts a genuine footer after an earlier lookalike"

echo "== still fails CLOSED on bad input =="
printf -- '-- PostgreSQL database dump\nCREATE TABLE t (id int);\nCOPY t (id) FROM stdin;\n1\n' > "$TMP/trunc.sql"
pg_dump_is_complete "$TMP/trunc.sql" && no "rejects a truncated dump" || ok "rejects a truncated dump"
: > "$TMP/empty.sql"
pg_dump_is_complete "$TMP/empty.sql" && no "rejects an empty file" || ok "rejects an empty file"
pg_dump_is_complete "$TMP/nope.sql" && no "rejects a missing file" || ok "rejects a missing file"
pg_dump_is_complete "" && no "rejects an empty arg" || ok "rejects an empty arg"

echo "== a truncation that CONTAINS the marker text as a substring is rejected =="
{ echo "-- PostgreSQL database dump"; echo "COPY t (note) FROM stdin;"
  echo "some row mentioning -- PostgreSQL database dump complete inline"; } > "$TMP/sneaky.sql"
for ((i = 0; i < 60; i++)); do echo "row $i"; done >> "$TMP/sneaky.sql"
pg_dump_is_complete "$TMP/sneaky.sql" && no "rejects marker-as-substring" \
                                      || ok "rejects marker-as-substring"

echo "== WRITE/READ SYMMETRY: restore accepts everything backup stores =="
# The guard has a third call site: restore.sh's _validate_pg_dump. It was left on
# the old inline `tail -n5` when backup.sh's two sites moved to the lib — strictly
# WORSE than the original bug, because a wider accept window on the write side than
# the read side manufactures a band of dumps that back up fine and are then refused
# at restore time, mid-disaster, with the error text "truncated".
sym=0
for n in 1 2 5 10 20 200; do
  # Subshell: restore.sh runs under `set -e`, which must not leak into the harness.
  if ( set +e; RESTORE_LIB_ONLY=1 . "$SCRIPT_DIR/restore.sh" >/dev/null 2>&1
       _validate_pg_dump test "$TMP/t$n.sql" >/dev/null 2>&1 ); then
    sym=$((sym + 1))
  fi
done
[ "$sym" -eq 6 ] && ok "restore.sh validates all 6 dumps backup.sh would store" \
                 || no "restore.sh accepted only $sym/6 dumps backup.sh would store"

echo "== the CLASS is closed: no tail-window marker guard survives =="
# Corpus assertion, not a spot fix — this fails if a copy of the guard is ever
# pasted in rather than sourced from the lib. Scope, honestly: it covers scripts/
# only, and catches the marker appearing within two lines of a `tail -n` (so a
# split pipeline is seen too, not just the single-line form). A copy living
# outside this tree — e.g. xdeca's own backup.sh at the shared /opt/scripts path
# on the same box — is NOT covered by this check.
strays=$(grep -rn -A2 --include="*.sh" -- "tail -n" "$SCRIPT_DIR" 2>/dev/null \
         | grep -- "PostgreSQL database dump complete" \
         | grep -v 'test-pg-dump-guard.sh' || true)
[ -z "$strays" ] && ok "no tail-window guard outside this test's deliberate oldguard()" \
                 || no "tail-window guard still present: $strays"
# The deleted knob must not come back: it was overridable from the environment
# and a `+`-prefixed value turns `tail -n` into a whole-file scan. COMMENT lines
# are excluded — the lib header documents WHY the knob was removed, and a check
# that forbids naming the thing it forbids would ban its own rationale. (This
# test file is excluded for the same reason: it names the knob to search for it,
# so an unfiltered grep matches its own pattern and can only ever fail.)
knob=$(grep -rn --include="*.sh" -- "PG_DUMP_TAIL_WINDOW" "$SCRIPT_DIR" 2>/dev/null \
       | grep -v 'test-pg-dump-guard.sh' \
       | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
[ -z "$knob" ] && ok "the PG_DUMP_TAIL_WINDOW env knob stays deleted" \
               || no "PG_DUMP_TAIL_WINDOW reintroduced: $knob"

echo "== a CRLF dump is not mistaken for a truncated one =="
# Fail-CLOSED bug found in r8 (Tesla) and confirmed by measurement: the COPY
# terminator test is an exact string compare, so on CRLF the terminator reads as
# "\.<CR>", incopy stays latched, seen never sets, and the caller DELETES a
# COMPLETE backup while logging "truncated". pg_dump does not emit CR, but these
# dumps live in a git repo. Cheaper to normalise than to rely on that.
printf -- '-- PostgreSQL database dump\r\nCREATE TABLE t (id int);\r\nCOPY t (id) FROM stdin;\r\n1\r\n\\.\r\n--\r\n-- PostgreSQL database dump complete\r\n--\r\n\r\n\\unrestrict TOK\r\n\r\n' > "$TMP/crlf.sql"
pg_dump_is_complete "$TMP/crlf.sql" && ok "accepts a CRLF dump" || no "accepts a CRLF dump"
# Null arm: CRLF must not become a way to sneak a truncated dump past the guard.
printf -- '-- PostgreSQL database dump\r\nCREATE TABLE t (id int);\r\nCOPY t (id) FROM stdin;\r\n1\r\n' > "$TMP/crlf-trunc.sql"
pg_dump_is_complete "$TMP/crlf-trunc.sql" && no "still rejects a truncated CRLF dump" \
                                          || ok "still rejects a truncated CRLF dump"

echo "== an indented footer is not mistaken for a truncated dump =="
# Same fail-closed class: the trailer tolerates leading space, so the marker had
# better too, or a future pretty-printer deletes every backup.
printf -- '-- PostgreSQL database dump\nCREATE TABLE t (id int);\n  -- PostgreSQL database dump complete\n  --\n\n  \\unrestrict TOK\n\n' > "$TMP/indent.sql"
pg_dump_is_complete "$TMP/indent.sql" && ok "accepts an indented footer" || no "accepts an indented footer"
# Null arm: whole-line anchoring must survive the whitespace tolerance, so a
# longer line merely CONTAINING the marker still cannot match.
{ echo "-- PostgreSQL database dump"; echo "CREATE TABLE t (id int);"
  echo "prefix -- PostgreSQL database dump complete suffix"; } > "$TMP/contain.sql"
pg_dump_is_complete "$TMP/contain.sql" && no "still rejects marker-as-substring on a longer line" \
                                       || ok "still rejects marker-as-substring on a longer line"

echo "== the guard is SILENT — it is a predicate, not a filter =="
# r4 raised this as a POSIX claim ("a record matching no rule is printed"). It is
# false — awk's default {print} applies to a PATTERN WITH NO ACTION, not to
# unmatched records — but the consequence if it were ever true is severe enough
# to pin: backup.sh runs from cron, so a chatty guard would mail the schema (and
# under --inserts, the whole database) into the nightly log. Asserted rather than
# argued, because "I reasoned it is fine" is not an instrument.
noise=$(pg_dump_is_complete "$TMP/t1.sql" 2>/dev/null)
[ -z "$noise" ] && ok "produces no stdout on an accepted dump" \
                || no "leaked $(printf '%s' "$noise" | wc -c) bytes of dump to stdout"
noise=$(pg_dump_is_complete "$TMP/trunc.sql" 2>/dev/null)
[ -z "$noise" ] && ok "produces no stdout on a rejected dump" \
                || no "leaked $(printf '%s' "$noise" | wc -c) bytes of dump to stdout"

echo "== a leading-dash filename is not parsed as an awk option =="
cp "$TMP/t1.sql" "$TMP/-dash.sql"
( cd "$TMP" && pg_dump_is_complete "./-dash.sql" ) && ok "accepts a ./-dash.sql path" \
                                                  || no "accepts a ./-dash.sql path"

echo "== non-letter psql trailers are footer-shaped too =="
# `\` + a letter was still a token freeze: it admits \unrestrict only because
# "u" is a letter, and would reject \; or \! (cage-match #157 r4, Tesla).
i=0
for meta in '\;' '\!' '\?' '\1'; do
  i=$((i + 1)); make_dump "$TMP/nl$i.sql" 1; printf '%s\n' "$meta" >> "$TMP/nl$i.sql"
  pg_dump_is_complete "$TMP/nl$i.sql" && ok "accepts non-letter trailer: $meta" \
                                      || no "accepts non-letter trailer: $meta"
done

echo "== SCHEMA GATE: a complete dump of an EMPTY database is refused =="
# The asymmetry this closes: restore.sh always refused these; backup.sh stored
# them. A dump of a wiped DB is perfectly complete and perfectly useless, and
# storing it overwrites the good copy while logging "Backup complete!".
{ echo "-- PostgreSQL database dump"; echo "SET statement_timeout = 0;"
  echo "--"; echo "-- PostgreSQL database dump complete"; echo "--"; } > "$TMP/empty-db.sql"
pg_dump_is_complete "$TMP/empty-db.sql" \
  && ok "an empty-DB dump is COMPLETE (so completeness alone cannot catch it)" \
  || no "expected the empty-DB dump to pass the completeness guard"
pg_dump_has_schema "$TMP/empty-db.sql" && no "refuses an empty-DB dump" \
                                       || ok "refuses an empty-DB dump"

echo "== SCHEMA GATE: a real dump is accepted =="
make_dump "$TMP/sch-real.sql" 1
pg_dump_has_schema "$TMP/sch-real.sql" && ok "accepts a dump with a real CREATE TABLE" \
                                       || no "accepts a dump with a real CREATE TABLE"

echo "== SCHEMA FORGERY: CREATE TABLE inside COPY data does not count =="
# Outline is a wiki, so a document body containing this line is content a user
# can type. The unanchored `grep -q 'CREATE TABLE'` this replaces counted it.
# RED-proven below: the old predicate accepts this schemaless dump.
{ echo "-- PostgreSQL database dump"
  echo "COPY d (body) FROM stdin;"
  echo "CREATE TABLE evil (x int);"
  echo "\\."
  echo "--"; echo "-- PostgreSQL database dump complete"; echo "--"; } > "$TMP/sch-forge.sql"
pg_dump_has_schema "$TMP/sch-forge.sql" && no "refuses a CREATE TABLE that only exists inside COPY data" \
                                        || ok "refuses a CREATE TABLE that only exists inside COPY data"
oldschema() { grep -q 'CREATE TABLE' "$1"; }
oldschema "$TMP/sch-forge.sql" && ok "REGRESSION PROOF: the old unanchored grep ACCEPTS the forged dump" \
                               || no "expected the old unanchored grep to accept the forged dump"

echo "== SCHEMA GATE: indented and IF NOT EXISTS forms still count =="
{ echo "  CREATE TABLE IF NOT EXISTS t (id int);"
  echo "--"; echo "-- PostgreSQL database dump complete"; echo "--"; } > "$TMP/sch-variant.sql"
pg_dump_has_schema "$TMP/sch-variant.sql" && ok "accepts an indented CREATE TABLE IF NOT EXISTS" \
                                          || no "accepts an indented CREATE TABLE IF NOT EXISTS"

echo "== SCHEMA GATE: a mid-line mention is not a declaration =="
{ echo "-- this dump will CREATE TABLE definitions later"
  echo "--"; echo "-- PostgreSQL database dump complete"; echo "--"; } > "$TMP/sch-comment.sql"
pg_dump_has_schema "$TMP/sch-comment.sql" && no "refuses a CREATE TABLE mentioned inside a comment" \
                                          || ok "refuses a CREATE TABLE mentioned inside a comment"
oldschema "$TMP/sch-comment.sql" && ok "REGRESSION PROOF: the old grep ACCEPTS the comment-only dump" \
                                 || no "expected the old grep to accept the comment-only dump"

echo "== SCHEMA GATE: missing/empty inputs are refused, not crashed on =="
pg_dump_has_schema "$TMP/nope.sql" && no "refuses a missing file" || ok "refuses a missing file"
: > "$TMP/sch-zero.sql"
pg_dump_has_schema "$TMP/sch-zero.sql" && no "refuses an empty file" || ok "refuses an empty file"
pg_dump_has_schema "" && no "refuses an empty arg" || ok "refuses an empty arg"

echo "== WRITE/READ ASYMMETRY LEDGER: the set of dumps backup stores and restore refuses =="
# The previous version of this test was VACUOUS and could never fail (found by
# Kelvin/gemini-2.5-pro reviewing this PR). It asserted `write=reject AND
# read=accept`, but restore.sh applies a SUPERSET of backup.sh's gates, so a
# write-reject always implies a read-reject. The condition was unreachable.
#
# The direction that can actually happen — and that matters — is the reverse:
# backup.sh STORES a dump restore.sh will categorically REFUSE, so the refusal
# surfaces mid-disaster. This test enumerates that set exactly.
#
# It is falsifiable in BOTH directions, which the old one was in neither:
#   - a NEW asymmetry appears  -> the set grows -> FAIL
#   - a known gap gets closed  -> the set shrinks -> FAIL (update the ledger)
# And the set being NON-EMPTY is its own positive control: the detector is
# demonstrably able to report something, so a future empty result means the
# gap closed, not that the check went blind.
#
# WHY THE REMAINING GAP IS NOT CLOSED HERE. restore.sh also refuses replay
# escapes (\connect, CREATE/DROP DATABASE). Moving that grep to the write side
# looks like the obvious symmetry fix and is a TRAP: the grep is case-insensitive
# and NOT COPY-aware, so an Outline document whose body line begins
# "create database ..." would match. On the READ side a false reject is safe —
# it refuses to restore and the live DB is untouched. On the WRITE side it
# DELETES the dump and fails the run, handing any wiki user a nightly backup
# outage. Verified: the grep does match such a COPY row; the live corpus has 0
# occurrences, so the surface is live but unoccupied. The escape guard needs the
# top-level COPY-aware parser tracked separately before it can be symmetrised.
mkfix() { printf -- "$2" > "$TMP/asym-$1.sql"; }  # $2 IS the format; no extra -- at the call site
mkfix real   '-- d\nCREATE TABLE t (id int);\nCOPY t (id) FROM stdin;\n1\n\\.\n--\n-- PostgreSQL database dump complete\n--\n'
mkfix empty  '-- d\nSET x = 0;\n--\n-- PostgreSQL database dump complete\n--\n'
mkfix escape '-- d\nCREATE TABLE t (id int);\n\\connect postgres\n--\n-- PostgreSQL database dump complete\n--\n'
mkfix dropdb '-- d\nCREATE TABLE t (id int);\nDROP DATABASE outline;\n--\n-- PostgreSQL database dump complete\n--\n'
# NB: fixtures are built with printf, never echo. Under zsh the builtin echo
# interprets backslash escapes, and `\c` means "stop output here" — which
# silently truncated a fixture during development and produced a confident
# wrong reading.
asym=""
for fx in real empty escape dropdb; do
  f="$TMP/asym-$fx.sql"
  # WRITE side = exactly what backup.sh enforces before storing.
  if pg_dump_is_complete "$f" && pg_dump_has_schema "$f"; then w=accept; else w=reject; fi
  if ( set +e; RESTORE_LIB_ONLY=1 . "$SCRIPT_DIR/restore.sh" >/dev/null 2>&1
       _validate_pg_dump test "$f" >/dev/null 2>&1 ); then r=accept; else r=reject; fi
  [ "$w" = accept ] && [ "$r" = reject ] && asym="$asym $fx"
done
asym=${asym# }
[ "$asym" = "escape dropdb" ] \
  && ok "write/read asymmetry is exactly the known escape-guard gap: $asym" \
  || no "write/read asymmetry ledger changed — expected 'escape dropdb', got '$asym'"
# Positive control on the detector itself: the schema fixture must NOT be in the
# set, and the set must be non-empty. An empty set here would mean either the
# gap closed or the detector went blind, and those must not look alike.
[ -n "$asym" ] && ok "asymmetry detector is live (non-empty set proves it can report)" \
               || no "asymmetry detector returned an empty set — closed gap, or blind check?"
case " $asym " in *" empty "*) no "the SCHEMA asymmetry is back — this PR regressed";; *) ok "the schema asymmetry this PR closes stays closed";; esac

echo "== the guard behaves identically across awk dialects =="
# This check exists because the guard moved completeness off `tail` + `grep -F`
# (byte-identical everywhere) onto awk, so the awk DIALECT is now part of the
# contract (cage-match #157 r2, Tesla). The production box is Ubuntu, whose
# /usr/bin/awk is mawk; CI is ubuntu-latest; a developer's mac is BSD awk. A
# construct that silently behaves differently on one of them means every dump
# reads as junk and the caller deletes it.
# Re-runs THIS ENTIRE FILE with each available awk shadowed onto PATH. The child
# sets PG_GUARD_DIALECT_CHILD so it skips this section rather than recursing.
if [ -z "${PG_GUARD_DIALECT_CHILD:-}" ]; then
  swept=0
  for a in mawk gawk busybox; do
    command -v "$a" >/dev/null 2>&1 || continue
    d=$(mktemp -d)
    if [ "$a" = busybox ]; then printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$d/awk"; chmod +x "$d/awk"
    else ln -sf "$(command -v "$a")" "$d/awk"; fi
    if PG_GUARD_DIALECT_CHILD=1 PATH="$d:$PATH" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
      ok "full suite passes under $a"; swept=$((swept + 1))
    else
      no "full suite FAILS under $a — the guard depends on an awk extension"
    fi
    rm -rf "$d"
  done
  # Silence must not read as success: if no alternate awk was installed, say so
  # rather than letting an unswept run look like a clean sweep.
  [ "$swept" -gt 0 ] || printf '  \033[1;33m--\033[0m no alternate awk installed (mawk/gawk/busybox) — dialect sweep did NOT run\n'
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
