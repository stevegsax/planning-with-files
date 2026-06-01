# Gated planning skeleton (Phase 0)

A walking skeleton for the disposable autonomous-agent design worked out in
`grill-me-sessions/redesign-plan-with-files.md`. It exists to answer the one
question the whole design rests on, on bare metal, before any cloud or image
work:

> Does a single headless Claude Code run, driven by a Stop hook and a JSON plan,
> march through a multi-phase spec and stop **only** when objective tests are
> green — while the acceptance suite and the gate stay outside the agent's reach?

The mechanism is proven deterministically by `tests/test_harness.sh`; the live
agent loop is driven by `examples/toy/run-experiment.sh`.

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
│       └── stop-gate.sh            # the Stop hook: block until green / escalated
├── examples/toy/                   # the RPN-calculator experiment
│   ├── run-experiment.sh           # the Phase 0 driver
│   ├── .python-version             # pins the interpreter (3.13)
│   ├── locked/                     # governance-owned, read-only to the agent
│   │   ├── plan.json               # 4 phases + proof commands
│   │   ├── sealed_check.py         # tamper-resistant out-of-process gate (phase 4)
│   │   └── tests/                  # pytest contract tests (agent feedback)
│   ├── workspace/                  # agent-owned: AGENT_TASK.md + rpn/ stub
│   ├── _reference/core.py          # harness-only reference solution (self-test)
│   └── _attacks/                   # harness-only adversarial fakes (self-test)
└── tests/test_harness.sh           # deterministic self-test (no LLM)
```

## Run the deterministic self-test

Proves the tools and Stop gate behave (RED/GREEN paths, escalate-and-wait,
bounded blocks, anti-injection, plan validation). No API key, no agent.

```
tests/test_harness.sh
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

## Not in this skeleton (later phases)

OS-user ownership boundary, the LLM-key proxy (brokering + cost cap + audit),
secrets injection, off-box CI gate, the disposable AMI, and SSM/tmux access — all
Phase 1+ in the design doc. Here the boundaries are simulated with directory
separation and env-pinned paths; Phase 1 enforces them with real OS users.
