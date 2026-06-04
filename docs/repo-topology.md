# Repository topology — decision record

**Question.** Should the CDK + deployment configuration (`infra/`) live in a separate
repository from the "Planning With Files" development loop (`skill/` + `proxy/` +
`examples/` + `tests/`), since standing up the host is a separate workstream from the
dev loop?

**Decision (2026-06-03, pre-first-deploy).** Keep **one repository** with clean
top-level dirs. Do the already-designed **security** split (`pwfg-acceptance`) when
workstream D is built; defer the **org** (infra) split until a concrete trigger fires.
Build the code-delivery channel split-ready so a later split is a tag bump, not a rewrite.

## Why one repo now

The two halves are coupled at the **runtime contract surface**, not merely by org
convenience — and pre-first-deploy there is no isolation benefit to bank:

- **The deploy bundles the dev loop.** `infra/bootstrap/bin/bootstrap.sh` copies
  `skill/` + `proxy/` (+ units + sudoers) onto the box from one `$SRC=/opt/pwfg/repo`
  tree. A split forces a two-checkout assembly step that buys nothing while neither
  side is stable.
- **One acceptance test spans both halves in one process.** `tests/test_boundary.sh`
  drives `run-loop.sh` / `run-proof-as.sh` (skill) *and* `imds-lock` / `egress-lock` /
  `boot-assert` / `launch-agent` (infra). It is the sole proof of agent containment and
  cannot live in either repo alone.
- **Four un-schematized env-var seams cross the line** (producer in an infra unit,
  consumer in skill/proxy): `PWFG_LAUNCH_CMD` (`pwfg-loop.service` → `run-loop.sh`);
  `PWFG_PROOF_AS` + `PWFG_UV_OFFLINE`/`_CACHE_DIR`/`_PYTHON_DIR` (`pwfg-loop.service` →
  `common.sh` / `run-proof-as.sh`); `PWFG_ENV_FILE` (`pwfg-loop.service` /
  `launch-agent.sh` → `common.sh`, with an ownership guard); `PWFG_PROXY_FORWARD`
  (`pwfg-proxy.service` → `proxy/app.py`). They break a *boot*, not a *build*; only the
  boundary test catches skew. The proxy dep pins (`httpx>=0.28,<1`, …) are duplicated
  across `pwfg-proxy.service`, `proxy/pyproject.toml`, `prime-uv.sh`, and CI.
- **One CI pipeline** (`.github/workflows/tests.yml`) runs all four halves with a
  hard-fail-on-`SKIP` guard on the boundary step. A split fragments this and re-invents
  the single checkout the monorepo gives for free.
- **Co-change is together.** As of HEAD, the box has never deployed; recent git
  co-change is ~7 commits touching both halves, ~9 dev-loop-only, **0 infra-only**.

A monorepo makes infra↔dev-loop version skew **structurally zero**: one SHA pins the
four seams, the dep pins, the `/srv/pwfg` path layout, and the boundary test.

## Two different cut lines (do not conflate)

```
SECURITY split (already designed, load-bearing, cheap)   ORG split (the question; optional, deferred)
──────────────────────────────────────────────────      ─────────────────────────────────────────────
cuts THROUGH skill/ + examples/*/locked/                 cuts BETWEEN infra/ and the dev loop
keeps the gate out of the agent's reach                  buys IAM/secrets access control, blast-radius
("the agent must not push to what judges it")              isolation, independent CDK cadence
→ pwfg-acceptance (RO to agent) + pwfg-impl (throwaway)   → a separate pwfg-infra repo
a TRUST boundary                                          an ORG/ops boundary
serves the P1 containment invariant                       serves it NOT AT ALL (a contained agent
                                                            can't reach IMDS/key/internet by design)
```

- The **security split** (`docs/P1-provisioning.md §6`, workstream D) is satisfiable
  **today without moving code**: stand up branch-protected `pwfg-acceptance` holding
  `skill/` + `locked/`, a one-way sync from the monorepo, and an on-box `==` acceptance
  verify. `test_boundary.sh` is an on-box-mechanism test (stays in the monorepo, sees
  both halves); the authoritative GREEN is the off-box `acceptance.yml`. **Do this first.**
- The **org split** is optional, reversible, and currently all-cost. Defer it.

They compose cleanly into a 3-repo end-state because `infra/` only references `locked/`
via `examples/$EX` (`select-example.sh`) — it never owns the gate.

## Triggers that flip the org split to "do it now"

1. **A distinct principal owns deploys** — whoever runs `cdk deploy`/`destroy`
   (VPC+IAM+EC2) is no longer the set editing `run-loop.sh`/`proxy/core.py` → infra
   wants its own branch protection + CODEOWNERS + deploy-only reviewers.
2. **IAM/secrets blast radius is the binding constraint** — a bad infra merge could
   mis-scope the AgentHostRole / KMS CMK / the Anthropic SecureString, or open egress,
   in a *live* account.
3. **The seams + `/srv/pwfg` layout stabilize and the box has deployed once** — there is
   a real pinned version downstream consumes (a dev-loop tag per AMI).
4. **Cadences diverge** — infra ships slowly ("stand up a box"), the loop ships
   continuously, and one SHA starts creating friction rather than removing it.

## If/when the org split happens — keep it cheap

- **Pin the dev loop as a versioned release tarball, not a git submodule** — a tarball
  is literally what the box already consumes, so the pin is the explicit version
  contract that today is implicit (submodules go stale and noisy).
- **Mechanism:** the infra artifact/AMI builder fetches the pinned dev-loop release and
  lays it under `/opt/pwfg/repo/{skill,proxy,examples}` next to `infra/bootstrap/`, so
  `bootstrap.sh` stays byte-for-byte unchanged (it only cares about the on-box layout;
  `PWFG_SRC` is already a variable).
- **Relocate `tests/test_boundary.sh` into the infra repo** (it owns the OS-fence claim);
  it checks out the pinned dev-loop release into a temp tree first — it already copies
  `skill/` into a `/tmp` tree, so it is half-built for this. The hard-fail-on-`SKIP`
  guard moves with it.
- **The CDK-synth-only layer** (`stacks/*.py`, `app.py`, `aspects.py`, `test_synth.py`)
  is the one cleanly-extractable piece — it imports nothing from the dev loop.

## Do now, regardless (so a later split is painless)

- [ ] **`CODEOWNERS` on `infra/`** + required infra-literate review — gate blast radius
      by *review* rather than by *repo* until a deploy team exists.
- [ ] **Keep the CI "SKIP-is-a-failure" guard**; add a small **seam contract test**
      asserting the four `PWFG_*` strings + the proxy/proof dep pins match across the
      units (`prime-uv.sh`, `pwfg-*.service`) and the skill/proxy consumers — today only
      `test_boundary.sh` catches that drift.
- [ ] **Build the code-delivery keystone as a versioned-artifact assembler** (the S3
      tarball, when built), not a single-tree copy — that builder *is* the future repo
      boundary; make it split-ready while still one repo.
- [ ] Keep `infra/` a clean subtree; never path-couple beyond `PWFG_SRC` + the four
      documented seams.

## Watch items

- One repo means every dev-loop contributor shares the repo that defines production
  IAM/secrets — mitigated by the `CODEOWNERS`/review gate above until a real deploy team
  exists.
- The four seams + duplicated dep pins are protected **only** by `test_boundary.sh` +
  the single pipeline. If the CI `SKIP`-guard is weakened or the boundary test
  self-skips on the real runner, seam drift ships silently. Keep the guard; add the
  contract test before any split.
- The security split introduces a **`skill/` mirror invariant**: on-box `skill/` (copied
  by `bootstrap.sh`) must be byte-identical to `pwfg-acceptance`'s `skill/` (sourced by
  off-box CI), or the on-box and off-box gates disagree. Enforce with a one-way sync +
  verify, not manual copying.
