# Phase 1 — provisioning & deploy runbook

This repo ships the **offline-buildable** half of Phase 1: the CDK stacks (synth +
cdk-nag clean), the brokering proxy (`proxy/`), the skill OS-boundary integration
(env-file hook + proof-as-agent), the bootstrap units/scripts, and the off-box CI
gate. The steps below are the **out-of-band** pieces you run against real AWS / real
secrets / real GitHub — they cannot run in the build container.

The deploy order is risk-first: prove reachability before adding capability, prove
the boundary before running an agent.

> **Build-first blockers (a stock `main` deploy will NOT boot a working box yet).**
> The offline build never had to get code/runtime/secrets onto an *isolated* box. Until
> these are closed in-repo, the box boots into a broken state — close or consciously
> waive each before deploying (see `deploy-readiness-worksheet.md §A`):
> 1. **Code delivery** — nothing places `/opt/pwfg` on the box (cloud-init runs
>    `bootstrap.sh` from a path that does not exist). Pick a delivery method (§B of the
>    worksheet; S3-via-gateway-endpoint recommended).
> 2. **Runtime toolchain** — `claude`/`uv`/`jq`/`git`/`timeout`/`curl` are not installed
>    and the isolated subnet cannot fetch them; they must ride the same channel as the code.
> 3. **Offline uv cache** — proofs/proxy `uv run --with …` need PyPI + a managed CPython;
>    prime a `UV_CACHE_DIR` and export `UV_OFFLINE=1` / `UV_PYTHON_DOWNLOADS=never`.
> 4. **Key + Squid-IP wiring** — `pwfg-key-fetch.service` (shipped) fills
>    `/run/pwfg/anthropic_key`; you must still write the `PWFG_PROXY_FORWARD` /
>    `PWFG_EGRESS_PROBE` drop-ins with the real Squid IP (§3b, §2).

## 0. Prerequisites you provision

| Thing | Notes |
|-------|-------|
| AWS account + region | Graviton (`t4g`) AL2023 is used; pick a region offering it in AZ[0]. |
| Dedicated Anthropic API key + budget | Brokered by the proxy; never handed to the agent. |
| Two GitHub repos | `pwfg-acceptance` (protected) + `pwfg-impl` (throwaway). Only needed when wiring the off-box CI gate (§6). |
| SSM SecureStrings | `pwfg/anthropic-key` (the LLM key) and `pwfg/git-deploy-key`. |
| Customer-managed KMS CMK | Encrypts the SecureStrings; **its key policy must grant the AgentHostRole `kms:Decrypt` via SSM** — the IAM-side grant alone does not authorize a customer CMK. |
| CloudWatch log group | `/pwfg/audit` (the role has `PutLogEvents`/`CreateLogStream`, NOT `CreateLogGroup` — it must pre-exist). |

Exact commands (capture each ARN into `deploy-readiness-worksheet.md §C`):

```
# A fresh account needs CDK's bootstrap stack before any deploy:
npx cdk@2 bootstrap aws://<acct>/<region>

# Confirm t4g is offered in the AZ you'll use:
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=instance-type,Values=t4g.small Name=location,Values=<az> --region <region>

# CMK with a key policy that lets the instance role decrypt via SSM (and keeps IAM delegation):
aws kms create-key --description pwfg --policy "$(cat cmk-policy.json)"   # see below
aws kms create-alias --alias-name alias/pwfg --target-key-id <key-id>

# The two SecureStrings, encrypted under that CMK:
aws ssm put-parameter --name pwfg/anthropic-key  --type SecureString --key-id alias/pwfg --value '<live-anthropic-key>'
aws ssm put-parameter --name pwfg/git-deploy-key --type SecureString --key-id alias/pwfg --value "$(cat deploy_key)"

# The audit log group (the role cannot create it):
aws logs create-log-group --log-group-name /pwfg/audit
```

`cmk-policy.json` must include the standard root delegation **and** an explicit
`kms:Decrypt`/`DescribeKey` allow for the `AgentHostRole` ARN, conditioned on
`kms:ViaService=ssm.<region>.amazonaws.com`. A default console CMK (root-only policy)
deploys cleanly then strands the proxy keyless with `AccessDenied` at runtime.

## 1. SSM reachability spike (de-risk first)

Deploy only `PwfgNetwork` and a bare instance with the SSM core role; confirm
`aws ssm start-session --target <id>` connects to a private box with **no inbound,
no public IP**. Nothing else matters until this works.

```
cd infra
uv run --python 3.13 --with aws-cdk-lib --with constructs --with cdk-nag \
  npx cdk@2 deploy PwfgNetwork \
  -c account=<acct> -c region=<region> -c git_cidr=<git-host-cidr>
```

## 2. Least-priv role + IMDS lockdown + boot assertions

Deploy `PwfgIam` + `PwfgAgentHost` with the real ARNs:

```
npx cdk@2 deploy PwfgIam PwfgAgentHost PwfgEgress \
  -c account=<acct> -c region=<region> \
  -c key_param_arn=<arn> -c deploy_key_param_arn=<arn> \
  -c cmk_arn=<arn> -c audit_log_group_arn=<arn>
```

(`git_cidr` is now vestigial — the box's egress is the Squid forward proxy, §3b, not a
direct SG rule; the isolated subnet has no route for a `git_cidr` rule anyway. Leave it
unset. `PwfgEgress` adds the egress path; see §3b.)

cloud-init runs `bootstrap.sh` → `imds-lock.sh` → `egress-lock.sh` → enables the units.
Confirm the **negative** assertions hold (the boot fails otherwise):

- `sudo -u agent curl --max-time 3 169.254.169.254` **fails** (owner-match DROP);
- `sudo -u agent curl --max-time 3 https://api.anthropic.com` **fails** and
  `sudo -u agent curl --max-time 3 http://<squid-ip>:3128` **fails** (the egress-lock
  owner-match — the agent's only outbound is the loopback proxy);
- the `agent` env carries no `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`;
- `agent` cannot read `/run/pwfg/anthropic_key` nor write `locked/` / `state/` /
  `gov/settings.json`.

`systemctl status pwfg-boot-assert` must be active (success). The same matrix is
proven locally by `sudo bash tests/test_boundary.sh`.

## 3. Tooling + pre-baked uv cache

Install `claude`, `uv` (py3.13), `jq`, `git`, coreutils `timeout`. Prime the uv
cache for the locked plan's proof commands (pytest/hypothesis/CPython-3.13) and run
proofs with `UV_OFFLINE=1`, so PyPI stays off the egress allowlist entirely. If a
phase needs an unprimed dep, prefer **re-priming the cache** — only as a last resort
add `pypi.org` / `files.pythonhosted.org` to the Squid allowlist (§3b), and never to
the agent's reach.

## 3b. Egress: the Squid forward proxy (PwfgEgress)

The agent host is in an isolated subnet with no internet route. `PwfgEgress` gives the
box its one path out: a `t4g.nano` **Squid forward proxy** on a separate public subnet,
domain-allowlisted to `api.anthropic.com`. The on-box brokering proxy CONNECT-tunnels
through it (TLS stays end-to-end to Anthropic, so Squid never sees the brokered key);
the agent-host SG egresses only to the Squid SG on `3128` (never `0.0.0.0/0`, so M6
holds); and `egress-lock.sh` fences the `agent` uid to loopback, so even a
prompt-injected agent cannot reach Squid or anything else but the local proxy.

- **Cost:** ~$7/mo (t4g.nano ~$3 + gp3 ~$0.64 + one public IPv4 ~$3.60). AWS Network
  Firewall (~$290/mo) is fleet-grade overkill for one disposable box and would push the
  agent-host SG toward `0.0.0.0/0` (M6 tension); revisit it only at fleet scale.
- **Wire the proxy to Squid (out of band).** After deploy, read the `PwfgEgress`
  `SquidPrivateIp` output and set it in `pwfg-proxy.service` — the unit ships a
  fail-closed placeholder `PWFG_PROXY_FORWARD=http://SQUID_PRIVATE_IP:3128`. A systemd
  drop-in is cleanest (no in-repo edit), e.g.:

  ```
  mkdir -p /etc/systemd/system/pwfg-proxy.service.d
  printf '[Service]\nEnvironment=PWFG_PROXY_FORWARD=http://%s:3128\n' "$SQUID_IP" \
    > /etc/systemd/system/pwfg-proxy.service.d/forward.conf
  systemctl daemon-reload && systemctl restart pwfg-proxy
  ```
- **The allowlist** lives in `infra/bootstrap/squid-cloud-init.yaml` (`/etc/squid/squid.conf`):
  CONNECT to `api.anthropic.com` only, from the in-VPC source, port 443; everything else
  denied. Add the documented git-host / PyPI escape hatches there only if you truly need
  on-box egress to them (they remain unreachable by the fenced agent uid regardless).
- **Pin the Squid IP** if you replace the box: a changed private IP must be reflected in
  `PWFG_PROXY_FORWARD`, or the proxy CONNECT fails closed (the loop stalls, never leaks).
- **Teardown order:** `PwfgEgress` imports the agent-host SG id from `PwfgNetwork` (the
  SG-referenced egress rule that keeps M6 green), so that export is locked while
  `PwfgEgress` exists. Delete `PwfgEgress` **before** `PwfgNetwork` (and before replacing
  the agent-host SG).

## 4. Key delivery + proxy + the real-key smoke

Key delivery is shipped as **`pwfg-key-fetch.service`** (root oneshot,
`RuntimeDirectory=pwfg` so `/run/pwfg` exists on tmpfs, ordered `Before` the proxy +
boot-assert): it runs `bin/fetch-key.sh`, which `aws ssm get-parameter --with-decryption`
writes `/run/pwfg/anthropic_key` (root `0400`) so `pwfg-proxy.service` can
`LoadCredential=` it into the kernel keyring. The agent env never holds the key. (The
role already permits `ssm:GetParameter` + `kms:Decrypt`-via-SSM — no policy change.)

Run the one step that needs the live key (outside the deterministic suite) via
**`skill/bin/smoke-proxy.sh`** (gov-run, on the box): it confirms `claude -p` drives
cleanly along the full path
— agent → loopback proxy (`ANTHROPIC_BASE_URL=http://127.0.0.1:8787`) → Squid CONNECT
(`PWFG_PROXY_FORWARD`) → `api.anthropic.com` — that `audit.jsonl` records the call, and
that the key appears in **neither** the audit nor journald (nor on the Squid box, which
only sees the CONNECT host). The deterministic behaviour (passthrough, cap, kill switch,
key-never-leaks, the `forward_proxy` wiring) is already covered by `tests/test_proxy.sh`
against the recording fake upstream.

**REQUIRED out-of-band negative smoke (the allowlist):** from the proxy/gov uid on the
box, `curl -x http://<squid-ip>:3128 https://example.com` (a non-allowlisted host) must
be **refused by Squid** (403), while the api.anthropic.com CONNECT succeeds — proving the
domain allowlist, not just connectivity.

## 5. Boundary end-to-end + the Stop-hook empirical check

Select the example for the run (`locked/` for `toy` or `ledger`) into
`/srv/pwfg/locked` and set `PWFG_PLAN` in `/srv/pwfg/gov/env`. Let the loop drive a
session and confirm:

- **REQUIRED negative test (plan risk #3)** via **`skill/bin/smoke-stop-hook.sh`**: as
  the agent, edit a workspace `.claude/settings.json` (and the `CLAUDE_CONFIG_DIR`
  `settings.json`) to remove/replace the Stop hook, then let a session end RED — the
  loop must **still gate** (the gov hook arrives via `--settings` and cannot be
  dropped). If it does not, adjust `CLAUDE_CONFIG_DIR` / `--setting-sources` in
  `bin/launch-agent.sh` until it does. **This has never been verified on a real box —
  it gates the deploy.**
- the agent reaches the verifier only via `sudo -u gov verify-*.sh`;
- `status.json` / `loop.json` / `BLOCKED` are gov-owned in the state dir.

## 6. Off-box CI = the authoritative GREEN

Put `locked/` + `skill/` in `pwfg-acceptance` (branch-protected; the agent's token
has no write). Install `.github/workflows/acceptance.yml` there. On a candidate, the
impl repo fires a `repository_dispatch` (or you run it manually) and CI runs
`verify-all.sh` over both checkouts. **Exit 0 is the true done-signal.** Confirm the
agent's repo-scoped credential cannot push to `pwfg-acceptance`. Wire CI-green into
`skill/bin/notify.sh` (a `PWFG_NOTIFY_CMD` consumer) and key any teardown off **CI
green**, never on-box status.

## 7. Teardown (reverse order)

`cdk destroy` in **reverse** so the cross-stack export + sole egress release cleanly:

```
npx cdk@2 destroy PwfgEgress PwfgAgentHost PwfgIam PwfgNetwork
```

`PwfgEgress` imports the agent-host SG from `PwfgNetwork` (the SG-referenced egress rule
that keeps M6 green), so that export is locked while `PwfgEgress` exists — Egress must go
first. Per the design, key any "complete"/teardown decision off **off-box CI green**, not
on-box status.

## Conventions reused (not reinvented)

- `PWFG_LAUNCH_CMD` seam (`run-loop.sh`) → `bin/launch-agent.sh` (sudo→agent).
- `PWFG_ENV_FILE` hook (`common.sh`) → sudo-invoked tools recover `PWFG_*`.
- `PWFG_PROOF_AS=agent` (`common.sh`) → proofs (which import agent code) run as agent.
- `notify.sh` / the audit JSONL conventions → off-box notification + per-call audit.

See `deploy-readiness-worksheet.md` for the fill-in prerequisites + on-box smoke checklist.
