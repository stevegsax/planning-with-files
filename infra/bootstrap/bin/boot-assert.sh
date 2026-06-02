#!/usr/bin/env bash
# boot-assert.sh — fail the boot if the security boundary is not in force.
#
# Run as a root systemd oneshot AFTER the users, the /srv/pwfg layout, and the IMDS
# lock are in place. Every check is a NEGATIVE assertion about the agent uid: a
# violation exits non-zero so the unit (and the box) is marked unhealthy rather than
# silently running an un-fenced agent. Parameterized so tests/test_boundary.sh can
# run it against a temp layout.
#
# Env (with defaults):
#   PWFG_SRV=/srv/pwfg                 the on-box layout root
#   PWFG_AGENT_USER=agent             the unprivileged uid
#   PWFG_IMDS_IP=169.254.169.254      the metadata endpoint
#   PWFG_KEY_CRED=<srv>/proxy/key     a file the agent must NOT be able to read
set -uo pipefail

SRV="${PWFG_SRV:-/srv/pwfg}"
AGENT_USER="${PWFG_AGENT_USER:-agent}"
IMDS_IP="${PWFG_IMDS_IP:-169.254.169.254}"
KEY_CRED="${PWFG_KEY_CRED:-$SRV/proxy/key}"

fail=0
ok()  { printf '  ok   %s\n' "$1"; }
no()  { printf '  FAIL %s\n' "$1"; fail=1; }

as_agent() { sudo -u "$AGENT_USER" "$@"; }

# 1. wedge detection needs a real timeout binary (run-loop.sh degrades to a warning
#    without it — a hung session would then block the loop forever).
if command -v timeout >/dev/null 2>&1; then ok "coreutils 'timeout' present (wedge detection armed)"
else no "coreutils 'timeout' MISSING — wedge detection would be disabled"; fi

# 2. the agent must NOT reach IMDS (else the instance role is a secret backdoor).
if as_agent curl -s -o /dev/null --max-time 3 "http://$IMDS_IP/latest/meta-data/" 2>/dev/null; then
  no "agent CAN reach IMDS ($IMDS_IP) — the role is exfiltratable"
else
  ok "agent cannot reach IMDS ($IMDS_IP)"
fi

# 3. the agent env must carry no LLM credential (it reaches Anthropic via the proxy).
if as_agent env 2>/dev/null | grep -qiE '^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)='; then
  no "agent env contains an LLM credential"
else
  ok "agent env has no LLM credential"
fi

# 4. the agent must not read the brokered key credential.
if [ -e "$KEY_CRED" ] && as_agent cat "$KEY_CRED" >/dev/null 2>&1; then
  no "agent can read the key credential ($KEY_CRED)"
else
  ok "agent cannot read the key credential"
fi

# 5. the agent must not write what judges it: the locked plan, the state dir, or the
#    gov-owned Stop-hook settings.
for tgt in "$SRV/locked/plan.json" "$SRV/state/status.json" "$SRV/gov/settings.json"; do
  if as_agent bash -c "echo x >>'$tgt'" 2>/dev/null; then
    no "agent can write $tgt"
  else
    ok "agent cannot write $tgt"
  fi
done

[ "$fail" -eq 0 ] && { echo "boot-assert: boundary in force"; exit 0; }
echo "boot-assert: BOUNDARY VIOLATION — failing the boot" >&2
exit 1
