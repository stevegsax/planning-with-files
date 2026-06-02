#!/usr/bin/env bash
# test_orchestrator.sh — deterministic self-test for the multi-session
# orchestrator (skill/bin/run-loop.sh). No LLM and no API: a fake launcher is
# injected via PWFG_LAUNCH_CMD to simulate agent sessions, so the orchestrator's
# decision logic (checkpoints, stall->human, budget, .subtype branching) is
# exercised against a trivial file-marker plan. Run from the repo root.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/skill"
FIXTURE="$REPO/tests/fixtures/orchestrator/plan.json"

PASS=0; FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() { [ "$2" = "$3" ] && ok "$1" || { no "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
assert_ok() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
assert_no() { if eval "$2" >/dev/null 2>&1; then no "$1"; else ok "$1"; fi; }

# --- fake launchers (the dependency-injection seam) ---
BIN="$(mktemp -d)"
cat >"$BIN/progress" <<'EOF'
#!/usr/bin/env bash
for n in 1 2 3; do
  [ -f "$PWFG_WORKSPACE/step$n.done" ] || { : >"$PWFG_WORKSPACE/step$n.done"; break; }
done
printf '{"subtype":"success"}\n'
EOF
cat >"$BIN/progress_maxturns" <<'EOF'
#!/usr/bin/env bash
for n in 1 2 3; do
  [ -f "$PWFG_WORKSPACE/step$n.done" ] || { : >"$PWFG_WORKSPACE/step$n.done"; break; }
done
printf '{"subtype":"error_max_turns"}\n'
EOF
cat >"$BIN/noprogress" <<'EOF'
#!/usr/bin/env bash
printf '{"subtype":"success"}\n'
EOF
cat >"$BIN/noprogress_maxturns" <<'EOF'
#!/usr/bin/env bash
printf '{"subtype":"error_max_turns"}\n'
EOF
cat >"$BIN/sessionerror" <<'EOF'
#!/usr/bin/env bash
printf '{"subtype":"error_during_execution"}\n'
EOF
# crash that leaves uncommitted work behind (to exercise the rollback)
cat >"$BIN/crash_dirty" <<'EOF'
#!/usr/bin/env bash
printf 'half-written agent work\n' >"$PWFG_WORKSPACE/partial.tmp"
printf '{"subtype":"error_during_execution"}\n'; exit 1
EOF
# nonzero exit with NO result JSON -> a crash detected via launch_rc, not subtype
cat >"$BIN/crash_silent" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
# crashes twice (counter in the sibling state dir), then makes real progress
cat >"$BIN/crash_then_progress" <<'EOF'
#!/usr/bin/env bash
c="$PWFG_STATE_DIR/.fakecrash"; n="$(cat "$c" 2>/dev/null || echo 0)"
if [ "$n" -lt 2 ]; then echo "$((n + 1))" >"$c"; printf '{"subtype":"error_during_execution"}\n'; exit 1; fi
for k in 1 2 3; do [ -f "$PWFG_WORKSPACE/step$k.done" ] || { : >"$PWFG_WORKSPACE/step$k.done"; break; }; done
printf '{"subtype":"success"}\n'
EOF
# ALTERNATES crash, progress, crash, progress... so a crash never follows a crash:
# proves the consecutive-crash counter RESETS on a productive session (transient
# crashes across a long run are tolerated; the streak never exhausts).
cat >"$BIN/crash_alternating" <<'EOF'
#!/usr/bin/env bash
c="$PWFG_STATE_DIR/.seq"; n="$(cat "$c" 2>/dev/null || echo 0)"; echo "$((n + 1))" >"$c"
if [ "$((n % 2))" -eq 0 ]; then printf '{"subtype":"error_during_execution"}\n'; exit 1; fi
for k in 1 2 3; do [ -f "$PWFG_WORKSPACE/step$k.done" ] || { : >"$PWFG_WORKSPACE/step$k.done"; break; }; done
printf '{"subtype":"success"}\n'
EOF
# healthy session that makes progress but prints non-JSON (subtype parses to "unknown",
# clean exit) -> must TRUST THE GATE, never roll back (no livelock)
cat >"$BIN/unknown_progress" <<'EOF'
#!/usr/bin/env bash
for k in 1 2 3; do [ -f "$PWFG_WORKSPACE/step$k.done" ] || { : >"$PWFG_WORKSPACE/step$k.done"; break; }; done
printf 'a friendly non-JSON log line\n'
EOF
# a session that writes uncommitted work, then hangs past the wall clock — exercises
# both wedge detection AND the killed-mid-write rollback.
cat >"$BIN/wedge" <<'EOF'
#!/usr/bin/env bash
printf 'half-written work when the session wedged\n' >"$PWFG_WORKSPACE/wedge_partial.tmp"
sleep 3
printf '{"subtype":"success"}\n'
EOF
# Simulates a brokering-proxy budget breach: the proxy wrote the sentinel and the 403
# made the session end abnormally (subtype=error_during_execution + nonzero exit).
cat >"$BIN/budget_breach" <<'EOF'
#!/usr/bin/env bash
[ -n "${PWFG_PROXY_SENTINEL:-}" ] && printf 'cost cap reached: 25.01 >= 25.00 USD\n' >"$PWFG_PROXY_SENTINEL"
printf '{"subtype":"error_during_execution"}\n'; exit 1
EOF
cat >"$BIN/notify_sink" <<'EOF'
#!/usr/bin/env bash
{ echo "STATUS=$PWFG_NOTIFY_STATUS"; echo "TITLE=$PWFG_NOTIFY_TITLE"
  echo "PHASE=$PWFG_NOTIFY_PHASE"; echo "RUNDIR=$PWFG_NOTIFY_RUNDIR"
  echo "--- message ---"; cat; } >>"$PWFG_NOTIFY_SINK"
EOF
chmod +x "$BIN"/*

ORCH_OUT=""
orch_run() {  # $1 = launcher name ; env limits set by caller
  local base; base="$(mktemp -d)"
  export PWFG_PLAN="$FIXTURE"
  unset PWFG_SCHEMA PWFG_TURNS_PER_SESSION
  export PWFG_WORKSPACE="$base/ws"; export PWFG_STATE_DIR="$base/state"
  mkdir -p "$PWFG_WORKSPACE"
  export PWFG_LAUNCH_CMD="$BIN/$1"
  ORCH_OUT="$("$SKILL/bin/run-loop.sh" 2>&1)"
}
green_count() { jq '[.phases[] | select(.result=="pass")] | length' "$PWFG_STATE_DIR/status.json"; }
checkpoint_commits() { git -C "$PWFG_WORKSPACE" log --format='%s' 2>/dev/null | grep -c '^checkpoint:'; }
# grep -c consumes all input (no early SIGPIPE that pipefail would surface as a failure).
has_recovery_stash() { [ "$(git -C "$PWFG_WORKSPACE" stash list 2>/dev/null | grep -c pwfg-recovery)" != 0 ]; }

echo "== happy path: completes across 3 fresh sessions =="
export PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2 PWFG_GIT_CHECKPOINTS=1
orch_run progress
assert_ok  "RESULT is GREEN" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: GREEN'"
assert_eq  "all 3 phases green" "$(green_count)" "3"
assert_eq  "one checkpoint commit per phase (3)" "$(checkpoint_commits)" "3"
assert_no  "no BLOCKED marker" "[ -f \"$PWFG_STATE_DIR/BLOCKED\" ]"
assert_ok  "reports session count" "printf '%s' \"\$ORCH_OUT\" | grep -q 'completed in 3 session'"

echo "== handoff doc is regenerated between sessions =="
assert_ok  "HANDOFF.md exists" "[ -f \"$PWFG_WORKSPACE/HANDOFF.md\" ]"
assert_ok  "HANDOFF anchors on ground truth" "grep -q 'GROUND TRUTH' \"$PWFG_WORKSPACE/HANDOFF.md\""

echo "== max-turns subtype with progress keeps going (not fatal) =="
export PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2
orch_run progress_maxturns
assert_ok  "still reaches GREEN" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: GREEN'"
assert_eq  "all 3 phases green" "$(green_count)" "3"

echo "== stall -> escalate to human (phase too big to re-author) =="
export PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2
orch_run noprogress
assert_ok  "RESULT is HUMAN NEEDED" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: HUMAN NEEDED'"
assert_ok  "BLOCKED cites no-progress / too large" "grep -qiE 'no progress|too large' \"$PWFG_STATE_DIR/BLOCKED\""
assert_ok  "BLOCKED tells a human to re-author the plan" "grep -qi 're-author' \"$PWFG_STATE_DIR/BLOCKED\""
assert_eq  "no phases green" "$(green_count)" "0"

echo "== budget cap halts a slow run =="
export PWFG_MAX_SESSIONS=2 PWFG_STALL_LIMIT=5
orch_run progress
assert_ok  "BLOCKED cites budget" "grep -qi 'max sessions' \"$PWFG_STATE_DIR/BLOCKED\""
assert_eq  "stopped with 2 of 3 green" "$(green_count)" "2"

echo "== crash subtype -> bounded auto-recovery, then escalate as an env/agent fault =="
export PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2
orch_run sessionerror
assert_ok  "retries before giving up (attempt 1/2)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'auto-recovering (attempt 1/2'"
assert_ok  "retries again (attempt 2/2)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'auto-recovering (attempt 2/2'"
assert_ok  "RESULT is HUMAN NEEDED once recovery is exhausted" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: HUMAN NEEDED'"
assert_ok  "BLOCKED cites repeated abnormal ends" "grep -qi 'ended abnormally' \"$PWFG_STATE_DIR/BLOCKED\""
assert_ok  "BLOCKED says NOT a too-big phase (correct diagnosis)" "grep -qi 'NOT a too-big phase' \"$PWFG_STATE_DIR/BLOCKED\""
assert_no  "BLOCKED does NOT misdiagnose as a too-large phase" "grep -qi 'too large' \"$PWFG_STATE_DIR/BLOCKED\""
assert_ok  "BLOCKED points at the recovery forensics" "grep -q 'recovery log' \"$PWFG_STATE_DIR/BLOCKED\""
assert_ok  "a recovery log was recorded" "[ -f \"$PWFG_STATE_DIR/logs/recovery.log\" ]"

echo "== transient crash recovers to GREEN (fresh sessions resume from disk) =="
export PWFG_MAX_SESSIONS=8 PWFG_STALL_LIMIT=2
orch_run crash_then_progress
assert_ok  "recovered and reached GREEN" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: GREEN'"
assert_eq  "all 3 phases green after recovery" "$(green_count)" "3"
assert_ok  "it did auto-recover along the way" "printf '%s' \"\$ORCH_OUT\" | grep -q 'auto-recovering'"
assert_no  "no escalation marker on a recovered run" "[ -f \"$PWFG_STATE_DIR/BLOCKED\" ]"

echo "== the crash counter RESETS on a productive session (transient crashes tolerated) =="
export PWFG_MAX_SESSIONS=20 PWFG_STALL_LIMIT=5
orch_run crash_alternating
assert_ok  "alternating crash/progress still reaches GREEN" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: GREEN'"
assert_eq  "all 3 phases green despite repeated (non-consecutive) crashes" "$(green_count)" "3"
assert_ok  "each isolated crash recovers (attempt 1/2 seen)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'attempt 1/2'"
assert_no  "the streak never reaches the limit (no attempt 2/2)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'attempt 2/2'"
assert_no  "never escalates as a crash loop" "[ -f \"$PWFG_STATE_DIR/BLOCKED\" ]"

echo "== crash rolls back the session's uncommitted work to the last checkpoint =="
export PWFG_MAX_SESSIONS=8 PWFG_STALL_LIMIT=2
orch_run crash_dirty
assert_no  "the crashed session's partial file is gone" "[ -f \"$PWFG_WORKSPACE/partial.tmp\" ]"
assert_ok  "the rolled-back work is preserved (recoverable) in a stash" "has_recovery_stash"
assert_eq  "the working tree is clean after rollback" "$(git -C "$PWFG_WORKSPACE" status --porcelain | wc -l | tr -d ' ')" "0"

echo "== nonzero exit with no result JSON is a crash (detected via launch_rc) =="
export PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2
orch_run crash_silent
assert_ok  "RESULT is HUMAN NEEDED" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: HUMAN NEEDED'"
assert_ok  "classified as a crash with no result JSON" "grep -qi 'no result JSON' \"$PWFG_STATE_DIR/BLOCKED\""
assert_ok  "it tried to recover first" "printf '%s' \"\$ORCH_OUT\" | grep -q 'auto-recovering'"

echo "== unknown subtype with a clean exit TRUSTS THE GATE (no rollback, no livelock) =="
export PWFG_MAX_SESSIONS=8 PWFG_STALL_LIMIT=2
orch_run unknown_progress
assert_ok  "progress is trusted and reaches GREEN" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: GREEN'"
assert_eq  "all 3 phases green" "$(green_count)" "3"
assert_no  "never rolled back a healthy session (no recovery log)" "[ -f \"$PWFG_STATE_DIR/logs/recovery.log\" ]"

echo "== a crash loop under a tight session budget still gets a cause-aware message =="
export PWFG_MAX_SESSIONS=2 PWFG_STALL_LIMIT=5
orch_run sessionerror
assert_ok  "RESULT is HUMAN NEEDED" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: HUMAN NEEDED'"
assert_ok  "budget message names the abnormal cause" "grep -qi 'ended abnormally' \"$PWFG_STATE_DIR/BLOCKED\""
assert_ok  "and still cites the budget cap" "grep -qi 'max sessions' \"$PWFG_STATE_DIR/BLOCKED\""

echo "== proxy budget ceiling escalates as a budget breach, NOT a crash (no recovery/retry) =="
bsent="$(mktemp -u)"; rm -f "$bsent"; export PWFG_PROXY_SENTINEL="$bsent"
export PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2
orch_run budget_breach
assert_ok  "RESULT is HUMAN NEEDED" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: HUMAN NEEDED'"
assert_ok  "BLOCKED diagnoses the LLM budget ceiling" "grep -qi 'budget ceiling' \"$PWFG_STATE_DIR/BLOCKED\""
assert_no  "did NOT auto-recover (no crash retry)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'auto-recovering'"
assert_no  "did NOT misdiagnose as an abnormal/crash loop" "grep -qi 'ended abnormally' \"$PWFG_STATE_DIR/BLOCKED\""
assert_no  "stopped after one session (no second launch)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'session 2 start'"
rm -f "$bsent"; unset PWFG_PROXY_SENTINEL

echo "== turn budget: formula scales with progress (deterministic) =="
# shellcheck disable=SC1091
. "$SKILL/lib/common.sh"
unset PWFG_TURNS_PER_SESSION PWFG_TURNS_BASE PWFG_TURNS_PER_PHASE PWFG_TURNS_MAX
assert_eq  "base budget at 0 green" "$(pwfg_session_budget 0 0)" "12"
assert_eq  "scales +3 per green phase" "$(pwfg_session_budget 3 0)" "21"
assert_eq  "clamps at max 24" "$(pwfg_session_budget 10 0)" "24"
assert_eq  "reactive extra adds on top" "$(pwfg_session_budget 2 4)" "22"
assert_eq  "fixed PWFG_TURNS_PER_SESSION overrides scaling" "$(PWFG_TURNS_PER_SESSION=7 pwfg_session_budget 5 8)" "7"

echo "== turn budget: grows with progress across sessions =="
export PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2
orch_run progress
assert_ok  "session 1 starts at base (12t)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'budget 12t'"
assert_ok  "budget grows as phases complete (15t)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'budget 15t'"
assert_ok  "budget grows further (18t)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'budget 18t'"

echo "== turn budget: reactive bump then escalate at max =="
export PWFG_MAX_SESSIONS=8 PWFG_STALL_LIMIT=2
orch_run noprogress_maxturns
assert_ok  "reactive bump raises the budget (16t)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'budget 16t'"
assert_ok  "budget climbs to the max (24t)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'budget 24t'"
assert_ok  "escalates once max budget can't finish" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: HUMAN NEEDED'"
assert_ok  "BLOCKED cites too-big-even-at-max" "grep -qi 'too large' \"$PWFG_STATE_DIR/BLOCKED\""

echo "== escalation notification: channel + local log + escalate-only filter =="
nb="$(mktemp -d)"
export PWFG_PLAN="$FIXTURE"; unset PWFG_SCHEMA
export PWFG_WORKSPACE="$nb/ws"; export PWFG_STATE_DIR="$nb/state"; mkdir -p "$PWFG_WORKSPACE"
export XDG_STATE_HOME="$nb/xdg"
"$SKILL/bin/init-session.sh" >/dev/null
printf 'reason: test stall — phase too big\n' > "$PWFG_STATE_DIR/BLOCKED"
export PWFG_NOTIFY_SINK="$nb/sink.txt"; : > "$PWFG_NOTIFY_SINK"
export PWFG_NOTIFY_CMD="$BIN/notify_sink"
"$SKILL/bin/notify.sh" HUMAN_NEEDED >/dev/null
assert_ok  "channel invoked on HUMAN_NEEDED" "[ -s \"$PWFG_NOTIFY_SINK\" ]"
assert_ok  "channel receives the status" "grep -q 'STATUS=HUMAN_NEEDED' \"$PWFG_NOTIFY_SINK\""
assert_ok  "channel receives the title" "grep -qF 'TITLE=[pwfg] orch-test: HUMAN_NEEDED' \"$PWFG_NOTIFY_SINK\""
assert_ok  "message carries the escalation reason" "grep -q 'phase too big' \"$PWFG_NOTIFY_SINK\""
assert_ok  "recorded to the durable local log" "grep -q HUMAN_NEEDED \"$XDG_STATE_HOME/pwfg/notifications.log\""
: > "$PWFG_NOTIFY_SINK"; rm -f "$PWFG_STATE_DIR/BLOCKED"
"$SKILL/bin/notify.sh" GREEN >/dev/null
assert_no  "GREEN does not invoke the channel by default" "[ -s \"$PWFG_NOTIFY_SINK\" ]"
PWFG_NOTIFY_ON=all "$SKILL/bin/notify.sh" GREEN >/dev/null
assert_ok  "GREEN invokes the channel when PWFG_NOTIFY_ON=all" "[ -s \"$PWFG_NOTIFY_SINK\" ]"

echo "== orchestrator fires the notification on escalation, not on success =="
isink="$(mktemp)"; export PWFG_NOTIFY_SINK="$isink"; export PWFG_NOTIFY_CMD="$BIN/notify_sink"
export XDG_STATE_HOME="$(mktemp -d)"; unset PWFG_NOTIFY_ON
export PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2
orch_run noprogress
assert_ok  "escalation run fired the channel" "grep -q 'STATUS=HUMAN_NEEDED' \"$isink\""
: > "$isink"
orch_run progress
assert_no  "completed run does not fire the channel by default" "grep -q 'STATUS=' \"$isink\""
unset PWFG_NOTIFY_CMD PWFG_NOTIFY_SINK XDG_STATE_HOME

echo "== handoff narrator: transcript digest (deterministic part) =="
# shellcheck disable=SC1091
. "$SKILL/lib/common.sh"
DG="$(pwfg_transcript_digest "$REPO/tests/fixtures/narrate/transcript.jsonl")"
assert_ok  "digest includes assistant prose" "printf '%s' \"\$DG\" | grep -q 'ASSISTANT: I will implement tokenize first'"
assert_ok  "digest includes tool calls with name + input" "printf '%s' \"\$DG\" | grep -q 'TOOL Write:.*rpn/core.py'"
assert_ok  "digest keeps the latest assistant note" "printf '%s' \"\$DG\" | grep -q 'malformed-number'"
assert_no  "digest excludes user/tool_result noise" "printf '%s' \"\$DG\" | grep -q tool_result"
assert_no  "narrator no-ops when disabled (PWFG_NARRATE unset)" "PWFG_NARRATE=0 \"$SKILL/bin/handoff-narrate.sh\" some-id | grep -q ."

echo "== wedge: a wall-clock hang is detected, retried with a bigger budget, then escalated =="
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  export PWFG_MAX_SESSIONS=8 PWFG_STALL_LIMIT=2
  export PWFG_SESSION_TIMEOUT=1 PWFG_TURNS_BASE=12 PWFG_TURNS_MAX=16 PWFG_TURNS_BUMP=4
  orch_run wedge
  assert_ok  "the hang is classified as a wedge" "printf '%s' \"\$ORCH_OUT\" | grep -qi 'wedged'"
  assert_ok  "a wedge raises the next budget (feeds the budget machinery, not crash-retry)" "printf '%s' \"\$ORCH_OUT\" | grep -q 'wedge with no progress — raising'"
  assert_ok  "RESULT is HUMAN NEEDED after persistent wedging" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: HUMAN NEEDED'"
  assert_ok  "BLOCKED diagnoses wedging (not a generic crash)" "grep -qi 'wedging' \"$PWFG_STATE_DIR/BLOCKED\""
  # the killed-mid-write rollback must fire on a wedge too (not just on a crash)
  assert_no  "the wedged session's uncommitted file is rolled back" "[ -f \"$PWFG_WORKSPACE/wedge_partial.tmp\" ]"
  assert_ok  "the wedge's rolled-back work is preserved in a stash" "has_recovery_stash"
  assert_eq  "the tree is clean after the wedge rollback" "$(git -C "$PWFG_WORKSPACE" status --porcelain | wc -l | tr -d ' ')" "0"
  unset PWFG_SESSION_TIMEOUT PWFG_TURNS_BASE PWFG_TURNS_MAX PWFG_TURNS_BUMP
else
  echo "  -- skipped (no timeout/gtimeout binary on this box) --"
fi

echo
printf '== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
