#!/usr/bin/env bash
# bootstrap.sh — lay out the three-user OS boundary under /srv/pwfg.
#
# Run as root from cloud-init BEFORE imds-lock.sh / the units. Idempotent. Two
# groups encode the access matrix:
#   pwfg     = {agent, gov}   -> agent-RO shared paths (locked/, gov settings)
#   pwfgkey  = {gov, proxy}   -> gov reads the proxy audit/ledger; agent excluded
# The security claims are exercised by tests/test_boundary.sh with prefixed test
# users; this installs the same matrix with the real agent/gov/proxy users.
#
# Env: PWFG_SRC (default /opt/pwfg/repo) — where skill/ + proxy/ + locked/ live.
set -euo pipefail

SRV=/srv/pwfg
SRC="${PWFG_SRC:-/opt/pwfg/repo}"
[ "$(id -u)" -eq 0 ] || { echo "bootstrap: must run as root" >&2; exit 1; }

# --- identities ---
getent group pwfg     >/dev/null || groupadd --system pwfg
getent group pwfgkey  >/dev/null || groupadd --system pwfgkey
id agent >/dev/null 2>&1 || useradd  --system --create-home --shell /usr/sbin/nologin -G pwfg          agent
id gov   >/dev/null 2>&1 || useradd  --system --create-home --shell /bin/bash         -G pwfg,pwfgkey gov
id proxy >/dev/null 2>&1 || useradd  --system --create-home --shell /usr/sbin/nologin -G pwfgkey       proxy

# --- layout ---
install -d -m 0755 "$SRV"
install -d -o root  -g pwfg    -m 0755 "$SRV/bin"
install -d -o gov   -g pwfg    -m 0750 "$SRV/locked" "$SRV/skill" "$SRV/gov"
install -d -o gov   -g gov     -m 0700 "$SRV/state"
install -d -o agent -g pwfg    -m 2770 "$SRV/workspace"
install -d -o proxy -g pwfgkey -m 0750 "$SRV/proxy"
install -d -o gov   -g pwfgkey -m 0750 "$SRV/control"
install -d -o agent -g pwfg    -m 2770 "$SRV/workspace/.agent-claude"

# --- deploy code (gov-owned, agent-RO via group) ---
if [ -d "$SRC/skill" ]; then
  cp -a "$SRC/skill/."  "$SRV/skill/"
  cp -a "$SRC/proxy/."  "$SRV/proxy-src/" 2>/dev/null || true
  # locked/ for the chosen example is selected out of band; see P1-provisioning.md.
  chown -R gov:pwfg "$SRV/skill"
  chmod -R o-rwx "$SRV/skill"
fi

# Deploy the infra helper scripts (launch-agent/imds-lock/boot-assert) to a stable,
# gov-readable path referenced by the units.
for s in launch-agent imds-lock egress-lock boot-assert; do
  install -o root -g pwfg -m 0755 "$SRC/infra/bootstrap/bin/$s.sh" "$SRV/bin/$s.sh"
done

# --- gov env + Stop-hook settings (agent-RO) ---
if [ ! -f "$SRV/gov/env" ]; then
  install -o gov -g pwfg -m 0640 "$SRC/infra/bootstrap/gov.env.example" "$SRV/gov/env"
fi
install -o gov -g pwfg -m 0640 "$SRC/infra/bootstrap/gov.settings.json" "$SRV/gov/settings.json"

# --- sudoers (agent->gov verify bridge; gov->agent launch) ---
install -o root -g root -m 0440 "$SRC/infra/bootstrap/sudoers.d/pwfg" /etc/sudoers.d/pwfg
visudo -cf /etc/sudoers.d/pwfg

# --- systemd units ---
for u in pwfg-imds-lock pwfg-egress-lock pwfg-proxy pwfg-loop pwfg-boot-assert; do
  install -o root -g root -m 0644 "$SRC/infra/bootstrap/units/$u.service" "/etc/systemd/system/$u.service"
done

echo "bootstrap: /srv/pwfg laid out; users agent/gov/proxy; groups pwfg/pwfgkey"
