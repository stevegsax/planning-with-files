#!/usr/bin/env bash
# test_harness.sh — deterministic self-test for the gated-planning harness.
#
# No LLM. Proves the tools and the Stop gate behave correctly against a known
# RED stub and a known GREEN reference solution, that adversarial fakes cannot
# reach a GREEN gate (the sealed differential gate), that infrastructure failures
# are distinguished from a red gate, plus escalate-and-wait, the bounded/fail-safe
# block guard, the proof-source (anti-injection) invariant, and plan validation.
# Run from the repo root: tests/test_harness.sh

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/skill"
TOY="$REPO/examples/toy"

PASS=0; FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() { [ "$2" = "$3" ] && ok "$1" || { no "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
assert_ok() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
assert_no() { if eval "$2" >/dev/null 2>&1; then no "$1"; else ok "$1"; fi; }

export PWFG_PLAN="$TOY/locked/plan.json"
export PWFG_SCHEMA="$SKILL/schema/plan.schema.json"

new_run() {
  local base; base="$(mktemp -d)"
  export PWFG_WORKSPACE="$base/ws"
  export PWFG_STATE_DIR="$base/state"
  mkdir -p "$PWFG_WORKSPACE/rpn"
  cp "$TOY/workspace/rpn/__init__.py" "$PWFG_WORKSPACE/rpn/__init__.py"
  set_red
  unset PWFG_MAX_BLOCKS
}
set_red()   { cp "$TOY/workspace/rpn/core.py" "$PWFG_WORKSPACE/rpn/core.py"; }
set_green() { cp "$TOY/_reference/core.py"    "$PWFG_WORKSPACE/rpn/core.py"; }
set_attack() { cp "$TOY/_attacks/$1.py"       "$PWFG_WORKSPACE/rpn/core.py"; }
status_of() { jq -r --arg id "$1" '.phases[$id].result' "$PWFG_STATE_DIR/status.json"; }

echo "== init & validation =="
new_run
assert_ok  "init-session succeeds" "\"$SKILL/bin/init-session.sh\""
assert_eq  "status.json lists 4 phases" "$(jq '.phases | length' "$PWFG_STATE_DIR/status.json")" "4"
assert_eq  "all phases start unknown" "$(jq -r '[.phases[].result] | unique | join(",")' "$PWFG_STATE_DIR/status.json")" "unknown"

echo "== RED path (stub) =="
assert_no  "verify-all fails on stub" "\"$SKILL/bin/verify-all.sh\""
assert_no  "verify-task phase1 fails on stub" "\"$SKILL/bin/verify-task.sh\" phase1-tokenize"
assert_eq  "phase1 status is fail" "$(status_of phase1-tokenize)" "fail"
block_out="$(echo '{}' | "$SKILL/bin/stop-gate.sh")"; block_rc=$?
assert_eq  "stop-gate exit 0 on RED" "$block_rc" "0"
assert_ok  "stop-gate emits decision:block on RED" "printf '%s' '$block_out' | jq -e '.decision==\"block\"'"
assert_ok  "block guidance present in reason" "printf '%s' '$block_out' | jq -e '.reason|length>0'"
assert_ok  "block guidance present in additionalContext" "printf '%s' '$block_out' | jq -e '.hookSpecificOutput.additionalContext|length>0'"

echo "== GREEN path (reference) =="
set_green
assert_ok  "verify-all passes on reference" "\"$SKILL/bin/verify-all.sh\""
assert_ok  "sealed phase passes on reference" "\"$SKILL/bin/verify-task.sh\" phase4-sealed-gate"
green_out="$(echo '{}' | "$SKILL/bin/stop-gate.sh")"; green_rc=$?
assert_eq  "stop-gate exit 0 on GREEN" "$green_rc" "0"
assert_eq  "stop-gate emits nothing on GREEN (allows stop)" "$green_out" ""

echo "== anti-fake: adversarial implementations cannot reach GREEN =="
for atk in makereport_flip eq_true; do
  new_run; "$SKILL/bin/init-session.sh" >/dev/null
  set_attack "$atk"
  # The sealed gate must catch it regardless of any pytest trickery.
  assert_no  "[$atk] sealed phase FAILS" "\"$SKILL/bin/verify-task.sh\" phase4-sealed-gate"
  assert_no  "[$atk] verify-all is NOT green" "\"$SKILL/bin/verify-all.sh\""
  atk_out="$(echo '{}' | "$SKILL/bin/stop-gate.sh")"
  assert_ok  "[$atk] stop-gate still blocks (no fake done)" "printf '%s' '$atk_out' | jq -e '.decision==\"block\"'"
  # Informational: whether the naive pytest phase was fooled (the hole the sealed gate closes).
  if "$SKILL/bin/verify-task.sh" phase1-tokenize >/dev/null 2>&1; then
    printf '  info [%s] fooled naive pytest phase1 (sealed gate caught it)\n' "$atk"
  fi
done

echo "== infra error is distinguished from RED =="
new_run; "$SKILL/bin/init-session.sh" >/dev/null
set_green                                  # correct code...
binstub="$(mktemp -d)"; printf '#!/bin/sh\nexit 127\n' > "$binstub/uv"; chmod +x "$binstub/uv"
SAVED_PATH="$PATH"; export PATH="$binstub:$PATH"   # ...but tooling is broken
"$SKILL/bin/verify-all.sh" >/dev/null 2>&1; infra_rc=$?
infra_out="$(echo '{}' | "$SKILL/bin/stop-gate.sh")"; infra_block_rc=$?
export PATH="$SAVED_PATH"
assert_eq  "verify-all returns ERROR (2), not RED (1), on broken tooling" "$infra_rc" "2"
assert_eq  "stop-gate does NOT block on infra error" "$infra_out" ""
assert_eq  "stop-gate exit 0 on infra error" "$infra_block_rc" "0"
assert_ok  "BLOCKED names the infrastructure cause" "grep -qi infrastructure \"$PWFG_STATE_DIR/BLOCKED\""

echo "== escalate-and-wait =="
new_run; "$SKILL/bin/init-session.sh" >/dev/null
"$SKILL/bin/escalate.sh" "self-test: simulated stuck" >/dev/null
esc_out="$(echo '{}' | "$SKILL/bin/stop-gate.sh")"; esc_rc=$?
assert_eq  "stop-gate allows stop after escalate (exit 0)" "$esc_rc" "0"
assert_eq  "stop-gate does NOT block after escalate" "$esc_out" ""
assert_ok  "BLOCKED marker present" "[ -f \"$PWFG_STATE_DIR/BLOCKED\" ]"

echo "== bounded-block guard =="
new_run; "$SKILL/bin/init-session.sh" >/dev/null
export PWFG_MAX_BLOCKS=1
echo '{}' | "$SKILL/bin/stop-gate.sh" >/dev/null
assert_eq  "first stop blocks (count=1)" "$(jq -r '.blocks' "$PWFG_STATE_DIR/loop.json")" "1"
assert_no  "no BLOCKED yet" "[ -f \"$PWFG_STATE_DIR/BLOCKED\" ]"
echo '{}' | "$SKILL/bin/stop-gate.sh" >/dev/null
assert_ok  "second stop converts to BLOCKED (bounded)" "[ -f \"$PWFG_STATE_DIR/BLOCKED\" ]"
unset PWFG_MAX_BLOCKS

echo "== block guard fails SAFE on corrupt state =="
new_run; "$SKILL/bin/init-session.sh" >/dev/null
printf 'not json at all' > "$PWFG_STATE_DIR/loop.json"     # corrupt -> must recover & advance
echo '{}' | "$SKILL/bin/stop-gate.sh" >/dev/null
assert_eq  "corrupt loop.json recovers and advances (blocks=1)" "$(jq -r '.blocks' "$PWFG_STATE_DIR/loop.json" 2>/dev/null)" "1"
new_run; "$SKILL/bin/init-session.sh" >/dev/null
printf '{"blocks":"abc"}' > "$PWFG_STATE_DIR/loop.json"    # non-numeric -> must escalate, not loop open
echo '{}' | "$SKILL/bin/stop-gate.sh" >/dev/null
assert_ok  "non-numeric block count fails SAFE (escalates)" "[ -f \"$PWFG_STATE_DIR/BLOCKED\" ]"

echo "== anti-injection: proof source is the locked plan only =="
new_run
printf '#!/bin/sh\necho HACKED\n' > "$PWFG_WORKSPACE/phase1-tokenize.proof"
proof_from_tool="$(bash -c ". \"$SKILL/lib/common.sh\"; pwfg_phase_field phase1-tokenize proof")"
proof_from_plan="$(jq -r '.phases[0].proof' "$PWFG_PLAN")"
assert_eq  "proof comes from plan.json, not workspace" "$proof_from_tool" "$proof_from_plan"
"$SKILL/bin/verify-task.sh" phase1-tokenize >/dev/null 2>&1 || true
assert_no  "run log shows no decoy execution" "grep -q HACKED \"$PWFG_STATE_DIR/logs/phase1-tokenize.txt\""

echo "== plan validation rejects malformed plans =="
badbase="$(mktemp -d)"
jq '.phases[1].id = .phases[0].id' "$TOY/locked/plan.json" > "$badbase/dup-ids.json"
jq 'del(.phases[0].proof)'         "$TOY/locked/plan.json" > "$badbase/no-proof.json"
jq '.workdir = "does-not-exist-xyz"' "$TOY/locked/plan.json" > "$badbase/bad-workdir.json"
assert_no  "duplicate phase ids rejected" "PWFG_PLAN=\"$badbase/dup-ids.json\" bash -c '. \"$SKILL/lib/common.sh\"; pwfg_validate_plan'"
assert_no  "missing proof rejected"        "PWFG_PLAN=\"$badbase/no-proof.json\" bash -c '. \"$SKILL/lib/common.sh\"; pwfg_validate_plan'"
assert_no  "unresolvable workdir rejected" "PWFG_PLAN=\"$badbase/bad-workdir.json\" bash -c '. \"$SKILL/lib/common.sh\"; pwfg_validate_plan'"
if command -v uv >/dev/null 2>&1; then
  assert_ok  "real plan passes JSON Schema" "uv run --quiet --with check-jsonschema check-jsonschema --schemafile \"$PWFG_SCHEMA\" \"$PWFG_PLAN\""
  assert_no  "bad plan fails JSON Schema"   "uv run --quiet --with check-jsonschema check-jsonschema --schemafile \"$PWFG_SCHEMA\" \"$badbase/no-proof.json\""
fi

echo "== PWFG_ENV_FILE guard (boundary: refuse agent-supplied / writable env files) =="
# Runs everywhere (no root needed): exercises the common.sh source guard that stops
# an agent pointing a gov-run tool at a file it wrote. The whole-boundary proof is
# tests/test_boundary.sh (root); this locks the load-bearing no-op/refuse contract.
gtmp="$(mktemp -d)"
printf 'export PWFG_GUARD_PROBE=ok\n'  >"$gtmp/safe.env";   chmod 600 "$gtmp/safe.env"
printf 'export PWFG_GUARD_PROBE=bad\n' >"$gtmp/unsafe.env"; chmod 666 "$gtmp/unsafe.env"
probe() { PWFG_ENV_FILE="$1" bash -c ". \"$SKILL/lib/common.sh\"; printf '%s' \"\${PWFG_GUARD_PROBE:-<unset>}\"" 2>/dev/null; }
assert_eq "owned + 0600 env file IS sourced"          "$(probe "$gtmp/safe.env")"   "ok"
assert_eq "group/other-writable env file is REFUSED"  "$(probe "$gtmp/unsafe.env")"  "<unset>"
assert_eq "missing env file is a clean no-op"         "$(probe "$gtmp/nope.env")"    "<unset>"
warn="$(PWFG_ENV_FILE="$gtmp/unsafe.env" bash -c ". \"$SKILL/lib/common.sh\"" 2>&1 >/dev/null)"
printf '%s' "$warn" | grep -qi 'refusing to source' && ok "refusal warns on stderr" || no "refusal warns on stderr"
rm -rf "$gtmp"

echo
printf '== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
