#!/usr/bin/env bash
# Run one role as a separate headless process of any supported host: independent by construction (fresh context, only the
# handoff), pinned to a directory (a task worktree), read-only when the role is read-only, and able to use a different
# host / model family than the main session (for example the verifier on another vendor).
# Usage: run-role.sh <role> --handoff FILE [--cwd DIR] [--host H] [--tier T] [--model M] [--out FILE] [--ignore-budget] [--dry-run]
#   role      a subagent role (analyst scout engineer developer test-writer devsecops reviewer security-auditor verifier verifier-deep)
#   --host    claude|codex|opencode|cursor|gemini. Default: VERIFIER_HOST for verifier roles, then RUN_ROLE_HOST (sdkit.env)
#   --tier    light|standard|strong (small|medium|large accepted): task size from tasks.md. Replaces the role's own tier, except that
#             verifier/reviewer/security-auditor never go below it (they may go up). Without it the role's tier applies, as before.
#             Codex: sets reasoning effort (CODEX_EFFORT_<TIER>) instead of a model.
#   --model   host-specific model id; wins over --tier. Default RUN_ROLE_MODEL_<LIGHT|STANDARD|STRONG> from sdkit.env;
#             with --tier also <HOST>_MODEL_<TIER> from core/tiers.env; else the host's default (the session's model)
#   --out     also write the role's answer there (it is always printed on stdout)
#   --envelope  (or RESULT_ENVELOPE=1) print a compact ENVELOPE/1 view of a long answer instead of the answer; the FULL answer is stored (--out, else
#             <project-dir>/work/<slug>/out/) and named in it; FAIL/CONFIRMED/BLOCKER lines are kept verbatim; verdict and contract checks use the full answer (digest.sh)
#   --ignore-budget  run although MAX_SPAWNS or TOKEN_BUDGET_TASK says stop (use after the user agreed; SDD_MODE=off/guided never stops)
#   --rerun WHY  routing only: run again although the same request already completed / valid evidence exists (the reason is recorded)
#   --dry-run print the command instead of running it
# The role text comes from core/roles/<role>.md (kit checkout / plugin) or <project-dir>/roles/<role>.md (copied by init).
# Contract (F02, opt-in): a handoff with a `CONTRACT:` line is validated and registered before the spawn (scripts/contract.sh issue; invalid: exit 2,
#   nothing is started) and the answer is checked for its HANDOFF-RESULT line afterwards. The answer is printed and stored either way.
#   With the high-assurance profile (scripts/workflow.sh) a handoff to a writing or deciding role must be contracted: exit 2 in strict mode, a warning in guided.
# Evidence (F04): verifier, reviewer and security-auditor runs while a task is open are the trusted execution path on every host. This script registers the
#   spawn (sdd.sh _spawn, with the diff as it is), and after the process ends records the answer's verdict itself (parse-verdict.sh --role .. --record --source
#   run-role), so the verdict is tied to this process, this role and this diff, not to anything the answer claims. A run that fails records nothing.
#   An answer that is not a valid verdict block, or that sdd.sh refuses (the diff changed meanwhile), exits 6.
# Routing (F06, opt-in ROUTING=on in sdkit.env): scripts/route.sh decides adapter, model, tier, budget and whether to run, reuse, retry or escalate; this script
#   executes that decision and records how the run ended. Off (default) = the behaviour above, unchanged. A decision that is not execute/retry/escalate starts nothing:
#   exit 3 budget exhausted, exit 2 refused by policy/config, exit 7 valid evidence reused (success-like: nothing to run, nothing to retry), exit 8 not run and nothing valid
#   exists (duplicate, standing BLOCK, retries/escalation exhausted, optional role skipped, ...): never treat 8 as success.
# Exit: the host CLI's status; 127 when its CLI is not installed; 2 on usage errors; 3 budget; 7 routing reused valid evidence; 8 routing declined to run; for a contracted handoff also 4 when the answer
#   breaks the contract and 5 when it is valid but reports partial|blocked|failed (exit 0 = valid and done; it never means verified); 6 when an evidence role's
#   answer could not be recorded as a verdict.
# UNVERIFIED against live CLIs: flag spellings per host below follow each tool's documented headless mode; run with
# --dry-run and check them against `<cli> --help` once per installed version (doctor.sh lists which CLIs are present).
set -u
role="${1:-}"; [ $# -gt 0 ] && shift
handoff=""; cwd="$PWD"; host=""; model=""; out=""; dry=0; want=""; nobudget=0; rerun=""; envelope="${RESULT_ENVELOPE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --handoff) handoff="$2"; shift ;; --cwd) cwd="$2"; shift ;; --host) host="$2"; shift ;;
    --tier) want="$2"; shift ;; --model) model="$2"; shift ;; --out) out="$2"; shift ;; --ignore-budget) nobudget=1 ;; --rerun) rerun="$2"; shift ;; --dry-run) dry=1 ;; --envelope) envelope=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
flag_host="$host"; flag_model="$model"; flag_tier="$want"   # what the caller asked for explicitly (routing validates these; it does not guess them)
[ -n "$role" ] && [ -f "$handoff" ] || { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ -d "$cwd" ] || { echo "--cwd $cwd is not a directory" >&2; exit 2; }
cwd="$(cd "$cwd" && pwd)"; handoff="$(cd "$(dirname "$handoff")" && pwd)/$(basename "$handoff")"

here="$(cd "$(dirname "$0")" && pwd)"
top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
. "$(dirname "${BASH_SOURCE[0]}")/env.sh" || { echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }; sdkit_env_load "$top"

# telemetry (off unless TELEMETRY=1): one agent.start / agent.end pair per run, correlated by span. Never changes what run-role does.
tele() { [ "${TELEMETRY:-}" = 1 ] && [ -x "$here/telemetry.sh" ] && { "$here/telemetry.sh" emit "$@" ${tslug:+--task "$tslug"} >/dev/null 2>&1 || true; }; return 0; }
tslug=""; span=""; t0=""
xid="rr-$(date +%s)-$$"   # ledger execution id when TELEMETRY (and so $span) is off
if [ "${TELEMETRY:-}" = 1 ]; then tslug="$(sdkit_active_slug "$top")"; span="rr-$(date +%s)-$$"; t0="$("$here/telemetry.sh" now-ms 2>/dev/null)"; fi

# Lifecycle (F14): once routing has decided to run (and reserved budget), EVERY way out of this script closes the decision exactly once, with the real exit status:
# normal end, a refused gate, a missing CLI, a failed host, SIGINT/SIGTERM. rr_close is idempotent (route.sh outcome releases a reservation once).
rid=""; tmp=""; raw=""; cpid=""; launched=0; finished=0; rr_closed=0; tq=unavailable; tin=0; tout=0; rdur=""; hcost=""
rr_close() { [ "$rr_closed" = 0 ] && [ -n "$rid" ] && [ "$dry" = 0 ] && "$here/route.sh" outcome --decision "$rid" --rc "$1" ${2:+--prc "$2"} ${tmp:+--stderr "$tmp.err"} ${rdur:+--dur-ms "$rdur"} ${hcost:+--cost-est "$hcost"} --tokens "$tq" --in "$tin" --out "$tout" >/dev/null 2>&1 && rr_closed=1; return 0; }
on_exit() {
  local rc=$?
  if [ "$launched" = 1 ] && [ "$finished" = 0 ]; then   # stopped by a signal while the host was running: tokens may have been spent but none were read
    [ -x "$here/usage.sh" ] && "$here/usage.sh" log --role "$role" --tier "$tier" --host "$host" --model "$model" --id "${span:-$xid}" --kind final --tq unavailable --status interrupted --source run-role >/dev/null 2>&1
    [ "${contracted:-0}" = 1 ] && "$here/contract.sh" close "${cid:-}" --reason interrupted --source run-role >/dev/null 2>&1
    [ -n "${evrun:-}" ] && CLAUDE_PROJECT_DIR="$top" "$here/sdd.sh" _spawn-close --run "$evrun" --reason interrupted >/dev/null 2>&1
  fi
  rr_close "$rc"
  rm -f "$tmp" "$raw" "${tmp:+$tmp.err}" "${tmp:+$tmp.prompt}"
  return $rc
}
on_sig() { [ -n "$cpid" ] && { pkill -TERM -P "$cpid" 2>/dev/null; kill -TERM "$cpid" 2>/dev/null; }; exit "$1"; }
trap on_exit EXIT; trap 'on_sig 130' INT; trap 'on_sig 143' TERM

[ "$nobudget" = 1 ] && [ "$dry" = 0 ] && "$here/audit.sh" log budget.override role="$role" source=run-role >/dev/null 2>&1
base="${role%-deep}"; tier=""; access=""
src=""; for c in "$here/../core/roles/$base.md" "$top/$KIT_DIR/roles/$base.md"; do [ -f "$c" ] && { src="$c"; break; }; done
[ -n "$src" ] || { echo "no role text for '$base' (looked in core/roles and $KIT_DIR/roles)" >&2; exit 2; }
fm() { awk -v k="$1" 'BEGIN{f=0} /^---$/{f++; next} f==1 && index($0,k":")==1 {sub("^"k":[ ]*",""); print; exit}' "$src"; }
tier="$(fm tier)"; access="$(fm access)"
[ "$role" != "$base" ] && tier="$(fm deep)"
[ -n "$tier" ] || tier=standard
tier="$(sdkit_role_tier "$role" "$tier")"   # AGENT_<ROLE>_TIER in sdkit.env
ro=1; [ "$access" = read-only ] || ro=0

rank() { case "$1" in light) echo 1 ;; standard) echo 2 ;; strong) echo 3 ;; esac; }
if [ -n "$want" ]; then
  case "$want" in small) want=light ;; medium) want=standard ;; large) want=strong ;; esac
  [ -n "$(rank "$want")" ] || { echo "--tier must be light|standard|strong (or small|medium|large), got '$want'" >&2; exit 2; }
  case "$base" in
    verifier|reviewer|security-auditor) [ "$(rank "$want")" -gt "$(rank "$tier")" ] && tier="$want" ;;
    *) tier="$want" ;;
  esac
fi

ropts=()
case "${ROUTING:-off}" in on|off|"") ;; *) echo "run-role: ROUTING must be on or off (is '${ROUTING}'); refusing to guess whether the routing policy applies" >&2; exit 2 ;; esac
if [ "${ROUTING:-off}" = on ]; then
  [ -x "$here/route.sh" ] || { echo "run-role: ROUTING=on but route.sh is missing next to this script (run sdkit upgrade); refusing to run without the routing policy" >&2; exit 2; }
  ropts=(decide --role "$role" --json --require-cli --source run-role --handoff "$handoff"); [ -n "$flag_host" ] && ropts+=(--host "$flag_host"); [ -n "$flag_model" ] && ropts+=(--model "$flag_model")
  [ -n "$flag_tier" ] && ropts+=(--tier "$flag_tier"); [ -n "$rerun" ] && ropts+=(--rerun "$rerun"); [ "$nobudget" = 1 ] && ropts+=(--ignore-budget)
  [ "$dry" = 1 ] || ropts+=(--reserve --pid "$$")
  dj="$(CLAUDE_PROJECT_DIR="$top" "$here/route.sh" "${ropts[@]}" 2>/dev/null)"; drc=$?
  act="$(printf '%s' "$dj" | jq -r '.action // empty' 2>/dev/null)"; rsn="$(printf '%s' "$dj" | jq -r '.reason // empty' 2>/dev/null)"
  [ -n "$act" ] || { echo "run-role: routing produced no decision (route.sh exit $drc); refusing to run without it" >&2; exit 2; }
  case "$act" in
    execute|retry|escalate) ;;
    *) echo "run-role: routing: $act ($rsn)$(printf '%s' "$dj" | jq -r '(.notes // []) | if length > 0 then ": " + join("; ") else "" end')" >&2
       case "$act" in
         reuse) echo "run-role: exit 7 = NOT A FAILURE: valid evidence for this diff already exists, nothing was run and nothing should be retried (read it: sdd.sh evidence)" >&2 ;;
         stop) [ "$drc" = 8 ] && echo "run-role: exit 8 = NOT RUN: routing declined to start it and no valid result exists for this request; this is not a verification and not a pass" >&2 ;;
       esac
       if [ "$rsn" = BUDGET_EXHAUSTED ]; then
         echo "run-role: task state is unchanged; raise the limit in $KIT_DIR/sdkit.local.env, or ask the user and re-run with --ignore-budget" >&2; tele failure --category budget --role "$role" --source run-role
       fi
       exit "$drc" ;;
  esac
  host="$(printf '%s' "$dj" | jq -r '.adapter')"; model="$(printf '%s' "$dj" | jq -r '.model // empty')"; effort="$(printf '%s' "$dj" | jq -r '.effort // empty')"
  tier="$(printf '%s' "$dj" | jq -r '.tier // empty')"; rid="$(printf '%s' "$dj" | jq -r '.decision_id')"; rtimeout="$(printf '%s' "$dj" | jq -r '.timeout_s // empty')"; rwait="$(printf '%s' "$dj" | jq -r '.wait_s // 0')"
  echo "run-role: routing: $act $host/${model:-default model} tier=$tier reason=$rsn ($rid)$(printf '%s' "$dj" | jq -r '(.warnings // []) | map(" [" + (split(":")[0]) + "]") | join("")')" >&2
fi
if [ -z "$rid" ]; then   # routing off: the host, model and effort are resolved here as before
if [ -z "$host" ]; then
  case "$base" in verifier|reviewer|security-auditor) host="${VERIFIER_HOST:-}" ;; esac
  [ -n "$host" ] || host="${RUN_ROLE_HOST:-}"
fi
[ -n "$host" ] || { echo "no host: pass --host or set RUN_ROLE_HOST (VERIFIER_HOST for independent roles) in $KIT_DIR/$KIT_ENV" >&2; exit 2; }
if [ -z "$model" ]; then
  T="$(printf '%s' "$tier" | tr a-z A-Z)"; eval "model=\${RUN_ROLE_MODEL_$T:-}"
fi
tierenv() { local f="$here/../core/tiers.env"; [ -f "$f" ] || f="$top/$KIT_DIR/tiers.env"; [ -f "$f" ] && sed -n "s/^$1=//p" "$f" | tail -1; }
HU="$(printf '%s' "$host" | tr a-z A-Z)"; TU="$(printf '%s' "$tier" | tr a-z A-Z)"
[ -z "$model" ] && [ -n "$want" ] && model="$(tierenv "${HU}_MODEL_$TU")"
effort=""
if [ "$host" = codex ] && [ -n "$want" ]; then
  effort="$(tierenv "CODEX_EFFORT_$TU")"
  [ -n "$effort" ] || case "$tier" in light) effort=low ;; standard) effort=medium ;; *) effort=high ;; esac
fi
fi   # routing off

contracted=0; cid=""; creply=""
if grep -qE '^[[:space:]]*CONTRACT:' "$handoff"; then
  contracted=1; cid="$(sed -n 's/^[[:space:]]*ID:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$handoff" | head -1)"
  creply=" Then end with the single HANDOFF-RESULT line the handoff asks for."
fi
if [ "$contracted" = 0 ] && [ -x "$here/workflow.sh" ] && [ -f "$top/$KIT_DIR/.sdd/state.json" ] && grep -q 'high-assurance' "$top/$KIT_DIR/.sdd/state.json"; then
  wfmsg="$(CLAUDE_PROJECT_DIR="$top" "$here/workflow.sh" require --role "$role" --boundary process --marker no 2>&1)" || {   # the task's profile requires a contract here
    echo "run-role: $wfmsg" >&2; [ "${SDD_MODE:-strict}" = strict ] && exit 2; }
fi
body="$(awk 'BEGIN{f=0} /^---$/{f++; next} f>=2{print}' "$src")"
prompt="$(printf 'You are running as the "%s" role of the spec-driven-kit workflow. Your project directory (holds sdkit.env) is `%s/`.\nYour working directory is %s. Do not touch files outside it.\n\n%s\n\n# Handoff\n\n%s\n\nAnswer in exactly the format your role defines.%s\n' \
  "$role" "$KIT_DIR" "$cwd" "$body" "$(cat "$handoff")" "$creply")"

tmp="$(mktemp)"
cli=""; args=()
case "$host" in
  claude)
    cli=claude; args=(-p "$prompt" --output-format json)
    [ -n "$model" ] && args+=(--model "$model")
    [ "$ro" = 1 ] && args+=(--disallowedTools "Edit Write NotebookEdit") || args+=(--permission-mode acceptEdits) ;;
  codex)
    cli=codex; args=(exec -C "$cwd" --sandbox "$([ "$ro" = 1 ] && echo read-only || echo workspace-write)" --output-last-message "$tmp")
    [ -n "$model" ] && args+=(-m "$model"); [ -n "$effort" ] && args+=(-c "model_reasoning_effort=$effort"); args+=("$prompt") ;;
  opencode)
    cli=opencode; args=(run --dir "$cwd" --agent "$role")
    [ -n "$model" ] && args+=(-m "$model"); args+=("$prompt") ;;
  cursor)
    cli=cursor-agent; args=(-p "$prompt" --output-format json --workspace "$cwd")
    [ -n "$model" ] && args+=(--model "$model")
    [ "$ro" = 1 ] && args+=(--mode ask) || args+=(--force) ;;
  gemini)
    cli=gemini; args=(-p "$prompt" -o json --approval-mode "$([ "$ro" = 1 ] && echo plan || echo auto_edit)")
    [ -n "$model" ] && args+=(-m "$model") ;;
  ext:*)  # F12: an external execution adapter, adapters.d/<name>.sh (contract: docs/design-adapters.md). The same gates, evidence and usage paths apply.
    xname="${host#ext:}"; xf=""; for c in "$top/$KIT_DIR/adapters.d/$xname.sh" "$here/../adapters.d/$xname.sh"; do [ -x "$c" ] && { xf="$c"; break; }; done
    case "$xname" in ''|*[!A-Za-z0-9_-]*) xf="" ;; esac
    [ -n "$xf" ] || { echo "run-role: no executable adapter '$xname' (adapters.d/$xname.sh)" >&2; exit 2; }
    printf '%s' "$prompt" > "$tmp.prompt"; cli="$xf"
    [ "$dry" = 1 ] || "$here/audit.sh" log adapter.exec adapter="$xname" role="$role" bytes="${#prompt}" >/dev/null 2>&1
    args=(execute --role "$role" --cwd "$cwd" --tier "$tier" --ro "$ro"); [ -n "$model" ] && args+=(--model "$model"); args+=(--prompt-file "$tmp.prompt") ;;
  *) echo "unknown host '$host' (claude|codex|opencode|cursor|gemini|ext:<adapter>)" >&2; exit 2 ;;
esac

if [ "$dry" = 1 ]; then
  [ "$contracted" = 1 ] && "$here/contract.sh" issue "$handoff" --role "$role" --check-only >&2
  printf '(cd %q && %s' "$cwd" "$cli"; for a in "${args[@]}"; do case "$a" in "$prompt") printf ' <prompt:%d chars>' "${#a}" ;; *) printf ' %q' "$a" ;; esac; done; printf ')\n'
  exit 0
fi
command -v "$cli" >/dev/null 2>&1 || { echo "run-role: '$cli' is not installed (host $host)" >&2; tele failure --category host-missing --role "$role" --host "$host" --source run-role; rr_close 127; exit 127; }

# F08: a verifier cannot judge a DoD that has no method, a bare "none" or a duplicate id; say so now, before it is paid for (only when a proposal is open)
if [ "$base" = verifier ]; then
  _prop="$(jq -r '.proposal // empty' "$top/$KIT_DIR/.sdd/state.json" 2>/dev/null)"
  if [ -n "$_prop" ] && [ -f "$top/$_prop" ] && [ ! -x "$here/dod-check.sh" ]; then
    echo "run-role: dod-check.sh is missing next to this script, so the DoD cannot be checked; refusing to run the verifier without it (run sdkit upgrade)" >&2
    tele failure --category gate --role "$role" --reason dod-check-missing --source run-role; exit 2
  fi
  if [ -n "$_prop" ] && [ -f "$top/$_prop" ] && ! _dm="$("$here/dod-check.sh" "$top/$_prop" 2>&1)"; then
    echo "run-role: DoD not verifiable, fix $_prop first (nothing was run):" >&2; printf '%s\n' "$_dm" | sed 's/^/  /' >&2
    tele failure --category gate --role "$role" --reason no-dod --source run-role; rr_close 2; exit 2
  fi
fi

# contracted handoff: validate and register it before anything is spent (a handoff that cannot yield a valid result is not started)
if [ "$contracted" = 1 ]; then
  csum="$("$here/contract.sh" issue "$handoff" --role "$role" --source run-role 2>&1)" || { echo "run-role: $csum" >&2; rr_close 2; exit 2; }
fi

# spawn and token budget (off unless MAX_SPAWNS / TOKEN_BUDGET_TASK are set): this is the spawn point on hosts without the Agent-tool hook
if [ -z "$rid" ] && [ -n "${MAX_SPAWNS:-}${TOKEN_BUDGET_TASK:-}" ] && [ "${SDD_MODE:-strict}" != off ]; then   # (with routing on, route.sh did this at the decision)
  bslug="$(sdkit_active_slug "$top")"
  if [ -n "$bslug" ] && [ -f "$top/$KIT_DIR/work/$bslug/state.json" ]; then
    over=""
    over="$("$here/state.sh" "$bslug" spawn 2>&1 >/dev/null)" || true
    b="$("$here/usage.sh" budget "$bslug" 2>&1)"; [ $? = 4 ] && over="${over:+$over; }$b"
    if [ -n "$over" ]; then
      echo "run-role: budget reached for task $bslug: $over" >&2
      if [ "${SDD_MODE:-strict}" = strict ] && [ "$nobudget" = 0 ]; then echo "run-role: ask the user, then re-run with --ignore-budget" >&2; tele failure --category budget --role "$role" --host "$host" --source run-role; exit 3; fi
    fi
  fi
fi

# evidence roles: register this run (the diff it will see) before it starts
evrun=""
case "$base" in verifier|reviewer|security-auditor)
  # (reviewer and security-auditor are evidence roles only at high risk; at lower risk their answers keep their free form)
  if [ "${SDD_MODE:-strict}" != off ] && [ -f "$top/$KIT_DIR/.sdd/state.json" ] && { [ "$base" = verifier ] || [ "$(jq -r '.risk // empty' "$top/$KIT_DIR/.sdd/state.json" 2>/dev/null)" = high ]; }; then
    evrun="rr-$(date +%s)-$$-$RANDOM"; CLAUDE_PROJECT_DIR="$top" "$here/sdd.sh" _spawn "$base" --source run-role --run "$evrun" >/dev/null 2>&1 || evrun=""
  fi ;; esac
raw="$(mktemp)"
[ -n "$t0" ] && t0="$("$here/telemetry.sh" now-ms 2>/dev/null)"   # the clock starts at the launch, not at the budget check
tele agent.start --span "$span" --role "$role" --host "$host" --model "$model" --tier "$tier" --source run-role
tpre=(); if [ -n "${rtimeout:-}" ]; then for tc in timeout gtimeout; do command -v "$tc" >/dev/null 2>&1 && { tpre=("$tc" "$rtimeout"); break; }; done; fi   # hard only where a timeout command exists (route.sh says which in the decision)
[ "${rwait:-0}" -gt 0 ] 2>/dev/null && [ "${SDKIT_ROUTE_NO_SLEEP:-}" != 1 ] && { echo "run-role: routing: waiting ${rwait}s before this retry (backoff)" >&2; sleep "$rwait"; }
# The child gets SDKIT_CHILD_RUN: this run is accounted HERE (usage.sh log below). A Claude Code child session would otherwise log the same tokens a second time
# through its own Stop hook (hooks/usage-log.sh skips the session snapshot when the marker is set; only this child process has it).
exec 3<&0; launched=1
( cd "$cwd" && SDKIT_CHILD_RUN="${span:-$xid}" "${tpre[@]+"${tpre[@]}"}" "$cli" "${args[@]}" ) <&3 > "$raw" 2>"$tmp.err" &
cpid=$!; wait "$cpid"; rc=$?; cpid=""; finished=1
dur=""; [ -n "$t0" ] && dur="$(( $("$here/telemetry.sh" now-ms 2>/dev/null || echo "$t0") - t0 ))"
if [ "$rc" != 0 ]; then
  echo "run-role: $cli exited $rc" >&2; tail -20 "$tmp.err" >&2; rdur="$dur"; rr_close "$rc"; rm -f "$tmp.err"
  tele agent.end --span "$span" --role "$role" --host "$host" --model "$model" --tier "$tier" --outcome error --dur-ms "$dur" --q duration=actual --source run-role
  # the host ran and failed: tokens may have been spent but none were read. Mark the execution (unmeasured, never 0) so the report shows a gap.
  [ -x "$here/usage.sh" ] && "$here/usage.sh" log --role "$role" --tier "$tier" --host "$host" --model "$model" --id "${span:-$xid}" --kind final --tq unavailable --status interrupted --source run-role >/dev/null 2>&1
  tele failure --category host-error --role "$role" --host "$host" --source run-role --note "exit $rc"
  [ "$contracted" = 1 ] && "$here/contract.sh" close "$cid" --reason interrupted --source run-role >/dev/null 2>&1
  [ -n "$evrun" ] && CLAUDE_PROJECT_DIR="$top" "$here/sdd.sh" _spawn-close --run "$evrun" --reason interrupted >/dev/null 2>&1
  exit "$rc"
fi
rm -f "$tmp.err"

# the answer, and token usage where the host prints it
cr=0; cw=0; answer=""; tq=unavailable   # tq: did the host print token usage that was read (never assume 0 is a count)
case "$host" in
  claude)
    answer="$(jq -r '.result // empty' "$raw" 2>/dev/null)"
    read -r tin tout cr cw < <(jq -r '[.usage.input_tokens // 0, .usage.output_tokens // 0, .usage.cache_read_input_tokens // 0, .usage.cache_creation_input_tokens // 0] | @tsv' "$raw" 2>/dev/null || echo "0 0 0 0")
    jq -e '.usage.input_tokens != null and .usage.output_tokens != null' "$raw" >/dev/null 2>&1 && tq=actual
    # total_cost_usd is Claude Code's CLIENT-SIDE estimate (not a bill; cumulative if a session is resumed, which this script never does): kept as a host estimate, apart from tokens
    hcost="$(jq -r '.total_cost_usd | select(type == "number" and . >= 0)' "$raw" 2>/dev/null)" ;;
  ext:*)  # the adapter contract: {"result": text, "usage": {input_tokens, output_tokens, cache_read_input_tokens?, cache_creation_input_tokens?}} ; no usage = unmeasured, never 0
    answer="$(jq -r '.result // empty' "$raw" 2>/dev/null)"
    read -r tin tout cr cw < <(jq -r '[.usage.input_tokens // 0, .usage.output_tokens // 0, .usage.cache_read_input_tokens // 0, .usage.cache_creation_input_tokens // 0] | @tsv' "$raw" 2>/dev/null || echo "0 0 0 0")
    jq -e '.usage.input_tokens != null and .usage.output_tokens != null' "$raw" >/dev/null 2>&1 && tq=actual; rm -f "$tmp.prompt" ;;
  cursor) answer="$(jq -r '.result // empty' "$raw" 2>/dev/null)" ;;
  gemini)
    answer="$(jq -r '.response // empty' "$raw" 2>/dev/null)"
    read -r tin tout < <(jq -r '[[.. | .promptTokenCount? // empty] | add // 0, [.. | .candidatesTokenCount? // empty] | add // 0] | @tsv' "$raw" 2>/dev/null || echo "0 0")
    jq -e '[.. | .promptTokenCount? // empty] | length > 0' "$raw" >/dev/null 2>&1 && tq=actual ;;
  codex) answer="$(cat "$tmp")" ;;
  opencode) answer="$(cat "$raw")" ;;
esac
[ -n "$answer" ] || answer="$(cat "$raw")"
if [ "$envelope" = 1 ] && [ -x "$here/digest.sh" ]; then
  _sl="${tslug:-$(sdkit_active_slug "$top" 2>/dev/null)}"; [ -n "$_sl" ] || _sl=_none
  [ -n "$out" ] || out="$top/$KIT_DIR/work/$_sl/out/$role-$xid.md"
  mkdir -p "$(dirname "$out")"; printf '%s\n' "$answer" > "$out"
  printf '%s\n' "$answer" | CLAUDE_PROJECT_DIR="$top" "$here/digest.sh" envelope --role "$role" --ref "$out"
else printf '%s\n' "$answer"; fi
[ -n "$out" ] && { mkdir -p "$(dirname "$out")"; printf '%s\n' "$answer" > "$out"; }
if [ "$tq" = actual ]; then   # cache counts exist only on claude; gemini has none: leave them out rather than write 0
  cq=(--cache-read "${cr:-0}" --cache-write "${cw:-0}"); case "$host" in claude|ext:*) ;; *) cq=() ;; esac
  tele agent.end --span "$span" --role "$role" --host "$host" --model "$model" --tier "$tier" --outcome ok --dur-ms "$dur" --q duration=actual \
    --in "${tin:-0}" --out "${tout:-0}" ${cq[@]+"${cq[@]}"} --q tokens=actual --source run-role
else
  tele agent.end --span "$span" --role "$role" --host "$host" --model "$model" --tier "$tier" --outcome ok --dur-ms "$dur" --q duration=actual --q tokens=unavailable --source run-role
fi
[ -x "$here/usage.sh" ] && "$here/usage.sh" log --role "$role" --tier "$tier" --host "$host" --model "$model" --id "${span:-$xid}" --kind final \
  --in "${tin:-0}" --out "${tout:-0}" --cache-read "${cr:-0}" --cache-write "${cw:-0}" --tq "$tq" ${hcost:+--cost-est "$hcost"} --source run-role >/dev/null 2>&1
if [ "${USAGE_LINE:-}" = 1 ]; then   # the same one-line summary the Claude SubagentStop hook prints (hooks/usage-log.sh); stderr, so the answer stays clean
  if [ "$tq" = actual ]; then
    awk -v r="$role" -v i="${tin:-0}" -v o="${tout:-0}" -v cr="${cr:-0}" -v cw="${cw:-0}" -v h="$host" 'function k(n) { return n >= 1000 ? sprintf("%.1fk", n / 1000) : n }
      BEGIN { t = i + cr + cw; c = (h == "claude" || h ~ /^ext:/) && t > 0 ? sprintf("%d%%", cr * 100 / t) : "n/a"
        printf "[sdkit] %s done — in: %s, out: %s, cache hit: %s\n", r, k(t), k(o), c }' >&2
  else echo "[sdkit] $role done — token usage not available ($host gave no data)" >&2; fi
fi
erc=0; prc=""; rdur="$dur"
if [ -n "$evrun" ]; then
  pa=(); prop="$(jq -r '.proposal // empty' "$top/$KIT_DIR/.sdd/state.json" 2>/dev/null)"
  [ "$base" = verifier ] && [ -n "$prop" ] && [ -f "$top/$prop" ] && pa=(--proposal "$top/$prop")
  esum="$(printf '%s\n' "$answer" | CLAUDE_PROJECT_DIR="$top" "$here/parse-verdict.sh" - --role "$base" --record --source run-role --run "$evrun" ${pa[@]+"${pa[@]}"} 2>&1)"; prc=$?
  echo "run-role: $esum" >&2
  [ "$prc" = 2 ] && { case "$esum" in *"MALFORMED[semantic]"*) _mr=inconsistent ;; *) _mr=malformed ;; esac; tele failure --category verdict-malformed --reason "$_mr" --role "$role" --source run-role; }
  case "$prc" in 2|3) erc=6; CLAUDE_PROJECT_DIR="$top" "$here/sdd.sh" _spawn-close --run "$evrun" --reason unrecorded >/dev/null 2>&1 ;; esac
fi
if [ "$contracted" = 1 ]; then
  csum="$(printf '%s\n' "$answer" | "$here/contract.sh" check-result - --id "$cid" --role "$role" --cwd "$cwd" --record --source run-role 2>&1)"; crc=$?
  echo "run-role: $csum" >&2
  case "$crc" in 0) ;; 1) rr_close 5 "$prc"; exit 5 ;; *) rr_close 4 "$prc"; exit 4 ;; esac
fi
rr_close "$erc" "$prc"
exit "$erc"
