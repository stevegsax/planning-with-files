#!/usr/bin/env bash
# common.sh — shared helpers (imperative shell) for plan-with-files-gated.
#
# Sourced by the bin/ tools. Provides path resolution pinned to the LOCKED plan
# (not cwd), plan validation, the proof runner, and the derived-status cache. All
# "what counts as done" data is read from the locked plan only — never from
# agent-writable files (closes the privileged-verifier injection trap).
#
# Contract via environment:
#   PWFG_PLAN        (required) absolute path to the locked plan.json
#   PWFG_WORKSPACE   (optional) agent's working dir; default <plan>/../workspace
#   PWFG_STATE_DIR   (optional) harness state dir; default <workspace>/.harness
#   PWFG_SCHEMA      (optional) plan.schema.json for a full JSON Schema check
#   PWFG_MAX_BLOCKS  (optional) Stop-gate block cap; default 40

set -uo pipefail

pwfg_die() { printf 'pwfg: %s\n' "$*" >&2; exit 1; }
pwfg_need() { command -v "$1" >/dev/null 2>&1 || pwfg_die "required tool not found: $1"; }

pwfg_plan_path() {
  local p="${PWFG_PLAN:-}"
  [ -n "$p" ] || pwfg_die "PWFG_PLAN is not set (absolute path to the locked plan.json)"
  [ -f "$p" ] || pwfg_die "plan not found: $p"
  printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")"
}

pwfg_plan_dir() { dirname "$(pwfg_plan_path)"; }

pwfg_workdir() {
  local plan plan_dir workdir
  plan="$(pwfg_plan_path)"; plan_dir="$(dirname "$plan")"
  workdir="$(jq -r '.workdir // "."' "$plan")"
  ( cd "$plan_dir" && cd "$workdir" 2>/dev/null && pwd ) \
    || pwfg_die "plan workdir does not resolve: $workdir"
}

pwfg_workspace() {
  local w="${PWFG_WORKSPACE:-}"
  [ -n "$w" ] || w="$(pwfg_plan_dir)/../workspace"
  printf '%s\n' "$w"
}

pwfg_state_dir() {
  local d="${PWFG_STATE_DIR:-}"
  [ -n "$d" ] || d="$(pwfg_workspace)/.harness"
  mkdir -p "$d/logs"
  printf '%s\n' "$d"
}

# Cheap structural validation (jq only). Runs in the hot gate path. Confirms the
# plan shape AND that the workdir resolves, so the gate fails with one clear
# message rather than per-phase noise.
pwfg_validate_plan() {
  local plan; plan="$(pwfg_plan_path)"; pwfg_need jq
  jq -e '
    (.schema_version == "1")
    and (.name | type == "string" and (. | length > 0))
    and (.phases | type == "array" and (length > 0))
    and (all(.phases[];
          (.id | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
          and (.title | type == "string" and (. | length > 0))
          and (.proof | type == "string" and (. | length > 0))))
    and (([.phases[].id]) | (length == (unique | length)))
  ' "$plan" >/dev/null 2>&1 || pwfg_die "plan failed structural validation: $plan"
  pwfg_workdir >/dev/null
}

# Full validation: structural + JSON Schema. Runs once at init (not per gate),
# so the schema check stays off the hot path.
pwfg_validate_plan_full() {
  pwfg_validate_plan
  local schema="${PWFG_SCHEMA:-}"
  if [ -n "$schema" ] && command -v uv >/dev/null 2>&1; then
    uv run --quiet --with check-jsonschema check-jsonschema \
      --schemafile "$schema" "$(pwfg_plan_path)" >/dev/null 2>&1 \
      || pwfg_die "plan failed JSON Schema validation: $(pwfg_plan_path)"
  fi
}

pwfg_phase_ids() { jq -r '.phases[].id' "$(pwfg_plan_path)"; }
pwfg_phase_exists() { pwfg_phase_ids | grep -qxF -- "$1"; }
pwfg_phase_field() {
  jq -r --arg id "$1" --arg f "$2" \
    '.phases[] | select(.id == $id) | .[$f] // empty' "$(pwfg_plan_path)"
}

# Run a phase's proof command. The command text comes ONLY from the locked plan;
# it runs with cwd = workdir. Combined output is captured to a per-phase log.
# Returns the proof's exit code (126/127 == could-not-run; callers treat those as
# an infrastructure error distinct from a test failure).
pwfg_run_proof() {
  local id="$1" workdir proof log
  pwfg_phase_exists "$id" || pwfg_die "unknown phase: $id"
  proof="$(pwfg_phase_field "$id" proof)"
  [ -n "$proof" ] || pwfg_die "phase has no proof command: $id"
  workdir="$(pwfg_workdir)" || exit 1
  log="$(pwfg_state_dir)/logs/$id.txt"
  ( cd "$workdir" && bash -c "$proof" ) >"$log" 2>&1
}

# ---- derived-status cache (advisory, agent-writable; the authoritative gate
#      re-runs fresh and never trusts this file) -------------------------------

pwfg_status_file() { printf '%s/status.json\n' "$(pwfg_state_dir)"; }

pwfg_status_init() {
  local plan f; plan="$(pwfg_plan_path)"; f="$(pwfg_status_file)"
  jq '{plan: .name,
       phases: (reduce .phases[] as $p ({};
                 .[$p.id] = {result: "unknown", checked_at: null, sha: null}))}' \
    "$plan" >"$f"
}

pwfg_status_set() {
  local id="$1" result="$2" f tmp ts sha
  f="$(pwfg_status_file)"; [ -f "$f" ] || pwfg_status_init
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sha="$( (cd "$(pwfg_workspace)" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null) || echo none )"
  tmp="$(mktemp)"
  jq --arg id "$id" --arg r "$result" --arg ts "$ts" --arg sha "$sha" \
    '.phases[$id] = {result: $r, checked_at: $ts, sha: $sha}' "$f" >"$tmp" && mv "$tmp" "$f"
}

pwfg_failing_ids() {
  jq -r '[.phases | to_entries[] | select(.value.result != "pass") | .key] | join(", ")' \
    "$(pwfg_status_file)" 2>/dev/null
}

# Phase ids whose cached result is pass (one per line).
pwfg_green_ids() {
  jq -r '[.phases | to_entries[] | select(.value.result == "pass") | .key][]' \
    "$(pwfg_status_file)" 2>/dev/null
}

# Remaining (not-green) phase ids, in plan order (one per line).
pwfg_remaining_ids() {
  local green; green="$(pwfg_green_ids)"
  if [ -z "$green" ]; then pwfg_phase_ids; return; fi
  pwfg_phase_ids | grep -vxF -f <(printf '%s\n' "$green")
}
