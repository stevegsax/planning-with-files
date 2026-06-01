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
cat >"$BIN/sessionerror" <<'EOF'
#!/usr/bin/env bash
printf '{"subtype":"error_during_execution"}\n'
EOF
chmod +x "$BIN"/*

ORCH_OUT=""
orch_run() {  # $1 = launcher name ; env limits set by caller
  local base; base="$(mktemp -d)"
  export PWFG_PLAN="$FIXTURE"
  unset PWFG_SCHEMA
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

echo
printf '== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
