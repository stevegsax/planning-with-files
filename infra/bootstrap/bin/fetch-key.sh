#!/usr/bin/env bash
# fetch-key.sh — deliver the brokered Anthropic key to the proxy's credential path.
#
# Run as ROOT by pwfg-key-fetch.service (a oneshot ordered BEFORE the proxy and
# boot-assert). The proxy (User=proxy) cannot read SSM itself — the agent-host role +
# the IMDS lock keep secret access to root/gov-side units — so root fetches the SSM
# SecureString here and writes it to a tmpfs credential file that pwfg-proxy.service
# then LoadCredential=s into the kernel keyring. The key never lands in any user's env
# or in /proc. Root reaches IMDS + the SSM interface endpoint (the agent owner-match
# only fences the agent uid), so this works on the isolated box.
#
# Env (with defaults):
#   PWFG_KEY_PARAM=pwfg/anthropic-key     the SSM SecureString name
#   PWFG_KEY_OUT=/run/pwfg/anthropic_key  the credential path (tmpfs; 0400 root)
#   PWFG_AWS_REGION=<unset>               override the region (else the CLI default)
set -euo pipefail

PARAM="${PWFG_KEY_PARAM:-pwfg/anthropic-key}"
OUT="${PWFG_KEY_OUT:-/run/pwfg/anthropic_key}"
region_arg=()
[ -n "${PWFG_AWS_REGION:-}" ] && region_arg=(--region "$PWFG_AWS_REGION")

[ "$(id -u)" -eq 0 ] || { echo "fetch-key: must run as root" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "fetch-key: aws CLI not found (deliver it with the runtime bundle)" >&2; exit 1; }

umask 077
mkdir -p "$(dirname "$OUT")"
# --output text + --query keeps the value off argv and out of any log; write atomically.
tmp="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
if ! aws ssm get-parameter --name "$PARAM" --with-decryption \
      --query Parameter.Value --output text "${region_arg[@]}" >"$tmp"; then
  echo "fetch-key: could not read SSM SecureString '$PARAM' (check the name, the CMK key policy, and the SSM endpoint)" >&2
  exit 1
fi
# Reject an empty/placeholder fetch rather than start the proxy with a bad key.
[ -s "$tmp" ] || { echo "fetch-key: fetched value is empty" >&2; exit 1; }
chmod 0400 "$tmp"
mv -f "$tmp" "$OUT"
trap - EXIT
echo "fetch-key: wrote $OUT (root 0400) from SSM '$PARAM'"
