#!/usr/bin/env bash
# run-loop.sh — drive the 6-phase ledger across MULTIPLE fresh sessions.
#
# The ledger is intentionally larger than one context window, so this reliably
# spans several sessions: the orchestrator checkpoints each green phase, commits
# it, regenerates HANDOFF.md (optionally narrated), and a fresh session resumes.
#
# The per-session turn budget SCALES WITH PROGRESS by default (it grows as phases
# complete, since the orientation tax grows with the codebase) and bumps reactively
# if a session runs out of turns with no progress. Set PWFG_TURNS_PER_SESSION to
# force a fixed budget instead.
#
# Usage:  examples/ledger/run-loop.sh
# Env:    ANTHROPIC_API_KEY (required)   PWFG_MODEL (default: sonnet)
#         PWFG_MAX_SESSIONS (default: 12)   PWFG_STALL_LIMIT (default: 2)
#         PWFG_NARRATE (default: 0)   PWFG_TURNS_{BASE,PER_PHASE,MAX} (12/3/24)

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO/skill"
LED="$REPO/examples/ledger"

for t in claude uv jq git; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing required tool: $t" >&2; exit 1; }
done
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "warning: no ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN set; headless auth may fail." >&2
fi

RUN_BASE="$(mktemp -d "${TMPDIR:-/tmp}/pwfg-ledger.XXXXXX")"
RUN_DIR="$RUN_BASE/workspace"
mkdir -p "$RUN_DIR"
cp -R "$LED/workspace/." "$RUN_DIR/"
rm -rf "$RUN_DIR/.harness"

mkdir -p "$RUN_DIR/.claude"
jq -n --arg cmd "$SKILL/bin/stop-gate.sh" '{
  hooks: { Stop: [ { hooks: [ { type: "command", command: $cmd } ] } ] }
}' >"$RUN_DIR/.claude/settings.json"

export PWFG_PLAN="$LED/locked/plan.json"
export PWFG_SCHEMA="$SKILL/schema/plan.schema.json"
export PWFG_WORKSPACE="$RUN_DIR"
export PWFG_STATE_DIR="$RUN_BASE/state"
export PWFG_STOP_AT_CHECKPOINT=1
export PWFG_MAX_SESSIONS="${PWFG_MAX_SESSIONS:-12}"
export PWFG_STALL_LIMIT="${PWFG_STALL_LIMIT:-2}"
export PWFG_MODEL="${PWFG_MODEL:-sonnet}"
export PWFG_NARRATE="${PWFG_NARRATE:-0}"
export PWFG_NARRATE_MODEL="${PWFG_NARRATE_MODEL:-haiku}"

echo "== ledger run: budget scales with progress (base ${PWFG_TURNS_BASE:-12}..max ${PWFG_TURNS_MAX:-24}), max-sessions=${PWFG_MAX_SESSIONS}, narrate=${PWFG_NARRATE} =="
"$SKILL/bin/run-loop.sh"

echo
echo "Run base: $RUN_BASE  (workspace/ + state/)"
echo "Checkpoints:"; git -C "$RUN_DIR" log --oneline 2>/dev/null | awk '{print "  " $0}'
echo "Handoff:  $RUN_DIR/HANDOFF.md"
