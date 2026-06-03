#!/usr/bin/env bash
# select-example.sh — place a chosen example's locked/ + workspace/ under /srv/pwfg.
#
# bootstrap.sh deliberately does not copy locked/ (the example is a per-run choice).
# This places examples/$PWFG_EXAMPLE/{locked,workspace} as SIBLINGS under /srv/pwfg
# with the boundary ownership/modes. The sibling layout is LOAD-BEARING: the toy plan's
# workdir is '..', and conftest.py / sealed_check.py fall back to parents[2|1]+'workspace'
# to find the workspace — which resolves to /srv/pwfg/workspace only because locked/ and
# workspace/ are siblings here (the agent proof's PWFG_WORKSPACE is not in the env_keep).
#
# Runs as root (called by prime.sh). Idempotent per example via a marker.
# Env: PWFG_SRV=/srv/pwfg  PWFG_SRC=/opt/pwfg/repo  PWFG_EXAMPLE=toy  PWFG_PRIME_FORCE=0
set -euo pipefail

SRV="${PWFG_SRV:-/srv/pwfg}"
SRC="${PWFG_SRC:-/opt/pwfg/repo}"
EX="${PWFG_EXAMPLE:-toy}"
SRC_EX="$SRC/examples/$EX"
MARK="$SRV/state/.example-$EX"

[ "$(id -u)" -eq 0 ] || { echo "select-example: must run as root" >&2; exit 1; }
[ -f "$SRC_EX/locked/plan.json" ] || { echo "select-example: no $SRC_EX/locked/plan.json" >&2; exit 1; }
[ -d "$SRC_EX/workspace" ] || { echo "select-example: no $SRC_EX/workspace" >&2; exit 1; }
if [ -f "$MARK" ] && [ "${PWFG_PRIME_FORCE:-0}" != 1 ]; then echo "select-example: $EX already placed; skip"; exit 0; fi

# locked/  gov:pwfg, dirs 0750 / files 0640 — agent reads via pwfg group, cannot write.
mkdir -p "$SRV/locked"
cp -a "$SRC_EX/locked/." "$SRV/locked/"
chown -R gov:pwfg "$SRV/locked"
chmod -R u=rwX,g=rX,o= "$SRV/locked"

# workspace/  agent:pwfg 2770 (setgid) — agent rwx, gov rwx via group.
mkdir -p "$SRV/workspace"
cp -a "$SRC_EX/workspace/." "$SRV/workspace/"
chown -R agent:pwfg "$SRV/workspace"
chmod 2770 "$SRV/workspace"
find "$SRV/workspace" -type d -exec chmod 2770 {} +
find "$SRV/workspace" -type f -exec chmod 0660 {} +

# Pin the interpreter the example expects (parity with the laptop/CI runs).
[ -f "$SRC_EX/.python-version" ] && install -o gov -g pwfg -m 0640 "$SRC_EX/.python-version" "$SRV/.python-version"

install -d -o gov -g gov -m 0700 "$SRV/state" 2>/dev/null || :
: >"$MARK" 2>/dev/null || true
echo "select-example: placed $EX (locked gov:pwfg ro, workspace agent:pwfg 2770)"
