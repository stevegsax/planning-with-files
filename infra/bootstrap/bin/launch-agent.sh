#!/usr/bin/env bash
# launch-agent.sh — start the agent's bounded, headless claude session.
#
# Invoked BY gov AS the agent uid (run-loop's PWFG_LAUNCH_CMD is
# "sudo -u agent /srv/pwfg/bin/launch-agent.sh"), so this script already runs
# unprivileged: it sets the agent's environment and execs claude DIRECTLY — no
# internal `sudo -u agent`. The gov->agent crossing is therefore the single narrow
# sudoers grant for THIS one script, never `env`/`claude`/arbitrary commands.
#
# The agent reaches Anthropic ONLY via the loopback proxy (no real key in its env),
# and the Stop hook arrives via the gov-owned --settings file (an agent-writable
# settings source can only ADD hooks, never remove this one). PWFG_PROMPT /
# PWFG_MAX_TURNS / PWFG_MODEL / PWFG_PROXY_PORT arrive from gov via the sudoers
# env_keep. PWFG_SRV (default /srv/pwfg) and PWFG_CLAUDE_BIN (default claude) are
# overridable so tests/test_boundary.sh can exercise this under a temp tree + a stub.
set -uo pipefail

SRV="${PWFG_SRV:-/srv/pwfg}"
PORT="${PWFG_PROXY_PORT:-8787}"
CLAUDE_BIN="${PWFG_CLAUDE_BIN:-claude}"

# No LLM credential in the agent env; the proxy injects the real key server-side.
unset CLAUDE_CODE_OAUTH_TOKEN
export ANTHROPIC_BASE_URL="http://127.0.0.1:${PORT}"
export ANTHROPIC_API_KEY="proxy-local-token"
# The Stop hook + verify bridge run AS gov and recover their context from the gov-owned
# env file (common.sh refuses to source any other PWFG_ENV_FILE), so set it for claude.
export PWFG_ENV_FILE="$SRV/gov/env"
export CLAUDE_CONFIG_DIR="$SRV/workspace/.agent-claude"

exec "$CLAUDE_BIN" -p "${PWFG_PROMPT:-}" \
  --model "${PWFG_MODEL:-sonnet}" \
  --max-turns "${PWFG_MAX_TURNS:-12}" \
  --settings "$SRV/gov/settings.json" \
  --setting-sources user \
  --dangerously-skip-permissions \
  --output-format json
# The gov Stop hook arrives via --settings (authoritative: an agent-writable source can
# only ADD hooks, never remove this one); --setting-sources excludes the workspace
# project/local settings the agent owns. The box build MUST confirm this empirically
# (negative test: agent edits a settings file to drop the hook -> the loop still gates);
# see docs/P1-provisioning.md.
