#!/usr/bin/env bash
# Workflow policy (F03): what the open task's profile and risk require, answered by one place. It only READS (the task's .sdd/state.json, the
# settings, the agent registry); sdd.sh stays the only thing that moves a phase and contract.sh the only thing that judges an exchange.
#   workflow.sh policy [--json]                 profile, risk, verifier, contract level, retry limit of the open task (or of a default task)
#   workflow.sh contracts [--role R]            off | optional | required: may/must a handoff to R carry a contract? (exit 0; prints one word)
#   workflow.sh gate <green|verified>           exit 0, or exit 1 + reason: agents are still in flight / were interrupted (only where contracts are required)
#   workflow.sh require --role R --boundary agent|process --marker yes|no
#                                               exit 1 + reason when contracts are required for R and the handoff has no contract marker (+ a decision event)
#   workflow.sh announce                        telemetry only: the contract level the task's profile sets, as one workflow.decision event
#   workflow.sh profiles                        the profiles, one line each
#   workflow.sh evidence-roles                  the roles whose independent PASS (trusted, this diff) the open task needs beyond the verify command (F04): high risk = verifier reviewer security-auditor
#   workflow.sh capabilities [--json]           what each execution path really enforces (F04); the claims are checked against the shipped files by tests/slow/evidence.test.sh
# Profiles (chosen with `sdd.sh start --profile`, default standard, fixed for the task like the risk label; they never lower a risk gate):
#   small           low risk only. No contract overhead even if CONTRACTS=1. Everything `low` already allows; nothing mandatory is skipped.
#   standard        today's workflow, unchanged. Contracts: optional with CONTRACTS=1, else off.
#   high-assurance  any risk. An independent verifier PASS for this diff is mandatory even at low risk, and contracts are required for every role
#                   that writes or decides (not scout, analyst or an agent that is not a kit role): a spawn without one is refused/asked, an agent that never
#                   answered blocks green and verified until it is closed and retried (contract.sh close; state.sh retry).
# Why a policy rather than a prompt rule: the Claude Code hook and run-role.sh call `contracts`, sdd.sh calls `gate`; nobody has to remember.
# Host limits: only Claude Code (PreToolUse on Agent) and run-role.sh can enforce at a spawn; other hosts get the same answer by hand
# (`workflow.sh contracts`) and the `gate` at advance time, which every host shares.
set -u
cmd="${1:-}"; [ $# -gt 0 ] && shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null || { echo "workflow.sh needs jq" >&2; exit 2; }
top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
. "$here/env.sh" || { echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 2; }
SDKIT_ENV_QUIET=1 sdkit_env_load "$top"
state="$top/$KIT_DIR/.sdd/state.json"

profile="standard"; risk=""; task=""
if [ -f "$state" ]; then
  { read -r task; read -r risk; read -r profile; } < <(jq -r '(.task // ""), (.risk // ""), (.profile // "standard")' "$state" 2>/dev/null)
fi
[ -n "$profile" ] || profile=standard

# contract_level <role>: the contract level for a handoff to <role> under the open task's profile
contract_level() {
  local base="${1##*:}" lvl=off; base="${base%-deep}"
  [ "${CONTRACTS:-}" = 1 ] && lvl=optional
  case "$profile" in
    small) ;;                                   # never more than the project asked for
    high-assurance)
      case "$base" in developer|test-writer|devsecops|engineer|verifier|reviewer|security-auditor|"") lvl=required ;; *) [ "$lvl" = off ] && lvl=optional ;; esac ;;   # scout, analyst and any non-kit agent: optional
  esac
  echo "$lvl"
}

# tele <type> [flags]: a telemetry event for the open task; off unless TELEMETRY=1, never changes the answer
tele() { [ "${TELEMETRY:-}" = 1 ] && [ -x "$here/telemetry.sh" ] && { "$here/telemetry.sh" emit "$@" ${task:+--task "$task"} >/dev/null 2>&1 || true; }; return 0; }

case "$cmd" in
  announce)
    lvl="$(contract_level developer)"; [ "$lvl" = off ] || tele workflow.decision --source contract-policy --outcome "$lvl" --profile "$profile" ;;
  require)
    role=""; boundary=agent; marker=no
    while [ $# -gt 0 ]; do case "$1" in --role) role="${2:-}"; shift ;; --boundary) boundary="${2:-}"; shift ;; --marker) marker="${2:-}"; shift ;; esac; shift; done
    [ "$marker" = yes ] && exit 0
    [ "$(contract_level "$role")" = required ] || exit 0
    tele workflow.decision --source contract-policy --outcome missing-marker --profile "$profile" --role "${role##*:}" --reason missing-field --note "boundary=$boundary"
    echo "profile $profile requires a contract for role ${role##*:}: add CONTRACT: 1, ID: and REPLY-END: to the handoff (references/contract.md)."
    exit 1 ;;
  contracts)
    role=""; while [ $# -gt 0 ]; do case "$1" in --role) role="${2:-}"; shift ;; esac; shift; done
    contract_level "$role" ;;
  gate)
    case "${1:-}" in green|verified) ;; *) exit 0 ;; esac
    [ -n "$task" ] && [ "$(contract_level developer)" = required ] || exit 0
    pend="$(CLAUDE_PROJECT_DIR="$top" "$here/contract.sh" pending --task "$task" 2>/dev/null | tr '\n' ' ')"
    [ -z "${pend// /}" ] && exit 0
    echo "agents still in flight or interrupted: ${pend% }. Wait for them, or close an interrupted one (contract.sh close <id> --reason interrupted) and retry it once (state.sh $task retry <id>)."
    exit 1 ;;
  evidence-roles)
    [ "$risk" = high ] && echo "verifier reviewer security-auditor"
    exit 0 ;;
  capabilities)
    # path | spawn-time contract | verdict parse | trusted role identity | evidence record | stale detection | completion gate | failure report
    # enforced = refuses/records by code at that point; detected = noticed later by code, not prevented; manual = a person/agent must run the command; none = nothing
    rows='claude-code|ask (PreToolUse Agent)|auto (SubagentStop)|host agent_id + spawn registry|auto|enforced|enforced (sdd.sh advance)|systemMessage to the orchestrator
run-role.sh (any host)|enforced (exit 2, nothing starts)|auto (after the process ends)|process-owned run id + spawn registry|auto|enforced|enforced (sdd.sh advance)|exit 3/4/5 + stderr
host-native subagents (codex, opencode, cursor, gemini)|none|manual (parse-verdict.sh --record)|none: recorded as manual, refused at high risk|manual|detected (at advance)|enforced (sdd.sh advance)|refusal at advance
git hooks / CI (all hosts)|none|none|attestation review|from the attestation|enforced (ci-check)|enforced (ci-check)|CI log'
    if [ "${1:-}" = --json ]; then
      printf '%s\n' "$rows" | jq -R -s 'split("\n") | map(select(. != "") | split("|") | {path:.[0], spawn_contract:.[1], verdict_parse:.[2], trusted_identity:.[3], evidence_record:.[4], stale_detection:.[5], completion_gate:.[6], failure_report:.[7]})'
    else
      printf '%s\n' "$rows" | awk -F'|' '{printf "%-52s contract=%s | parse=%s | identity=%s | record=%s | stale=%s | gate=%s | failure=%s\n",$1,$2,$3,$4,$5,$6,$7,$8}'
    fi ;;
  policy)
    ver=verify-command   # low risk: the verify command; the independent verifier is mandatory for medium, high and the high-assurance profile
    case "$risk:$profile" in medium:*|high:*|*:high-assurance) ver=independent-verifier ;; esac
    c_dev="$(contract_level developer)"; c_scout="$(contract_level scout)"
    if [ "${1:-}" = --json ]; then
      jq -n --arg t "$task" --arg r "$risk" --arg p "$profile" --arg v "$ver" --arg cd "$c_dev" --arg cs "$c_scout" \
        --arg ev "$([ "$risk" = high ] && echo "verifier reviewer security-auditor")" \
        '{task:$t, risk:$r, profile:$p, verifier:$v, contracts:{writing_and_deciding_roles:$cd, lookup_roles:$cs}, automatic_retries:1, evidence_roles:($ev | split(" ") | map(select(. != "")))}'
    else
      printf 'task=%s risk=%s profile=%s verifier=%s contracts=%s (scout/analyst: %s) automatic-retries=1\n' "${task:--}" "${risk:--}" "$profile" "$ver" "$c_dev" "$c_scout"
    fi ;;
  profiles)
    echo "small           low risk only; no contract overhead; no mandatory step skipped"
    echo "standard        the default workflow; contracts optional (CONTRACTS=1)"
    echo "high-assurance  any risk; independent verifier PASS mandatory at every risk; contracts required for writing/deciding roles" ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
