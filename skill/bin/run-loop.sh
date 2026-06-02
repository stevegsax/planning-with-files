#!/usr/bin/env bash
# run-loop.sh — outer orchestrator for context-bounded autonomous runs.
#
# Launches a sequence of FRESH, bounded `claude -p` sessions until the gate is
# green, the loop stalls, or the budget is spent. Each session sheds its context;
# continuity lives on disk (locked plan, derived status, git checkpoints,
# HANDOFF.md). It never edits the locked plan: a stuck/too-big phase escalates to
# a human to re-author it.
#
# Per-session end is read from `claude -p --output-format json` .subtype, plus the
# launcher's exit code:
#   success            -> completed a checkpoint or stopped cleanly
#   error_max_turns    -> hit the turn cap mid-phase (context bound) -> bump / stall
#   error_during_...   -> the session CRASHED -> roll back + retry fresh (bounded),
#                         then escalate as an environment/agent fault
#   (killed by timeout) -> the session WEDGED -> roll back + bump budget / stall,
#                         then escalate (a slow/too-big phase is diagnosed as a stall)
#   unknown (exit 0)   -> ended for an unrecorded reason; TRUST THE GATE (no rollback)
#
# Auto-recovery is the disposable design's natural self-heal: a crashed or wedged
# session is shed and a fresh one resumes from the last green checkpoint on disk.
# PWFG_MAX_SESSIONS is the ultimate backstop — every retry counts as a session, so
# the loop always terminates regardless of the recovery/stall counters.
#
# Env (with defaults):
#   PWFG_PLAN/WORKSPACE/STATE_DIR  (required; as for the other tools)
#   PWFG_TURNS_PER_SESSION=12   PWFG_MAX_SESSIONS=10   PWFG_STALL_LIMIT=2
#   PWFG_MODEL=sonnet           PWFG_GIT_CHECKPOINTS=1 PWFG_STOP_AT_CHECKPOINT=1
#   PWFG_RECOVER_LIMIT=2        PWFG_RECOVER_RESET=1   PWFG_SESSION_TIMEOUT=3600
#   PWFG_LAUNCH_CMD  (test seam: a command run instead of claude; must print JSON
#                     with a .subtype field and may mutate the workspace)

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"
pwfg_need jq; pwfg_need git

: "${PWFG_MAX_SESSIONS:=10}"
: "${PWFG_STALL_LIMIT:=2}"
: "${PWFG_MODEL:=sonnet}"
: "${PWFG_GIT_CHECKPOINTS:=1}"
# Turn budget scales with progress (see pwfg_session_budget). PWFG_TURNS_PER_SESSION,
# if set, overrides with a fixed budget and disables scaling.
: "${PWFG_TURNS_BASE:=12}"
: "${PWFG_TURNS_PER_PHASE:=3}"
: "${PWFG_TURNS_MAX:=24}"
: "${PWFG_TURNS_BUMP:=4}"
# Auto-recovery of crashed/wedged sessions.
: "${PWFG_RECOVER_LIMIT:=2}"      # consecutive crash retries before escalating
: "${PWFG_RECOVER_RESET:=1}"      # 1 = roll the workspace back to the last checkpoint on a crash/wedge
: "${PWFG_SESSION_TIMEOUT:=3600}" # per-session wall clock (seconds); 0 disables wedge detection
TIMEOUT_BIN=""                    # resolved at init to timeout|gtimeout|"" (none)

ws="$(pwfg_workspace)"; sd="$(pwfg_state_dir)"
# Canonicalize so the state-dir-inside-workspace prefix test (gitignore seeding) is
# robust to `./`, `..`, and trailing slashes — a mis-detection there would let the
# harness state cache be tracked and then churned by a rollback.
ws="$(cd "$ws" 2>/dev/null && pwd -P || printf '%s' "$ws")"
sd="$(cd "$sd" 2>/dev/null && pwd -P || printf '%s' "$sd")"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '[run-loop] %s\n' "$*"; }
escalate() { { printf 'reason: %s\n' "$1"; printf 'at: %s\n' "$(now)"; shift; for l in "$@"; do printf '%s\n' "$l"; done; } >"$sd/BLOCKED"; }

launch() {  # $1 = prompt, $2 = max-turns -> prints session JSON ({.subtype: ...})
  if [ -n "${PWFG_LAUNCH_CMD:-}" ]; then
    # Expose BOTH the prompt and the computed (progress-scaled) turn budget to the
    # custom launcher, so an out-of-process launcher (e.g. the box's sudo->agent
    # claude wrapper) can honor the same budget the default path uses.
    if [ -n "$TIMEOUT_BIN" ]; then
      PWFG_PROMPT="$1" PWFG_MAX_TURNS="$2" "$TIMEOUT_BIN" -k 5 "$PWFG_SESSION_TIMEOUT" bash -c "$PWFG_LAUNCH_CMD"
    else
      PWFG_PROMPT="$1" PWFG_MAX_TURNS="$2" bash -c "$PWFG_LAUNCH_CMD"
    fi
  else
    if [ -n "$TIMEOUT_BIN" ]; then
      ( cd "$ws" && "$TIMEOUT_BIN" -k 5 "$PWFG_SESSION_TIMEOUT" claude -p "$1" \
          --model "$PWFG_MODEL" --max-turns "$2" \
          --dangerously-skip-permissions --output-format json )
    else
      ( cd "$ws" && claude -p "$1" \
          --model "$PWFG_MODEL" --max-turns "$2" \
          --dangerously-skip-permissions --output-format json )
    fi
  fi
}

git_checkpoint() {  # $1 = message
  [ "$PWFG_GIT_CHECKPOINTS" = 1 ] || return 0
  git -C "$ws" add -A >/dev/null 2>&1
  git -C "$ws" -c user.name=pwfg -c user.email=pwfg@local commit -q -m "$1" >/dev/null 2>&1 || true
}

# Roll a crashed/wedged session's UNCOMMITTED work back to the last green checkpoint
# so a fresh session resumes from known-good state (committed checkpoints are kept).
# Forensics go to the STATE dir (a sibling of the workspace, safe from the rollback).
# Prefers a recoverable `git stash`; the destructive fallback refuses to delete any
# untracked file it could not first archive. Sets `did_rollback=1` if it actually
# rolled work back. Returns 3 if it cannot leave a clean tree without losing work
# (caller must escalate, not retry).
recover_workspace() {  # $1 = session number, $2 = kind label
  local n="$1" kind="$2" rdir="$sd/recovery" rlog="$sd/logs/recovery.log" f archive_ok
  mkdir -p "$rdir"
  printf '=== session %s %s @ %s (subtype=%s rc=%s) ===\n' \
    "$n" "$kind" "$(now)" "$subtype" "$launch_rc" >>"$rlog"
  { [ "$PWFG_RECOVER_RESET" = 1 ] && [ "$PWFG_GIT_CHECKPOINTS" = 1 ] && [ -d "$ws/.git" ]; } \
    || { log "kept the $kind session's workspace as-is (no rollback)"; return 0; }
  [ -n "$(git -C "$ws" status --porcelain 2>/dev/null)" ] || return 0  # nothing to roll back

  git -C "$ws" status --porcelain >>"$rlog" 2>&1
  git -C "$ws" -c core.pager=cat diff HEAD >"$rdir/session-$n.diff" 2>/dev/null || true

  if git -C "$ws" -c user.name=pwfg -c user.email=pwfg@local \
       stash push --include-untracked -q -m "pwfg-recovery: session $n ($kind)" >/dev/null 2>&1; then
    did_rollback=1
    printf 'rolled back via: %s\n' "$(git -C "$ws" stash list 2>/dev/null | head -1)" >>"$rlog"
    log "rolled the $kind session back to the last checkpoint (git stash; forensics in $rdir)"
  else
    # Stash failed. Archive every untracked file BEFORE the destructive reset+clean.
    # (Tracked edits are already captured in session-$n.diff and recoverable from it.)
    # If ANY untracked file cannot be archived, do NOT destroy the tree — leave it
    # intact and signal the caller to escalate, so a human can recover it by hand.
    # Use process substitution (not a `| while` subshell) so archive_ok survives.
    archive_ok=1
    while IFS= read -r -d '' f; do
      mkdir -p "$rdir/session-$n-untracked/$(dirname "$f")"
      cp "$ws/$f" "$rdir/session-$n-untracked/$f" 2>/dev/null || archive_ok=0
    done < <(git -C "$ws" ls-files --others --exclude-standard -z 2>/dev/null)
    if [ "$archive_ok" -ne 1 ]; then
      printf 'stash failed AND could not archive all untracked files — tree left INTACT for a human\n' >>"$rlog"
      log "could NOT safely roll back the $kind session (stash + archive both failed) — leaving the tree intact"
      return 3
    fi
    git -C "$ws" reset -q --hard HEAD >/dev/null 2>&1
    git -C "$ws" clean -fdq >/dev/null 2>&1
    did_rollback=1
    printf 'stash failed; hard-reset after archiving untracked to %s\n' "$rdir/session-$n-untracked" >>"$rlog"
    log "rolled the $kind session back to the last checkpoint (hard reset; archived to $rdir)"
  fi

  # A still-dirty tree must not silently poison the next fresh session.
  [ -z "$(git -C "$ws" status --porcelain 2>/dev/null)" ] || return 3
  return 0
}

build_prompt() {
  local green remaining
  green="$(pwfg_green_ids | paste -sd, -)"
  remaining="$(pwfg_remaining_ids | paste -sd, -)"
  cat <<EOF
Resuming an autonomous, test-gated task in a FRESH session — your context is
empty and all memory is on disk. Read HANDOFF.md and the locked plan first.
HANDOFF.md lists the exact files for this phase under "Files for this phase" —
start from those; read elsewhere only if a needed symbol isn't there.

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
# Keep harness/scratch artifacts OUT of git so a recovery rollback (stash / clean)
# can never delete or churn them, and so they survive across sessions on disk:
#   HANDOFF.md, progress.md  — regenerated/advisory, read from disk not git
#   the state dir, if it resolves INSIDE the workspace (the library default)
# This must happen before the first `git add -A`. Only the agent's gated CODE is
# committed in checkpoints, so a crash rollback sheds exactly that and nothing else.
if [ "$PWFG_GIT_CHECKPOINTS" = 1 ]; then
  [ -d "$ws/.git" ] || git -C "$ws" init -q
  for _g in "HANDOFF.md" "progress.md"; do
    grep -qxF "$_g" "$ws/.gitignore" 2>/dev/null || printf '%s\n' "$_g" >>"$ws/.gitignore"
  done
  case "$sd/" in
    "$ws/"*) _g="${sd#"$ws"/}/"
             grep -qxF "$_g" "$ws/.gitignore" 2>/dev/null || printf '%s\n' "$_g" >>"$ws/.gitignore" ;;
  esac
fi
# Seed an initial handoff so even session 1 gets the derived file pointers.
PWFG_SESSION_N=0 "$DIR/handoff.sh" >/dev/null
if [ "$PWFG_GIT_CHECKPOINTS" = 1 ] && ! git -C "$ws" rev-parse HEAD >/dev/null 2>&1; then
  git_checkpoint "initial: task workspace"
fi

# Resolve a wall-clock timeout binary for wedge detection (on by default).
if [ "$PWFG_SESSION_TIMEOUT" != 0 ]; then
  if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
  else
    log "PWFG_SESSION_TIMEOUT=${PWFG_SESSION_TIMEOUT}s requested but no timeout/gtimeout binary found — wedge detection DISABLED (a hung session will block the loop). Install coreutils, or set PWFG_SESSION_TIMEOUT=0 to silence this."
  fi
fi
[ -n "$TIMEOUT_BIN" ] && log "wedge detection on: each session capped at ${PWFG_SESSION_TIMEOUT}s wall clock (via $TIMEOUT_BIN)"

session=0; stall=0; total_cost=0; extra=0; recoveries=0
last_was_crash=0; last_was_wedge=0; last_kind=""
while :; do
  session=$((session + 1))
  if [ "$session" -gt "$PWFG_MAX_SESSIONS" ]; then
    if [ "$last_was_crash" -eq 1 ] || [ "$last_was_wedge" -eq 1 ]; then
      escalate "budget — max sessions ($PWFG_MAX_SESSIONS) reached; recent sessions ended abnormally (${last_kind})" \
        "This looks like a crash/wedge loop that ran out the session budget before the" \
        "recovery limit. It is likely an environment/agent fault, not a too-big phase." \
        "  recovery log:    $sd/logs/recovery.log" \
        "  recovery diffs:  $sd/recovery/" \
        "  last session:    $sd/logs/_session.txt (stderr: _session.err)"
    else
      escalate "budget — max sessions ($PWFG_MAX_SESSIONS) reached without a green gate"
    fi
    log "BUDGET reached"; break
  fi

  before_green="$(pwfg_green_ids | sort)"
  pwfg_green_ids | jq -R . | jq -s 'map(select(length > 0))' >"$sd/session_baseline.json"
  printf '{"blocks":0}\n' >"$sd/loop.json"

  green_count="$(pwfg_green_ids | wc -l | tr -d ' ')"
  turns="$(pwfg_session_budget "$green_count" "$extra")"
  log "session $session start (budget ${turns}t, green: $(printf '%s' "$before_green" | paste -sd',' -))"

  # Launch. Capture the launcher exit code on the VERY NEXT line (no `|| true`, no
  # intervening command) so a timeout's 124/137 survives for wedge classification.
  launch "$(build_prompt)" "$turns" >"$sd/logs/_session.txt" 2>"$sd/logs/_session.err"; launch_rc=$?
  session_json="$(cat "$sd/logs/_session.txt" 2>/dev/null || true)"
  # jq emits nothing (not the // default) on EMPTY/invalid input, so normalize to
  # "unknown"/0 explicitly — a silent crash leaves an empty stdout, and that must
  # still classify as unknown, not as "".
  subtype="$(printf '%s' "$session_json" | jq -r '.subtype // "unknown"' 2>/dev/null || echo unknown)"
  [ -n "$subtype" ] || subtype=unknown
  sid="$(printf '%s' "$session_json" | jq -r '.session_id // empty' 2>/dev/null || true)"
  cost="$(printf '%s' "$session_json" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)"
  [ -n "$cost" ] || cost=0
  total_cost="$(awk "BEGIN{printf \"%.4f\", ${total_cost:-0} + ${cost:-0}}" 2>/dev/null || echo "$total_cost")"

  # Classify an abnormal end. A wall-clock kill is a WEDGE (handled like no-progress,
  # so the budget can still grow and a too-big phase is diagnosed as a stall). A hard
  # error subtype, or a nonzero exit with no result JSON, is a CRASH. `unknown` with a
  # clean exit is NOT abnormal — trust the gate (no rollback).
  is_wedge=0; is_crash=0; crash_kind=""
  if [ -n "$TIMEOUT_BIN" ] && { [ "$launch_rc" -eq 124 ] || [ "$launch_rc" -eq 137 ]; }; then
    is_wedge=1; crash_kind="wedged (exceeded the ${PWFG_SESSION_TIMEOUT}s wall clock; killed)"
  else
    case "$subtype" in
      error_during_execution) is_crash=1; crash_kind="crashed (subtype=error_during_execution, rc=$launch_rc)" ;;
      unknown) if [ "$launch_rc" -ne 0 ]; then is_crash=1; crash_kind="crashed (no result JSON, rc=$launch_rc)"; fi ;;
    esac
  fi
  if [ "$is_wedge" -eq 1 ] || [ "$is_crash" -eq 1 ]; then
    log "session $session end: $crash_kind  cost=\$${cost}  (total \$${total_cost})"
  else
    log "session $session end: subtype=$subtype  rc=$launch_rc  cost=\$${cost}  (total \$${total_cost})"
  fi
  last_was_crash=$is_crash; last_was_wedge=$is_wedge; last_kind="${crash_kind:-subtype=$subtype}"

  "$DIR/verify-all.sh" >"$sd/logs/_gate.txt" 2>&1; gate_rc=$?
  after_green="$(pwfg_green_ids | sort)"
  new_green="$(comm -13 <(printf '%s\n' "$before_green") <(printf '%s\n' "$after_green") | sed '/^$/d')"

  # Commit any newly-green phase FIRST (so a rollback below can never lose it).
  if [ -n "$new_green" ]; then
    stall=0
    git_checkpoint "checkpoint: $(printf '%s' "$new_green" | paste -sd',' -) (session $session)"
    log "checkpoint: $(printf '%s' "$new_green" | paste -sd',' -)"
  fi

  # Shed a crashed/wedged session's uncommitted remainder before any retry.
  did_rollback=0
  if [ "$is_crash" -eq 1 ] || [ "$is_wedge" -eq 1 ]; then
    recover_workspace "$session" "$crash_kind"; recover_rc=$?
    if [ "$recover_rc" -eq 3 ]; then
      escalate "auto-recovery could not return the workspace to a clean checkpoint (${crash_kind})" \
        "Recovery could not roll the workspace back without risking uncommitted work" \
        "(git stash failed and not all files could be safely archived), so the tree was" \
        "left INTACT — launching a fresh session on it would resume from a corrupt state." \
        "ACTION (human): recover anything needed and clean the workspace by hand, then re-run." \
        "  recovery log: $sd/logs/recovery.log" \
        "  workspace:    $ws" \
        "stuck-phase: $(pwfg_remaining_ids | head -1)"
      log "RECOVERY could not clean the tree — human needed"; break
    fi
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

  # CRASH recovery: bounded fresh retries from the clean checkpoint, then escalate as
  # an environment/agent fault (distinct from a too-big-phase stall).
  if [ "$is_crash" -eq 1 ]; then
    if [ "$recoveries" -lt "$PWFG_RECOVER_LIMIT" ]; then
      recoveries=$((recoveries + 1))
      log "$crash_kind — auto-recovering (attempt $recoveries/$PWFG_RECOVER_LIMIT, fresh session from the last checkpoint)"
      PWFG_LAST_SUBTYPE="$subtype" PWFG_LAST_RECOVERED="$did_rollback" PWFG_SESSION_N="$session" "$DIR/handoff.sh" >/dev/null
      PWFG_SESSION_ID="$sid" "$DIR/handoff-narrate.sh" || true
      continue
    fi
    escalate "session repeatedly ended abnormally ($((recoveries + 1)) in a row: ${crash_kind})" \
      "Each retry started a FRESH session from the last green checkpoint and still failed" \
      "to end cleanly, so this is an environment or agent fault — NOT a too-big phase, and" \
      "re-authoring the plan will not help. A human should inspect the box/agent." \
      "  recovery log:    $sd/logs/recovery.log" \
      "  recovery diffs:  $sd/recovery/" \
      "  last session:    $sd/logs/_session.txt (stderr: _session.err)" \
      "  last gate:       $sd/logs/_gate.txt" \
      "stuck-phase: $(pwfg_remaining_ids | head -1)"
    log "CRASH — auto-recovery exhausted, human needed"; break
  fi

  # Reached only for a NON-crash session, so the consecutive-crash streak is broken.
  recoveries=0
  if [ -n "$new_green" ]; then
    : # progress already checkpointed above
  elif [ "$is_wedge" -eq 1 ] && [ -z "${PWFG_TURNS_PER_SESSION:-}" ] && [ "$turns" -lt "$PWFG_TURNS_MAX" ]; then
    extra=$((extra + PWFG_TURNS_BUMP))
    log "wedge with no progress — raising next session's budget by $PWFG_TURNS_BUMP (a bigger budget may clear it)"
  elif [ -z "${PWFG_TURNS_PER_SESSION:-}" ] && [ "$subtype" = "error_max_turns" ] && [ "$turns" -lt "$PWFG_TURNS_MAX" ]; then
    extra=$((extra + PWFG_TURNS_BUMP))
    log "no progress + hit the turn cap — raising next session's budget by $PWFG_TURNS_BUMP"
  else
    stall=$((stall + 1))
    log "no new green (stall $stall/$PWFG_STALL_LIMIT)"
  fi

  if [ "$stall" -ge "$PWFG_STALL_LIMIT" ]; then
    stuck="$(pwfg_remaining_ids | head -1)"
    if [ "$is_wedge" -eq 1 ] || [ "$last_was_wedge" -eq 1 ]; then
      escalate "no progress in $PWFG_STALL_LIMIT consecutive sessions on phase '$stuck' (sessions kept wedging)" \
        "Sessions kept exceeding the ${PWFG_SESSION_TIMEOUT}s wall clock with no progress, even" \
        "after the budget reached ${turns} turns. The agent may be wedging on this phase, or" \
        "the phase may be too large to finish within the wall clock." \
        "ACTION (human): raise PWFG_SESSION_TIMEOUT if sessions legitimately need longer, raise" \
        "PWFG_TURNS_MAX, or re-author the LOCKED plan to split this phase." \
        "  recovery log: $sd/logs/recovery.log" \
        "stuck-phase: $stuck"
    else
      escalate "no progress in $PWFG_STALL_LIMIT consecutive sessions on phase '$stuck'" \
        "The per-session budget reached ${turns} turns and the phase still did not" \
        "complete, so it is likely genuinely too large for one context window (the loop" \
        "already auto-raised the budget toward its max of ${PWFG_TURNS_MAX})." \
        "ACTION (human): re-author the LOCKED plan to split this phase into smaller," \
        "independently-gated phases (the loop will not), or raise PWFG_TURNS_MAX if you" \
        "believe more turns would finish it." \
        "stuck-phase: $stuck"
    fi
    log "STALL — human needed"; break
  fi

  # did_rollback is 1 when a wedge (or a non-fatal crash) just rolled the tree back,
  # so the next session is told its predecessor's uncommitted work was discarded.
  PWFG_LAST_SUBTYPE="$subtype" PWFG_LAST_RECOVERED="$did_rollback" PWFG_SESSION_N="$session" "$DIR/handoff.sh" >/dev/null
  PWFG_SESSION_ID="$sid" "$DIR/handoff-narrate.sh" || true
done

# --- final report ---
echo
if "$DIR/verify-all.sh" >/dev/null 2>&1; then
  echo "RESULT: GREEN — completed in $session session(s)."
  result_status=GREEN
elif [ -f "$sd/BLOCKED" ]; then
  echo "RESULT: HUMAN NEEDED —"; awk '{print "  " $0}' "$sd/BLOCKED"
  result_status=HUMAN_NEEDED
else
  echo "RESULT: INCOMPLETE (sessions=$session)."
  result_status=INCOMPLETE
fi
printf 'Total session cost: $%s\n' "$total_cost"
"$DIR/notify.sh" "$result_status" || true
"$DIR/plan-status.sh" 2>/dev/null || true
