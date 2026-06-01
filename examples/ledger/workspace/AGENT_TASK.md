# Task: implement the mini double-entry ledger

Implement the function bodies across the `ledger/` package so the locked contract
tests pass, phase by phase, in order. This task is intentionally larger than one
context window — you will likely run out of turns mid-way; that's expected. A fresh
session will resume from this workspace, the committed checkpoints, and HANDOFF.md.

## Rules

- Work the phases in order. Each phase is a separate module + its own contract test.
- The contract tests under `../locked/tests/` are the spec — **read-only**. Do not
  change the public types or signatures in the `ledger/` modules.
- **Completion is derived from the tests, not asserted.** Do not touch `.harness/`.
- Money is `Decimal` (from `str`, never `float`); failures are returned as error
  values (e.g. `MoneyError`), not raised. Pure functions, no I/O.
- Check a phase with the verifier (absolute paths are given to you at launch):
  `verify-task.sh <phase-id>`; full gate: `verify-all.sh`.
- Keep `progress.md` and (across sessions) `HANDOFF.md` honest — the next session
  relies on them. If stuck after three attempts, run `escalate.sh "<reason>"`.

## Phases

1. `phase1-money`   — `parse_money()` in `ledger/money.py`
2. `phase2-posting` — `make_posting()` in `ledger/posting.py`
3. `phase3-entry`   — `validate_entry()` in `ledger/entry.py`
4. `phase4-post`    — `post()` in `ledger/post.py`
5. `phase5-report`  — `is_balanced()` + `format_statement()` in `ledger/report.py`
6. `phase6-sealed-gate` — passes automatically once phases 1–4 are correct (it runs
   the whole pipeline out of process); nothing to implement.
