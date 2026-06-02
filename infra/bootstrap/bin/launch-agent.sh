#!/usr/bin/env bash
# launch-agent.sh — the PWFG_LAUNCH_CMD target: gov spawns the agent's claude.
#
# Runs as gov (the loop unit), drops to the agent uid, and starts a bounded headless
# session that reaches Anthropic ONLY via the loopback proxy (no key in the agent
# env) and carries the Stop hook via the gov-owned --settings file. The agent's
# workspace .claude config dir is agent-writable (transcripts); the Stop hook cannot
# be removed by any agent-writable settings source because it arrives via --settings.
#
# Inherits PWFG_PROMPT + PWFG_MAX_TURNS from run-loop.sh's launch().
set -uo pipefail

PORT="${PWFG_PROXY_PORT:-8787}"
# PWFG_ENV_FILE is exported into the AGENT env (and kept by env_keep across the
# agent->gov sudo) so the Stop hook + verify bridge, which run AS gov, recover their
# PWFG_* context via common.sh. The file is RO config (paths, not secrets).
exec sudo -u agent --preserve-env=PWFG_PROMPT,PWFG_MAX_TURNS \
  env -u CLAUDE_CODE_OAUTH_TOKEN \
      ANTHROPIC_BASE_URL="http://127.0.0.1:${PORT}" \
      ANTHROPIC_API_KEY="proxy-local-token" \
      PWFG_ENV_FILE=/srv/pwfg/gov/env \
      CLAUDE_CONFIG_DIR=/srv/pwfg/workspace/.agent-claude \
  claude -p "$PWFG_PROMPT" \
    --model "${PWFG_MODEL:-sonnet}" \
    --max-turns "${PWFG_MAX_TURNS:-12}" \
    --settings /srv/pwfg/gov/settings.json \
    --setting-sources user \
    --dangerously-skip-permissions \
    --output-format json
# NOTE: the gov Stop hook arrives via --settings (authoritative: an agent-writable
# source can only ADD hooks, never remove this one). --setting-sources excludes the
# workspace project/local settings the agent owns. The box build MUST empirically
# confirm this (negative test: agent edits a settings file to drop the hook -> the
# loop still gates); see docs/P1-provisioning.md.
