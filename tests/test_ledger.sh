#!/usr/bin/env bash
# test_ledger.sh — deterministic self-test for the 6-phase ledger toy.
# Proves the reference passes every phase (incl. the sealed gate), the stub fails,
# and the sealed gate catches the stub. Run from the repo root.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/skill"
LED="$REPO/examples/ledger"

PASS=0; FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() { [ "$2" = "$3" ] && ok "$1" || { no "$1"; printf '       want=[%s] got=[%s]\n' "$3" "$2"; }; }
assert_ok() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }
assert_no() { if eval "$2" >/dev/null 2>&1; then no "$1"; else ok "$1"; fi; }

export PWFG_PLAN="$LED/locked/plan.json"
export PWFG_SCHEMA="$SKILL/schema/plan.schema.json"

set_ws() {  # $1 = reference|stub
  local base; base="$(mktemp -d)"
  export PWFG_WORKSPACE="$base/ws"; export PWFG_STATE_DIR="$base/state"
  mkdir -p "$PWFG_WORKSPACE/ledger"
  if [ "$1" = reference ]; then
    cp "$LED/_reference"/*.py "$PWFG_WORKSPACE/ledger/"
  else
    cp "$LED/workspace/ledger"/*.py "$PWFG_WORKSPACE/ledger/"
  fi
}

echo "== plan shape =="
set_ws stub
assert_ok  "init-session succeeds" "\"$SKILL/bin/init-session.sh\""
assert_eq  "plan has 6 phases" "$(jq '.phases | length' "$PWFG_STATE_DIR/status.json")" "6"

echo "== RED on the stub =="
assert_no  "verify-all fails on stub" "\"$SKILL/bin/verify-all.sh\""
assert_no  "sealed gate fails on stub" "\"$SKILL/bin/verify-task.sh\" phase6-sealed-gate"

echo "== GREEN on the reference (all 6 phases) =="
set_ws reference
"$SKILL/bin/init-session.sh" >/dev/null
assert_ok  "verify-all passes on reference" "\"$SKILL/bin/verify-all.sh\""
for p in phase1-money phase2-posting phase3-entry phase4-post phase5-report phase6-sealed-gate; do
  assert_eq  "$p green" "$(jq -r --arg p "$p" '.phases[$p].result' "$PWFG_STATE_DIR/status.json")" "pass"
done

echo
printf '== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
