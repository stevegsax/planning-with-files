# Phase 1 — first-deploy readiness worksheet

Fill this in **before** `cdk deploy`. It captures the per-deploy values and decisions
a real deploy needs and that the stacks do NOT create for you. Pair it with the runbook
in `P1-provisioning.md` (the ordered steps + exact commands). Nothing here has run on
real AWS yet — treat the first deploy as a de-risking exercise, not a routine apply.

## A. Build-first blockers (must be CLOSED in-repo before a deploy can succeed)

A stock deploy of `main` cannot boot a working box yet — these are tracked gaps, not
operator steps. Confirm each is closed (or consciously waived) before you start:

- [ ] **Code delivery** — a mechanism places `/opt/pwfg` (skill/proxy/bootstrap + the
      chosen example) on the isolated box at first boot. (Keystone decision — §B.)
- [ ] **Runtime toolchain** — `claude`(+node), `uv`, `jq`, `git`, coreutils `timeout`,
      `curl` are installed on the box (the isolated subnet cannot fetch them at boot).
- [ ] **Offline uv cache** — a primed `UV_CACHE_DIR` (proxy deps + proof deps + a uv-managed
      CPython 3.13) plus `UV_OFFLINE=1` / `UV_PYTHON_DOWNLOADS=never` so no proof/proxy
      `uv run` ever reaches PyPI.
- [ ] **Key delivery** — `pwfg-key-fetch.service` writes `/run/pwfg/anthropic_key`
      (root `0400`) from SSM before the proxy + boot-assert. (Shipped — verify enabled.)
- [ ] **Proxy → Squid wiring** — `PWFG_PROXY_FORWARD` carries the real Squid IP (not the
      `SQUID_PRIVATE_IP` placeholder); the proxy refuses to start if it is unset. (§D.)
- [ ] **boot-assert egress probe is non-vacuous** — `curl` present is a hard requirement,
      and the probe targets the Squid `:3128` endpoint (the one path the agent can route
      to), not the unreachable `api.anthropic.com` default.

## B. Keystone decision — how code + runtime reach the isolated box

The agent subnet has no internet route; the only egress is Squid → `api.anthropic.com`.
So code, the toolchain, and the uv cache must arrive over a channel that does not need
the internet. Pick one and record it:

- [ ] **S3 via the existing gateway endpoint (recommended v1).** One artifact bucket +
      a tarball (repo + pinned binaries + primed uv cache + chosen example); a
      bucket-scoped `s3:GetObject` grant; cloud-init `aws s3 cp && tar -x` before
      bootstrap. The S3 gateway endpoint already exists (free); preserves isolation.
- [ ] **Baked AMI (the P2 endgame).** No boot-time fetch at all, but needs an image
      build pipeline this repo does not have yet.
- [ ] **SSM push** (SendCommand/State Manager). Adds `ssm:*` surface + ordering.

Chosen method: ____________________   Artifact bucket / AMI id: ____________________

## C. Out-of-band prerequisites (create these; capture the ARNs)

None are created by the stacks — they are referenced by ARN. See `P1-provisioning.md §0`
for the exact `aws` commands.

| Prerequisite | Value / ARN | Done |
|---|---|---|
| AWS account id | | [ ] |
| Region (must offer `t4g` in AZ[0]) | | [ ] |
| `cdk bootstrap aws://<acct>/<region>` run | n/a | [ ] |
| CMK ARN (**with a key policy granting the AgentHostRole `kms:Decrypt` via SSM**) | | [ ] |
| SecureString `pwfg/anthropic-key` (under the CMK) | | [ ] |
| SecureString `pwfg/git-deploy-key` (under the CMK) | | [ ] |
| Audit log group `/pwfg/audit` (the role cannot CreateLogGroup) | | [ ] |
| `pwfg-acceptance` / `pwfg-impl` GitHub repos (only if wiring off-box CI now) | | [ ] |

## D. Post-deploy values (captured DURING the deploy)

| Value | Where it comes from | Value |
|---|---|---|
| `SquidPrivateIp` | `PwfgEgress` stack output | |
| `PWFG_PROXY_FORWARD` drop-in written | `pwfg-proxy.service.d/forward.conf = http://<SquidPrivateIp>:3128` | [ ] |
| `PWFG_EGRESS_PROBE` set for boot-assert | `http://<SquidPrivateIp>:3128` (so the probe is real, not vacuous) | [ ] |
| Chosen example | `PWFG_EXAMPLE` = `toy` or `ledger` (places `locked/` + `workspace/`, sets `PWFG_PLAN`) | |

## E. On-box smoke gates (run via SSM Session Manager — each MUST pass)

- [ ] **SSM reachability** — `aws ssm describe-instance-information` shows `PingStatus=Online`;
      `aws ssm start-session --target <id>` connects (no inbound, no public IP).
- [ ] **boot-assert active for the RIGHT reason** — `systemctl is-active pwfg-boot-assert`
      = active; its egress negative used the Squid `:3128` probe; `curl`/`timeout`/`uv`/`claude` present.
- [ ] **Real-key proxy smoke** — `skill/bin/smoke-proxy.sh`: a real `claude -p` completes
      agent → loopback proxy → Squid CONNECT → `api.anthropic.com`; the call is in
      `audit.jsonl`; **the key appears in neither the audit nor journald**.
- [ ] **Squid allowlist negative** — `curl -x http://<squid-ip>:3128 https://example.com`
      is refused (403) while `api.anthropic.com` succeeds.
- [ ] **Agent egress fence** — `sudo -u agent curl --max-time 3 http://<squid-ip>:3128`
      and `... https://api.anthropic.com` both FAIL (the owner-match).
- [ ] **Stop-hook negative test (plan risk #3)** — `skill/bin/smoke-stop-hook.sh`: the
      agent edits its own settings to drop the Stop hook, a session ends RED, the loop
      STILL gates. If it does not, fix `launch-agent.sh` (`CLAUDE_CONFIG_DIR` /
      `--setting-sources`) before trusting the boundary.
- [ ] **Offline proof** — `sudo -u agent /srv/pwfg/skill/bin/run-proof-as.sh <first-phase>`
      passes with networking effectively down (validates the primed uv cache).

## F. Teardown order (release the cross-stack export + sole egress correctly)

`cdk destroy` in **reverse**: `PwfgEgress` → `PwfgAgentHost` → `PwfgIam` → `PwfgNetwork`.
(`PwfgEgress` imports the agent-host SG from `PwfgNetwork`, locking that export while it
exists.)
