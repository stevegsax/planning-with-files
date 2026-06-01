#!/usr/bin/env bash
# verify-all.sh — the authoritative local gate.
#
# Runs EVERY phase's proof FRESH (never trusts the cache) so cross-phase
# regressions surface immediately. Updates the cache.
#
# Exit codes:
#   0  GREEN — every phase passes
#   1  RED   — at least one phase's tests failed
#   2  ERROR — a phase could not be run (tooling/interpreter missing: exit 126/127)
#
# The ERROR code lets the Stop gate distinguish "the agent's code is wrong" from
# "the gate could not run", instead of telling the agent to fix correct code.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

pwfg_validate_plan
[ -f "$(pwfg_status_file)" ] || pwfg_status_init

fail=0
infra=0
while IFS= read -r id; do
  pwfg_run_proof "$id"; rc=$?
  case "$rc" in
    0)
      pwfg_status_set "$id" pass
      printf 'PASS   %s\n' "$id"
      ;;
    126 | 127)
      infra=1
      printf 'ERROR  %s  (could not run: exit %d; see %s)\n' \
        "$id" "$rc" "$(pwfg_state_dir)/logs/$id.txt"
      ;;
    *)
      pwfg_status_set "$id" fail
      printf 'FAIL   %s  (log: %s)\n' "$id" "$(pwfg_state_dir)/logs/$id.txt"
      fail=1
      ;;
  esac
done < <(pwfg_phase_ids)

if [ "$infra" -eq 1 ]; then
  printf 'GATE: ERROR — could not run the gate (infrastructure)\n'
  exit 2
fi
if [ "$fail" -eq 0 ]; then
  printf 'GATE: GREEN — all phases pass\n'
  exit 0
fi
printf 'GATE: RED\n'
exit 1
