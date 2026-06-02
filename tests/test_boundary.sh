#!/usr/bin/env bash
# test_boundary.sh — the P1 OS-ownership boundary acceptance test.
#
# Proves the Phase-1 security claim on a real multi-user system: the `agent` uid is
# contained (cannot edit what judges it, cannot read the brokered key/audit, cannot
# reach IMDS) WHILE the governance contract still works (gov drives the loop across
# the uid boundary and the gate reaches GREEN against an agent-owned workspace).
#
# Requires root + useradd/sudo/iptables (it creates throwaway users and a temp
# /srv/pwfg-style tree, then tears them down). Skips cleanly (exit 0) when it cannot
# run, so it is safe in CI / on a laptop. Run from the repo root.
#
# Test identities are PREFIXED (pwfgagent/pwfggov/pwfgproxy) so they never collide
# with the box's real agent/gov/proxy users or anything already on the host.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/skill"
BOOT="$REPO/infra/bootstrap/bin"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
no()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP test_boundary.sh: %s\n' "$1"; exit 0; }
# assert a command FAILS (the heart of a containment test)
deny() { if "${@:2}" >/dev/null 2>&1; then no "$1 (it was ALLOWED)"; else ok "$1"; fi; }
allow() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else no "$1 (it was DENIED)"; fi; }

[ "$(id -u)" -eq 0 ] || skip "must run as root"
for t in useradd userdel groupadd groupdel sudo iptables; do
  command -v "$t" >/dev/null 2>&1 || skip "missing tool: $t"
done

AG=pwfgagent; GV=pwfggov; PX=pwfgproxy
G1=pwfgshare      # {agent, gov}  -> agent-RO shared paths (locked/, gov settings)
G2=pwfgkey        # {gov, proxy}  -> gov reads audit/ledger; agent excluded
SRV=""; SUDOERS=""; IMDS_IP="169.254.169.254"
made_users=0

cleanup() {
  iptables -D OUTPUT -d "$IMDS_IP" -m owner --uid-owner "$AG" -j DROP 2>/dev/null
  iptables -D OUTPUT -o lo -p tcp --dport 18254 -m owner --uid-owner "$AG" -j REJECT 2>/dev/null
  [ -n "$SUDOERS" ] && rm -f "$SUDOERS"
  if [ "$made_users" -eq 1 ]; then
    userdel "$AG" 2>/dev/null; userdel "$GV" 2>/dev/null; userdel "$PX" 2>/dev/null
    groupdel "$G1" 2>/dev/null; groupdel "$G2" 2>/dev/null
  fi
  [ -n "$SRV" ] && rm -rf "$SRV"
}
trap cleanup EXIT

# Refuse to clobber pre-existing identities.
for u in "$AG" "$GV" "$PX"; do id "$u" >/dev/null 2>&1 && skip "user $u already exists"; done

# --- create identities ---
groupadd "$G1"; groupadd "$G2"
useradd -M -s /usr/sbin/nologin -G "$G1" "$AG"
useradd -M -s /usr/sbin/nologin -G "$G1","$G2" "$GV"
useradd -M -s /usr/sbin/nologin -G "$G2" "$PX"
made_users=1

# A gov/agent-traversable home for the skill + tree. The repo checkout may sit under
# a dir the throwaway users cannot traverse (e.g. /home/runner in CI, or any $HOME),
# so copy the skill into the world-traversable /tmp tree and run it from there —
# mirroring the real box, where the skill lives gov-owned under /srv/pwfg (not a
# user's home). Boot scripts ($BOOT) are only ever run as root, so they stay in-repo.
SRV="$(mktemp -d -p /tmp pwfgbnd.XXXXXX)"; chmod 0755 "$SRV"
mkdir -p "$SRV/skill"; cp -a "$SKILL/." "$SRV/skill/"
chown -R "$GV:$G1" "$SRV/skill"; chmod -R u+rwX,go+rX "$SRV/skill"
RUNSKILL="$SRV/skill"
# launch-agent.sh runs AS the agent (Option A), so it too must live on a path the
# agent can traverse/execute — deploy it gov-owned into the /tmp tree (mirrors
# /srv/pwfg/bin on the box). Boot scripts ($BOOT) stay in-repo (root-run only).
install -d -o "$GV" -g "$G1" -m 0755 "$SRV/bin"
install -o "$GV" -g "$G1" -m 0755 "$BOOT/launch-agent.sh" "$SRV/bin/launch-agent.sh"
LAUNCH_AGENT="$SRV/bin/launch-agent.sh"

# Mirror infra/bootstrap/sudoers.d/pwfg with the test identities + paths. The gov->agent
# grant is NARROW (production-faithful): only the fake-agent launcher and the proof
# wrapper — never an arbitrary `bash` as agent. PWFG_PLAN is kept gov->agent so the
# wrapper reads the proof from the locked plan; PWFG_PROOF_AS is NOT kept agent->gov
# (the agent must not choose the proof uid).
SUDOERS="/etc/sudoers.d/pwfg-boundary-test"
AGENT_WORK="$SRV/agent-work.sh"
cat >"$SUDOERS" <<EOF
Defaults:$GV env_keep += "PWFG_PROMPT PWFG_MAX_TURNS PWFG_MODEL PWFG_PROXY_PORT PWFG_SRV PWFG_CLAUDE_BIN PWFG_STUB_OUT PWFG_WORKSPACE PWFG_PLAN PWFG_ENV_FILE GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2"
Defaults:$AG env_keep += "PWFG_ENV_FILE GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2"
$GV ALL=($AG) NOPASSWD: $AGENT_WORK, $LAUNCH_AGENT, $RUNSKILL/bin/run-proof-as.sh
$AG ALL=($GV) NOPASSWD: $RUNSKILL/bin/verify-all.sh, $RUNSKILL/bin/verify-task.sh, $RUNSKILL/bin/escalate.sh
EOF
chmod 0440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null 2>&1 || { no "sudoers fragment is valid"; }

# --- lay out the rest of the /srv/pwfg-style tree under $SRV (created above, in /tmp
# so the agent uid can traverse it: a 0700 $TMPDIR would let the negative checks pass
# for the WRONG reason — no traversal — instead of the right one, ownership/perms). ---
mkdir -p "$SRV"/{locked,state,gov,proxy,control,workspace}
mkdir -p "$SRV/locked/tests"

# locked/  gov:G1 0750, files 0640  -> agent reads (group), cannot write
cat >"$SRV/locked/plan.json" <<'EOF'
{ "schema_version": "1", "name": "boundary", "workdir": "../workspace",
  "phases": [
    { "id": "phase1", "title": "p1", "description": "marker step1", "proof": "test -f step1.done" },
    { "id": "phase2", "title": "p2", "description": "marker step2", "proof": "test -f step2.done" }
  ] }
EOF
chown -R "$GV:$G1" "$SRV/locked"; chmod 0750 "$SRV/locked" "$SRV/locked/tests"; chmod 0640 "$SRV/locked/plan.json"

# state/  gov:gov 0700  -> agent has NO access
chown "$GV:$GV" "$SRV/state"; chmod 0700 "$SRV/state"

# gov/  gov:G1 0750; settings.json + env 0640 -> agent reads, cannot write
cat >"$SRV/gov/settings.json" <<EOF
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "sudo -u $GV $RUNSKILL/bin/stop-gate.sh" } ] } ] } }
EOF
cat >"$SRV/gov/env" <<EOF
export PWFG_PLAN="$SRV/locked/plan.json"
export PWFG_WORKSPACE="$SRV/workspace"
export PWFG_STATE_DIR="$SRV/state"
EOF
chown -R "$GV:$G1" "$SRV/gov"; chmod 0750 "$SRV/gov"; chmod 0640 "$SRV/gov/settings.json" "$SRV/gov/env"

# proxy/  proxy:G2 0750; key 0400 proxy-only; audit 0640 group(G2) -> gov reads, agent excluded
echo "sk-ant-SECRET-do-not-leak" >"$SRV/proxy/key"
echo '{"ts":"2026-06-02T00:00:00Z","model":"x","cost":"0.01"}' >"$SRV/proxy/audit.jsonl"
chown -R "$PX:$G2" "$SRV/proxy"; chmod 0750 "$SRV/proxy"; chmod 0400 "$SRV/proxy/key"; chmod 0640 "$SRV/proxy/audit.jsonl"

# control/  gov:G2 0750 -> gov writes KILL, proxy reads, agent excluded
chown "$GV:$G2" "$SRV/control"; chmod 0750 "$SRV/control"

# workspace/  agent:G1 2770 (setgid) -> agent rwx, gov rwx via group
chown "$AG:$G1" "$SRV/workspace"; chmod 2770 "$SRV/workspace"

echo "== NEGATIVE: the agent is contained =="
deny  "agent cannot write the locked plan"            sudo -u "$AG" bash -c "echo x >>'$SRV/locked/plan.json'"
deny  "agent cannot create files under state/"        sudo -u "$AG" bash -c "echo x >'$SRV/state/status.json'"
deny  "agent cannot read state/ (no access)"          sudo -u "$AG" bash -c "ls '$SRV/state'"
deny  "agent cannot write the gov Stop settings"      sudo -u "$AG" bash -c "echo x >>'$SRV/gov/settings.json'"
deny  "agent cannot read the brokered key"            sudo -u "$AG" cat "$SRV/proxy/key"
deny  "agent cannot read the proxy audit log"         sudo -u "$AG" cat "$SRV/proxy/audit.jsonl"

echo "== POSITIVE: the governance contract still works =="
allow "agent CAN read the locked plan (RO)"           sudo -u "$AG" cat "$SRV/locked/plan.json"
allow "agent CAN read the gov Stop settings (RO)"     sudo -u "$AG" cat "$SRV/gov/settings.json"
allow "agent CAN write its workspace"                 sudo -u "$AG" bash -c "umask 002; echo x >'$SRV/workspace/probe'"
allow "gov CAN read the proxy audit log (monitoring)" sudo -u "$GV" cat "$SRV/proxy/audit.jsonl"

echo "== IMDS owner-match lockdown =="
if PWFG_AGENT_USER="$AG" PWFG_IMDS_IP="$IMDS_IP" PWFG_IMDS_PERSIST=0 "$BOOT/imds-lock.sh" >/dev/null 2>&1; then
  allow "the exact IMDS DROP rule is installed for the agent uid" \
        iptables -C OUTPUT -d "$IMDS_IP" -m owner --uid-owner "$AG" -j DROP
  # Functional owner-match proof on loopback (no `ip` to alias the real IMDS IP here):
  # a listener root can reach but the agent uid is REJECTed, proving the mechanism.
  if command -v python3 >/dev/null 2>&1; then
    iptables -A OUTPUT -o lo -p tcp --dport 18254 -m owner --uid-owner "$AG" -j REJECT 2>/dev/null
    python3 -m http.server 18254 --bind 127.0.0.1 >/dev/null 2>&1 &
    lpid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null --max-time 1 http://127.0.0.1:18254/ && break; sleep 0.3; done
    allow "root reaches the listener (owner-match does not block root)" \
          curl -s -o /dev/null --max-time 3 http://127.0.0.1:18254/
    deny  "agent uid is owner-match blocked from the same endpoint" \
          sudo -u "$AG" curl -s -o /dev/null --max-time 3 http://127.0.0.1:18254/
    kill "$lpid" 2>/dev/null; wait "$lpid" 2>/dev/null
  fi
else
  no "imds-lock.sh ran"
fi

echo "== boot-assert.sh passes against the in-force layout =="
allow "boot-assert reports the boundary in force" \
      env PWFG_SRV="$SRV" PWFG_AGENT_USER="$AG" PWFG_IMDS_IP="$IMDS_IP" PWFG_KEY_CRED="$SRV/proxy/key" "$BOOT/boot-assert.sh"

echo "== END-TO-END: gov drives the loop across the uid boundary -> GREEN =="
# The fake-agent worker runs AS the agent uid (umask 002 so gov can later manage the
# files), proving gov spawns agent, agent writes the workspace, and gov's gate reads
# it. It is a FIXED script invoked via the narrow gov->agent grant (no `sudo -u agent
# bash`), mirroring production. Proofs likewise run as the agent uid via the
# run-proof-as.sh wrapper (PWFG_PROOF_AS), so agent code never executes as gov.
cat >"$AGENT_WORK" <<EOF
#!/usr/bin/env bash
umask 002
cd "\$1" || exit 1
for n in 1 2; do [ -f "step\$n.done" ] || { : >"step\$n.done"; break; }; done
printf '{"subtype":"success"}\n'
EOF
chmod 0755 "$AGENT_WORK"; chown "$GV:$G1" "$AGENT_WORK"

# git in this env may force commit signing; neutralize it + mark the repo safe for
# the duration of these commands only (no persistent config change).
GI="GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false GIT_CONFIG_KEY_1=safe.directory GIT_CONFIG_VALUE_1=* GIT_CONFIG_KEY_2=init.defaultBranch GIT_CONFIG_VALUE_2=main"

sudo -u "$GV" env $GI \
  PWFG_ENV_FILE="$SRV/gov/env" \
  PWFG_PROOF_AS="$AG" \
  PWFG_STOP_AT_CHECKPOINT=1 PWFG_MAX_SESSIONS=5 PWFG_STALL_LIMIT=2 \
  PWFG_LAUNCH_CMD="sudo -u $AG $AGENT_WORK $SRV/workspace" \
  bash "$RUNSKILL/bin/run-loop.sh" >"$SRV/loop.out" 2>&1
loop_rc=$?

assert_grep() { if grep -q "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1"; printf '       (see %s)\n' "$3"; fi; }
[ "$loop_rc" -eq 0 ] && ok "run-loop.sh exited 0" || { no "run-loop.sh exited 0 (rc=$loop_rc)"; tail -5 "$SRV/loop.out" | sed 's/^/       /'; }
assert_grep "loop reports RESULT: GREEN" "RESULT: GREEN" "$SRV/loop.out"
# status.json is gov-owned in the gov-only state dir, written by the gov-run gate
allow "status.json is gov-owned in the state dir" bash -c "[ \"\$(stat -c %U '$SRV/state/status.json')\" = '$GV' ]"
gp="$(sudo -u "$GV" jq '[.phases[]|select(.result=="pass")]|length' "$SRV/state/status.json" 2>/dev/null)"
[ "$gp" = 2 ] && ok "both phases GREEN in gov-owned status" || no "both phases GREEN (got=$gp)"
# the workspace files the agent created are agent-owned
allow "workspace markers are agent-owned" bash -c "[ \"\$(stat -c %U '$SRV/workspace/step1.done')\" = '$AG' ]"

echo "== agent -> gov verify bridge (narrow sudoers + env-file) =="
# The agent reaches the verifier ONLY through the narrow `sudo -u gov verify-all.sh`
# rule; gov recovers its context from the gov-owned env file (PWFG_ENV_FILE). The
# command must be verify-all.sh itself — the rule permits nothing else. PWFG_PROOF_AS
# is deliberately NOT passed: it is not kept agent->gov (the agent can't choose the
# proof uid), so bridge-path proofs run in-process as gov (the accepted residual; the
# loop path above is where proofs run as the agent uid via the wrapper).
allow "agent can run verify-all only via the gov bridge, sees GREEN" \
      sudo -u "$AG" env PWFG_ENV_FILE="$SRV/gov/env" $GI \
        sudo -u "$GV" "$RUNSKILL/bin/verify-all.sh"

echo "== LAUNCH path: gov starts the agent via launch-agent.sh under the narrow rule =="
# launch-agent.sh runs AS the agent (Option A): gov invokes it through the SAME narrow
# gov->agent grant as the proof wrapper (no `env`/`claude`/arbitrary command), and it
# execs claude directly. A `claude` STUB records its env + args so we can assert the
# crossing isn't denied, claude ran as the agent uid, the proxy base-url is set with no
# real key, and the gov-owned Stop-hook --settings is carried. (Real claude needs an
# API key; the stub validates the sudo crossing + env scrubbing structurally.)
STUB_OUT="$SRV/workspace/claude-invocation.txt"
cat >"$SRV/claude-stub" <<EOF
#!/usr/bin/env bash
{ echo "ARGS: \$*"; echo "WHOAMI=\$(id -un)"
  echo "BASE_URL=\${ANTHROPIC_BASE_URL:-<unset>}"; echo "OAUTH=\${CLAUDE_CODE_OAUTH_TOKEN:-<unset>}"
} >"\${PWFG_STUB_OUT:-/dev/null}"
printf '{"subtype":"success"}\n'
EOF
chmod 0755 "$SRV/claude-stub"; chown "$GV:$G1" "$SRV/claude-stub"
lout="$(sudo -u "$GV" env PWFG_PROMPT="hi" PWFG_SRV="$SRV" PWFG_PROXY_PORT="8787" \
          PWFG_CLAUDE_BIN="$SRV/claude-stub" PWFG_STUB_OUT="$STUB_OUT" PWFG_MODEL=sonnet PWFG_MAX_TURNS=5 \
          sudo -u "$AG" "$LAUNCH_AGENT" 2>&1)"; lrc=$?
[ "$lrc" -eq 0 ] && ok "gov launches launch-agent.sh as agent (narrow rule, not denied)" \
  || { no "gov launches launch-agent.sh as agent (rc=$lrc)"; printf '%s\n' "$lout" | head -3 | sed 's/^/       /'; }
printf '%s' "$lout" | grep -q '"subtype":"success"' && ok "agent session produced result JSON" || no "agent session produced result JSON"
grep -q "WHOAMI=$AG" "$STUB_OUT" 2>/dev/null && ok "claude ran AS the agent uid" || no "claude ran AS the agent uid"
grep -q "BASE_URL=http://127.0.0.1:8787" "$STUB_OUT" 2>/dev/null && ok "ANTHROPIC_BASE_URL points at the proxy" || no "ANTHROPIC_BASE_URL points at the proxy"
grep -q "OAUTH=<unset>" "$STUB_OUT" 2>/dev/null && ok "no CLAUDE_CODE_OAUTH_TOKEN in the agent env" || no "no CLAUDE_CODE_OAUTH_TOKEN in the agent env"
grep -q -- "--settings $SRV/gov/settings.json" "$STUB_OUT" 2>/dev/null && ok "carries the gov-owned Stop-hook --settings" || no "carries the gov-owned --settings"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
