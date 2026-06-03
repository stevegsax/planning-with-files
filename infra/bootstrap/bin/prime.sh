#!/usr/bin/env bash
# prime.sh — TEST-1 "prime-then-fence" setup driver (ExecStart of pwfg-prime.service).
#
# Path A for the first watchable AWS test: the agent box is given SETUP-TIME egress
# through Squid so root can install the toolchain + prime an offline uv cache, AFTER
# which the loop runs with the agent uid fenced to loopback (egress-lock) and the
# agent's model traffic going through Squid. This is a REVERSIBLE TEST-1 BROADENING:
# the Squid allowlist must be opened (on the SEPARATE Squid box, over SSM) for the
# duration of priming and RE-FENCED to api.anthropic.com after; this script only
# touches the AGENT box (dnf/env proxy), never Squid's config.
#
# Runs as ROOT (unaffected by egress-lock — that owner-match fences the agent uid only,
# and by imds-lock). Idempotent: skips if already primed unless PWFG_PRIME_FORCE=1.
#
# Requires (delivered via a systemd drop-in, like the proxy's forward.conf):
#   SQUID_IP    the PwfgEgress SquidPrivateIp (the forward proxy to install THROUGH)
#   VPC_CIDR    the VPC CIDR, so in-VPC endpoints + IMDS stay OFF the proxy (NO_PROXY)
# Env (with defaults):
#   PWFG_SRV=/srv/pwfg   PWFG_SRC=/opt/pwfg/repo   PWFG_EXAMPLE=toy
#   PWFG_PRIME_FORCE=0   PWFG_CLAUDE_FROM_BUNDLE=0 (1 = claude already on PATH; skip install)
#
# FIRST-REAL-BOX VALIDATION: the exact install incantations (uv/claude installers,
# dnf-via-CONNECT-proxy) and the AL2023 dnf mirror hosts are unverified off arm64/AWS;
# tail the Squid access.log during the first run and reconcile the allowlist.
set -uo pipefail

SRV="${PWFG_SRV:-/srv/pwfg}"
SRC="${PWFG_SRC:-/opt/pwfg/repo}"
BIN="$SRV/bin"
SENTINEL="$SRV/state/.primed"

log() { printf 'prime: %s\n' "$*"; }
die() { printf 'prime: ERROR %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ "${PWFG_PRIME_FORCE:-0}" = 1 ] || { [ -f "$SENTINEL" ] && { log "already primed ($SENTINEL); skip"; exit 0; }; }
[ -n "${SQUID_IP:-}" ] || die "SQUID_IP unset — deliver it via a pwfg-prime.service.d drop-in (the PwfgEgress SquidPrivateIp). Failing closed."
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
PROXY="http://${SQUID_IP}:3128"

# --- open setup-time egress THROUGH Squid (reversed at the end) ---
DNF_CONF=/etc/dnf/dnf.conf
PROFILE=/etc/profile.d/pwfg-test1-proxy.sh
restore() {
  [ -f "${DNF_CONF}.pwfg-bak" ] && mv -f "${DNF_CONF}.pwfg-bak" "$DNF_CONF"
  rm -f "$PROFILE"
}
trap restore EXIT

cp -a "$DNF_CONF" "${DNF_CONF}.pwfg-bak" 2>/dev/null || :
grep -q '^proxy=' "$DNF_CONF" 2>/dev/null || printf 'proxy=%s\n' "$PROXY" >>"$DNF_CONF"
cat >"$PROFILE" <<EOF
export HTTPS_PROXY=$PROXY ALL_PROXY=$PROXY
export NO_PROXY=169.254.169.254,169.254.169.253,localhost,127.0.0.1,$VPC_CIDR
EOF
# shellcheck disable=SC1090
. "$PROFILE"

retry() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge 3 ] && return 1; log "retry $n: $*"; sleep 5; done; }

log "installing base toolchain via dnf (through $PROXY)"
retry dnf install -y jq git coreutils curl tmux tar gzip || die "dnf install failed (check the Squid allowlist + access.log)"

if ! command -v uv >/dev/null 2>&1; then
  log "installing uv (astral)"
  retry bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' || die "uv install failed"
  # The astral installer drops uv in ~/.local/bin or /root/.local/bin; expose it system-wide.
  for p in /root/.local/bin/uv "$HOME/.local/bin/uv"; do [ -x "$p" ] && install -m 0755 "$p" /usr/local/bin/uv && break; done
fi
command -v uv >/dev/null 2>&1 || die "uv not on PATH after install"

if [ "${PWFG_CLAUDE_FROM_BUNDLE:-0}" != 1 ] && ! command -v claude >/dev/null 2>&1; then
  log "installing claude"
  retry bash -c 'curl -fsSL https://claude.ai/install.sh | bash' || die "claude install failed (or set PWFG_CLAUDE_FROM_BUNDLE=1 if it rides the code bundle)"
  for p in /root/.local/bin/claude "$HOME/.local/bin/claude"; do [ -x "$p" ] && install -m 0755 "$p" /usr/local/bin/claude && break; done
fi

log "priming the offline uv cache + managed CPython"
"$BIN/prime-uv.sh" || die "prime-uv.sh failed"

log "placing the locked plan + workspace for PWFG_EXAMPLE=${PWFG_EXAMPLE:-toy}"
"$BIN/select-example.sh" || die "select-example.sh failed"

# --- RE-FENCE the agent box's setup egress (Squid itself is re-fenced by the operator) ---
restore; trap - EXIT
install -d -o gov -g gov -m 0700 "$SRV/state" 2>/dev/null || :
: >"$SENTINEL" 2>/dev/null || true
log "done; dnf/env proxy reverted. RE-FENCE Squid now (re-comment the TEST-1 block + reload)."
