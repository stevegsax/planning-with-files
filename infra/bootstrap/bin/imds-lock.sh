#!/usr/bin/env bash
# imds-lock.sh — block the AGENT uid from the instance metadata endpoint.
#
# IMDSv2 + a hop limit of 1 is the control-plane half of the IMDS defense; this is
# the on-box half. Without it the agent could still reach 169.254.169.254 and use
# the instance role as a backdoor to every secret the role can read. An OUTPUT
# owner-match DROP scoped to the agent uid keeps root/gov/proxy able to fetch
# secrets at boot while the agent cannot. Idempotent; run as root.
#
# Env (with defaults):
#   PWFG_AGENT_USER=agent             the unprivileged uid to fence off
#   PWFG_IMDS_IP=169.254.169.254      the metadata endpoint
#   PWFG_IMDS_PERSIST=1               1 = persist the ruleset (iptables-save)
set -euo pipefail

AGENT_USER="${PWFG_AGENT_USER:-agent}"
IMDS_IP="${PWFG_IMDS_IP:-169.254.169.254}"

[ "$(id -u)" -eq 0 ] || { echo "imds-lock: must run as root" >&2; exit 1; }
id "$AGENT_USER" >/dev/null 2>&1 || { echo "imds-lock: no such user: $AGENT_USER (create the agent uid FIRST)" >&2; exit 1; }

# Add only if the exact rule is absent (idempotent across reboots / re-runs).
if ! iptables -C OUTPUT -d "$IMDS_IP" -m owner --uid-owner "$AGENT_USER" -j DROP 2>/dev/null; then
  iptables -A OUTPUT -d "$IMDS_IP" -m owner --uid-owner "$AGENT_USER" -j DROP
  echo "imds-lock: installed DROP $AGENT_USER -> $IMDS_IP"
else
  echo "imds-lock: rule already present"
fi

if [ "${PWFG_IMDS_PERSIST:-1}" = 1 ]; then
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
  elif command -v iptables-save >/dev/null 2>&1 && [ -d /etc/sysconfig ]; then
    iptables-save >/etc/sysconfig/iptables
  else
    echo "imds-lock: no persistence backend found; rule is live but not saved" >&2
  fi
fi
