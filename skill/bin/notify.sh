#!/usr/bin/env bash
# notify.sh <status> — emit a run-outcome notification.
#
# Always records the outcome to a durable local log. Invokes a user-provided
# channel command (PWFG_NOTIFY_CMD) so the notification can reach you OFF the box
# (ntfy, a webhook, Slack, SNS, email, ...). By default the channel fires only on
# escalation (HUMAN_NEEDED / INCOMPLETE); set PWFG_NOTIFY_ON=all to also notify on
# GREEN completion.
#
# The channel command receives structured data via env and a formatted message on
# stdin:
#   PWFG_NOTIFY_STATUS  GREEN | HUMAN_NEEDED | INCOMPLETE
#   PWFG_NOTIFY_PLAN    plan name
#   PWFG_NOTIFY_PHASE   the stuck/next phase id
#   PWFG_NOTIFY_RUNDIR  the workspace (where to look / SSH to)
#   PWFG_NOTIFY_TITLE   one-line title
# Example:  export PWFG_NOTIFY_CMD='curl -s -H "Title: $PWFG_NOTIFY_TITLE" -d "$(cat)" ntfy.sh/my-topic'

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../lib/common.sh"

status="${1:-UNKNOWN}"
plan="$(jq -r '.name' "$(pwfg_plan_path)" 2>/dev/null || echo '?')"
ws="$(pwfg_workspace)"; sd="$(pwfg_state_dir)"
green="$(pwfg_green_ids | paste -sd, -)"
remaining="$(pwfg_remaining_ids | paste -sd, -)"
stuck="$(pwfg_remaining_ids | head -1)"
title="[pwfg] ${plan}: ${status}"

reason=""
[ -f "$sd/BLOCKED" ] && reason="$(cat "$sd/BLOCKED")"

msg="$title
plan:       $plan
status:     $status
green:      ${green:-none}
remaining:  ${remaining:-none}
stuck/next: ${stuck:-none}
run dir:    $ws"
[ -n "$reason" ] && msg="$msg
details:
$reason"

# Always record locally (durable, XDG).
logdir="${XDG_STATE_HOME:-$HOME/.local/state}/pwfg"
mkdir -p "$logdir"
printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "$plan" "$ws" \
  >>"$logdir/notifications.log"

# External channel: on escalation by default.
case "$status" in
  HUMAN_NEEDED | INCOMPLETE) fire=1 ;;
  *) [ "${PWFG_NOTIFY_ON:-escalate}" = "all" ] && fire=1 || fire=0 ;;
esac

if [ "$fire" = 1 ] && [ -n "${PWFG_NOTIFY_CMD:-}" ]; then
  if PWFG_NOTIFY_STATUS="$status" PWFG_NOTIFY_PLAN="$plan" PWFG_NOTIFY_PHASE="${stuck:-}" \
     PWFG_NOTIFY_RUNDIR="$ws" PWFG_NOTIFY_TITLE="$title" \
     bash -c "$PWFG_NOTIFY_CMD" <<<"$msg"; then
    printf 'notify: %s — channel invoked\n' "$status"
  else
    printf 'notify: %s — channel FAILED (non-fatal); recorded in %s\n' "$status" "$logdir/notifications.log" >&2
  fi
elif [ "$fire" = 1 ]; then
  printf 'notify: %s — recorded (set PWFG_NOTIFY_CMD to ping a channel)\n' "$status"
else
  printf 'notify: %s — recorded\n' "$status"
fi
