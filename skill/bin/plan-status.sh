#!/usr/bin/env bash
# plan-status.sh — print the derived status (from the advisory cache).
#
# Cheap progress view for the agent and a future summarizer. This reads the
# CACHE and does not re-run anything; for an authoritative verdict use
# verify-all.sh.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

f="$(pwfg_status_file)"
if [ ! -f "$f" ]; then
  echo "status: not initialized — run init-session.sh"
  exit 0
fi

printf 'plan: %s   (cached; run verify-all.sh for an authoritative check)\n' \
  "$(jq -r '.plan' "$f")"
jq -r '.phases | to_entries[]
       | "  \(.value.result | ascii_upcase)\t\(.key)\t[\(.value.checked_at // "never")]"' \
  "$f" | column -t -s $'\t' 2>/dev/null || \
  jq -r '.phases | to_entries[] | "  \(.value.result | ascii_upcase)  \(.key)"' "$f"

sd="$(pwfg_state_dir)"
if [ -f "$sd/BLOCKED" ]; then
  echo "STATE: BLOCKED (escalated to human) —"
  awk '{print "  " $0}' "$sd/BLOCKED"
fi
