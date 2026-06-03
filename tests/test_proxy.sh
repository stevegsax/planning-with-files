#!/usr/bin/env bash
# test_proxy.sh — deterministic, no-LLM, no-real-key test of the brokering proxy.
#
# Stands the proxy up against a RECORDING FAKE upstream with a DUMMY key and asserts
# the security-relevant behavior: byte-exact streaming passthrough, the real key is
# injected while inbound auth is stripped, the cost cap fires (403 + sentinel), the
# kill switch fires, the audit line is well-shaped, and the key never appears in the
# audit or the proxy's own logs. Run from the repo root.
#
# Uses `uv run --python 3.13 --with …` for the proxy's deps (starlette/httpx/uvicorn),
# matching the repo's existing proof convention. Skips cleanly if uv is absent.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

PASS=0; FAIL=0
ok() { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP test_proxy.sh: %s\n' "$1"; exit 0; }
command -v uv >/dev/null 2>&1 || skip "uv not found"
command -v jq >/dev/null 2>&1 || skip "jq not found"

FPORT=18788; PPORT=18787
KEY="sk-ant-DUMMY-TESTKEY-do-not-log"
TMP="$(mktemp -d -p "${TMPDIR:-/tmp}" pwfgproxy.XXXXXX)"
HEADERS="$TMP/recv_headers.json"
PLOG="$TMP/proxy.log"
mkdir -p "$TMP/state" "$TMP/control"

fpid=""; ppid=""
cleanup() {
  [ -n "$ppid" ] && kill "$ppid" 2>/dev/null
  [ -n "$fpid" ] && kill "$fpid" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }; return 1; }
wait_port() { for _ in $(seq 1 50); do port_open "$1" && return 0; sleep 0.2; done; return 1; }
# The proxy records usage in the post-stream `finally` (after the client gets EOF),
# so a check immediately after curl can race it under load. Wait for the file.
wait_file() { for _ in $(seq 1 50); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }

# --- start the recording fake upstream (stdlib only) ---
PWFG_FAKE_PORT="$FPORT" PWFG_FAKE_HEADERS="$HEADERS" python3 proxy/tests/fake_upstream.py &
fpid=$!
wait_port "$FPORT" || skip "fake upstream did not start"

# --- start the proxy (dummy key, fake upstream, tiny cost cap) ---
PWFG_PROXY_AUTOSTART=0 \
PWFG_PROXY_UPSTREAM="http://127.0.0.1:$FPORT" \
PWFG_PROXY_KEY="$KEY" \
PWFG_PROXY_STATE="$TMP/state" \
PWFG_CONTROL_DIR="$TMP/control" \
PWFG_PROXY_HOST=127.0.0.1 PWFG_PROXY_PORT="$PPORT" \
PWFG_PROXY_MAX_COST_USD="0.005" \
  uv run --python 3.13 --with starlette --with 'httpx>=0.28,<1' --with uvicorn \
  python -m proxy.app >"$PLOG" 2>&1 &
ppid=$!
wait_port "$PPORT" || { no "proxy did not start"; cat "$PLOG"; echo "== $PASS passed, $((FAIL+1)) failed =="; exit 1; }

REQ='{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"hi"}],"stream":true}'

echo "== request 1: byte-exact passthrough + key injection/stripping =="
curl -s -o "$TMP/body1" \
  -H "content-type: application/json" \
  -H "x-api-key: LEAKED-INBOUND-KEY" \
  -H "authorization: Bearer LEAKED-BEARER" \
  -H "anthropic-version: 2023-06-01" \
  --data "$REQ" "http://127.0.0.1:$PPORT/v1/messages"

python3 proxy/tests/fake_upstream.py --dump >"$TMP/expected_body"
if cmp -s "$TMP/body1" "$TMP/expected_body"; then ok "response body is byte-exact"; else no "response body is byte-exact"; fi

recv_xapikey="$(jq -r '.["x-api-key"] // ""' "$HEADERS" 2>/dev/null)"
[ "$recv_xapikey" = "$KEY" ] && ok "upstream received the injected real key" || no "upstream received the injected real key (got '$recv_xapikey')"
[ "$recv_xapikey" != "LEAKED-INBOUND-KEY" ] && ok "inbound x-api-key was stripped" || no "inbound x-api-key was stripped"
[ "$(jq -r '.authorization // "ABSENT"' "$HEADERS")" = "ABSENT" ] && ok "inbound Authorization was stripped" || no "inbound Authorization was stripped"
[ "$(jq -r '.["anthropic-version"] // ""' "$HEADERS")" = "2023-06-01" ] && ok "anthropic-version was preserved" || no "anthropic-version was preserved"
# H3: the proxy must forbid upstream compression so passthrough stays byte-faithful
# and usage is readable. (The fake upstream gzips iff gzip is requested, so a proxy
# that let gzip through would also fail the byte-exact + cost assertions below.)
[ "$(jq -r '.["accept-encoding"] // ""' "$HEADERS")" = "identity" ] && ok "upstream compression disabled (accept-encoding: identity)" || no "upstream compression disabled (got '$(jq -r '.["accept-encoding"] // ""' "$HEADERS")')"

echo "== audit + ledger =="
audit="$TMP/state/audit.jsonl"
wait_file "$audit"  # the allow accounting lands in the post-stream finally
if [ -f "$audit" ]; then ok "audit log written"; else no "audit log written"; fi
allow_cost="$(grep '"outcome":"allow"' "$audit" 2>/dev/null | tail -1 | jq -r '.cost_usd' 2>/dev/null)"
[ -n "$allow_cost" ] && [ "$allow_cost" != "0" ] && ok "allow line records a non-zero cost ($allow_cost)" || no "allow line records a non-zero cost (got '$allow_cost')"
# 1000 input @3/M + 500 output @15/M + 200 cache_read @0.30/M = 0.01056
[ "$allow_cost" = "0.01056" ] && ok "cost matches the priced usage exactly" || no "cost matches the priced usage (got '$allow_cost')"
wait_file "$TMP/state/ledger.json"
[ -f "$TMP/state/ledger.json" ] && ok "ledger persisted to disk" || no "ledger persisted to disk"

echo "== the dummy key never leaks =="
grep -q "$KEY" "$audit" 2>/dev/null && no "key absent from audit log" || ok "key absent from audit log"
grep -q "$KEY" "$PLOG" 2>/dev/null && no "key absent from proxy logs" || ok "key absent from proxy logs"

echo "== request 2: cost cap fires (ledger now over 0.005) =="
code2="$(curl -s -o "$TMP/body2" -w '%{http_code}' \
  -H "content-type: application/json" --data "$REQ" "http://127.0.0.1:$PPORT/v1/messages")"
[ "$code2" = "403" ] && ok "over-cap request returns 403" || no "over-cap request returns 403 (got $code2)"
[ -f "$TMP/state/PROXY_BUDGET_EXHAUSTED" ] && ok "budget-exhausted sentinel written" || no "budget-exhausted sentinel written"
[ "$(jq -r '.type' "$TMP/body2" 2>/dev/null)" = "error" ] && ok "denial body is Anthropic-shaped error" || no "denial body is Anthropic-shaped error"

echo "== kill switch fires =="
: >"$TMP/control/KILL"
curl -s -o "$TMP/body3" "http://127.0.0.1:$PPORT/v1/messages" --data "$REQ" -H "content-type: application/json"
grep -qi "kill" "$TMP/body3" 2>/dev/null && ok "kill switch refuses with a kill message" || no "kill switch refuses with a kill message"
rm -f "$TMP/control/KILL"

echo "== forward-proxy chaining wiring (PWFG_PROXY_FORWARD) =="
# All assertions above ran with PWFG_PROXY_FORWARD UNSET, so the default (direct-to-
# upstream) path is proven byte-identical. Here, prove the seam itself: config_from_env
# surfaces None when unset and the Squid URL when set (the Broker passes it to
# httpx.AsyncClient(proxy=...) so the upstream is CONNECT-tunneled through Squid).
cfg_check="$(env -u PWFG_PROXY_FORWARD uv run --python 3.13 \
  --with starlette --with 'httpx>=0.28,<1' --with uvicorn python - <<'PY'
import os
os.environ["PWFG_PROXY_AUTOSTART"] = "0"  # don't build the module-level app on import
from proxy.app import config_from_env

assert config_from_env().forward_proxy is None, "forward_proxy must be None when unset"
os.environ["PWFG_PROXY_FORWARD"] = "http://10.0.250.5:3128"
assert config_from_env().forward_proxy == "http://10.0.250.5:3128", "forward_proxy must read the env URL"
print("OK")
PY
)"
[ "$cfg_check" = "OK" ] && ok "config_from_env surfaces forward_proxy (None unset / URL set)" \
  || no "config_from_env forward_proxy wiring (got '$cfg_check')"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
