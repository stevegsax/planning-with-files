#!/usr/bin/env bash
# run-proof-as.sh <phase-id> — run ONE phase's proof. Intended to be invoked by the
# governance user AS the unprivileged agent uid (`sudo -u agent run-proof-as.sh <id>`),
# so a pytest proof that imports the agent's code never executes as the privileged
# caller (closes the in-process-as-gov residual).
#
# The proof STRING is read ONLY from the locked plan (by phase-id), never from argv —
# so although this runs as the agent uid, neither the wrapper (gov-owned, agent-RO)
# nor the proof (from the gov-owned plan) is agent-controlled: TRAP 1 stays closed.
# This is why the sudoers grant can be just THIS script instead of an arbitrary `bash`
# as the proof uid (least privilege).
#
# Context (PWFG_PLAN) arrives from the gov caller via the sudoers env_keep. stdout +
# stderr are inherited from the caller, which opened the per-phase log in the
# gov-owned state dir, so this writes the proof's output there without needing access
# to the state dir itself.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh"
pwfg_need jq

# Offline-uv (Path A / TEST-1): when gov sets PWFG_UV_OFFLINE (the pwfg-loop unit), point
# the proof's `uv run` at the box's PRIMED, agent-writable cache + the gov-RO managed
# CPython, and forbid any network/python download — so a fenced agent's proof is a pure
# cache hit. Set HERE (not gov/env, not profile.d, not a broad env_keep): this fixed
# gov-owned wrapper always runs as the agent in the proof's own process after
# `sudo -u agent` resets the env; gov/env is refused when sourced as the agent
# (owner != euid), and profile.d is not read for a nologin non-interactive sudo. A no-op
# off-box / in CI / in the boundary test, whose sudoers never sets PWFG_UV_OFFLINE.
if [ -n "${PWFG_UV_OFFLINE:-}" ]; then
  export UV_CACHE_DIR="${PWFG_UV_CACHE_DIR:-/srv/pwfg/uv/cache}"
  export UV_PYTHON_INSTALL_DIR="${PWFG_UV_PYTHON_DIR:-/srv/pwfg/uv/python}"
  export UV_OFFLINE=1
  export UV_PYTHON_DOWNLOADS=never
fi

id="${1:-}"
[ -n "$id" ] || pwfg_die "usage: run-proof-as.sh <phase-id>"
pwfg_phase_exists "$id" || pwfg_die "unknown phase: $id"
proof="$(pwfg_phase_field "$id" proof)"
[ -n "$proof" ] || pwfg_die "phase has no proof command: $id"

cd "$(pwfg_workdir)" || pwfg_die "plan workdir does not resolve"
exec bash -c "$proof"
