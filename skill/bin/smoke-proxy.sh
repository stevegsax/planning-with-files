#!/usr/bin/env bash
# smoke-proxy.sh — on-box, live-key smoke for the brokering proxy + Squid allowlist.
#
# Run ON THE DEPLOYED BOX (via SSM Session Manager) as root/operator AFTER the proxy is
# up and PWFG_PROXY_FORWARD points at the real Squid IP. This is the one step that needs
# the live key; the deterministic behaviour is already covered offline by
# tests/test_proxy.sh. It asserts the full egress path works AND that the key does not
# leak — turning P1-provisioning.md §4 prose into a pass/fail deploy gate.
#
# Env (with defaults):
#   PWFG_PROXY_PORT=8787                      the loopback proxy port
#   PWFG_PROXY_STATE=/srv/pwfg/proxy          where audit.jsonl lives
#   PWFG_PROXY_FORWARD=<from the proxy unit>  http://<squid-ip>:3128 (for the allowlist test)
#   PWFG_SMOKE_MODEL=claude-haiku-4-5-20251001  a cheap model for the live call
set -uo pipefail

PORT="${PWFG_PROXY_PORT:-8787}"
STATE="${PWFG_PROXY_STATE:-/srv/pwfg/proxy}"
FORWARD="${PWFG_PROXY_FORWARD:-}"
MODEL="${PWFG_SMOKE_MODEL:-claude-haiku-4-5-20251001}"
AUDIT="$STATE/audit.jsonl"

PASS=0; FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
for t in curl; do command -v "$t" >/dev/null 2>&1 || { echo "smoke-proxy: missing $t" >&2; exit 2; }; done

echo "== live completion through the loopback proxy -> Squid -> api.anthropic.com =="
before="$( [ -f "$AUDIT" ] && wc -l <"$AUDIT" || echo 0 )"
req='{"model":"'"$MODEL"'","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}'
code="$(curl -s -o /tmp/pwfg-smoke-body -w '%{http_code}' --max-time 60 \
  -X POST "http://127.0.0.1:$PORT/v1/messages" \
  -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -H 'x-api-key: smoke-dummy-the-proxy-injects-the-real-one' \
  --data "$req")"
[ "$code" = "200" ] && ok "completion returned 200 (full egress path works)" \
  || { no "completion HTTP $code (expected 200)"; sed 's/^/       /' /tmp/pwfg-smoke-body 2>/dev/null | head -4; }

echo "== the live key does NOT leak =="
# We don't know the key value here (gov has no key), so assert no sk-ant- token appears
# in the audit or the proxy's journal — the proxy must never log/persist the key.
if grep -aq 'sk-ant-' "$AUDIT" 2>/dev/null; then no "an sk-ant- token appears in $AUDIT"; else ok "no sk-ant- token in the audit log"; fi
if command -v journalctl >/dev/null 2>&1; then
  if journalctl -u pwfg-proxy --no-pager 2>/dev/null | grep -aq 'sk-ant-'; then
    no "an sk-ant- token appears in the pwfg-proxy journal"
  else ok "no sk-ant- token in the pwfg-proxy journal"; fi
else printf '  note  journalctl unavailable; skipped the journal leak check\n'; fi

echo "== the call was audited =="
after="$( [ -f "$AUDIT" ] && wc -l <"$AUDIT" || echo 0 )"
[ "$after" -gt "$before" ] && ok "a new audit line was written ($before -> $after)" || no "no new audit line ($before -> $after)"

echo "== Squid allowlist (CONNECT to a non-allowlisted host is refused) =="
if [ -n "$FORWARD" ]; then
  # A non-allowlisted host must be refused by Squid (403/forbidden); the allowed host
  # must NOT be refused. We check the proxy's own response, not the upstream.
  ec="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x "$FORWARD" https://example.com 2>/dev/null)"
  case "$ec" in
    403|407) ok "Squid refuses CONNECT to example.com (HTTP $ec)" ;;
    000)     no "no response from Squid at $FORWARD (is the IP/route right?)" ;;
    *)       no "Squid did NOT refuse example.com (HTTP $ec) — allowlist too broad" ;;
  esac
  ac="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -x "$FORWARD" https://api.anthropic.com/v1/messages 2>/dev/null)"
  # Anthropic returns 401/400 to an unauthenticated probe — anything but a Squid 403 means
  # the tunnel was allowed (the point: Squid did not block the allowlisted host).
  [ "$ac" != "403" ] && [ "$ac" != "000" ] && ok "Squid allows CONNECT to api.anthropic.com (HTTP $ac)" \
    || no "Squid did not allow api.anthropic.com (HTTP $ac)"
else
  printf '  note  PWFG_PROXY_FORWARD unset; skipped the allowlist test (set it to http://<squid-ip>:3128)\n'
fi

rm -f /tmp/pwfg-smoke-body
echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
