#!/usr/bin/env bash
# handoff.sh — regenerate a bounded, fact-anchored HANDOFF.md for the next
# session. Deterministic: the verified status, the next phase, the last failing
# log, and the last checkpoint commit are GROUND TRUTH (from the gate/status/git);
# the agent's own progress notes are included as ADVISORY only. Rewritten (not
# appended) each session so it never grows into the context problem it solves.
#
# Context from the orchestrator (optional): PWFG_LAST_SUBTYPE, PWFG_SESSION_N.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

ws="$(pwfg_workspace)"; sd="$(pwfg_state_dir)"
hf="$ws/HANDOFF.md"

green="$(pwfg_green_ids | paste -sd, -)"
remaining="$(pwfg_remaining_ids | paste -sd, -)"
next="$(pwfg_remaining_ids | head -1)"
last_commit="$( (cd "$ws" && git log -1 --format='%h %s' 2>/dev/null) || echo 'none' )"

# Derived GROUND-TRUTH file pointers for the next phase (no LLM; recomputed each
# session from the locked plan + proof + workspace). Guarded so it cannot print a
# wrong-but-trusted pointer: EDIT lists only files that actually exist on disk.
edit_files=""; prove_files=""; test_imports=""
if [ -n "${next:-}" ]; then
  _desc="$(pwfg_phase_field "$next" description)"
  _proof="$(pwfg_phase_field "$next" proof)"
  _workdir="$(pwfg_workdir)"
  for _f in $(printf '%s\n' "$_desc" | grep -oE '[A-Za-z_][A-Za-z0-9_/]*\.py' | sort -u); do
    [ -f "$ws/$_f" ] && edit_files="${edit_files:+$edit_files }$_f"
  done
  prove_files="$(printf '%s\n' "$_proof" | grep -oE '[A-Za-z_][A-Za-z0-9_/.-]*\.py' | sort -u | paste -sd' ' -)"
  _first="$(printf '%s' "$prove_files" | awk '{print $1}')"
  if [ -n "$_first" ] && [ -f "$_workdir/$_first" ]; then
    test_imports="$(grep -E '^from ' "$_workdir/$_first" 2>/dev/null | grep -vE 'pytest|hypothesis' | head -8 || true)"
  fi
fi

case "${PWFG_LAST_SUBTYPE:-unknown}" in
  success)         why="stopped cleanly (completed a checkpoint, or had nothing left it could do)";;
  error_max_turns) why="hit the per-session turn cap mid-phase (context bound) — partial work may be on disk";;
  unknown)         why="ended for an unrecorded reason";;
  *)               why="ended with subtype=${PWFG_LAST_SUBTYPE}";;
esac

{
  printf '# Handoff — %s\n\n' "$(jq -r '.name' "$(pwfg_plan_path)")"
  printf 'Updated: %s   Session: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PWFG_SESSION_N:-?}"
  if [ "${PWFG_SESSION_N:-0}" = "0" ]; then
    printf 'Initial handoff — no prior session yet.\n\n'
  else
    printf 'Previous session %s.\n\n' "$why"
  fi

  printf '## Verified status (GROUND TRUTH — run verify-all.sh to confirm; do not trust prose)\n'
  printf -- '- GREEN, do not redo: %s\n' "${green:-none}"
  printf -- '- REMAINING: %s\n' "${remaining:-none}"
  printf -- '- Last checkpoint commit: %s\n\n' "$last_commit"

  printf '## Focus for this session\n'
  printf -- '- Work this phase next: %s\n' "${next:-none — gate may be green}"
  if [ -n "${next:-}" ]; then
    printf -- '- Files for this phase (start here; read elsewhere only if a needed symbol is missing):\n'
    if [ -n "$edit_files" ]; then
      printf -- '    EDIT: %s\n' "$edit_files"
    else
      printf -- '    EDIT: (see the phase description)\n'
    fi
    [ -n "$prove_files" ] && printf -- '    PROVE WITH: %s\n' "$prove_files"
    if [ -n "$test_imports" ]; then
      printf -- '    the proof tests import (the contract types to satisfy):\n'
      printf '%s\n' "$test_imports" | awk '{print "      " $0}'
    fi
  fi
  if [ -n "${next:-}" ] && [ -f "$sd/logs/$next.txt" ]; then
    printf -- '- Last failing output for %s (tail):\n' "$next"
    tail -n 12 "$sd/logs/$next.txt" | awk '{print "      " $0}'
  fi
  printf '\n'

  printf '## Prior agent notes (ADVISORY — verify against the gate before relying on these)\n'
  if [ -f "$ws/progress.md" ]; then
    tail -n 25 "$ws/progress.md" | awk '{print "  " $0}'
  else
    printf '  (none)\n'
  fi
} >"$hf"

printf 'handoff written: %s\n' "$hf"
