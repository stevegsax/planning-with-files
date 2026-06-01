#!/usr/bin/env bash
# run-loop.sh — drive the toy across MULTIPLE fresh sessions via the orchestrator.
#
# Same gated toy as run-experiment.sh, but each session is context-bounded and the
# orchestrator restarts fresh ones until green / stall / budget. The toy is small
# enough to finish in one session, so this mainly demonstrates orchestrator<->agent
# composition; the multi-session LOGIC (checkpoints, stall->human, budget) is proven
# deterministically in tests/test_orchestrator.sh.
#
# The per-session turn budget scales with progress by default (set
# PWFG_TURNS_PER_SESSION to force a fixed value).
#
# Usage:  examples/toy/run-loop.sh
# Env:    ANTHROPIC_API_KEY (required)   PWFG_MODEL (default: sonnet)
#         PWFG_MAX_SESSIONS (default: 8)   PWFG_STALL_LIMIT (default: 2)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO/skill"
TOY="$REPO/examples/toy"

for t in claude uv jq git; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "warning: no ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN set; headless auth may fail." >&2
fi

RUN_BASE="$(mktemp -d "${TMPDIR:-/tmp}/pwfg-loop.XXXXXX")"
RUN_DIR="$RUN_BASE/workspace"
mkdir -p "$RUN_DIR"
cp -R "$TOY/workspace/." "$RUN_DIR/"
rm -rf "$RUN_DIR/.harness"

mkdir -p "$RUN_DIR/.claude"
jq -n --arg cmd "$SKILL/bin/stop-gate.sh" '{
  hooks: { Stop: [ { hooks: [ { type: "command", command: $cmd } ] } ] }
}' >"$RUN_DIR/.claude/settings.json"

export PWFG_PLAN="$TOY/locked/plan.json"
export PWFG_SCHEMA="$SKILL/schema/plan.schema.json"
export PWFG_WORKSPACE="$RUN_DIR"
export PWFG_STATE_DIR="$RUN_BASE/state"
export PWFG_STOP_AT_CHECKPOINT=1
export PWFG_MAX_SESSIONS="${PWFG_MAX_SESSIONS:-8}"
export PWFG_STALL_LIMIT="${PWFG_STALL_LIMIT:-2}"
export PWFG_MODEL="${PWFG_MODEL:-sonnet}"
export PWFG_NARRATE="${PWFG_NARRATE:-0}"            # 1 = LLM handoff narrator
export PWFG_NARRATE_MODEL="${PWFG_NARRATE_MODEL:-haiku}"

echo "== orchestrated run: budget scales with progress, max-sessions=${PWFG_MAX_SESSIONS}, narrate=${PWFG_NARRATE} =="
"$SKILL/bin/run-loop.sh"

echo
echo "Run base: $RUN_BASE  (workspace/ + state/)"
echo "Checkpoints:"; git -C "$RUN_DIR" log --oneline 2>/dev/null | awk '{print "  " $0}'
echo "Handoff:  $RUN_DIR/HANDOFF.md"
