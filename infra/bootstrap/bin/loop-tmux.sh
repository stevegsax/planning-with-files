#!/usr/bin/env bash
# loop-tmux.sh — run the orchestrator inside a tmux session so an operator can attach
# READ-ONLY over SSM and watch the agent work, without weakening the no-inbound box.
#
# Runs as gov (ExecStart of pwfg-loop.service). The tricky part (first-real-box check):
# keep the systemd unit's lifetime tracking the LOOP's lifetime, with no orphaned or
# duplicated loop on a Restart. We start a detached session that runs run-loop.sh then
# signals done, and BLOCK in the foreground on that signal — so the unit stays active
# for exactly the loop's life. On a host without tmux (laptop/CI), exec run-loop.sh
# unchanged.
#
# Env: PWFG_TMUX_SOCK=/srv/pwfg/control/tmux.sock  PWFG_SRV=/srv/pwfg
set -uo pipefail

SOCK="${PWFG_TMUX_SOCK:-/srv/pwfg/control/tmux.sock}"
SRV="${PWFG_SRV:-/srv/pwfg}"
SESSION=pwfg
RUNLOOP="$SRV/skill/bin/run-loop.sh"

# Fallback: no tmux, or already inside one — just run the loop directly.
if ! command -v tmux >/dev/null 2>&1 || [ -n "${TMUX:-}" ]; then
  exec "$RUNLOOP"
fi

# -A reuses/recreates the session idempotently so a unit Restart can't collide on the
# name; remain-on-exit keeps the pane + scrollback for a post-mortem.
tmux -S "$SOCK" new-session -A -d -s "$SESSION" -n loop
tmux -S "$SOCK" set-option -g history-limit 50000 >/dev/null 2>&1 || true
tmux -S "$SOCK" set-option -g remain-on-exit on   >/dev/null 2>&1 || true

# Run the loop in the pane, then raise a signal; block here on it so this process (and
# thus the unit) stays alive for the loop's whole life.
tmux -S "$SOCK" send-keys -t "$SESSION:loop" "$RUNLOOP; tmux -S '$SOCK' wait-for -S pwfg-done" Enter
exec tmux -S "$SOCK" wait-for pwfg-done
