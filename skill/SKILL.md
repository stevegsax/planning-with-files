---
name: plan-with-files-gated
version: "0.1.0"
description: Test-gated, file-based planning for autonomous Claude Code runs. A locked plan declares per-phase proof commands; completion is DERIVED from running them, never asserted by the agent. Forked from planning-with-files for the disposable-agent design.
user-invocable: true
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
---

# plan-with-files-gated

A forked, test-gated evolution of `planning-with-files`. Same "working memory on
disk" discipline, but **completion is objective**: the plan declares the command
that proves each phase, and a Stop hook keeps the agent working until every proof
passes. The agent cannot mark itself done.

> The Stop gate is wired by the run harness (a project `.claude/settings.json`),
> NOT by this skill's frontmatter — so it only gates real gated runs, never an
> ordinary interactive session.

## The two kinds of artifact

| Artifact | Owner | Writable by agent? |
|----------|-------|--------------------|
| Locked plan (`plan.json`) + acceptance tests | governance (you) | no — read-only |
| Workspace (implementation, `progress.md`) | agent | yes |
| Status cache (`.harness/status.json`) | the tools | no — derived only |

The plan and tests define *what counts as done*. The agent only changes the
workspace; it makes proofs pass, it never edits them.

## Workflow

1. Read the locked `plan.json`. Work the phases **in order**.
2. Implement in the workspace. Keep `progress.md` updated (recitation — re-read
   the plan before decisions).
3. Check your work with the tools (absolute paths are provided at launch):
   - `verify-task.sh <phase-id>` — run one phase's proof; fast feedback.
   - `verify-all.sh` — the authoritative gate; runs every proof fresh.
   - `plan-status.sh` — cached progress view.
4. The session will not stop until `verify-all` is green. Don't fight it — make
   the tests pass.
5. **3-strike rule:** diagnose → try a different approach → rethink. If still
   stuck after three distinct attempts, run `escalate.sh "<reason>"` to hand off
   to a human (the gate then allows the session to end/wait).

## Rules

- Never edit the locked tests, the plan, or anything under `.harness/`.
- Never try to "mark" a phase complete — status is computed from the tests.
- Completion = `verify-all` green. The authoritative gate also runs **off-box**
  (CI against an acceptance suite the agent can't push to); local green is fast
  feedback, not the final word.

## Design notes

- Status is **derived, then cached**. The cache is advisory and agent-writable;
  `verify-all` re-runs the full suite fresh (never trusts the cache) so
  cross-phase regressions surface immediately.
- **Tamper-resistant gate.** A test phase that imports the agent's code lets that
  code run inside the gate's process and rewrite the verdict — not closed by a
  uid boundary or off-box CI. The authoritative gate therefore runs the code
  **out of process** against a trusted oracle on unpredictable inputs (the toy's
  `phase4-sealed-gate`), so faking the gate means actually computing the answer.
  The pytest phases are agent feedback and are foolable from within; the sealed
  phase is not.
- The Stop gate blocks via JSON `{"decision":"block", …}`, carrying guidance in
  **both** `reason` and `hookSpecificOutput.additionalContext`. A bounded
  block-counter (`PWFG_MAX_BLOCKS`, fails *safe* on corrupt state) plus the run's
  `--max-turns` prevent runaway loops; an infrastructure error (missing tooling)
  escalates immediately instead of telling the agent to fix correct code.
- Proof commands are read **only** from the locked plan, so a privileged verifier
  never executes agent-authored command strings.

## Long tasks: bounded sessions + resume

A single session shares one context window. For tasks too large for one window,
the orchestrator (`run-loop.sh`) runs a sequence of **fresh, bounded sessions** —
context is shed each session; continuity lives on disk (locked plan, derived
status, git checkpoints, `HANDOFF.md`). It reads each session's `claude -p
--output-format json` `.subtype` (`success` = checkpoint/clean stop;
`error_max_turns` = hit the cap mid-phase), commits newly-green phases, and
regenerates a bounded, fact-anchored handoff for the next session.

A phase too big to finish in one window surfaces as a **cross-session stall** and
escalates to a human — it never auto-splits a phase, because splitting a phase
means splitting its proof, which is a governance act. Note the per-session
**orientation tax**: a fresh agent must re-read the handoff/plan/tests before it
can make progress, so the turn cap must exceed that tax.
