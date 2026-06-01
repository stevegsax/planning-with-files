# Task: implement the RPN calculator

Implement the function bodies in `rpn/core.py` so the locked contract tests pass,
one phase at a time. This is the Phase 0 walking-skeleton experiment: the point is
to prove the gated loop drives a multi-phase plan to a green-tests stop.

## Rules

- The plan and its phases are fixed. Work the phases **in order**.
- The contract tests are the spec. They are **read-only** — do not edit them, and
  do not change the public signatures or type names in `rpn/core.py`.
- **Completion is derived from the tests, not asserted.** You cannot mark a phase
  done; you make its proof command pass. Do not touch any file under `.harness/`.
- After each change, check a phase with the verifier (paths are provided to you at
  launch):
  - `verify-task.sh phase1-tokenize` — fast feedback for one phase
  - `verify-all.sh` — the full gate (what decides "done")
- Keep `progress.md` updated with what you did and what you learned.
- The session will not let you stop until the gate is green. If you are genuinely
  stuck after three distinct attempts at the same problem, run
  `escalate.sh "<reason>"` to hand off to a human.

## Phases

1. `phase1-tokenize` — `tokenize(expression)` → tuple of `Number`/`Operator`, or
   `ParseError("empty")` / `ParseError("malformed-number", token)`.
2. `phase2-evaluate` — `evaluate(tokens)` → `Decimal`, or `EvalError(...)` for
   underflow, leftover operands, or division by zero.
3. `phase3-calc` — `calc(expression)` → tokenize then evaluate, propagating errors.
