# Grill Session: reproducible-raspberry-pi

Started: 2026-06-01
Last updated: 2026-06-01
Status: complete
Domain: Systems architecture + security (autonomous-agent host design)

## Summary

A disposable cloud VM that runs an autonomous Claude Code agent in tmux to
implement a pre-authored spec. The grilling pivoted the original premise off BOTH
named technologies: off the Raspberry Pi (→ cloud VM, to keep the agent off the
home LAN) and off NixOS for v1 (→ baked AMI + cloud-init; Nix deferred to v1.5
for full reproducibility).

Final v1 architecture:
- Disposable AWS VM, nothing persists; one task set at launch (cloud-IAM gated).
- Three users: `agent` (unprivileged worker), `governance` (owns tests/spec/
  scripts/status + scoped dev creds; the human connects here), `proxy` (owns only
  the brokered Anthropic API key).
- Autonomy = a forked planning-with-files skill: JSON+schema plan, externalized
  tools, status DERIVED from tests (never self-certified), loop redesigned around
  explicit escalate-and-wait.
- Done-gate = green contract tests + build, evaluated OFF-BOX in CI against an
  acceptance suite in a SEPARATE protected repo the agent can't push to. The
  agent works in its own throwaway repo.
- LLM key brokered through a localhost proxy (hides key + enforces cost cap +
  audit log). Web tools OFF; egress whitelist for git/Anthropic/OpenAI/Mistral/
  Supabase/S3; pinned deps, no runtime registries; IMDS blocked for the agent.
- Human access via SSM Session Manager (no inbound port), read-only tmux attach
  by default, read-write only to intervene. System admin via IAM break-glass.

Core security reframe that drove the whole design: blast radius = credential
scope + network scope + network location. Wiping local files is almost irrelevant
to it (it only buys inter-task confidentiality). Any control the agent can edit
or feed input to is not a control against the agent — hence OS-ownership
boundaries, off-box gates, and brokered (not handed-over) unscopeable secrets.

Build order: P0 brain (local, de-risk the loop+gate first) → P1 security boundary
+ proxy + secrets → P2 disposable image → P3 SSM/tmux + summarizer.

## Decision Log

### DECIDED: Threat model is (a) + some (b)
- **Decision**: Primary threat is an honest agent that errs; secondary is prompt
  injection. Not defending against a deliberately malicious model.
- **Rationale**: Matches intended use (agent works a plan in its own sandbox).
- **Open follow-up**: (b) only matters if untrusted content enters the task —
  entry point not yet identified.
- **Date**: 2026-06-01

### DECIDED: Cloud VM, not Raspberry Pi
- **Decision**: Run on a disposable cloud VM.
- **Rationale**: Keeps the agent off the home LAN (blast-radius isolation),
  easier egress filtering, trivial teardown, cloud-init secrets injection, no
  SD-card wear.
- **Date**: 2026-06-01

### DECIDED: Dedicated throwaway repository
- **Decision**: Agent works in its own throwaway repo, not a branch in a repo
  the user cares about.
- **Rationale**: Total credential compromise touches only the disposable repo;
  eliminates the server-side branch-protection problem.
- **Date**: 2026-06-01

### DECIDED: Total wipe, nothing persists
- **Decision**: The box is fully wiped between tasks; no state survives.
- **Rationale**: Prevents inter-task data/secret leakage; forces clean start.
- **Open consequence**: Requires an external secrets/config injection mechanism
  at each boot (see Open Threads → Secrets injection).
- **Date**: 2026-06-01

## Open Threads

### Branch 2 — Autonomous loop lifecycle (MOSTLY RESOLVED via homework)
- FINDING: `planning-with-files` is a context-management discipline, NOT a
  planner→executor pipeline. Research + build are one continuous process; the
  skill does not enforce a "research done, spec handed off" boundary — the USER
  imposes that by committing a complete task_plan.md.
- FINDING: the skill's `Stop` hook runs `check-complete.sh`, which counts
  `**Status:** complete` vs total `### Phase` lines in task_plan.md. THIS is the
  loop mechanism — a single `claude` invocation kept alive until all phases
  complete. Auto-mode only suppresses permission prompts; it adds no looping.
- CRITICAL TO VERIFY: check-complete.sh exits 1 on incomplete. Claude Code Stop
  hooks block stopping on exit code **2**, not 1 — exit 1 is non-blocking. If so,
  the hook does NOT force continuation and the agent stops early. MUST TEST with a
  multi-phase plan before building on this.
- MESH: skill's 3-strike protocol escalates to user after 3 failures → in auto
  mode the agent waits in tmux → summarizer reports "stuck" → user SSHes in to
  answer. v1 human-in-loop and skill escalation fit together.
- Watch: if Stop hook DOES block (exit 2), escalate-vs-don't-stop tug-of-war /
  thrash instead of clean wait.

### Branch 2b — Gate integrity (ACTIVE, newly opened)
- THE HOLE: a test/build gate the agent can author or tamper with reproduces the
  self-certification problem one level up. Agent writes weak tests (assert True),
  @skips failures, or edits the gate script / fakes exit codes. Under threat (a)
  this happens *accidentally* (agent skips a failing test "to get unblocked");
  under residual (b) it's a deliberate bypass.
- REQUIREMENTS implied: (1) acceptance tests authored independently of the
  execution agent (from the spec, committed by user), and locked so the agent
  can't modify them; (2) ideally the gate runs OUTSIDE the agent's tamper reach.
- ELEGANT OPTION: done-signal = CI green on the throwaway repo (runs off-box on
  push). Agent can't tamper; also yields a trustworthy completion signal AND a
  teardown trigger (CI green → webhook → teardown). Converges 3 open problems.
- CLEANER PLAN MODEL: stop STORING phase status; DERIVE it. Plan declares, per
  phase, the command that proves it (e.g. `pytest tests/phase3 && build`). Gate
  runs them; completion is computed, never claimed. Removes self-certification
  entirely.
- v2 escalation: agent must EXPLICITLY emit a BLOCKED marker; otherwise blocked
  is indistinguishable from done-wrong or crashed.
- FINDING (from P0 skeleton build + adversarial review, 2026-06-01): a deeper
  hole than "agent edits the tests." A test gate that IMPORTS the agent's code
  runs that code INSIDE the gate's own process, where it can rewrite the verdict
  (verified: a core.py that registers a pytest hook flipping every outcome to
  "passed" → gate reports GREEN with zero implementation). This is NOT closed by
  the OS-uid boundary (the verifier must import the code to test it) NOR by
  off-box CI (CI imports it too) — so the earlier "off-box CI = tamper-proof
  gate" assumption is only partly true. CLOSURE: an OUT-OF-PROCESS differential
  gate — run the agent's code in a hardened subprocess and compare serialized
  outputs to a trusted oracle on UNPREDICTABLE inputs, so faking == solving.
  Implemented + tested in the skeleton (examples/toy/locked/sealed_check.py,
  phase4-sealed-gate). LIMIT: needs an oracle / held-out inputs; where the spec
  has none, this degrades and you fall back to the threat model — and note this
  subversion is a deliberately-adversarial (threat-c) move, out of the agreed
  scope, so under (a)+(b) it isn't exploited.

### DECIDED: Pinned dependency set, no runtime registry access
- **Decision**: Research phase produces a fixed dependency list; cache/pre-bake
  into the VM; registries are NOT open at runtime.
- **Consequence**: the spec cannot introduce a new library mid-run without a
  re-bake. Accepted.
- **Date**: 2026-06-01

### DECIDED: Objective done-gate (green tests + build), not self-certification
- **Decision**: Completion gated on passing tests + successful build; add code
  quality steps (radon, etc.). Agent self-assessment not accepted.
- **Direction**: likely a forked/custom skill (Claude-Code-only, explicit "/"
  invocation, public multi-agent/auto-trigger parts stripped).
- **OPEN CHALLENGE (active)**: a gate the agent can author or tamper with is not
  a gate against the agent — see Branch 2.
- **Date**: 2026-06-01

### DECIDED: JSON + JSON schema for the plan/task file
- **Decision**: Replace markdown-regex plan with schema-validated JSON.
- **Caveat**: fixes regex brittleness but trades it for JSON-validity brittleness
  if the agent hand-edits; and schema validates shape, not truth (truth = test
  gate). Update via tool/command, or derive status from tests rather than store.
- **Date**: 2026-06-01

### DECIDED: Explicit plan-file location (not cwd)
- **Decision**: Give the custom skill a fixed, explicit path for plan files.
- **Date**: 2026-06-01

### DECIDED: Redesign loop toward explicit escalate-and-wait (v1 human watches)
- **Decision**: When blocked, agent legitimately escalates and waits; human
  monitors in v1; notification deferred to v2.
- **OPEN**: need a continue-driver that yields to genuine escalation, and a
  machine-detectable "BLOCKED" signal to distinguish stuck-vs-done-wrong-vs-
  crashed (see Branch 2).
- **Date**: 2026-06-01

### DECIDED: Externalize scripts into task-specific tools
- **Decision**: Rewrite moves inline SKILL.md scripts into discrete tools
  (e.g. mark-task-complete.sh <ID>) so the agent doesn't re-derive common tasks.
- **Alignment**: matches function-core / imperative-shell preference; tools = the
  imperative shell.
- **Refinement (open)**: a "mark complete" SETTER contradicts derived status. The
  tool should VERIFY (run the phase's proof-command) and refuse if red, not set a
  field the agent can lie to. Rename semantics to verify-task.
- **Date**: 2026-06-01

### DECIDED: verify-task.sh memoizes status (derive-then-cache)
- **Decision**: verify-task.sh RUNS the proof-command and writes the result to a
  status file, so intermediate progress is persisted/readable. Status is the only
  writer; agent does not write status directly.
- **Enforcement layering (corrected)**:
  - Claude permissions deny on Write/Edit to status file = guards ACCIDENTAL
    writes (threat a) only. NOT a hard boundary — agent's Bash can bypass via
    echo/tee/python/etc.; permission patterns can't enumerate-deny all shells.
  - REAL lock (available because we own the disposable box): OS file ownership.
    Run the agent as an unprivileged user; status file + acceptance tests +
    verify-task owned by a different uid/root. Bash can't cross a uid boundary.
  - Remote CI aggregate run = authoritative backstop. Local status is an advisory
    cache (fast feedback + summarizer input), explicitly NOT trusted for "done."
- **Verify scope (clarified)**: staleness only exists if verify is PER-PHASE
  scoped (cache of last-checked-per-phase). If verify runs the FULL suite every
  time, all phase statuses are re-derived and cross-phase regressions surface
  immediately — no staleness, SHA-stamping unnecessary. Recommendation: with fast
  contract tests, always run the full suite; drop to focused-while-iterating +
  verify-all-before-done only if the suite gets slow.
- **Two SEPARATE reasons for off-box run (do not conflate)**:
  1. Staleness — solved by full-suite local verify; CI not required for this.
  2. Tamper-resistance — NOT solved locally (agent controls the box); off-box run
     is required for this regardless of local verify scope.
- **Constraint**: never key anything irreversible (teardown) off local status.
- **Date**: 2026-06-01

### DECIDED: OS-enforced ownership boundary (agent unprivileged, harness owns governance)
- **Decision**: Two users. Agent runs unprivileged; acceptance tests + status +
  verify-task owned by a separate user (harness/root), agent has read-only.
- **ORGANIZING PRINCIPLE**: the agent owns its WORKSPACE; the harness owns
  everything that GOVERNS or JUDGES the agent — tests, proof-command mapping,
  verify-task, status file, the loop hook/settings, and the secrets. If the agent
  can edit the thing that constrains it, it isn't constrained.
- **TRAP 1 — privileged verifier + agent-authored input = escalation**: if
  verify-task runs as harness (via a narrow sudo rule) AND executes proof-command
  strings the agent can write, the agent injects code that runs as harness and
  defeats the boundary. → proof-command DEFINITIONS must live in the locked,
  harness-owned region, NOT the agent-writable plan. Split artifacts:
    - Locked spec (harness-owned, RO): phases, acceptance criteria, proof-command
      selectors, test files. Authored by user.
    - Agent scratch/progress (agent-owned): advisory notes only.
    - Status (harness-owned, written only by verify-task).
- **TRAP 2 — CI runs tests from the agent's pushable repo**: locking tests RO
  on-box does nothing if CI runs the acceptance suite from the branch the agent
  pushes to (intermediate commits are allowed). Agent edits a test, pushes, CI
  runs the weakened test, green, "done" — full bypass. → acceptance suite must be
  immutable in CI too: CI sources it from a SEPARATE protected repo the agent's
  (repo-scoped) credential cannot push to. Agent's throwaway repo holds only
  implementation.
- **Residual (quality, not security)**: RO-read of tests is required for CDD but
  enables "teaching to the literal test"; mitigate with property-based / multi-
  case contracts.
- **Synergy**: the whole boundary (users, ownership, sudo rule, systemd unit) is
  declarative in NixOS — reproduced identically each wipe, free to maintain.
- **Date**: 2026-06-01

### DECIDED: Acceptance suite via contract-driven development
- **Decision**: Pre-authored, robust contract tests as the acceptance suite.
- **Caveat**: the done-gate is only as complete as the contracts. A phase with no
  contract has no gate — contract coverage IS the spec.
- **Date**: 2026-06-01

### DECIDED: Intermediate commits may be red; completion is gated, commits are not
- **Decision**: Agent commits/pushes WIP freely (red allowed). Only phase/overall
  COMPLETION is gated on the acceptance suite.
- **Consequence (open)**: "CI green" can't be the naive done-signal if CI runs on
  every push. Done-signal = AGGREGATE acceptance gate (all phase proof-commands
  pass), evaluated off-box for tamper-resistance. Separate ungated intermediate
  push from authoritative completion check.
- **Date**: 2026-06-01

### DEFERRED: Teardown (manual for now)
- **Reason**: Revisit once the loop/gate design is settled.
- **Date**: 2026-06-01

### DEFERRED: Supervisor design (v2 exploration)
- **Reason**: User accepts human-in-loop (SSH + summarizer) for v1; designing the
  right automated supervisor is explicitly a v2 exploration.
- **Open questions**: Does the Stop hook actually block (exit-code test)? What
  handles wedged/crashed/escalating states without a human? What triggers VM
  teardown on completion?
- **Risk if ignored**: "minimize user interventions" goal is only partially met
  in v1; idle/crashed VM keeps billing until a human notices (ties to Branch 3).
- **Date**: 2026-06-01

### DECIDED: Disable web tools for execution agent
- **Decision**: WebSearch/WebFetch disabled for the execution agent.
- **Rationale**: Research is complete before handoff; closes most of threat (b),
  shrinks egress whitelist.
- **Caveat to remember**: tool-disabling is defense-in-depth only. The agent
  still has Bash/curl + SDKs; the NETWORK egress whitelist is the real boundary.
- **Date**: 2026-06-01

### DECIDED: Egress whitelist targets
- **Decision**: git host, Anthropic, OpenAI, Mistral, Supabase, S3.
- **Open gap**: package registries (PyPI/npm/cargo) NOT listed — but an
  implementation task almost certainly installs deps. Either pre-bake deps into
  the image or add registries (which are exfil channels). Unresolved.
- **Residual**: S3 (*.amazonaws.com) and the git host are themselves data-egress
  paths; accepted under threat (a) + reduced (b).
- **Date**: 2026-06-01

### DECIDED: Acceptance suite in a separate, protected, read-only repo
- **Decision**: Acceptance tests live in a separate repo the agent's credential
  cannot push to. CI checks out implementation (agent repo) + suite (protected
  repo) and runs one against the other. Closes the CI-tamper path (Trap 2).
- **Date**: 2026-06-01

### Branch 4 — Secrets injection (ACTIVE)
- CENTRAL TENSION: agent must USE secrets (LLM keys, git, S3, Supabase) but must
  not be able to READ/exfil them. "Harness owns secrets, agent denied" collides
  with "agent needs them to work."
- KEY INSIGHT: the egress whitelist does NOT protect credentials. It limits exfil
  FROM the box, but a leaked key is used by an attacker OFF the box, where the
  whitelist has no reach. Only brokering (key never leaves the box) or scoping
  (key's value is bounded) protects a credential.
- RECOMMENDED HYBRID:
  - BROKER the unscopeable, high-value secrets = the LLM API keys. Local proxy
    (localhost) holds the real key; agent points ANTHROPIC_BASE_URL / app SDKs at
    the proxy with a dummy local token. Agent never holds the upstream key.
    BONUS: the proxy is also the natural place for the cost cap (Branch 3) and a
    per-call audit log. One component solves secret-hiding + cost + audit.
  - SCOPE the rest = git (already repo-scoped), S3 (bucket/prefix), Supabase
    (dev only). Leakage = already-accepted blast radius, so handing these to the
    agent is acceptable.
- TRAP — IMDS / metadata endpoint (169.254.169.254): if the agent can reach it,
  it can use the instance role to fetch every secret the role can read. MUST
  block agent-uid access (iptables owner match / netns / IMDSv2 hop limit) and
  deny the metadata IP in the egress whitelist. Total-compromise path under (b).
- BOOT MECHANISM: privileged systemd oneshot (root, declared in Nix) fetches from
  a secrets manager (SSM/Secrets Manager/Vault) via the instance role at boot →
  lands in harness-only-readable location / proxy config. Agent's systemd unit
  gets NONE in its environment. Declarative + reproduced each wipe.
- ROTATION: brokered keys never touch the box → no per-run rotation. Any secret
  handed to the agent is "burned" after a (b)-suspect run → rotate.
- DECIDED (proxy mechanism): broker LLM keys via local proxy. Proxy =
  harness-owned, config 0400 harness, listens localhost-only, never logs the key.
  uid boundary + ptrace_scope protect its memory from the unprivileged agent.
- DECIDED — auth split: dedicated Anthropic API key for the autonomous loop
  (brokered via proxy → hidden, cost-capped, audited); OAuth subscription
  reserved for INTERACTIVE use (human SSH-attach sessions). Each credential used
  for its intended channel; brokering fully restored.
- DECIDED — task selector set at LAUNCH (user-data/tag/SSM param). Collapses
  "who decides what runs" into cloud IAM = same root of trust as the instance
  role/secrets. No new authenticated channel. One box, one task, manual teardown.
  Dynamic task-pulling (queue/poll) is a v2 feature, explicitly avoided in v1.

### Branch 5 — SSH access & tmux interaction (ACTIVE)
- Goal: human attaches to the live Claude Code tmux to observe / unblock an
  escalated agent.
- REACHABILITY: avoid public SSH on a disposable box (inbound attack surface +
  host-key churn every wipe → known_hosts/MITM warnings). RECOMMEND SSM Session
  Manager (no inbound port, IAM-gated = same root of trust, auditable, no host
  keys) or Tailscale SSH. Agent user has NO SSH login; only the human admin user.
- COLLISION (user's flagged concern): two writers on one PTY. Default to
  READ-ONLY attach (tmux attach -r) = observe without injecting keystrokes;
  switch to read-write only to deliberately intervene. The escalate-and-wait
  design already creates the clean window: agent idle at a prompt = safe to type;
  agent working = observe only.
- DECIDED: AWS SSM Session Manager for v1 (Tailscale maybe later). No inbound
  port, IAM-gated, auditable, no host-key churn. Agent user has no SSH login.
- DECIDED: read-only attach by default; read-write only to deliberately
  intervene. Escalate-and-wait gives the collision-free window (agent idle at
  prompt = type; working = observe).
- IDENTITY — user connects as the GOVERNANCE owner, not root (least privilege).
  Can observe, intervene, and override the gate (edit governance-owned locked
  spec/tests); cannot do system-level damage. Agent still cannot touch the spec.
  Completion still derived from off-box tests → human unblocks REASONING, can't
  fake "done."
- REFINEMENT (offered): SPLIT secrets-owner from governance-owner so the human's
  interactive session never has the unscopeable LLM key in reach:
    - agent (unprivileged worker)
    - governance/harness (owns tests/specs/scripts/status + the SCOPED dev creds
      the tests need to run) ← human connects here
    - proxy (owns ONLY the brokered LLM API key; runs the proxy)
  Result: human-as-governance sees only already-accepted scoped creds, never the
  LLM key.
- TMUX SOCKET: cross-user attach needs a shared-group socket (e.g. group
  tmuxshare = agent + governance, socket group-rw at a known path). Declarative
  in Nix. Only those two users in the group.
- DECIDED: split governance (human connects here) from proxy (LLM key only).
- DECIDED: shared-group tmux socket (tmuxshare = agent + governance).
- DECIDED: NO narrow sudo. governance stays strictly unprivileged; operational
  recovery (restart wedged agent, system fixes) = deliberate admin break-glass
  via IAM/SSM, logged. Accepts slightly more friction for a hole-free boundary.
- REPRODUCIBILITY WRINKLE: human interventions are un-versioned side-channel
  inputs — least reproducible part of a "reproducible" system. Proxy audit log
  captures resulting API calls; consider tmux pipe-pane session logging if replay
  matters.

### DECIDED: Locked plan-as-spec lives in the protected read-only repo with tests
- **Decision**: phases + acceptance criteria + proof-command/test-selector
  mapping live in the protected RO repo alongside the tests (user-authored,
  immutable, versioned in lockstep). The agent's MUTABLE progress/scratch lives
  separately in its workspace. The forked skill's single task_plan.md splits into
  immutable spec (RO repo) + mutable progress log (agent workspace).
- **Bonus**: proof-commands sourced only from the immutable repo closes Trap 1
  (privileged verify-task never executes agent-authored command strings).
- **Date**: 2026-06-01

### Branch 1 — Threat model & blast radius (MOSTLY CLOSED)
- User's containment instincts are sound: scope to dev DB, push only to dedicated
  branch, web whitelist.
- KEY UNRESOLVED QUESTION: which threat are we defending against?
  (a) honest agent that errs, (b) prompt-injected agent, (c) deliberately
  malicious agent. The answer changes whether a whitelist is "good enough."
- Challenge on the table: local-file wiping protects *inter-task* confidentiality
  but does almost nothing for *intra-task* blast radius. Blast radius = credential
  scope + network scope + network location.

### Pi vs cloud VM (sub-decision under Branch 1)
- User prefers Pi (idle hardware, no ongoing cost). Open to cloud if meaningful
  advantage.
- Strongest pro-cloud argument raised: a Pi sits on the home LAN, expanding blast
  radius to home network devices; cloud VM is isolated from home LAN by default.
  Also: egress filtering, snapshot/teardown, and cloud-init secrets injection are
  all easier on cloud; SD-card write endurance is a Pi liability.

### Point-by-point items raised by user (to resolve)
1. Web whitelist — feasible but leaky if github/pypi/npm are allowed; DNS/DoH/IP
   bypass; depends on threat model.
2. "Only its branch" — client-side git hook is NOT a boundary (agent can bypass
   with --no-verify / delete hook). Real enforcement is server-side (deploy key
   scoped to one repo + server push ruleset), or simplest: give it its own repo.
3. Secrets injection mechanism needed because nothing persists (see below).
4. planning-with-files + /goal — does not by itself solve loop termination,
   completion detection, or cost runaway.
5. Summarizer — reads session file locally (no write race granted), but if it
   PUSHES to the same branch there's still a push/non-fast-forward race. Trust
   caveat: an LLM summary of the agent's own session is not a security monitor.
6. Dev-DB-only + branch-only + whitelist — correct containment instinct.

## Parking Lot

### Branch 6 — Scope / MVP sequencing (ACTIVE)
- KEY INSIGHT: the highest-RISK piece (does the loop actually drive a multi-phase
  plan to a test-gated stop?) is also the most INFRA-INDEPENDENT. Build it FIRST,
  locally, before any cloud/Nix. Don't start with the disposable image.
- Proposed phases:
  - P0 (de-risk core, local laptop): forked skill + JSON plan + externalized
    verify-task + redesigned Stop-hook/loop + local test gate against a locked
    dir, on a 2-3 phase toy spec. Zero cloud/Nix/proxy/secrets. Proves the one
    load-bearing uncertainty.
  - P1 (security boundary, plain cloud VM ok): agent/governance/proxy users +
    ownership; the LLM proxy (broker + cost cap + audit); secrets via SSM +
    instance role; IMDS lockdown; off-box CI with protected RO test repo.
  - P2 (disposable image): assemble validated parts into the reproducible image;
    wipe semantics. LAST among core — it's assembly, and has its own yak-shave.
  - P3 (ergonomics): SSM access + read-only tmux attach; summarizer.
  - Deferred: teardown automation, v2 supervisor/notifications, dynamic task
    pulling, Tailscale.
- OPEN CHALLENGE: is NixOS MVP or polish? A baked AMI + cloud-init delivers
  DISPOSABILITY (terminate + relaunch) with far less yak-shave; NixOS adds full
  declarative REPRODUCIBILITY. Could defer Nix to v1.5 so the isolated autonomous
  agent lands sooner. Needs user decision.
- PRINCIPLE: walking skeleton — thinnest end-to-end path (one toy task: boot/run
  → loop → gate → observe) before hardening each piece.
- DECIDED: build order accepted (brain → boundary → image → ergonomics).
- DECIDED: NixOS deferred to v1.5; v1 uses baked AMI + cloud-init. Investigating
  Nix was the goal, not mandating it; reproducibility is a follow-on, not a v1
  requirement.

## Open Risks / Things To Verify Before Building (carry into P0/P1)

1. **Stop-hook exit code (P0 blocker).** check-complete.sh exits 1; Claude Code
   Stop hooks block on exit 2. TEST whether the loop is actually forced to
   continue; if not, build a blocking Stop hook / wrapper. The whole autonomy
   story rests on this — verify before anything else.
2. **Gate tamper integrity.** Acceptance suite must be immutable to the agent
   EVERYWHERE it's evaluated — OS-RO on-box AND sourced from a protected repo in
   CI. Proof-commands come only from the locked repo (closes the privileged-
   verify escalation, Trap 1). UPDATE (P0 build): immutability is necessary but
   NOT sufficient — a gate that imports the agent's code runs it in-process and
   can be subverted from within, which neither OS-uid nor off-box CI closes. The
   authoritative gate must run the code OUT OF PROCESS vs a trusted oracle on
   unpredictable inputs (see Branch 2b FINDING; implemented as the sealed gate).
3. **IMDS lockdown.** Block agent-uid access to 169.254.169.254 or the instance
   role becomes a backdoor to every secret. Easy to forget.
4. **Proxy feasibility.** Confirm Claude Code drives cleanly via
   ANTHROPIC_BASE_URL with the dedicated API key; confirm tests need scoped dev
   creds but NOT the LLM key (so governance/human session never holds it).

## Consciously Deferred (not gaps — known choices)

- Teardown automation (manual for v1; idle-VM cost accepted short-term).
- v2 supervisor + notifications (auto recovery for wedged/crashed/escalated
  states; v1 is human-in-loop via SSM).
- Dynamic task-pulling (queue/poll); v1 is one-box-one-task-at-launch.
- NixOS reproducibility (v1.5); Tailscale access (maybe later).
- Quality residual: agent can "teach to the literal test"; mitigate with
  property-based / multi-case contracts.

- **Branch 3 — Cost control (mostly RESOLVED via the proxy)**: the brokering
  proxy is the enforcement point for a hard token/$ ceiling + kill switch + audit
  — the only place a cap can be enforced (agent can't be trusted to cap itself).
  Remaining: idle-VM cost (ties to manual teardown).

## Post-build addition: context-bounded multi-session orchestrator (2026-06-01)

Built in the P0 skeleton (skill/bin/run-loop.sh + handoff.sh), partially
addressing the DEFERRED supervisor:
- PROBLEM: one `claude -p` session = one context window; long tasks exhaust it.
  The Stop-hook loop keeps ONE session alive, which makes context pressure worse.
- FIX: an outer loop of FRESH bounded sessions; continuity on disk (locked plan,
  derived status, git checkpoints, HANDOFF.md). NOT `--continue`/`--resume`
  (those reuse the prior context — the opposite of what we want).
- Per-session end read from `claude -p --output-format json` `.subtype` (verified
  on 2.1.159: `success` vs `error_max_turns` vs `error_during_execution`; process
  exit 0 vs non-zero is coarser, so branch on `.subtype`).
- Decision table: green→done; agent 3-strike→human; cross-session stall (no new
  green in N sessions)→human; infra→human; session budget→human.
- IMMUTABLE-PLAN UPHELD: a too-big phase escalates to a human to raise the turn
  cap OR re-author the plan into finer phases. The loop never edits the plan
  (splitting a phase = splitting its proof = a governance act).
- HANDOFF = deterministic ground-truth facts (gate/status/git) + advisory agent
  notes; rewritten (not appended) each session so it stays bounded.
- FINDING (live run): each fresh session pays an ORIENTATION TAX (re-reading the
  handoff/plan/tests) before progress. A turn cap below that tax false-stalls
  before the first checkpoint — the stall message names both causes (cap too low
  vs phase too big). Live: drove the toy to a tamper-verified green gate across 2
  fresh sessions (session 2 resumed from session 1's on-disk state).
- FINDING (6-phase ledger, 2026-06-01): the orientation tax GROWS as the codebase
  grows — later sessions re-read more committed code before they can implement, so
  a FIXED per-session turn cap that's fine early can stall on a late, even trivial,
  phase. Ledger at cap 8 → spanned 6 sessions, completed 5/6, then correctly
  escalated on the last phase; at cap 16 → completed all 6 across 3 sessions
  (resumption carried it to a green sealed gate). IMPLICATION for the real system:
  the per-session turn/context bound should scale with task progress (or the
  handoff must be good enough that the agent does targeted reads instead of
  re-exploring) — a static cap is a footgun on long tasks. Also: per-session +
  total cost is now logged from `total_cost_usd` (ledger run ~ $1.18 for 3
  sessions), feeding the Branch 3 cost cap.
- FORENSICS (transcript analysis of the ledger runs, 2026-06-01): the orientation
  tax is dominated by re-reading file CONTENTS to rebuild understanding, NOT by
  finding files (the agent located+opened the same 12-27 line files every
  session). In the blocked cap-8 run, 4 of 6 sessions wrote ZERO code;
  orientation:implementation ran ~11:1 (done run) to ~15:1 (blocked). The DECISIVE
  lever is the turn budget (8 blocked, 16 done), not information. DECISION: add a
  deterministic "Files for this phase" pointer to the handoff (EDIT module if it
  exists on disk + PROVE WITH test/proof path + the test's own imports verbatim;
  derived from plan+proof so it can't go stale or point wrong) + a SOFT read-here-
  first nudge. REJECTED (adversarial critique): a computed dependency-graph "reuse"
  line (not correctly derivable from current helpers; self-referential; duplicates
  the test's imports), a repo TOC, a source map (stubs+locked tests already pin
  signatures here), and a second DECISIONS prose stream (the narrator already owns
  the advisory slot). IMPLICATION for the real system: the per-session context/
  turn bound should SCALE WITH the codebase (the orientation floor rises as more is
  committed) — a static cap is the footgun, derived pointers are a modest (~1-4
  calls/session) secondary help, not the fix.
- BUILT (2026-06-01): the turn budget now SCALES WITH PROGRESS —
  clamp(base + per_phase*green_count + reactive_extra, base, max), defaults
  12/3/24/4. Proactive (more green phases -> more turns) + reactive (a no-progress
  max-turns session raises reactive_extra and retries instead of stalling).
  Escalates to a human only when even the MAX budget can't finish a phase. Live:
  the ledger completed in 3 sessions from base 12 (12 -> reactive 16 -> scaled 24)
  with no hand-picked cap. PWFG_TURNS_PER_SESSION still forces a fixed budget. This
  is the decisive lever the forensics identified; derived pointers stay secondary.
- Secrets/config injection at boot (trust anchor now that nothing persists)
- Tamper-evident audit log vs agent-written summary (for security monitoring)
- SSH access control + tmux input-collision when human attaches
- Scope / MVP ordering (this is 5–6 subprojects)
