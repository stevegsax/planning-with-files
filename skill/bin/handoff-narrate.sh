#!/usr/bin/env bash
# handoff-narrate.sh [session-id] — OPTIONAL LLM narrator for the handoff.
#
# Reads the just-ended session's transcript and appends a brief, ADVISORY
# "what was tried / what to do next" note to HANDOFF.md. Most valuable when the
# session died on error_max_turns (the dev agent got no turn to leave notes).
#
# Advisory only: the gate stays authoritative, so a wrong narrative cannot fake
# progress. No-op (exit 0) when disabled, when there's no session id/transcript,
# or when claude is unavailable — so the deterministic path never depends on it.
#
# Env: PWFG_NARRATE=1 to enable; PWFG_NARRATE_MODEL (default haiku);
#      PWFG_SESSION_ID (or pass the id as $1).

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

[ "${PWFG_NARRATE:-0}" = 1 ] || exit 0
command -v claude >/dev/null 2>&1 || { echo "narrate: no claude; skipping" >&2; exit 0; }

sid="${1:-${PWFG_SESSION_ID:-}}"
[ -n "$sid" ] || { echo "narrate: no session id; skipping" >&2; exit 0; }

tf="$(pwfg_find_transcript "$sid")"
[ -n "$tf" ] && [ -f "$tf" ] || { echo "narrate: transcript not found for $sid; skipping" >&2; exit 0; }

digest="$(pwfg_transcript_digest "$tf")"
[ -n "$digest" ] || { echo "narrate: empty transcript digest; skipping" >&2; exit 0; }

read -r -d '' prompt <<EOF || true
You are writing a short handoff note for the NEXT autonomous coding agent, which
starts fresh with no memory of the session digested below (it may have hit its
turn cap mid-task). Summarize in 150 words or fewer, grounded ONLY in the digest
— do not invent or restate the task:
- what was attempted,
- what was learned / what is blocking,
- the single most useful next step.

--- session digest ---
$digest
--- end digest ---
EOF

narrative="$(claude -p "$prompt" \
  --model "${PWFG_NARRATE_MODEL:-haiku}" \
  --max-turns 1 \
  --output-format json 2>/dev/null | jq -r '.result // empty' 2>/dev/null)"
[ -n "$narrative" ] || { echo "narrate: empty narrative; skipping" >&2; exit 0; }

hf="$(pwfg_workspace)/HANDOFF.md"
{
  printf '\n## Narrative (LLM, advisory — verify against the gate)\n'
  printf '%s\n' "$narrative"
} >>"$hf"
echo "narrate: appended LLM narrative to $hf"
