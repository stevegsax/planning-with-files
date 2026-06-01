#!/usr/bin/env bash
# init-session.sh — initialize harness state for a run.
#
# Validates the locked plan, resets the status cache and loop counter, clears any
# stale escalation, and seeds the agent's mutable progress log.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

pwfg_validate_plan_full
pwfg_status_init

sd="$(pwfg_state_dir)"
rm -f "$sd/BLOCKED"
printf '{"blocks":0}\n' >"$sd/loop.json"

ws="$(pwfg_workspace)"
prog="$ws/progress.md"
if [ ! -f "$prog" ]; then
  {
    echo "# Progress log"
    echo
    echo "Mutable scratch for the agent (recitation). The locked plan and tests are"
    echo "read-only; status is derived from the tests, never asserted here."
    echo
  } >"$prog"
fi

plan="$(pwfg_plan_path)"
printf 'Initialized: %s  (%s phases)\n' \
  "$(jq -r '.name' "$plan")" "$(pwfg_phase_ids | wc -l | tr -d ' ')"
pwfg_phase_ids | awk '{print "  - " $0}'
