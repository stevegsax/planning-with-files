# Phase 1 — first watchable test (Path A: prime-then-fence)

A linear runbook for the first real AWS test: stand up the boxes, run the `toy`
(RPN-calculator) example, SSM in and watch the loop work, then tear down.

**Path A = prime-then-fence.** The agent box gets *setup-time* egress through Squid so
root installs the toolchain and primes an offline `uv` cache; then the loop runs with
the **agent uid fenced to loopback** and the agent's model traffic going through Squid.
This proves the loop + proxy + Squid + fence + watch mechanics with the least new code.
Full offline-bundle isolation (no setup-time broadening) is a later test.

> Almost none of Path A's on-box behavior can be tested off arm64/AWS. The install/prime
> incantations, the AL2023 dnf mirror hosts, the offline `uv` cache-hit, and the
> tmux/systemd lifetime are **first-real-box validation** — see "Validate on the box".

## Prereqs

Do everything in `P1-provisioning.md §0` first (`cdk bootstrap`; the CMK **with** a key
policy granting the AgentHostRole `kms:Decrypt` via SSM; the two SecureStrings; the
`/pwfg/audit` log group; the t4g AZ preflight). Fill in `deploy-readiness-worksheet.md`.
The agent box also needs the repo + the `examples/toy` tree on it — Path A assumes your
chosen code-delivery channel (worksheet §B) places `/opt/pwfg/repo` (incl. `examples/`)
before `pwfg-prime.service` runs.

## 1. Deploy

```
cd infra
# Offline gate first — must stay green:
uv run --python 3.13 --with aws-cdk-lib --with constructs --with cdk-nag --with pytest \
  python -m pytest tests/test_synth.py -q
# Risk-first: network, then the rest:
npx cdk@2 deploy PwfgNetwork -c account=<acct> -c region=<region>
npx cdk@2 deploy PwfgIam PwfgAgentHost PwfgEgress \
  -c account=<acct> -c region=<region> \
  -c key_param_arn=<arn> -c deploy_key_param_arn=<arn> \
  -c cmk_arn=<arn> -c audit_log_group_arn=<arn>
```

## 2. Wire the Squid IP (over SSM, post-deploy)

Read the `PwfgEgress` **`SquidPrivateIp`** output, then on the AGENT box write two
drop-ins (the placeholders fail closed until you do):

```
sudo mkdir -p /etc/systemd/system/pwfg-proxy.service.d /etc/systemd/system/pwfg-prime.service.d
printf '[Service]\nEnvironment=PWFG_PROXY_FORWARD=http://%s:3128\n' "$SQUID_IP" \
  | sudo tee /etc/systemd/system/pwfg-proxy.service.d/forward.conf
printf '[Service]\nEnvironment=SQUID_IP=%s\nEnvironment=VPC_CIDR=10.0.0.0/16\n' "$SQUID_IP" \
  | sudo tee /etc/systemd/system/pwfg-prime.service.d/squid.conf
# Make boot-assert's egress probe non-vacuous (probe the one path the agent could reach):
printf '[Service]\nEnvironment=PWFG_EGRESS_PROBE=http://%s:3128\n' "$SQUID_IP" \
  | sudo tee /etc/systemd/system/pwfg-boot-assert.service.d/probe.conf
sudo systemctl daemon-reload
```

## 3. Open the Squid TEST-1 broadening (on the SEPARATE Squid box)

`aws ssm start-session` into the **Squid** instance, paste
`infra/bootstrap/squid-test1-priming.conf.snippet` into `/etc/squid/squid.conf`
(substituting your region into the `al2023` hosts), then `sudo systemctl reload squid`.
Keep `sudo tail -f /var/log/squid/access.log` open here to capture every CONNECT host.

## 4. Prime (on the agent box)

```
sudo systemctl start pwfg-prime.service
sudo journalctl -fu pwfg-prime     # installs toolchain via Squid, primes uv cache + CPython, places toy
```

## 5. Re-fence (back on the Squid box) — do not skip

Re-comment the TEST-1 block, `sudo systemctl reload squid`, then verify the fence:

```
curl -x http://127.0.0.1:3128 https://pypi.org          # expect 403
curl -x http://127.0.0.1:3128 https://example.com       # expect 403
curl -x http://127.0.0.1:3128 https://api.anthropic.com # NOT 403 (allowed)
```

`boot-assert` does **not** check the Squid allowlist — a forgotten-open broadening is the
real risk, so this step is operator-gated.

## 6. Boot-assert + start the loop

```
systemctl is-active pwfg-boot-assert     # active (now asserting a real locked/plan.json)
sudo systemctl start pwfg-loop           # runs under tmux via loop-tmux.sh
```

## 7. Watch (SSM-only; no inbound, no SSH)

```
aws ssm start-session --target <agent-instance-id> --region <region>
sudo journalctl -fu pwfg-loop                       # orchestrator narration
sudo -u gov /srv/pwfg/skill/bin/watch.sh attach     # live agent session, READ-ONLY (Ctrl-b d to detach)
sudo -u gov /srv/pwfg/skill/bin/watch.sh status     # systemctl + any BLOCKED escalation
sudo -u gov /srv/pwfg/skill/bin/watch.sh logs       # follow the state-dir logs
```

Optional heavier path (your own tmux/scrollback): SSM-tunneled SSH via
`AWS-StartSSHSession` (`ssh -o ProxyCommand='aws ssm start-session ...'`) — still no
inbound :22. Watch the toy drive its phases to a GREEN sealed gate.

## 8. Tear down

Follow `docs/P1-teardown.md` — `cdk destroy` in reverse (`PwfgEgress → PwfgAgentHost →
PwfgIam → PwfgNetwork`) and the cost-verification checks. Detaching tmux never signals
the loop; teardown is unaffected.

## Validate on the box (Path A's untested-from-here parts)

1. **Offline proof is a pure cache hit:** `sudo -u agent env PWFG_UV_OFFLINE=1 \
   PWFG_UV_CACHE_DIR=/srv/pwfg/uv/cache PWFG_UV_PYTHON_DIR=/srv/pwfg/uv/python \
   /srv/pwfg/skill/bin/run-proof-as.sh <first-phase>` passes with the fence in force
   (no PyPI/python download). If it rebuilds, pin one `uv` version and confirm priming
   used the same `UV_PYTHON_INSTALL_DIR`.
2. **dnf mirror hosts:** read `/etc/yum.repos.d/amazonlinux.repo` + `/etc/dnf/vars/*` on
   the booted box; put the real `al2023-repos-*` S3 host(s) for your region in the snippet.
3. **Reconcile the allowlist** against the live `access.log` CONNECT hosts during prime
   (release CDNs / Fastly / the exact S3 host) before re-fencing.
4. **claude install via the proxy on arm64** works (or set `PWFG_CLAUDE_FROM_BUNDLE=1`
   and drop `claude_install` from the allowlist if it rides the code bundle).
5. **tmux/systemd lifetime:** `pwfg-loop` stays `active` for the loop's whole life; no
   orphaned/duplicate loop on a Restart.
6. **Watch principal:** confirm the SSM default user (ssm-user vs ec2-user) matches the
   `watch.sh` sudoers grant.
