#!/usr/bin/env bash
# prime-uv.sh — populate the offline uv cache + managed CPython for the FENCED agent.
#
# Called by prime.sh while setup-time Squid egress is live (HTTPS_PROXY set). uv keeps
# the wheel cache (UV_CACHE_DIR) and the managed CPython (UV_PYTHON_INSTALL_DIR) in
# SEPARATE trees; the fenced agent later runs `uv run --python 3.13 --with pytest
# --with hypothesis` OFFLINE, so BOTH must be primed and reachable.
#
# WHY the cache is agent-WRITABLE but the python tree is gov-RO (the verified
# correction): at run time uv writes lock/ephemeral-env files INTO the cache root, so a
# group-RO cache fails offline. So we prime a root-owned SEED cache, then copy it into
# an agent-owned cache the agent can write. The managed CPython is only read, so it
# stays gov:pwfg read-only (the agent reads + executes it via the pwfg group).
#
# CACHE-KEY INVARIANT (first-real-box check): uv's ephemeral-env key includes the
# ABSOLUTE interpreter path, so priming MUST use the SAME UV_PYTHON_INSTALL_DIR
# (/srv/pwfg/uv/python) the agent run will use, or the agent misses the primed env and
# tries (and fails, fenced) to reach PyPI. Pin ONE uv version on the box.
set -euo pipefail

SRV="${PWFG_SRV:-/srv/pwfg}"
PYDIR="$SRV/uv/python"
SEED="$SRV/uv/cache-seed"
CACHE="$SRV/uv/cache"
PYVER="3.13"

[ "$(id -u)" -eq 0 ] || { echo "prime-uv: must run as root" >&2; exit 1; }
command -v uv >/dev/null 2>&1 || { echo "prime-uv: uv not on PATH" >&2; exit 1; }

mkdir -p "$SEED" "$PYDIR"
export UV_CACHE_DIR="$SEED" UV_PYTHON_INSTALL_DIR="$PYDIR"

echo "prime-uv: installing managed CPython $PYVER"
uv python install "$PYVER"

# Warm the EXACT proof env (toy/ledger proofs: pytest + hypothesis) AND a bare
# interpreter run, so the cached ephemeral-env hash matches the agent's later run.
echo "prime-uv: warming proof + proxy dependency caches"
uv run --python "$PYVER" --with pytest --with hypothesis python -c 'import pytest, hypothesis'
uv run --python "$PYVER" python -c 'import sys; assert sys.version_info[:2] == (3, 13)'
# The proxy also runs via uv (starlette/httpx<1/uvicorn) — warm it too (proxy uid reads
# the same cache via the pwfg group; harmless to seed here).
uv run --python "$PYVER" --with starlette --with 'httpx>=0.28,<1' --with uvicorn python -c 'import starlette, httpx, uvicorn' || true

# Managed CPython: gov-owned, group-readable/executable, NOT writable by the agent.
chown -R gov:pwfg "$PYDIR"
chmod -R u=rwX,g=rX,o= "$PYDIR"

# Agent-writable cache: copy the seed, hand it to the agent so uv can write its
# lock/ephemeral-env files at run time.
rm -rf "$CACHE"; mkdir -p "$CACHE"
cp -a "$SEED/." "$CACHE/"
chown -R agent:pwfg "$CACHE"
chmod -R u=rwX,g=rwX,o= "$CACHE"
# Reclaim the transient seed (the 8GB root is tight with CPython + wheels x2).
rm -rf "$SEED"

echo "prime-uv: primed cache=$CACHE (agent:pwfg rw), python=$PYDIR (gov:pwfg ro)"
