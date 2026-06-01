#!/usr/bin/env bash
# escalate.sh "<reason>" — explicit, machine-detectable human handoff.
#
# Writes a BLOCKED marker. The Stop gate honors it and allows the session to end
# (or, in interactive use, to wait) so a human can intervene. Use only after the
# 3-strike protocol is exhausted.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

reason="${*:-no reason given}"
sd="$(pwfg_state_dir)"
{
  printf 'reason: %s\n' "$reason"
  printf 'at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$sd/BLOCKED"

echo "Escalation recorded. The Stop gate will allow this session to end so a human can step in."
