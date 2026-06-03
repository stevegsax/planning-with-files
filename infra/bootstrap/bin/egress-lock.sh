#!/usr/bin/env bash
# egress-lock.sh — fence the AGENT uid to loopback only (no direct internet egress).
#
# The box now HAS an egress path (the Squid forward proxy), so an instance SG can no
# longer be the agent's only fence: SGs are per-instance, not per-uid. This is the
# per-uid half — an OUTPUT owner-match that lets the agent reach ONLY 127.0.0.1 (the
# loopback brokering proxy) and DROPs everything else from the agent uid. Even with
# subnet egress, a prompt-injected agent cannot exfil: it has no route to the Squid
# box, the VPC DNS resolver, or anywhere else — its sole outbound is the loopback
# proxy, which itself only ever CONNECTs to its hardcoded upstream. Mirrors
# imds-lock.sh (which it subsumes for 169.254.169.254, but that DROP is kept as an
# independently-asserted defense-in-depth layer). Idempotent; run as root.
#
# Two ORDERED rules: a loopback ACCEPT must sit ABOVE the catch-all DROP (netfilter is
# top-down). The ACCEPT is scoped to the loopback DESTINATION (-d 127.0.0.0/8), NOT the
# loopback interface (-o lo): the kernel routes traffic to the host's OWN routable IPs
# out lo too, so an -o lo rule would also let the agent reach a service bound to the
# eth0 IP. Matching the destination keeps the fence "the agent reaches only 127.0.0.0/8
# (the loopback brokering proxy on 127.0.0.1)" true regardless of what binds where. The
# catch-all DROP has no -d/-p/--dport: it blocks DNS-over-eth0, ICMP, raw sockets, and
# any direct dial of the Squid IP — closing the DNS-tunnel and proxy-bypass holes.
#
# To guarantee the ACCEPT-above-DROP ordering invariant regardless of prior chain state
# (a half-applied run, a restored ruleset), we DELETE any existing copies first, then
# insert the ACCEPT at the top and append the DROP — so the order is never inverted.
#
# Durability across reboots is provided by re-running this script every boot via
# pwfg-egress-lock.service (ordered before the proxy/loop/boot-assert) — NOT by
# iptables-save, which is inert on AL2023 without a restore unit. PWFG_EGRESS_PERSIST=1
# still attempts a best-effort save where a backend exists.
#
# Env (with defaults):
#   PWFG_AGENT_USER=agent             the unprivileged uid to fence off
#   PWFG_EGRESS_PERSIST=1             1 = also best-effort persist (iptables-save)
set -euo pipefail

AGENT_USER="${PWFG_AGENT_USER:-agent}"

[ "$(id -u)" -eq 0 ] || { echo "egress-lock: must run as root" >&2; exit 1; }
id "$AGENT_USER" >/dev/null 2>&1 || { echo "egress-lock: no such user: $AGENT_USER (create the agent uid FIRST)" >&2; exit 1; }

# Clear any prior copies of our two rules so we can re-establish a known order.
while iptables -C OUTPUT -d 127.0.0.0/8 -m owner --uid-owner "$AGENT_USER" -j ACCEPT 2>/dev/null; do
  iptables -D OUTPUT -d 127.0.0.0/8 -m owner --uid-owner "$AGENT_USER" -j ACCEPT
done
while iptables -C OUTPUT -m owner --uid-owner "$AGENT_USER" -j DROP 2>/dev/null; do
  iptables -D OUTPUT -m owner --uid-owner "$AGENT_USER" -j DROP
done

# Rule 1 — loopback-destination ACCEPT, INSERTED at the top so it always precedes the
# catch-all DROP (the brokered path: agent -> 127.0.0.1:<proxy port>).
iptables -I OUTPUT 1 -d 127.0.0.0/8 -m owner --uid-owner "$AGENT_USER" -j ACCEPT
echo "egress-lock: installed ACCEPT $AGENT_USER -> 127.0.0.0/8 (top of OUTPUT)"

# Rule 2 — catch-all DROP for everything else from the agent uid, appended to the tail.
iptables -A OUTPUT -m owner --uid-owner "$AGENT_USER" -j DROP
echo "egress-lock: installed catch-all DROP for $AGENT_USER (loopback only)"

if [ "${PWFG_EGRESS_PERSIST:-1}" = 1 ]; then
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
  elif command -v iptables-save >/dev/null 2>&1 && [ -d /etc/sysconfig ]; then
    iptables-save >/etc/sysconfig/iptables
  else
    echo "egress-lock: no persistence backend found; rules are live but not saved" >&2
  fi
fi
