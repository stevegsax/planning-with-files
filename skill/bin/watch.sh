#!/usr/bin/env bash
# watch.sh — review the autonomous run over SSM, READ-ONLY, on the no-inbound box.
#
# Run as gov (the operator reaches it via the narrow `sudo -u gov watch.sh` grant, or
# directly when already gov). Subcommands:
#   attach      tmux attach -r (READ-ONLY) to the live loop/agent session
#   logs        follow the orchestrator + gate logs in the state dir
#   status      systemctl status of the loop + any escalation (BLOCKED) marker
#
# The attach is ALWAYS read-only (-r) so a watcher's keystroke can never inject input
# into, or kill, the autonomous run. Detach with Ctrl-b then d.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$DIR/../lib/common.sh" 2>/dev/null || true

SOCK="${PWFG_TMUX_SOCK:-/srv/pwfg/control/tmux.sock}"
SESSION=pwfg
sd="$( (pwfg_state_dir 2>/dev/null) || echo "${PWFG_STATE_DIR:-/srv/pwfg/state}")"

cmd="${1:-attach}"
case "$cmd" in
  attach)
    [ -S "$SOCK" ] || { echo "watch: no tmux socket at $SOCK (is pwfg-loop running under tmux?)"; exit 1; }
    exec tmux -S "$SOCK" attach -r -t "$SESSION"
    ;;
  logs)
    echo "watch: following logs in $sd (Ctrl-c to stop); also: sudo journalctl -fu pwfg-loop"
    # Follow whatever the orchestrator/gate have written, tolerant of which exist yet.
    # shellcheck disable=SC2046
    exec tail -n 40 -F $(ls "$sd"/*.txt "$sd"/*.out "$sd"/*.log 2>/dev/null) 2>/dev/null
    ;;
  status)
    systemctl status pwfg-loop --no-pager 2>/dev/null || true
    if [ -f "$sd/BLOCKED" ]; then echo "--- BLOCKED ---"; cat "$sd/BLOCKED"; else echo "(no BLOCKED marker)"; fi
    [ -f "$sd/status.json" ] && { echo "--- status.json ---"; cat "$sd/status.json"; }
    ;;
  *)
    echo "usage: watch.sh [attach|logs|status]" >&2; exit 2 ;;
esac
