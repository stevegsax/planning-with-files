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

case "${PWFG_LAST_SUBTYPE:-unknown}" in
  success)         why="stopped cleanly (completed a checkpoint, or had nothing left it could do)";;
  error_max_turns) why="hit the per-session turn cap mid-phase (context bound) — partial work may be on disk";;
  unknown)         why="ended for an unrecorded reason";;
  *)               why="ended with subtype=${PWFG_LAST_SUBTYPE}";;
esac

{
  printf '# Handoff — %s\n\n' "$(jq -r '.name' "$(pwfg_plan_path)")"
  printf 'Updated: %s   Session: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PWFG_SESSION_N:-?}"
  printf 'Previous session %s.\n\n' "$why"

  printf '## Verified status (GROUND TRUTH — run verify-all.sh to confirm; do not trust prose)\n'
  printf -- '- GREEN, do not redo: %s\n' "${green:-none}"
  printf -- '- REMAINING: %s\n' "${remaining:-none}"
  printf -- '- Last checkpoint commit: %s\n\n' "$last_commit"

  printf '## Focus for this session\n'
  printf -- '- Work this phase next: %s\n' "${next:-none — gate may be green}"
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
