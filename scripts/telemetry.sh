#!/usr/bin/env bash
# Structured run events: one JSON line per event, so a task's execution (phases, agents, retries, failures, verification) can be measured
# instead of guessed. Off unless TELEMETRY=1 in sdkit.local.env (emit is then a silent no-op). Local files only, no service, no prompts.
# File: <project-dir>/work/<slug>/events.jsonl (personal, gitignored). Tokens are NOT a second ledger: agent.end carries the same numbers
# usage.sh logs, tagged with how they were obtained. Schema, metrics and limits: docs/design-telemetry.md.
#   telemetry.sh emit <type> [--task S] [--run ID] [--span ID] [--parent ID] [--phase P] [--from P] [--to P] [--role R] [--host H]
#                [--model M] [--tier T] [--dur-ms N] [--in N] [--out N] [--cache-read N] [--cache-write N] [--tool-calls N]
#                [--attempt N] [--bytes N] [--cv N] [--contract ID] [--stage handoff|result] [--status S] [--reason R] [--outcome O] [--category C] [--source X] [--risk R] [--profile P] [--note TEXT] [--q metric=actual|estimated|unavailable]
#                [--force] [--strict]
#       Never fails the caller: a problem (no jq, unwritable directory, invalid field) drops the event and exits 0. --strict exits 2 on an
#       invalid event instead (tests). A number that is missing is left out and marked unavailable, never written as 0.
#       types: task.start task.end phase.enter phase.reject agent.start agent.end retry test.result verify.result failure bench.mark contract.check workflow.decision
#       workflow.decision (F03): --source profile|contract-policy|transition, --outcome <the decision>, --profile small|standard|high-assurance, --reason R.
#       an event with --span replaces nothing: summary keeps the LAST agent.end per span (snapshots of a growing session)
#   telemetry.sh summary [slug] [--run ID] [--file F] [--json]   one run: status, phase and agent durations, tokens, cost, retries, failures, verification
#   telemetry.sh list                                             every task that has events (and archived ones), one line each
#   telemetry.sh validate [slug|--file F]                         check every line against the schema; exit 1 and list the bad lines
#   telemetry.sh archive [slug]                                   copy events, ledger and summary to work/_archive/ (work/<slug> is deleted at closeout)
#   telemetry.sh run-id [slug]                                    the current run id (made on first use; task.start starts a new run)
#   telemetry.sh now-ms                                           milliseconds since the epoch (whole seconds where date has no %N)
# Environment: SDKIT_RUN_ID overrides the run id; SDKIT_TELEMETRY_MODE=simulated marks events from fixtures (default live);
#   TELEMETRY_PRICES = JSON file of USD per million tokens per model id (default <project-dir>/pricing.json); no file, no cost.
set -u
cmd="${1:-}"; [ $# -gt 0 ] && shift

now_ms() {
  local t; t="$(date +%s%3N 2>/dev/null)"
  case "$t" in ''|*[!0-9]*) t="$(( $(date +%s) * 1000 ))" ;; esac
  echo "$t"
}
[ "$cmd" = now-ms ] && { now_ms; exit 0; }

# emit must never break the caller, whatever happens below
if [ "$cmd" = emit ]; then trap 'exit 0' ERR 2>/dev/null; else command -v jq >/dev/null || { echo "telemetry.sh needs jq" >&2; exit 1; }; fi
command -v jq >/dev/null || { [ "$cmd" = emit ] && exit 0; exit 1; }
top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
. "$(dirname "${BASH_SOURCE[0]}")/env.sh" 2>/dev/null || { [ "$cmd" = emit ] && exit 0; echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }
SDKIT_ENV_QUIET=1 sdkit_env_load "$top"
work="$top/$KIT_DIR/work"

# The schema, once: emit builds an event and runs errs on it, validate runs errs on every stored line.
SCHEMA='
def types: ["task.start","task.end","phase.enter","phase.reject","agent.start","agent.end","retry","test.result","verify.result","failure","bench.mark","contract.check","workflow.decision"];
def cats: ["budget","gate","tests","verdict-block","verdict-malformed","host-error","host-missing","timeout","contract","other"];
def reasons: ["no-result","malformed","unsupported-version","missing-field","bad-value","inconsistent","id-mismatch","role-mismatch","task-mismatch","unknown-id","duplicate","stale","unsafe-path","missing-artifact","out-of-scope","not-next","unknown-phase","no-artifact","no-dod","no-design","tests-pass","tests-fail","verify-failed","no-verdict","verdict-block","stale-verdict","risk-floor","profile-risk","agents-pending","retry-exhausted","out-of-phase","concurrent","no-evidence","evidence-block","stale-evidence","untrusted-evidence","role-conflict"];
def profiles: ["small","standard","high-assurance"];
def stages: ["handoff","result"];
def execs: ["done","partial","blocked","failed"];
def quals: ["actual","estimated","unavailable"];
def ints: ["dur_ms","in","out","cache_read","cache_write","tool_calls","attempt","bytes","cv"];
def need($k): if ((.[$k] // "") | tostring) == "" then "\(.type) needs \($k)" else empty end;
def errs:
  if type != "object" then ["not an object"] else
  [ (if .v != 1 then "v must be 1" else empty end),
    (if ((.ts // null) | type) != "string" or ((.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) | not) then "ts must be YYYY-MM-DDTHH:MM:SSZ" else empty end),
    (if (.type as $t | types | index($t)) == null then "unknown type" else empty end),
    (if ((.task // "") | type) != "string" or ((.task // "") | test("^[A-Za-z0-9_.-]+$") | not) then "task must be a slug" else empty end),
    (if ((.run // "") | type) != "string" or ((.run // "") == "") then "run is required" else empty end),
    (if ([.mode] | inside(["live","simulated"])) | not then "mode must be live or simulated" else empty end),
    (ints[] as $k | if has($k) and ((.[$k] | type) != "number" or .[$k] < 0 or (.[$k] | floor) != .[$k]) then "\($k) must be a non-negative integer" else empty end),
    ((.q // {}) | to_entries[] | if (.value as $v | quals | index($v)) == null then "q.\(.key) must be actual, estimated or unavailable" else empty end),
    (if has("category") and (.category as $c | cats | index($c)) == null then "unknown category" else empty end),
    (if .type == "agent.start" or .type == "agent.end" then need("role") else empty end),
    (if .type == "phase.enter" then need("to") else empty end),
    (if .type == "task.end" or .type == "verify.result" or .type == "test.result" then need("outcome") else empty end),
    (if .type == "failure" then need("category") else empty end),
    (if has("reason") and (.reason as $r | reasons | index($r)) == null then "unknown reason" else empty end),
    (if has("status") and (.status as $r | execs | index($r)) == null then "status must be done, partial, blocked or failed" else empty end),
    (if has("profile") and (.profile as $p | profiles | index($p)) == null then "unknown profile" else empty end),
    (if .type == "workflow.decision" then (need("source"), need("outcome")) else empty end),
    (if .type == "contract.check" then
       (need("outcome"), need("stage"), need("cv"),
        (if ([.outcome] | inside(["valid","invalid"])) | not then "contract.check outcome must be valid or invalid" else empty end),
        (if (.stage as $x | stages | index($x)) == null then "stage must be handoff or result" else empty end),
        (if .outcome == "invalid" then need("reason") else empty end))
     else empty end)
  ] end;'

run_id() {  # run_id <task>: SDKIT_RUN_ID, else the run in work/<task>/run.id (created on first use)
  [ -n "${SDKIT_RUN_ID:-}" ] && { printf '%s' "$SDKIT_RUN_ID"; return 0; }
  local f="$work/$1/run.id" id=""
  [ -s "$f" ] && { printf '%s' "$(<"$f")"; return 0; }
  sdkit_lock "$f"
  [ -s "$f" ] || { new_run_id > "$f"; }
  id="$(<"$f")"; sdkit_unlock "$f"; printf '%s' "$id"
}
new_run_id() { printf 'r%s-%s%s' "$(date -u +%Y%m%d%H%M%S)" "$$" "$RANDOM"; }

default_task() { local s; s="$(sdkit_active_slug "$top")"; echo "${s:-_misc}"; }

cmd_emit() {
  local type="${1:-}"; [ $# -gt 0 ] && shift
  local task="" run="" force=0 strict=0 mode="${SDKIT_TELEMETRY_MODE:-live}" note="" newrun=0
  local args=() quals=() have_tok=0 k
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) task="$2"; shift ;; --run) run="$2"; shift ;; --force) force=1 ;; --strict) strict=1 ;; --note) note="$2"; shift ;;
      --span|--parent|--phase|--from|--to|--role|--host|--model|--tier|--outcome|--category|--source|--risk|--contract|--stage|--reason|--status|--profile)
        k="${1#--}"; args+=("s:$k" "${2:-}"); shift ;;
      --dur-ms|--in|--out|--cache-read|--cache-write|--tool-calls|--attempt|--bytes|--cv)
        k="${1#--}"; k="${k//-/_}"; case "$k" in in|out|cache_read|cache_write) have_tok=1 ;; esac
        args+=("n:$k" "${2:-}"); shift ;;
      --q) args+=("q:${2%%=*}" "${2#*=}"); shift ;;
      *) [ "$strict" = 1 ] && { echo "telemetry emit: unknown option $1" >&2; exit 2; } ;;
    esac
    shift
  done
  [ "${TELEMETRY:-}" = 1 ] || [ "$force" = 1 ] || exit 0
  [ -n "$type" ] || exit 0
  [ -n "$task" ] || task="$(default_task)"
  case "$task" in ''|*[!A-Za-z0-9_.-]*) [ "$strict" = 1 ] && { echo "telemetry emit: bad task slug" >&2; exit 2; }; exit 0 ;; esac
  [ -d "$work/$task" ] || mkdir -p "$work/$task" 2>/dev/null || exit 0
  if [ "$type" = task.start ] && [ -z "${SDKIT_RUN_ID:-}" ] && [ -z "$run" ]; then
    run="$(new_run_id)"; { sdkit_lock "$work/$task/run.id"; printf '%s' "$run" > "$work/$task/run.id"; sdkit_unlock "$work/$task/run.id"; } 2>/dev/null
  fi
  [ -n "$run" ] || run="$(run_id "$task")"
  [ -z "$note" ] || note="$(printf '%s' "$note" | tr '\n\r\t' '   ' | cut -c1-160)"
  # drop numbers that are not numbers (a missing value is "unavailable", never 0)
  local clean=() i=0 n=${#args[@]} key val
  while [ "$i" -lt "$n" ]; do
    key="${args[$i]}"; val="${args[$((i + 1))]}"; i=$((i + 2))
    case "$key" in
      n:*) case "$val" in ''|*[!0-9]*) [ "$strict" = 1 ] && { echo "telemetry emit: ${key#n:} is not a non-negative integer" >&2; exit 2; }; continue ;; esac ;;
      s:*|q:*) [ -n "$val" ] || continue ;;
    esac
    clean+=("$key" "$val")
  done
  local line errf=/dev/null; [ "$strict" = 1 ] && errf="${TMPDIR:-/tmp}/.sdkit-telemetry.err.$$"
  line="$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg type "$type" --arg task "$task" --arg run "$run" --arg mode "$mode" --arg note "$note" \
    "$SCHEMA"'
    $ARGS.positional as $a | [range(0; $a | length; 2) as $i | [$a[$i], $a[$i + 1]]] as $p
    | ({v:1, ts:$ts, type:$type, task:$task, run:$run, mode:$mode} + (if $note != "" then {note:$note} else {} end)) as $base
    | reduce $p[] as [$k,$v] ($base;
        if ($k|startswith("n:")) then .[$k[2:]] = ($v|tonumber)
        elif ($k|startswith("q:")) then .q[$k[2:]] = $v
        else .[$k[2:]] = ($v[:120]) end)
    # a number that is not there is unavailable, whatever the caller claimed
    | if .type == "agent.end" and ((has("in") or has("out")) | not) then .q.tokens = "unavailable" else . end
    | if .type == "agent.end" and (has("dur_ms") | not) then .q.duration = "unavailable" else . end
    | if (errs | length) > 0 then error(errs | join("; ")) else . end' --args "${clean[@]+"${clean[@]}"}" 2>"$errf")" || {
      [ "$strict" = 1 ] && { cat "$errf" >&2; rm -f "$errf"; exit 2; }
      exit 0; }
  [ "$strict" = 1 ] && rm -f "$errf"
  # O_APPEND writes of one short line do not interleave: concurrent agents need no lock here
  printf '%s\n' "$line" >> "$work/$task/events.jsonl" 2>/dev/null
  exit 0
}

events_file() {  # events_file <slug|""> -> path (default: the open task, else the newest events.jsonl)
  local s="${1:-}" f
  if [ -n "$s" ]; then echo "$work/$s/events.jsonl"; return; fi
  s="$(sdkit_active_slug "$top")"
  [ -n "$s" ] && [ -f "$work/$s/events.jsonl" ] && { echo "$work/$s/events.jsonl"; return; }
  f="$(ls -t "$work"/*/events.jsonl 2>/dev/null | head -1)"; echo "${f:-$work/${s:-_misc}/events.jsonl}"
}
ledger_for() {  # the usage ledger next to an events file, if any
  local d; d="$(dirname "$1")"; [ -f "$d/usage.jsonl" ] && echo "$d/usage.jsonl"
  [ -f "${1%.events.jsonl}.usage.jsonl" ] && [ "${1%.events.jsonl}" != "$1" ] && echo "${1%.events.jsonl}.usage.jsonl"
  return 0
}

# summary_json <events file> <run id|""> <ledger file|""> <prices file|"">
summary_json() {
  local ev="$1" run="$2" led="$3" prices="$4" pj='{}' lj='[]'
  [ -f "$prices" ] && pj="$(sdkit_prices_flat "$prices")"
  [ -n "$led" ] && [ -f "$led" ] && lj="$(jq -sc . "$led" 2>/dev/null || echo '[]')"
  jq -sc --arg run "$run" --argjson prices "$pj" --argjson ledger "$lj" '
    def secs($a; $b): (($b | fromdateiso8601) - ($a | fromdateiso8601));
    def tally($rows): {in:($rows|map(.in // 0)|add // 0), out:($rows|map(.out // 0)|add // 0), cache_read:($rows|map(.cache_read // 0)|add // 0), cache_write:($rows|map(.cache_write // 0)|add // 0)};
    # lines that are not valid events are ignored here (telemetry.sh validate reports them)
    map(select(type == "object" and (.ts // null) != null and (.type // null) != null)) as $all
    | (if $run != "" then $run else ($all | map(select(.type == "task.start")) | last // ($all | last) | .run // "") end) as $r
    | ($all | map(select(.run == $r))) as $e
    | if ($e | length) == 0 then {error: "no events for this run"} else
      ($e | map(select(.type == "task.start")) | first) as $ts
      | ($e | map(select(.type == "task.end")) | last) as $te
      | ($e | map(select(.type == "agent.end")) | (map(select(.span != null)) | group_by(.span) | map(last)) + map(select(.span == null))) as $ag
      | ($e | map(select(.type == "agent.start") | .span) | unique) as $started
      | ($ag | map(select((.q.tokens // "") == "actual" or (.q.tokens // "") == "estimated"))) as $tk
      | ($e | map(select(.type == "phase.enter"))) as $ph
      | ([$ts // empty | {phase: (.phase // "intake"), at: .ts}] + ($ph | map({phase: .to, at: .ts}))) as $marks
      | ($e | last | .ts) as $lastts
      | (($te | .ts) // $lastts) as $endts
      | ($tk | map(select(.model != null and ($prices[.model] != null)))) as $priced
      | {
        task: ($e[0].task), run: $r,
        mode: ($e | map(.mode // "live") | unique | if length == 1 then .[0] else "mixed" end),
        risk: ($ts.risk // null),
        status: (if $te then ($te.outcome) else "in-progress" end),
        verified: ($ph | map(.to) | index("verified") != null),
        started: (($ts // $e[0]) | .ts), ended: ($te.ts // null),
        wall_s: secs((($ts // $e[0]) | .ts); $endts),
        phases: [range(0; $marks | length) as $i | $marks[$i] as $m
                 | {phase: $m.phase, at: $m.at,
                    dur_s: (if $i + 1 < ($marks | length) then secs($m.at; $marks[$i + 1].at) elif $te and $m.phase != "done" then secs($m.at; $te.ts) else null end)}],
        agents: {
          spawned: (($ag | map(.span // empty) + $started | unique | length) + ($ag | map(select(.span == null)) | length)),
          finished: ($ag | length),
          by_role: ($ag | group_by(.role) | map({role: .[0].role, runs: length,
                    dur_s: ((map(select(.dur_ms != null) | .dur_ms) | add // null) | if . == null then null else . / 1000 end),
                    runs_without_duration: (map(select(.dur_ms == null)) | length),
                    tool_calls: (map(select(.tool_calls != null) | .tool_calls) | add // null)} + tally(map(select((.q.tokens // "") != "unavailable" and (.q.tokens // "") != "")))
                    + {runs_without_tokens: (map(select((.q.tokens // "unavailable") == "unavailable")) | length)}))
        },
        tokens: (tally($tk) + {runs_measured: ($tk | length), runs_unmeasured: (($ag | length) - ($tk | length)),
                 quality: ($tk | map(.q.tokens) | unique | if length == 0 then "unavailable" elif length == 1 then .[0] else "mixed" end),
                 complete: (($ag | length) > 0 and ($tk | length) == ($ag | length))}),
        cost: (if ($prices | length) == 0 then {usd: null, quality: "unavailable", reason: "no pricing.json or TELEMETRY_PRICES"}
               else {usd: ($priced | map(. as $x | $prices[$x.model] | (($x.in // 0) * (.in // 0) + ($x.out // 0) * (.out // 0) + ($x.cache_read // 0) * (.cache_read // 0) + ($x.cache_write // 0) * (.cache_write // 0)) / 1000000) | add // 0),
                    quality: "estimated", unpriced_runs: (($tk | length) - ($priced | length)), note: "user-supplied USD per million tokens"} end),
        retries: ($e | map(select(.type == "retry")) | length),
        efficiency: ($e | map(select(.type == "failure" and .category == "verdict-malformed")) as $vm
                     | ($e | map(select(.type == "verify.result" and (.outcome == "block" or .outcome == "BLOCK"))) | length) as $blk
                     | {agent_executions: ($ag | length),
                        format_retries: ($vm | map(select((.reason // "malformed") != "inconsistent")) | length),
                        semantic_retries: ($vm | map(select(.reason == "inconsistent")) | length),
                        block_reasons: ($e | map(select(.type == "failure" and (.category == "verdict-block" or .category == "gate" or .category == "tests")) | (.category + ":" + (.reason // "unspecified"))) | group_by(.) | map({key: .[0], value: length}) | from_entries),
                        blocks: $blk,
                        accepted: ($ph | map(.to) | index("verified") != null),
                        cost_per_accepted_task_usd: (if ($ph | map(.to) | index("verified")) != null and ($prices | length) > 0 and ($tk | length) > 0
                          then ($priced | map(. as $x | $prices[$x.model] | (($x.in // 0) * (.in // 0) + ($x.out // 0) * (.out // 0) + ($x.cache_read // 0) * (.cache_read // 0) + ($x.cache_write // 0) * (.cache_write // 0)) / 1000000) | add // 0) else null end),
                        cost_complete: (($ag | length) > 0 and ($tk | length) == ($ag | length) and ($priced | length) == ($tk | length))}),
        failures: {total: ($e | map(select(.type == "failure")) | length),
                   by_category: ($e | map(select(.type == "failure") | .category) | group_by(.) | map({key: .[0], value: length}) | from_entries),
                   gate_rejections: ($e | map(select(.type == "phase.reject")) | length)},
        tests: ($e | map(select(.type == "test.result")) | map({phase: (.phase // "-"), outcome}) | group_by([.phase, .outcome]) | map({phase: .[0].phase, outcome: .[0].outcome, runs: length})),
        verification: {results: ($e | map(select(.type == "verify.result") | {outcome, source: (.source // null), role: (.role // null)})),
                       final: ($e | map(select(.type == "verify.result")) | last | .outcome // null)},
        ledger: (if ($ledger | length) > 0 then (($ledger | map(select((.id // "") != "")) | group_by(.id) | map(last)) + ($ledger | map(select((.id // "") == "")))) as $l | tally($l) + {rows: ($l | length), source: "usage.jsonl"} else null end),
        contracts: ($e | map(select(.type == "contract.check")) as $c
                    | {checked: ($c | length), valid: ($c | map(select(.outcome == "valid")) | length), invalid: ($c | map(select(.outcome == "invalid")) | length),
                       handoffs: ($c | map(select(.stage == "handoff")) | length), results: ($c | map(select(.stage == "result")) | length),
                       by_reason: ($c | map(select(.outcome == "invalid") | .reason) | group_by(.) | map({key: .[0], value: length}) | from_entries),
                       by_status: ($c | map(select(.outcome == "valid" and .stage == "result") | .status) | group_by(.) | map({key: .[0], value: length}) | from_entries),
                       handoff_bytes: ($c | map(select(.stage == "handoff") | .bytes // 0) | add // 0), result_bytes: ($c | map(select(.stage == "result") | .bytes // 0) | add // 0),
                       versions: ($c | map(.cv) | unique)}),
        workflow: {profile: ($ts.profile // null),
                   decisions: ($e | map(select(.type == "workflow.decision")) | map({source, outcome, reason: (.reason // null)})),
                   rejections_by_reason: ($e | map(select(.type == "phase.reject") | (.reason // "unspecified")) | group_by(.) | map({key: .[0], value: length}) | from_entries)},
        events: ($e | length)
      } end' "$ev"
}

render() {  # render a summary JSON (stdin) as text
  jq -r '
    def n: if . == null then "-" else tostring end;
    def dur: if . == null then "-" else (. | floor | tostring) + "s" end;
    def pad($w): tostring | . + (" " * ([$w - length, 0] | max));
    if .error then "telemetry: \(.error)" else
    "task \(.task)   run \(.run)   mode \(.mode)   risk \(.risk | n)",
    "status \(.status)   verified \(.verified)   wall \(.wall_s | dur)   events \(.events)",
    "",
    "phases",
    (.phases[] | "  \(.phase | pad(12))\(.dur_s | dur)"),
    "",
    "agents: \(.agents.spawned) spawned, \(.agents.finished) finished",
    (if (.agents.by_role | length) > 0 then
      "  \("role" | pad(18))\("runs" | pad(6))\("time" | pad(8))\("tools" | pad(7))\("in" | pad(10))\("out" | pad(10))\("cache_read" | pad(12))\("cache_write" | pad(12))no-tokens",
      (.agents.by_role[] | "  \(.role | pad(18))\(.runs | pad(6))\(.dur_s | dur | pad(8))\(.tool_calls | n | pad(7))\(.in | pad(10))\(.out | pad(10))\(.cache_read | pad(12))\(.cache_write | pad(12))\(.runs_without_tokens)") else empty end),
    "",
    "tokens (\(.tokens.quality)): in \(.tokens.in)  out \(.tokens.out)  cache_read \(.tokens.cache_read)  cache_write \(.tokens.cache_write)   measured \(.tokens.runs_measured) of \(.tokens.runs_measured + .tokens.runs_unmeasured) runs\(if .tokens.complete then "" else "  (INCOMPLETE: unmeasured runs are not counted)" end)",
    (if .cost.usd == null then "cost: unavailable (\(.cost.reason))" else "cost (estimated): $\(.cost.usd * 10000 | round / 10000)  unpriced runs \(.cost.unpriced_runs)" end),
    "efficiency: executions \(.efficiency.agent_executions)   format retries \(.efficiency.format_retries)   semantic retries \(.efficiency.semantic_retries)   blocks \(.efficiency.blocks)   accepted \(.efficiency.accepted)   cost/accepted \(if .efficiency.cost_per_accepted_task_usd == null then "unavailable" else "$\(.efficiency.cost_per_accepted_task_usd * 10000 | round / 10000)\(if .efficiency.cost_complete then "" else " (PARTIAL: unmeasured or unpriced runs)" end)" end)",
    "retries \(.retries)   failures \(.failures.total) \(.failures.by_category | to_entries | map("\(.key)=\(.value)") | join(" "))   gate rejections \(.failures.gate_rejections)",
    (if .workflow.profile != null then "workflow: profile \(.workflow.profile)   decisions \(.workflow.decisions | length)   rejections \(.workflow.rejections_by_reason | to_entries | map("\(.key)=\(.value)") | join(" "))" else empty end),
    (if .contracts.checked > 0 then "contracts: \(.contracts.checked) checked, \(.contracts.valid) valid, \(.contracts.invalid) invalid \(.contracts.by_reason | to_entries | map("\(.key)=\(.value)") | join(" "))   agent status \(.contracts.by_status | to_entries | map("\(.key)=\(.value)") | join(" "))   handoff bytes \(.contracts.handoff_bytes)  result bytes \(.contracts.result_bytes)   (a valid contract is not a verification)" else empty end),
    "tests: \(if (.tests | length) == 0 then "none recorded" else (.tests | map("\(.phase) \(.outcome) x\(.runs)") | join(", ")) end)",
    "verification: \(if (.verification.results | length) == 0 then "none recorded" else (.verification.results | map(.outcome) | join(" -> ")) end)   final \(.verification.final | n)",
    (if .ledger then "usage ledger (cross-check): in \(.ledger.in)  out \(.ledger.out)  cache_read \(.ledger.cache_read)  cache_write \(.ledger.cache_write)  rows \(.ledger.rows)" else empty end)
    end'
}

case "$cmd" in
  emit) cmd_emit "$@" ;;
  run-id) s="${1:-}"; [ -n "$s" ] || s="$(default_task)"; run_id "$s"; echo ;;
  summary)
    slug=""; run=""; file=""; json=0
    while [ $# -gt 0 ]; do
      case "$1" in --run) run="$2"; shift ;; --file) file="$2"; shift ;; --json) json=1 ;; -*) echo "unknown option $1" >&2; exit 2 ;; *) slug="$1" ;; esac
      shift
    done
    [ -n "$file" ] || file="$(events_file "$slug")"
    [ -s "$file" ] || { echo "no events recorded for ${slug:-the current task} (set TELEMETRY=1 in sdkit.local.env)"; exit 0; }
    prices="${TELEMETRY_PRICES:-$top/$KIT_DIR/pricing.json}"
    out="$(summary_json "$file" "$run" "$(ledger_for "$file")" "$prices")" || { echo "telemetry: cannot read $file" >&2; exit 1; }
    if [ "$json" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | render; fi ;;
  trace)
    # F17: one task's story, chronological, joined by ids: task -> phase -> role/execution (span) -> usage-ledger request row -> routing decision -> gate result.
    # Identifiers, roles, numbers, outcomes and reason codes only. Notes, prompts, answers and file paths are never printed (a failed task is explained
    # without exposing source or transcripts). --json: the same rows as JSON for an external viewer; nothing is sent anywhere.
    slug=""; run=""; file=""; json=0
    while [ $# -gt 0 ]; do case "$1" in --run) run="$2"; shift ;; --file) file="$2"; shift ;; --json) json=1 ;; -*) echo "unknown option $1" >&2; exit 2 ;; *) slug="$1" ;; esac; shift; done
    [ -n "$file" ] || file="$(events_file "$slug")"
    [ -s "$file" ] || { echo "no events recorded for ${slug:-the current task} (set TELEMETRY=1 in sdkit.local.env)"; exit 0; }
    led="$(ledger_for "$file")"; ljson='[]'; [ -n "$led" ] && [ -f "$led" ] && ljson="$(jq -sc . "$led" 2>/dev/null || echo '[]')"
    rj='[]'; rf="$(dirname "$file")/routing.jsonl"; [ -f "$rf" ] && rj="$(jq -sc . "$rf" 2>/dev/null || echo '[]')"
    rows="$(jq -sc --arg run "$run" --argjson led "$ljson" --argjson rt "$rj" '
      map(select(type == "object" and .ts != null and .type != null)) as $all
      | (if $run != "" then $run else ($all | map(select(.type == "task.start")) | last // ($all | last) | .run // "") end) as $r
      | ($all | map(select(.run == $r))) as $e
      | [ $e[] | {ts, kind: .type, phase: (.phase // .to // null), role: (.role // null), span: (.span // null), tier: (.tier // null), host: (.host // null), model: (.model // null),
          outcome: (.outcome // null), category: (.category // null), reason: (.reason // null), status: (.status // null), attempt: (.attempt // null),
          dur_ms: (.dur_ms // null), tokens: (if .in != null then {in, out, cache_read, cache_write, quality: (.q.tokens // null)} else null end)} ]
      | map(. as $x | if $x.span != null and $x.kind == "agent.end" then . + {ledger_row: (($led | map(select(.id == $x.span)) | last) as $l | if $l == null then null else {in: $l.in, out: $l.out, cache_read: $l.cache_read, cache_write: $l.cache_write, tq: ($l.tq // "actual"), model: $l.model} end)} else . end)
      | . + ($rt | map({ts, kind: ("route." + .type), role, decision: .id, action: (.action // null), reason: (.reason // null), outcome: (.class // null), attempt: (.attempt // null), tier: (.tier // null), host: (.adapter // null), model: (.model // null)}))
      | sort_by(.ts)' "$file" 2>/dev/null)" || { echo "telemetry: cannot read $file" >&2; exit 1; }
    if [ "$json" = 1 ]; then printf '%s\n' "$rows" | jq .; else
      printf '%s\n' "$rows" | jq -r '
        def d: if . == null then "" else " " + tostring end;
        .[] | "\(.ts | sub("T"; " ") | sub("Z"; "")) \(.kind | (. + "              ")[0:18])"
          + (if .phase then " phase=\(.phase)" else "" end) + (if .role then " role=\(.role)" else "" end) + (if .span then " span=\(.span)" else "" end)
          + (if .decision then " decision=\(.decision)" else "" end) + (if .action then " action=\(.action)" else "" end)
          + (if .host then " host=\(.host)" else "" end) + (if .model then " model=\(.model)" else "" end) + (if .tier then " tier=\(.tier)" else "" end)
          + (if .attempt then " attempt=\(.attempt)" else "" end) + (if .dur_ms then " dur=\(.dur_ms / 1000 | floor)s" else "" end)
          + (if .tokens then " tokens(in/out/cr/cw)=\(.tokens.in // "-")/\(.tokens.out // "-")/\(.tokens.cache_read // "-")/\(.tokens.cache_write // "-")" else "" end)
          + (if .ledger_row then " ledger(\(.ledger_row.tq))=\(.ledger_row.in)/\(.ledger_row.out)" else "" end)
          + (if .outcome then " outcome=\(.outcome)" else "" end) + (if .category then " category=\(.category)" else "" end) + (if .reason then " reason=\(.reason)" else "" end)'
      echo "--"
      printf '%s\n' "$rows" | jq -r '
        ([.[] | select(.kind == "failure" or .kind == "phase.reject" or (.kind == "verify.result" and (.outcome | tostring | test("block|BLOCK|malformed"))))] | last) as $f
        | if $f == null then "explain: no failure, rejection or BLOCK recorded in this run"
          else "explain: last problem = \($f.kind) at \($f.ts)\($f.category | if . then " category=" + . else "" end)\($f.reason | if . then " reason=" + . else "" end)\($f.outcome | if . then " outcome=" + . else "" end)\($f.role | if . then " role=" + . else "" end)" end'
    fi ;;
  list)
    shopt -s nullglob
    printf 'task\trun\tstatus\tmode\tagents\ttokens(in+out)\tsource\n'
    for f in "$work"/*/events.jsonl "$work"/_archive/*.events.jsonl; do
      [ -s "$f" ] || continue
      src=work; case "$f" in */_archive/*) src=archive ;; esac
      summary_json "$f" "" "" "" | jq -r --arg src "$src" 'if .error then empty else "\(.task)\t\(.run)\t\(.status)\t\(.mode)\t\(.agents.finished)\t\(.tokens.in + .tokens.out)\t\($src)" end'
    done | column -t -s "$(printf '\t')" ;;
  validate)
    file=""; slug=""
    while [ $# -gt 0 ]; do case "$1" in --file) file="$2"; shift ;; *) slug="$1" ;; esac; shift; done
    [ -n "$file" ] || file="$(events_file "$slug")"
    [ -f "$file" ] || { echo "no events file: $file" >&2; exit 1; }
    bad="$(jq -Rr "$SCHEMA"'
      . as $l | (try fromjson catch null) as $o
      | if $o == null then "line \(input_line_number): not JSON" else ($o | errs | if length > 0 then "line \(input_line_number): " + join("; ") else empty end) end' "$file")"
    if [ -n "$bad" ]; then printf '%s\n' "$bad"; exit 1; fi
    echo "ok: $(grep -c . "$file") events valid" ;;
  archive)
    s="${1:-}"; [ -n "$s" ] || s="$(default_task)"
    [ -s "$work/$s/events.jsonl" ] || { echo "nothing to archive for $s"; exit 0; }
    mkdir -p "$work/_archive" && run="$(run_id "$s")" || exit 0
    cp "$work/$s/events.jsonl" "$work/_archive/$s.events.jsonl"
    [ -f "$work/$s/usage.jsonl" ] && cp "$work/$s/usage.jsonl" "$work/_archive/$s.usage.jsonl"
    for x in routing context selection; do [ -f "$work/$s/$x.jsonl" ] && cp "$work/$s/$x.jsonl" "$work/_archive/$s.$x.jsonl"; done   # the Value Report can be rebuilt from the archive
    summary_json "$work/$s/events.jsonl" "" "$work/$s/usage.jsonl" "${TELEMETRY_PRICES:-$top/$KIT_DIR/pricing.json}" > "$work/_archive/$s.summary.json"
    echo "archived to $KIT_DIR/work/_archive/$s.{events.jsonl,summary.json}" ;;
  *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
