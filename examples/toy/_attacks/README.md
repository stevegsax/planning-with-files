# Adversarial fixtures (harness-only)

These are deliberately malicious `rpn/core.py` implementations used by
`tests/test_harness.sh` to prove the gate cannot be faked. They are NOT given to
the agent. Each one tries to reach a GREEN gate without implementing the
calculator:

- `makereport_flip.py` — runs at import inside the pytest process and registers a
  hook that rewrites every test outcome to "passed" (the reviewer's blocker).
- `eq_true.py` — returns objects whose `__eq__` is always true, to satisfy the
  contract suite's equality assertions without computing anything.

Both fool a naive pytest gate; neither passes the sealed differential gate
(`locked/sealed_check.py`), which runs the code out of process and compares
serialized outputs against a trusted oracle on unpredictable inputs.
