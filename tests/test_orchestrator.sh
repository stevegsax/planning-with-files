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

echo "== session error subtype -> escalate =="
export PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2
orch_run sessionerror
assert_ok  "RESULT is HUMAN NEEDED" "printf '%s' \"\$ORCH_OUT\" | grep -q 'RESULT: HUMAN NEEDED'"
assert_ok  "BLOCKED cites the error subtype" "grep -q 'error_during_execution' \"$PWFG_STATE_DIR/BLOCKED\""

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

echo "== handoff narrator: transcript digest (deterministic part) =="
# shellcheck disable=SC1091
. "$SKILL/lib/common.sh"
DG="$(pwfg_transcript_digest "$REPO/tests/fixtures/narrate/transcript.jsonl")"
assert_ok  "digest includes assistant prose" "printf '%s' \"\$DG\" | grep -q 'ASSISTANT: I will implement tokenize first'"
assert_ok  "digest includes tool calls with name + input" "printf '%s' \"\$DG\" | grep -q 'TOOL Write:.*rpn/core.py'"
assert_ok  "digest keeps the latest assistant note" "printf '%s' \"\$DG\" | grep -q 'malformed-number'"
assert_no  "digest excludes user/tool_result noise" "printf '%s' \"\$DG\" | grep -q tool_result"
assert_no  "narrator no-ops when disabled (PWFG_NARRATE unset)" "PWFG_NARRATE=0 \"$SKILL/bin/handoff-narrate.sh\" some-id | grep -q ."

echo
printf '== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
