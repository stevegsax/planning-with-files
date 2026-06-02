# Phase 1 — provisioning & deploy runbook

This repo ships the **offline-buildable** half of Phase 1: the CDK stacks (synth +
cdk-nag clean), the brokering proxy (`proxy/`), the skill OS-boundary integration
(env-file hook + proof-as-agent), the bootstrap units/scripts, and the off-box CI
gate. The steps below are the **out-of-band** pieces you run against real AWS / real
secrets / real GitHub — they cannot run in the build container.

The deploy order is risk-first: prove reachability before adding capability, prove
the boundary before running an agent.

## 0. Prerequisites you provision

| Thing | Notes |
|-------|-------|
| AWS account + region | Graviton (`t4g`) AL2023 is used; pick a region with it. |
| Dedicated Anthropic API key + budget | Brokered by the proxy; never handed to the agent. |
| Two GitHub repos | `pwfg-acceptance` (protected, holds `locked/` + `skill/`, RO to the agent) and `pwfg-impl` (throwaway, the agent pushes here; intermediate commits may be RED). |
| SSM SecureStrings | `pwfg/anthropic-key` (the LLM key) and `pwfg/git-deploy-key` (RO deploy key for cloning). |
| Customer-managed KMS CMK | Encrypts the two SecureStrings; the role decrypts `kms:ViaService=ssm` only. |
| CloudWatch log group | `/pwfg/audit` for journald + proxy audit shipping. |

Create the SecureStrings + CMK **before** deploy and pass their ARNs as CDK context
(never synthesize secret values into the template).

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
npx cdk@2 deploy PwfgIam PwfgAgentHost \
  -c account=<acct> -c region=<region> \
  -c key_param_arn=<arn> -c deploy_key_param_arn=<arn> \
  -c cmk_arn=<arn> -c audit_log_group_arn=<arn> -c git_cidr=<cidr>
```

cloud-init runs `bootstrap.sh` → `imds-lock.sh` → enables the units. Confirm the
**negative** assertions hold (the boot fails otherwise):

- `sudo -u agent curl --max-time 3 169.254.169.254` **fails** (owner-match DROP);
- the `agent` env carries no `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN`;
- `agent` cannot read `/run/pwfg/anthropic_key` nor write `locked/` / `state/` /
  `gov/settings.json`.

`systemctl status pwfg-boot-assert` must be active (success). The same matrix is
proven locally by `sudo bash tests/test_boundary.sh`.

## 3. Tooling + pre-baked uv cache

Install `claude`, `uv` (py3.13), `jq`, `git`, coreutils `timeout`. Prime the uv
cache for the locked plan's proof commands (pytest/hypothesis/CPython-3.13) and run
proofs with `UV_OFFLINE=1`, so PyPI drops off the egress list entirely. Keep a
documented NAT + host-allowlist fallback only if a phase needs an unprimed dep.

## 4. Key delivery + proxy + the real-key smoke

Deliver the SSM SecureString to `/run/pwfg/anthropic_key` (root-owned, `0400`) at
boot — e.g. a root oneshot doing `aws ssm get-parameter --with-decryption` — so
`pwfg-proxy.service` can `LoadCredential=` it into the kernel keyring. The agent env
never holds the key.

Run the one step that needs the live key (outside the deterministic suite): a
**gov-run real-key smoke** confirming `claude -p` drives cleanly through
`ANTHROPIC_BASE_URL=http://127.0.0.1:8787`, that `audit.jsonl` records the call, and
that the key appears in **neither** the audit nor journald. The deterministic
behaviour (passthrough, cap, kill switch, key-never-leaks) is already covered by
`tests/test_proxy.sh` against the recording fake upstream.

## 5. Boundary end-to-end + the Stop-hook empirical check

Select the example for the run (`locked/` for `toy` or `ledger`) into
`/srv/pwfg/locked` and set `PWFG_PLAN` in `/srv/pwfg/gov/env`. Let the loop drive a
session and confirm:

- **REQUIRED negative test (plan risk #3):** as the agent, edit a workspace
  `.claude/settings.json` (and `~/.claude/settings.json`) to remove/replace the Stop
  hook, then let a session end RED — the loop must **still gate** (the gov hook
  arrives via `--settings` and cannot be dropped). If it does not, adjust
  `--setting-sources` in `bin/launch-agent.sh` until it does.
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

## Conventions reused (not reinvented)

- `PWFG_LAUNCH_CMD` seam (`run-loop.sh`) → `bin/launch-agent.sh` (sudo→agent).
- `PWFG_ENV_FILE` hook (`common.sh`) → sudo-invoked tools recover `PWFG_*`.
- `PWFG_PROOF_AS=agent` (`common.sh`) → proofs (which import agent code) run as agent.
- `notify.sh` / the audit JSONL conventions → off-box notification + per-call audit.
