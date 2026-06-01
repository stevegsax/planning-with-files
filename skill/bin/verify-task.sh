#!/usr/bin/env bash
# verify-task.sh <phase-id> — run ONE phase's proof for fast feedback.
#
# VERIFIES (runs the locked proof command); it never SETS status from agent
# input. Updates the advisory status cache. Exit 0 on pass, 1 on fail.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

[ $# -ge 1 ] || pwfg_die "usage: verify-task.sh <phase-id>"
id="$1"
pwfg_validate_plan
pwfg_phase_exists "$id" || pwfg_die "unknown phase: $id (known: $(pwfg_phase_ids | paste -sd' ' -))"

if pwfg_run_proof "$id"; then
  pwfg_status_set "$id" pass
  printf 'PASS  %s\n' "$id"
  exit 0
else
  rc=$?
  pwfg_status_set "$id" fail
  log="$(pwfg_state_dir)/logs/$id.txt"
  printf 'FAIL  %s  (exit %d)  log: %s\n' "$id" "$rc" "$log"
  tail -n 20 "$log" | awk '{print "    " $0}'
  exit 1
fi
