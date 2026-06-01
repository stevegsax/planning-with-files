#!/usr/bin/env bash
# stop-gate.sh — the Stop hook. Keeps the autonomous loop running until the
# acceptance gate is GREEN, while honoring an explicit human-escalation request,
# distinguishing infrastructure failures from a red gate, and bounding the loop.
#
# Wired via a project .claude/settings.json Stop hook by the run harness — NOT by
# the skill itself — so it only gates real experiment runs.
#
# Decision logic on each stop attempt:
#   - not in an experiment (no PWFG_PLAN)  -> allow stop
#   - BLOCKED marker present (escalated)   -> allow stop  (escalate-and-wait)
#   - verify-all GREEN                     -> allow stop  (done)
#   - verify-all ERROR (infra)             -> write BLOCKED naming the failure, allow stop
#   - block count >= cap                   -> write BLOCKED, allow stop (bounded)
#   - otherwise (RED)                      -> emit decision:block, continue
#
# We deliberately do NOT gate on the stdin `stop_hook_active` flag: this loop is
# meant to block repeatedly until green. The block-counter + the run's
# --max-turns are the real runaway guards, and the counter fails SAFE (forces
# escalation) on any corrupt/garbage state. Assumes a single Stop writer per run
# dir (true for one `claude -p` session).

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"
pwfg_need jq

# Drain the hook's stdin JSON, but never block on a terminal / never-closing fd.
[ -t 0 ] || cat >/dev/null 2>&1 || true

[ -n "${PWFG_PLAN:-}" ] || exit 0   # not an experiment -> never block

sd="$(pwfg_state_dir)"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

[ -f "$sd/BLOCKED" ] && exit 0       # escalate-and-wait

"$DIR/verify-all.sh" >"$sd/logs/_gate.txt" 2>&1
gate_rc=$?
case "$gate_rc" in
  0) exit 0 ;;   # GREEN -> done
  2)             # ERROR -> infra failure, escalate with the real reason
    {
      printf 'reason: gate could not run (infrastructure error). The agent code may be fine.\n'
      printf 'at: %s\n' "$(now)"
      printf '%s\n' '--- gate output (tail) ---'
      tail -n 12 "$sd/logs/_gate.txt"
    } >"$sd/BLOCKED"
    exit 0
    ;;
esac

# Checkpoint mode (used by the orchestrator): if a NEW phase has gone green since
# the session baseline, allow the session to stop here so the orchestrator can
# restart with a fresh context window. verify-all just refreshed the cache.
if [ "${PWFG_STOP_AT_CHECKPOINT:-0}" = 1 ] && [ -f "$sd/session_baseline.json" ]; then
  base="$(jq -r '.[]?' "$sd/session_baseline.json" 2>/dev/null | sort)"
  cur="$(pwfg_green_ids | sort)"
  if [ -n "$(comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$cur") | sed '/^$/d')" ]; then
    exit 0   # a checkpoint was reached -> allow stop
  fi
fi

# RED — bounded-block guard that FAILS SAFE on garbage.
loop="$sd/loop.json"
jq -e . "$loop" >/dev/null 2>&1 || printf '{"blocks":0}\n' >"$loop"
blocks="$(jq -r '.blocks // 0' "$loop" 2>/dev/null)"
max="${PWFG_MAX_BLOCKS:-40}"
case "$blocks" in ''|*[!0-9]*) blocks="$max" ;; esac   # non-numeric -> force the cap
case "$max" in ''|*[!0-9]*) max=40 ;; esac

if [ "$blocks" -ge "$max" ]; then
  {
    printf 'reason: auto-escalation — max blocks (%s) reached without a green gate\n' "$max"
    printf 'at: %s\n' "$(now)"
  } >"$sd/BLOCKED"
  exit 0
fi

tmp="$(mktemp)"
if jq '.blocks = (.blocks + 1)' "$loop" >"$tmp" 2>/dev/null; then
  mv "$tmp" "$loop"
else
  rm -f "$tmp"
  # Counter update failed (corrupt state). Fail safe: escalate rather than loop.
  { printf 'reason: auto-escalation — loop counter unwritable\n'; printf 'at: %s\n' "$(now)"; } >"$sd/BLOCKED"
  exit 0
fi

failing="$(pwfg_failing_ids)"
guidance="Run verify-task.sh <phase-id> to see failing assertions, fix the code in the workspace, and continue. Do NOT edit the locked tests or status files. If stuck after three distinct attempts, run escalate.sh \"<reason>\"."
ctx="Acceptance gate is RED. Failing/incomplete phases: ${failing:-unknown}. ${guidance}"

# Carry the guidance in BOTH reason (shown to the user) and additionalContext
# (intended for the model) so it lands regardless of which the runtime surfaces.
jq -cn --arg reason "Gate is RED — failing: ${failing:-unknown}. ${guidance}" --arg ctx "$ctx" '{
  decision: "block",
  reason: $reason,
  hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}
}'
exit 0
