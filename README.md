# Gated planning skeleton (Phase 0)

A walking skeleton for the disposable autonomous-agent design worked out in
`grill-me-sessions/redesign-plan-with-files.md`. It exists to answer the one
question the whole design rests on, on bare metal, before any cloud or image
work:

> Does a single headless Claude Code run, driven by a Stop hook and a JSON plan,
> march through a multi-phase spec and stop **only** when objective tests are
> green — while the acceptance suite and the gate stay outside the agent's reach?

That core mechanism is proven deterministically by `tests/test_harness.sh` and
driven live by `examples/toy/run-experiment.sh`. The skeleton has since grown into
a fuller autonomy engine — multi-session resume across fresh context windows, a
self-scaling turn budget, a fact-anchored (optionally LLM-narrated) handoff, and
off-box escalation notifications — all exercised by three no-LLM self-test suites.

## Layout

```
test-planning-with-files/
├── skill/                          # the forked, test-gated skill
│   ├── SKILL.md
│   ├── schema/plan.schema.json     # the plan contract (JSON Schema)
│   ├── lib/common.sh               # path/JSON helpers, proof runner, status cache
│   └── bin/
│       ├── init-session.sh         # validate plan, reset state
│       ├── verify-task.sh          # run ONE phase's proof (fast feedback)
│       ├── verify-all.sh           # authoritative gate: run ALL proofs fresh
│       ├── plan-status.sh          # cached progress view
│       ├── escalate.sh             # explicit human handoff (BLOCKED marker)
│       ├── stop-gate.sh            # the Stop hook: block until green / checkpoint
│       ├── handoff.sh              # regenerate the fact-anchored HANDOFF.md
│       ├── handoff-narrate.sh      # optional LLM narrator (reads the transcript)
│       ├── notify.sh               # run-outcome notification (escalation channel)
│       └── run-loop.sh             # orchestrator: fresh bounded sessions + resume
├── examples/toy/                   # the RPN-calculator experiment
│   ├── run-experiment.sh           # single-session driver
│   ├── run-loop.sh                 # multi-session orchestrated driver
│   ├── .python-version             # pins the interpreter (3.13)
│   ├── locked/                     # governance-owned, read-only to the agent
│   │   ├── plan.json               # 4 phases + proof commands
│   │   ├── sealed_check.py         # tamper-resistant out-of-process gate (phase 4)
│   │   └── tests/                  # pytest contract tests (agent feedback)
│   ├── workspace/                  # agent-owned: AGENT_TASK.md + rpn/ stub
│   ├── _reference/core.py          # harness-only reference solution (self-test)
│   └── _attacks/                   # harness-only adversarial fakes (self-test)
├── examples/ledger/                # 6-phase double-entry ledger (spans sessions)
│   ├── run-loop.sh                 # multi-session driver
│   ├── locked/                     # plan.json + sealed_check.py + tests/
│   ├── workspace/ledger/           # 5 stub modules the agent implements
│   └── _reference/                 # reference modules (self-test)
├── tests/
│   ├── test_harness.sh             # deterministic gate/tool self-test (no LLM)
│   ├── test_orchestrator.sh        # deterministic orchestrator self-test (no LLM)
│   ├── test_ledger.sh              # deterministic ledger self-test (no LLM)
│   ├── test_proxy.sh               # P1: brokering proxy vs a recording fake upstream
│   ├── test_boundary.sh            # P1: OS-ownership boundary (root; throwaway users)
│   └── fixtures/
├── proxy/                          # P1: LLM brokering proxy (function core + shell)
│   ├── core.py                     # pure: cost / caps / parse_usage / audit_line
│   ├── app.py                      # shell: Starlette+httpx streaming passthrough
│   └── tests/test_core.py          # pytest/hypothesis pure-core tests
├── infra/                          # P1: AWS CDK (Python) — synth + cdk-nag
│   ├── app.py  aspects.py  stacks/ # Network / Iam / AgentHost / Egress stacks
│   ├── bootstrap/                  # cloud-init, systemd units, sudoers, imds/egress-lock, squid
│   └── tests/test_synth.py         # offline synth + nag assertions
└── docs/P1-provisioning.md         # the out-of-band AWS/secrets/CI deploy runbook
```

## Phase 1 — the real security boundary

Phase 0's workspace/state split is a *convention* under one OS user. Phase 1 makes
it an enforced boundary on a cloud VM: three OS users (`agent`/`gov`/`proxy`), an
on-box IMDS lock, the LLM key brokered by a loopback proxy (hidden + cost-capped +
audited), and an off-box CI gate. This repo holds the offline-buildable half; see
`docs/P1-provisioning.md` for the AWS deploy steps. The boundary itself is proven by
`sudo tests/test_boundary.sh` (creates throwaway users and checks the agent cannot
edit what judges it, read the key/audit, reach IMDS, or egress off-box — while gov
still drives the loop to GREEN across the uid split).

The agent host sits in an isolated subnet with no internet route. Its one path to
`api.anthropic.com` is a **domain-allowlist Squid forward proxy** on a separate public
subnet (`PwfgEgress`): the brokering proxy CONNECT-tunnels through it (TLS end-to-end,
so Squid never sees the key), the agent-host security group egresses only to the Squid
SG (never `0.0.0.0/0`), and an `egress-lock` owner-match fences the `agent` uid to
loopback so even a prompt-injected agent reaches nothing but the local proxy. ~$7/mo
for a `t4g.nano` (vs ~$290/mo for AWS Network Firewall — overkill for one disposable box).

## Run the deterministic self-test

Proves the tools, Stop gate, and orchestrator behave — no API key, no agent.

```
tests/test_harness.sh        # RED/GREEN, sealed anti-fake, infra-vs-RED, escalate, bounded blocks, anti-injection
tests/test_orchestrator.sh   # multi-session: checkpoints, scaling budget, stall->human, notifications, .subtype
tests/test_ledger.sh         # 6-phase ledger reference passes every phase incl. the sealed gate
```

Requires `bash`, `jq`, `uv`, `git`. The first run downloads `pytest`/`hypothesis`
into an ephemeral `uv` environment.

## Run the live experiment

Drives a real headless Claude Code run against a disposable copy of the toy
workspace, gated by the Stop hook.

```
export ANTHROPIC_API_KEY=sk-ant-...      # a dedicated key (not your subscription)
examples/toy/run-experiment.sh
```

Optional env: `PWFG_MODEL` (default `sonnet`), `MAX_TURNS` (default `40`),
`PWFG_MAX_BLOCKS` (default `40`).

**Success looks like:** `RESULT: GREEN — the loop drove the plan to completion`,
reached only by actually implementing the calculator (the sealed gate makes
faking infeasible). A bounded `RESULT: BLOCKED` (escalation or infra error) or
`RESULT: RED` (hit `--max-turns`) are the designed safe stops, not crashes.

## Long tasks: bounded sessions + resume

A single `claude -p` run shares one context window, so a long task can exhaust it
before finishing. The orchestrator (`skill/bin/run-loop.sh`) instead runs a
sequence of **fresh, bounded sessions** — each sheds its context; continuity lives
on disk (locked plan, derived status, git checkpoints, `HANDOFF.md`).

```
examples/toy/run-loop.sh        # the easy RPN toy (usually one session)
examples/ledger/run-loop.sh     # a 6-phase ledger that reliably spans sessions
```

The ledger is the real multi-session demo: it checkpoints each phase, commits it,
and a fresh session resumes from the committed code + `HANDOFF.md`. With the
default progress-scaling budget (below) it completes all 6 phases across ~3 fresh
sessions, with no hand-picked turn cap.

Each session ends on either a **checkpoint** (a phase goes green → `subtype:
success`) or the **turn cap** (`subtype: error_max_turns`); the orchestrator then
runs `verify-all`, commits any newly-green phase as a checkpoint, regenerates a
bounded fact-anchored `HANDOFF.md`, and launches a fresh session that resumes from
disk. A session that **crashes** or **wedges** is shed and retried fresh
([auto-recovery](#auto-recovery-self-heals-a-crashed-or-wedged-session)). It stops
on: gate green (done), agent 3-strike escalation, a cross-session **stall** (no new
green in N sessions → human), an **infra error**, a crash/wedge loop that exhausts
the recovery limit, or a **session budget** cap.

It **never edits the locked plan.** A phase too big even at the *maximum*
per-session budget surfaces as a stall and escalates to a human to re-author the
plan into smaller, independently-gated phases — splitting a phase means splitting
its proof, which is a governance act, not an autonomous one.

### The turn budget scales with progress

Transcript forensics on real runs showed the orientation tax is dominated by
re-reading file *contents* to rebuild understanding (in a blocked run, 4 of 6
sessions wrote zero code; orientation:implementation ran ~11–15:1), that the tax
**grows as the codebase grows**, and that the **turn budget is the decisive lever**
(at 8 turns the ledger blocked; at 16 it completed). So the budget is no longer a
fixed cap — it **scales with progress**:

```
budget = clamp(base + per_phase × green_count + reactive_extra, base, max)
```

Later phases (more committed code) get more turns *proactively*; and if a session
runs out of turns with **no** progress, the orchestrator raises `reactive_extra`
and retries rather than counting a stall — automating the old "raise the cap"
advice. It escalates to a human only once even the **max** budget can't finish a
phase. Knobs: `PWFG_TURNS_BASE` (12), `PWFG_TURNS_PER_PHASE` (3), `PWFG_TURNS_MAX`
(24), `PWFG_TURNS_BUMP` (4); set `PWFG_TURNS_PER_SESSION` to force a fixed budget.
Live: the ledger completed in 3 sessions from a base of 12 (12 → reactive 16 →
scaled 24) with no hand-picked cap.

As a *secondary* help, the handoff carries a deterministic **"Files for this
phase"** block — `EDIT` (the module, only if it exists on disk), `PROVE WITH` (the
test/proof path), and the test's own import lines verbatim — derived from the
locked plan + proof so it can't go stale or point wrong, with a *soft* "start here,
read elsewhere only if a symbol's missing" nudge. (A repo TOC or source map was
rejected for this plan-driven repo: the plan already navigates, and stubs + locked
tests already pin every signature.)

The handoff backbone is deterministic. An **optional LLM narrator**
(`handoff-narrate.sh`, enabled with `PWFG_NARRATE=1`) reads the just-ended
session's transcript — located by the exact `session_id` from its `claude -p`
json — digests it, and appends a brief *advisory* "what was tried / next step"
note (via a cheap `haiku` call). It matters most after `error_max_turns`, when the
dev agent got no turn to leave notes. Advisory only: the gate stays authoritative,
so a wrong narrative can't fake progress; it no-ops cleanly when disabled or when
no transcript is found. The orchestrator also logs per-session and total
`total_cost_usd` from the json.

**Notifications.** When a run ends, `notify.sh` records the outcome to a durable
local log (`$XDG_STATE_HOME/pwfg/notifications.log`) and — on **escalation**
(`HUMAN_NEEDED`) by default — invokes a user-provided channel so the ping reaches
you *off the box*. Set `PWFG_NOTIFY_CMD` to any command; it receives the outcome
via env (`PWFG_NOTIFY_STATUS`/`_PLAN`/`_PHASE`/`_RUNDIR`/`_TITLE`) and a formatted
message on stdin. Examples:

```
# ntfy.sh
export PWFG_NOTIFY_CMD='curl -s -H "Title: $PWFG_NOTIFY_TITLE" -d "$(cat)" ntfy.sh/my-topic'
# Slack/Discord incoming webhook
export PWFG_NOTIFY_CMD='curl -s -X POST -H "Content-type: application/json" \
  --data "{\"text\": $(cat | jq -Rs .)}" "$SLACK_WEBHOOK_URL"'
```

Set `PWFG_NOTIFY_ON=all` to also notify on `GREEN` completion. The agent's own
3-strike `escalate.sh`, a cross-session stall, infra errors, and the session-budget
cap all surface as `HUMAN_NEEDED` and trigger the channel.

### Auto-recovery self-heals a crashed or wedged session

A fresh session resuming from disk is exactly how the disposable design recovers
from a session that died, so the orchestrator does that automatically instead of
escalating on the first failure. It classifies an abnormal session end into two
kinds and treats them differently:

- A **crash** — `subtype: error_during_execution`, or a non-zero exit with no
  result JSON — is shed and **retried from a fresh session** up to
  `PWFG_RECOVER_LIMIT` (default `2`) *consecutive* times. The counter resets on any
  productive or clean session, so occasional transient crashes across a long run are
  tolerated; only a persistent crash loop escalates — with a **distinct** "this is an
  environment/agent fault, *not* a too-big phase" message and pointers to the
  forensics (it never tells a human to re-author the plan, which would be the wrong
  fix). `subtype: unknown` with a *clean* exit is **not** treated as a crash — the
  gate is trusted, so a healthy session that merely printed an odd log line is never
  rolled back (which would livelock it).
- A **wedge** — a session killed by the per-session wall clock (`PWFG_SESSION_TIMEOUT`,
  default `3600`s, via `timeout`/`gtimeout`) — is rolled back and fed through the same
  budget/stall machinery as a no-progress turn-cap: the budget is raised and the
  session retried, and if sessions keep wedging even at the maximum budget it
  escalates as a wedge (raise the timeout / `PWFG_TURNS_MAX`, or re-author). This
  keeps a slow-but-too-big phase from being misdiagnosed as a crash. Wedge detection
  needs a `timeout` binary; without one it warns and degrades (a true hang would
  otherwise block the loop forever).

Before any retry, the crashed/wedged session's **uncommitted** work is rolled back
to the last green checkpoint with `git stash` (recoverable; the destructive
`reset --hard` fallback archives untracked files first), and the tree is verified
clean before the next session starts. Committed checkpoints are never touched.
`HANDOFF.md`, `progress.md`, and the harness state dir are kept out of git, so a
rollback only ever sheds the agent's own uncommitted *code* — never the handoff,
the agent's notes, or the status cache. Forensics for every abnormal session land
in `.harness/logs/recovery.log` and `.harness/recovery/`. `PWFG_RECOVER_RESET=0`
keeps a crashed tree as-is (retry without rolling back); `PWFG_SESSION_TIMEOUT=0`
disables wedge detection. `PWFG_MAX_SESSIONS` remains the ultimate backstop — every
retry counts as a session, so the loop always terminates regardless of the
recovery and stall counters.

Knobs: turn budget `PWFG_TURNS_{BASE,PER_PHASE,MAX,BUMP}` (12/3/24/4, or
`PWFG_TURNS_PER_SESSION` to fix it), `PWFG_MAX_SESSIONS` (10), `PWFG_STALL_LIMIT`
(2), `PWFG_STOP_AT_CHECKPOINT` (1), `PWFG_GIT_CHECKPOINTS` (1), `PWFG_RECOVER_LIMIT`
(2), `PWFG_RECOVER_RESET` (1), `PWFG_SESSION_TIMEOUT` (3600), `PWFG_NARRATE` (0),
`PWFG_NARRATE_MODEL` (haiku), `PWFG_NOTIFY_CMD` (unset), `PWFG_NOTIFY_ON`
(escalate).

## What the gate does and does not guarantee (P0)

The contract tests under `locked/tests/` import the agent's `rpn.core`, so the
agent's code runs *inside* the pytest process and a deliberately adversarial
agent can rewrite a pytest verdict from within (verified — see `_attacks/`). This
is **not** closed by an OS-uid boundary or by off-box CI, because both still
import the agent's code into the judging process.

The skeleton closes it with a **sealed differential gate** (`phase4-sealed-gate`,
`locked/sealed_check.py`): it runs `calc` in a locked-down subprocess and compares
serialized outputs against a trusted oracle on unpredictable inputs, so faking
the gate requires actually computing the answer. The Stop gate requires this
phase, so "done" cannot be faked even by a `core.py` that fools pytest.

Caveats that remain for P0 (closed in Phase 1):
- the status cache and loop counter are agent-writable; they are advisory and
  never trusted (the gate re-runs fresh; the counter fails safe). Phase 1 makes
  them harness-uid-owned.
- the in-process pytest subversion is a *deliberately adversarial* (threat-c)
  move; under the design's threat model (honest agent + prompt-injection) it is
  not exploited, and the sealed gate closes it regardless. Where a spec has no
  trusted oracle, this pattern degrades and you fall back to the threat model +
  process isolation.

## How this maps to the design decisions

| Grill decision | Where it lives |
|----------------|----------------|
| Derived status, never self-certified | `verify-*` compute from proofs; status is advisory only |
| Objective gate = green tests | `verify-all.sh` runs the locked suite + sealed gate |
| Gate the agent can't fake | `phase4-sealed-gate` / `sealed_check.py` (out-of-process) |
| Locked tests/plan immutable to agent | `examples/toy/locked/`; proof source = plan only |
| Escalate-and-wait vs forced-continue | `stop-gate.sh` (BLOCKED wins) + `escalate.sh` |
| Infra error ≠ test failure | `verify-all` exit 2 → `stop-gate` escalates, doesn't loop |
| Bounded runaway (fails safe) | `PWFG_MAX_BLOCKS` + run `--max-turns` |
| Context hygiene | terse verdict to the model; full output to `.harness/logs/` |
| Context-bounded long tasks | `run-loop.sh`: fresh sessions, continuity on disk |
| Resume across fresh sessions | `handoff.sh` (facts) + git checkpoints + derived status |
| Turn budget scales with progress | `pwfg_session_budget`: proactive + reactive bump |
| Cut re-orientation | `handoff.sh` "Files for this phase" (EDIT / PROVE WITH / imports) |
| Too-big phase → human, not auto-split | cross-session stall → `BLOCKED` "re-author the plan" |
| Self-heal a crashed session | `run-loop.sh` rolls back + retries fresh, bounded by `PWFG_RECOVER_LIMIT` |
| Self-heal a wedged session | wall-clock `PWFG_SESSION_TIMEOUT` → roll back → bump budget / stall |
| Crash ≠ too-big phase (no misdiagnosis) | distinct, cause-aware escalations; forensics in `.harness/recovery/` |
| Off-box escalation alert | `notify.sh` → `PWFG_NOTIFY_CMD` on `HUMAN_NEEDED` |

## Not in this skeleton (later phases)

OS-user ownership boundary, the LLM-key proxy (brokering + cost cap + audit),
secrets injection, off-box CI gate, the disposable AMI, and SSM/tmux access — all
Phase 1+ in the design doc. Here the boundaries are simulated with directory
separation and env-pinned paths; Phase 1 enforces them with real OS users.
