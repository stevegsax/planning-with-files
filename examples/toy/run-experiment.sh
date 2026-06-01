#!/usr/bin/env bash
# run-experiment.sh — the Phase 0 walking-skeleton driver.
#
# Launches a single headless Claude Code run, gated by the Stop hook, against a
# disposable copy of the toy workspace. Proves the loop drives the multi-phase
# plan to a green-tests stop (or a bounded escalation), with the acceptance suite
# and the gate outside the agent's reach.
#
# Usage:  examples/toy/run-experiment.sh
# Env:    ANTHROPIC_API_KEY (required)   PWFG_MODEL (default: sonnet)
#         MAX_TURNS (default: 40)        PWFG_MAX_BLOCKS (default: 40)

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO/skill"
TOY="$REPO/examples/toy"

for t in claude uv jq git; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "warning: neither ANTHROPIC_API_KEY nor CLAUDE_CODE_OAUTH_TOKEN is set;" >&2
  echo "         headless auth will likely fail. See README." >&2
fi

# Disposable run base: agent workspace and harness state are SIBLINGS, so the
# harness state (status, loop counter) lives outside the agent's working dir and
# is never named in the prompt. (Real OS-uid ownership is Phase 1.)
RUN_BASE="$(mktemp -d "${TMPDIR:-/tmp}/pwfg-run.XXXXXX")"
RUN_DIR="$RUN_BASE/workspace"
mkdir -p "$RUN_DIR"
cp -R "$TOY/workspace/." "$RUN_DIR/"
rm -rf "$RUN_DIR/.harness"

# Scope the Stop hook to THIS run only, via the run dir's project settings.
mkdir -p "$RUN_DIR/.claude"
jq -n --arg cmd "$SKILL/bin/stop-gate.sh" '{
  hooks: { Stop: [ { hooks: [ { type: "command", command: $cmd } ] } ] }
}' >"$RUN_DIR/.claude/settings.json"

export PWFG_PLAN="$TOY/locked/plan.json"
export PWFG_SCHEMA="$SKILL/schema/plan.schema.json"
export PWFG_WORKSPACE="$RUN_DIR"
export PWFG_STATE_DIR="$RUN_BASE/state"
export PWFG_MAX_BLOCKS="${PWFG_MAX_BLOCKS:-40}"

"$SKILL/bin/init-session.sh"

read -r -d '' PROMPT <<EOF || true
Read AGENT_TASK.md in this directory and implement the RPN calculator in rpn/core.py
to make the locked contract tests pass, phase by phase, in order.

Tools (absolute paths):
  verify a single phase : $SKILL/bin/verify-task.sh <phase-id>
  run the full gate     : $SKILL/bin/verify-all.sh
  escalate to a human   : $SKILL/bin/escalate.sh "<reason>"

Phase ids: phase1-tokenize, phase2-evaluate, phase3-calc.
Do not edit the locked tests or anything under .harness/. Completion is decided by
the tests; the session will keep you working until the gate is green.
EOF

echo "== launching headless run (model: ${PWFG_MODEL:-sonnet}, max-turns: ${MAX_TURNS:-40}) =="
echo "== run dir: $RUN_DIR =="

( cd "$RUN_DIR" && claude -p "$PROMPT" \
    --model "${PWFG_MODEL:-sonnet}" \
    --max-turns "${MAX_TURNS:-40}" \
    --dangerously-skip-permissions \
    --output-format json ) | jq -r '.result? // empty' 2>/dev/null || true

echo
echo "== final gate (authoritative, fresh) =="
if "$SKILL/bin/verify-all.sh"; then
  echo "RESULT: GREEN — the loop drove the plan to completion."
else
  if [ -f "$PWFG_STATE_DIR/BLOCKED" ]; then
    echo "RESULT: BLOCKED — escalated to a human:"
    awk '{print "  " $0}' "$PWFG_STATE_DIR/BLOCKED"
  else
    echo "RESULT: RED — ended incomplete (likely hit --max-turns). Inspect logs."
  fi
fi
echo
"$SKILL/bin/plan-status.sh"
echo
echo "Run base left for inspection: $RUN_BASE  (workspace/ + state/)"
