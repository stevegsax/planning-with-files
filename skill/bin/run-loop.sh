#!/usr/bin/env bash
# run-loop.sh — outer orchestrator for context-bounded autonomous runs.
#
# Launches a sequence of FRESH, bounded `claude -p` sessions until the gate is
# green, the loop stalls, or the budget is spent. Each session sheds its context;
# continuity lives on disk (locked plan, derived status, git checkpoints,
# HANDOFF.md). It never edits the locked plan: a stuck/too-big phase escalates to
# a human to re-author it.
#
# Per-session end is read from `claude -p --output-format json` .subtype:
#   success           -> completed a checkpoint or stopped cleanly
#   error_max_turns   -> hit the turn cap mid-phase (context bound)
#   error_during_...  -> a real session error -> escalate
#
# Env (with defaults):
#   PWFG_PLAN/WORKSPACE/STATE_DIR  (required; as for the other tools)
#   PWFG_TURNS_PER_SESSION=12   PWFG_MAX_SESSIONS=10   PWFG_STALL_LIMIT=2
#   PWFG_MODEL=sonnet           PWFG_GIT_CHECKPOINTS=1 PWFG_STOP_AT_CHECKPOINT=1
#   PWFG_LAUNCH_CMD  (test seam: a command run instead of claude; must print JSON
#                     with a .subtype field and may mutate the workspace)

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"
pwfg_need jq; pwfg_need git

: "${PWFG_TURNS_PER_SESSION:=12}"
: "${PWFG_MAX_SESSIONS:=10}"
: "${PWFG_STALL_LIMIT:=2}"
: "${PWFG_MODEL:=sonnet}"
: "${PWFG_GIT_CHECKPOINTS:=1}"

ws="$(pwfg_workspace)"; sd="$(pwfg_state_dir)"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[run-loop] %s\n' "$*"; }
escalate() { { printf 'reason: %s\n' "$1"; printf 'at: %s\n' "$(now)"; shift; for l in "$@"; do printf '%s\n' "$l"; done; } >"$sd/BLOCKED"; }

launch() {  # $1 = prompt -> prints session JSON ({.subtype: ...})
  if [ -n "${PWFG_LAUNCH_CMD:-}" ]; then
    PWFG_PROMPT="$1" bash -c "$PWFG_LAUNCH_CMD"
  else
    ( cd "$ws" && claude -p "$1" \
        --model "$PWFG_MODEL" \
        --max-turns "$PWFG_TURNS_PER_SESSION" \
        --dangerously-skip-permissions \
        --output-format json )
  fi
}

git_checkpoint() {  # $1 = message
  [ "$PWFG_GIT_CHECKPOINTS" = 1 ] || return 0
  git -C "$ws" add -A >/dev/null 2>&1
  git -C "$ws" -c user.name=pwfg -c user.email=pwfg@local commit -q -m "$1" >/dev/null 2>&1 || true
}

build_prompt() {
  local green remaining
  green="$(pwfg_green_ids | paste -sd, -)"
  remaining="$(pwfg_remaining_ids | paste -sd, -)"
  cat <<EOF
Resuming an autonomous, test-gated task in a FRESH session — your context is
empty and all memory is on disk. Read HANDOFF.md and the locked plan first.

Verified GREEN (do not redo): ${green:-none}
Remaining: ${remaining:-none}

Implement the next remaining phase as far as you can. Trust verify-all for what is
actually done — not any prose summary. Tools:
  verify one phase : $DIR/verify-task.sh <phase-id>
  full gate        : $DIR/verify-all.sh
  escalate         : $DIR/escalate.sh "<reason>"
Do not edit the locked tests/plan or anything in the harness state dir. If you are
stuck after three distinct attempts on the same problem, escalate.
EOF
}

# --- init (once) ---
pwfg_validate_plan_full
pwfg_status_init
rm -f "$sd/BLOCKED"; printf '{"blocks":0}\n' >"$sd/loop.json"
[ -f "$ws/progress.md" ] || printf '# Progress log\n\n' >"$ws/progress.md"
if [ "$PWFG_GIT_CHECKPOINTS" = 1 ] && [ ! -d "$ws/.git" ]; then
  git -C "$ws" init -q
  git_checkpoint "initial: task workspace"
fi

session=0; stall=0; total_cost=0
while :; do
  session=$((session + 1))
  if [ "$session" -gt "$PWFG_MAX_SESSIONS" ]; then
    escalate "budget — max sessions ($PWFG_MAX_SESSIONS) reached without a green gate"
    log "BUDGET reached"; break
  fi

  before_green="$(pwfg_green_ids | sort)"
  pwfg_green_ids | jq -R . | jq -s 'map(select(length > 0))' >"$sd/session_baseline.json"
  printf '{"blocks":0}\n' >"$sd/loop.json"

  log "session $session start (green: $(printf '%s' "$before_green" | paste -sd',' -))"
  session_json="$(launch "$(build_prompt)" 2>/dev/null || true)"
  subtype="$(printf '%s' "$session_json" | jq -r '.subtype // "unknown"' 2>/dev/null || echo unknown)"
  sid="$(printf '%s' "$session_json" | jq -r '.session_id // empty' 2>/dev/null || true)"
  cost="$(printf '%s' "$session_json" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)"
  total_cost="$(awk "BEGIN{printf \"%.4f\", ${total_cost:-0} + ${cost:-0}}" 2>/dev/null || echo "$total_cost")"
  log "session $session end: subtype=$subtype  cost=\$${cost}  (total \$${total_cost})"

  "$DIR/verify-all.sh" >"$sd/logs/_gate.txt" 2>&1; gate_rc=$?
  after_green="$(pwfg_green_ids | sort)"
  new_green="$(comm -13 <(printf '%s\n' "$before_green") <(printf '%s\n' "$after_green") | sed '/^$/d')"

  if [ -n "$new_green" ]; then
    stall=0
    git_checkpoint "checkpoint: $(printf '%s' "$new_green" | paste -sd',' -) (session $session)"
    log "checkpoint: $(printf '%s' "$new_green" | paste -sd',' -)"
  else
    stall=$((stall + 1))
    log "no new green (stall $stall/$PWFG_STALL_LIMIT)"
  fi

  if [ "$gate_rc" -eq 0 ]; then
    rm -f "$sd/BLOCKED"; log "GATE GREEN — done"; break
  fi
  if [ -f "$sd/BLOCKED" ]; then
    log "agent escalated (BLOCKED) — human needed"; break
  fi
  if [ "$gate_rc" -eq 2 ]; then
    escalate "infrastructure error running the gate — see _gate.txt" "$(tail -n 12 "$sd/logs/_gate.txt")"
    log "INFRA error — human needed"; break
  fi
  if [ "$subtype" = "error_during_execution" ] || [ "$subtype" = "unknown" ]; then
    escalate "session ended with error subtype=$subtype"
    log "session ERROR ($subtype) — human needed"; break
  fi
  if [ "$stall" -ge "$PWFG_STALL_LIMIT" ]; then
    stuck="$(pwfg_remaining_ids | head -1)"
    escalate "no progress in $PWFG_STALL_LIMIT consecutive sessions on phase '$stuck'" \
      "Each session ended before reaching a checkpoint. Likely cause: the per-session" \
      "turn cap (PWFG_TURNS_PER_SESSION=$PWFG_TURNS_PER_SESSION) is too low to cover a" \
      "fresh session's orientation PLUS real progress, OR the phase is genuinely too" \
      "large for one context window." \
      "ACTION (human): raise PWFG_TURNS_PER_SESSION, or re-author the LOCKED plan to" \
      "split this phase into smaller, independently-gated phases. The loop does neither." \
      "stuck-phase: $stuck"
    log "STALL — human needed (raise the turn cap or split the phase)"; break
  fi

  PWFG_LAST_SUBTYPE="$subtype" PWFG_SESSION_N="$session" "$DIR/handoff.sh" >/dev/null
  PWFG_SESSION_ID="$sid" "$DIR/handoff-narrate.sh" || true
done

# --- final report ---
echo
if "$DIR/verify-all.sh" >/dev/null 2>&1; then
  echo "RESULT: GREEN — completed in $session session(s)."
elif [ -f "$sd/BLOCKED" ]; then
  echo "RESULT: HUMAN NEEDED —"; awk '{print "  " $0}' "$sd/BLOCKED"
else
  echo "RESULT: INCOMPLETE (sessions=$session)."
fi
printf 'Total session cost: $%s\n' "$total_cost"
"$DIR/plan-status.sh" 2>/dev/null || true
