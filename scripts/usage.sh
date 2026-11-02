#!/usr/bin/env bash
# Token ledger: one JSON line per agent run (and model), so usage and cost can be measured instead of guessed. Off unless USAGE_LOG=1 in sdkit.env
# (log is then a silent no-op). File: <project-dir>/work/<slug>/usage.jsonl (personal, gitignored).
#   usage.sh log --role R [--tier T] [--host H] [--model M] [--provider P] [--in N] [--out N] [--cache-read N] [--cache-write N]
#                [--slug S] [--id ID] [--session SID] [--origin sdk|observed] [--kind snapshot|final] [--status S] [--source X]
#                [--tq actual|unavailable] [--cost-est USD] [--force]
#       --in is the input WITHOUT cache; cache reads and cache writes are separate fields (never folded into --in).
#       --id is the stable execution id. A line replaces an earlier line with the same id AND model (snapshots of a growing session), unless
#       that would lose data: a snapshot never replaces a final line and a smaller total never replaces a larger one (counters only grow).
#       --origin sdk (default) = recorded by the kit (hook, run-role); observed = read afterwards from a host transcript by `scan`.
#       --kind final = the execution has ended; snapshot (default) = a cumulative reading of a run that may still grow.
#       --status interrupted = the run did not finish normally (with --tq unavailable when its usage is unknown).
#       --cost-est USD is the HOST'S OWN client-side cost estimate for that run (Claude Code's total_cost_usd), stored as cost_est_usd with cost_src "host-estimate".
#       It is not a billed amount and not the kit's price-table estimate (pricing.json); the three are kept apart. Never written when the host did not print it.
#       --tq unavailable marks a run whose host printed no token usage: its in/out/cache fields are 0 only because nothing was read, not because nothing was used
#       (route.sh counts such runs as unmeasured, never as zero)
#       --force logs even when USAGE_LOG is not 1
#   usage.sh report [slug] [--project] [--session ID|current] [--as-model MODEL] [--json]
#                               --as-model (json rows only): also price every run as if it had run on MODEL (rows[].as_cost_usd, same resolver; the
#                               Value Report's routing counterfactual). Nothing is stored.
#                               usage per role, model and session, cache effectiveness, estimated cost and coverage warnings. Default scope: the
#                               given slug, else every open task. --project adds archived tasks (work/_archive). --session narrows to one session.
#                               Cost is API-EQUIVALENT (tokens x your pricing.json), never a bill, and the total says PARTIAL whenever a run is unpriced
#                               or unmeasured. Nothing is stored: re-running after a pricing change recalculates.
#   usage.sh prices [--json]    which price table is in force, its source, and what it covers
#   usage.sh scan [--session ID | --since YYYY-MM-DD] [--dir DIR] [--slug S]
#                               Claude Code only: read the session transcript(s) and their subagent transcripts and log them as origin "observed"
#                               (same ids as the hooks, so nothing is counted twice). Default: the most recent session.
#   usage.sh context [transcript] [--top N] [--json]
#                               Claude Code only: where a session's context came from. Tool results by tool (calls, ~tokens = chars/4, share) and the
#                               N largest single results, with "re-read" = tokens x the turns that came after the result (what it cost to carry it).
#                               Default transcript: the most recent session of this project. No prompts or file contents are printed, only a short
#                               label (command or path) per result. Use it to decide what to cap (capped.sh) or delegate.
#   usage.sh extract <transcript> [--since TS]   one JSON object with the token totals of a transcript (the hooks use this; one parser, one rule);
#                               --since counts only requests from TS on (a session serving several tasks is charged to each task from its start)
#   usage.sh reconcile [--slug S]   fill in subagent runs logged as unmeasured (transcript not yet written at SubagentStop) from the transcripts now on disk
#   usage.sh window             start of the open task (ISO UTC) or nothing: the --since value the hooks pass for the orchestrator
#   usage.sh budget [slug]      used vs TOKEN_BUDGET_TASK (in + out + cache-write; cache reads are cheap and left out).
#                               Exit 0 under TOKEN_BUDGET_WARN_PCT (default 70), 3 from there, 4 at 100%. Silent exit 0 when no budget or no data.
# Slug default: the task the phase machine has open (sdd.sh task), else the most recently updated work/<slug>/state.json, else "_misc".
set -u
command -v jq >/dev/null || { echo "usage.sh needs jq" >&2; exit 1; }
top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"   # the hooks set it: no git process per call
. "$(dirname "${BASH_SOURCE[0]}")/env.sh" || { echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }; sdkit_env_load "$top"
work="$top/$KIT_DIR/work"

current_slug() {  # the open SDD task, else the most recently updated work/*/state.json, else _misc
  local s; s="$(sdkit_active_slug "$top")"
  echo "${s:-_misc}"
}

# extract_json <transcript> [since]: totals of one Claude Code transcript, as one JSON object. With <since> (ISO UTC, e.g. the start of the open task)
# only requests made at or after it count: one session often serves several tasks and its transcript is cumulative, so without a window every task
# would be charged for the whole session. A request without a timestamp is kept (it cannot be placed).
#  - a streamed assistant message appears several times with a growing output_tokens: each field is the MAX over the repeats, never the first
#  - records are keyed by requestId (one API request = one usage, however many records carry it), else message id
#  - a record without either is keyed by its uuid (else its position), so unrelated messages are never merged into one
#  - synthetic messages (model "<synthetic>", no real call) count nothing
#  - usage is split by model: a session that switches model is priced per model, not at the last one's rate
#  - input_tokens is already WITHOUT cache; cache_read_input_tokens and cache_creation_input_tokens are separate
extract_json() {
  jq -cs --arg since "${2:-}" '
    def n: (. // 0);
    def norm_ts: if type == "string" then sub("\\.[0-9]+"; "") else . end;
    ( [ to_entries[] | .key as $i | .value | select(type == "object" and .type == "assistant" and ((.message.usage // null) | type) == "object")
        | {k: ((.requestId // .message.id // .uuid) // "line\($i)"), model: (.message.model // ""), u: .message.usage, ts: (.timestamp // null)} ]
      | map(select(.model != "<synthetic>"))
      | map(select($since == "" or .ts == null or (.ts | norm_ts) >= $since))
      | group_by(.k)
      | map({model: (map(.model | select(. != "")) | last // ""),
             in: (map(.u.input_tokens | n) | max), out: (map(.u.output_tokens | n) | max),
             cache_read: (map(.u.cache_read_input_tokens | n) | max), cache_write: (map(.u.cache_creation_input_tokens | n) | max)}) ) as $msgs
    | ([ .[] | select(type == "object") | .timestamp? // empty | select(type == "string") ] | sort) as $ts
    | ([ .[] | select(type == "object") | .sessionId? // empty ] | first // "") as $sid
    | ([ .[] | select(type == "object" and .type == "assistant") | .message.id // empty ] | first // "" | if startswith("msg_bdrk_") then "bedrock" elif startswith("msg_vrtx_") then "vertex" elif startswith("msg_") then "anthropic" else "" end) as $prov
    | {messages: ($msgs | length), session: $sid, provider: $prov, first_ts: ($ts | first // null), last_ts: ($ts | last // null),
       in: ($msgs | map(.in) | add // 0), out: ($msgs | map(.out) | add // 0),
       cache_read: ($msgs | map(.cache_read) | add // 0), cache_write: ($msgs | map(.cache_write) | add // 0),
       model: ($msgs | map(.model | select(. != "")) | last // ""),
       by_model: ($msgs | group_by(.model) | map({model: .[0].model, in: (map(.in) | add), out: (map(.out) | add), cache_read: (map(.cache_read) | add), cache_write: (map(.cache_write) | add)}))}' "$1" 2>/dev/null
}

# log_line <json line> <file>: add one ledger line under the lock, replacing the same (id, model) only when that loses nothing
log_line() {
  local line="$1" file="$2" id mdl ntq ex exj
  # one jq for the three fields (a separator that is not whitespace, so an empty model survives `read`)
  IFS=$'\x1f' read -r id mdl ntq <<< "$(jq -r '[(.id // ""), (.model // ""), (.tq // "actual")] | join("\u001f")' <<< "$line")"
  sdkit_lock "$file"
  if [ -n "$id" ] && [ -f "$file" ]; then
    exj="$(jq -Rc --arg id "$id" --arg m "$mdl" '(try fromjson catch null) | select(type == "object" and .id == $id and (.model // "") == $m)' "$file" | tail -1)"
    if [ -n "$exj" ] && [ "$(jq -r '.tq // "actual"' <<< "$exj")" != unavailable ]; then
      # an earlier reading with real numbers exists. Counters only grow and a final line ends the run:
      #  - a snapshot never replaces a final line or a larger reading, and an unmeasured mark never replaces a measurement
      #  - a FINAL line with smaller counters is still the end of the run: it is promoted, keeping the larger counter of each kind (the report and the budget then agree)
      ex="$(jq -r '"\(.kind // "snapshot") \((.in // 0) + (.out // 0) + (.cache_read // 0) + (.cache_write // 0))"' <<< "$exj")"; set -- $ex
      local nk nt; IFS=' ' read -r nk nt <<< "$(jq -r '"\(.kind) \(.in + .out + .cache_read + .cache_write)"' <<< "$line")"
      if [ "$ntq" = unavailable ] || { [ "$nk" != final ] && { [ "$1" = final ] || [ "$nt" -lt "$2" ]; }; }; then sdkit_unlock "$file"; return 0; fi
      # counters only grow: whatever replaces the earlier reading keeps the larger value of each counter (a final may read lower on one kind than a snapshot did)
      line="$(jq -nc --argjson n "$line" --argjson e "$exj" '$n + {in: ([$n.in, ($e.in // 0)] | max), out: ([$n.out, ($e.out // 0)] | max), cache_read: ([$n.cache_read, ($e.cache_read // 0)] | max), cache_write: ([$n.cache_write, ($e.cache_write // 0)] | max)}')"
    fi
    # drop what the new line replaces: the same (id, model); and an empty-model "unavailable" placeholder once the same execution has a measured line
    # (an unmeasured placeholder must not be added when a measured line for that id already exists)
    if [ "$ntq" = unavailable ] && [ -z "$mdl" ] && jq -Re --arg id "$id" '(try fromjson catch null) | select(type == "object" and .id == $id and (.tq // "actual") != "unavailable")' "$file" >/dev/null 2>&1; then
      sdkit_unlock "$file"; return 0; fi
    jq -Rr --arg id "$id" --arg m "$mdl" --arg tq "$ntq" '(try fromjson catch null) as $o
      | if $o != null and ($o | type) == "object" and $o.id == $id and (($o.model // "") == $m or ($tq != "unavailable" and ($o.model // "") == "" and ($o.tq // "actual") == "unavailable")) then empty else . end' "$file" > "$file.tmp.$$" || true
    mv "$file.tmp.$$" "$file"
  fi
  printf '%s\n' "$line" >> "$file"
  sdkit_unlock "$file"
}

# The report, in two jq programs: USAGE_JQ turns ledger lines into one JSON result (reconcile, price, aggregate, warn); USAGE_TXT renders it.
# Everything is computed at read time from tokens and the price table in force, so a pricing change recalculates the whole history.
USAGE_JQ='
def n: (. // 0);
def norm: . + {in: (.in | n), out: (.out | n), cache_read: (.cache_read | n), cache_write: (.cache_write | n), role: (.role // "?"),
               tier: ((.tier // "") | if . == "" then "-" else . end), model: (.model // ""), provider: (.provider // ""), session: (.session // ""),
               origin: (.origin // "sdk"), kind: (.kind // "snapshot"), id: (.id // ""), tq: (.tq // "actual"), status: (.status // "")};
def tot: .in + .out + .cache_read + .cache_write;

# --- price table: v2 {"version":2,"models":[{model,provider?,effective_from?,effective_to?,in,out,cache_read,cache_write}]} or the flat v1 {model:{...}}
'"$SDKIT_PRICE_JQ"'def unpriced($r; $why): $r + {cost_usd: null, cache_saving_usd: null, cost_status: "unpriced", cost_reason: $why};
def price($r):
  if $r.tq == "unavailable" then $r + {cost_usd: null, cache_saving_usd: null, cost_status: "unmeasured", cost_reason: "tokens_unavailable"}
  elif $pt == null then unpriced($r; "no_pricing_table")
  elif (entries | length) == 0 then unpriced($r; "pricing_table_has_no_models")
  else pick($r) as $p
    | if $p.err then unpriced($r; $p.err) else
      $p.entry as $e
      | ([["in"], ["out"], ["cache_read"], ["cache_write"]] | map(.[0]) | map(select($r[.] > 0 and num($e[.]) == null))) as $miss
      | if ($miss | length) > 0 then unpriced($r; "missing_rate:" + ($miss | join("+")))
        else $r + {cost_usd: (($r.in * (num($e.in) // 0) + $r.out * (num($e.out) // 0) + $r.cache_read * (num($e.cache_read) // 0) + $r.cache_write * (num($e.cache_write) // 0)) / 1000000),
                   cache_saving_usd: (if num($e.in) != null and num($e.cache_read) != null then $r.cache_read * (num($e.in) - num($e.cache_read)) / 1000000 else null end),
                   cost_status: "priced", cost_reason: ""} end end end;

# --- aggregate
def agg: {runs: (map(select(.id != "")) | map(.id) | unique | length) + (map(select(.id == "")) | length), lines: length,
          in: (map(.in) | add // 0), out: (map(.out) | add // 0), cache_read: (map(.cache_read) | add // 0), cache_write: (map(.cache_write) | add // 0),
          unmeasured: (map(select(.tq == "unavailable")) | length), priced: (map(select(.cost_status == "priced")) | length),
          unpriced: (map(select(.cost_status != "priced")) | length),
          cost_usd: (map(select(.cost_status == "priced") | .cost_usd) | if length == 0 then null else add end),
          partial: (any(.[]; .cost_status != "priced"))};

map(select(type == "object") | norm) as $raw
| ($raw | map(select($sf == "" or .session == $sf))) as $sel
# --- reconcile: one line per (id, model). Final beats snapshot, then the larger total (counters only grow), then the later one. Lines without an id cannot be matched: each stays.
| ($sel | map(select(.id != "" and .tq != "unavailable") | .id) | unique) as $measured
| ($sel | map(select(.id != "" and (.tq == "unavailable" and .model == "" and (.id as $i | $measured | index($i)) != null | not)))
    | group_by([.id, .model])
    | map(sort_by([(if .kind == "final" then 1 else 0 end), (if .tq == "unavailable" then 0 else 1 end), tot, .ts]) as $g | ($g | last) as $l
          | if $l.tq == "unavailable" then $l
            else $l + {in: (map(.in) | max), out: (map(.out) | max), cache_read: (map(.cache_read) | max), cache_write: (map(.cache_write) | max), kind: (if any(.[]; .kind == "final") then "final" else $l.kind end)} end)) as $keep
| ($sel | map(select(.id == ""))) as $anon
| ($keep + $anon | map(price(.))) as $rows
| ($rows | map(select(.id != "") | .id) | unique | length) as $nid
| ($sel | length) as $nlines
| ($rows | agg) as $T
| ($rows | map(select(.tq != "unavailable"))) as $meas
| (($meas | map(.in + .cache_read + .cache_write) | add // 0)) as $inputside
| ($rows | map(.cost_est_usd // empty)) as $hc
| (if $pt == null then null else (if ($pt | type) == "object" and (($pt.models // null) | type) == "array" then ($pt.currency // "USD") else "USD" end) end) as $cur
| ($rows | map(select(.cost_status == "unpriced")) | group_by(.cost_reason) | map({reason: .[0].cost_reason, runs: length, models: (map(.model | if . == "" then "(none)" else . end) | unique)})) as $unp
| ($rows | map(select(.session != "" and .id != "")) | group_by(.session) | map(select(any(.[]; .role != "orchestrator") and (any(.[]; .role == "orchestrator") | not)) | .[0].session)) as $noorch
| ($rows | map(select(.role != "orchestrator")) | map(.id) | unique | length) as $agentruns
| [ (if $psrc == "none" then "no pricing table (\($psrc)): cost is NOT computed, tokens only; add <project-dir>/pricing.json (see docs) or set TELEMETRY_PRICES" else empty end),
    (if $psrc | startswith("unreadable") then "pricing table unreadable (\($psrc)): cost is NOT computed" else empty end),
    (if $cur != null and $cur != "USD" then "pricing currency is \($cur), not USD: the USD figures below are wrong for it" else empty end),
    ($T.unmeasured as $u | if $u > 0 then "\($u) run(s) reported no token usage: their zeros above are unmeasured, not counted usage" else empty end),
    (if $pt != null then ($unp[] | "\(.runs) run(s) not priced (\(.reason)): \(.models | join(", "))") else empty end),
    ($noorch[] | "session \(.) has agent runs but no orchestrator record (turn never ended or hook off): orchestrator usage is missing; try usage.sh scan"),
    ($rows | map(select(.role != "orchestrator" and .model == "" and .tq != "unavailable")) | length | if . > 0 then "\(.) agent run(s) carry no model id: they cannot be priced" else empty end),
    (if ($spawns != null) and $sf == "" and ($spawns > $agentruns) then "\($spawns) subagent spawn(s) were counted for this task but only \($agentruns) have a ledger record: \($spawns - $agentruns) execution(s) are missing" else empty end),
    ($anon | length | if . > 0 then "\(.) legacy line(s) have no execution id: they cannot be deduplicated" else empty end)
  ] as $warn
| {scope: $scope,
   pricing: {source: $psrc, currency: $cur},
   totals: $T,
   rows: ($rows | map({id, role, tier, host: (.host // ""), model, provider, session, origin, kind, status, tq, ts, in, out, cache_read, cache_write, cost_usd, cost_status, cost_reason}
                      + (if $asm != "" then (price(. + {model: $asm, provider: ""}) | {as_cost_usd: .cost_usd, as_status: .cost_status, as_reason: .cost_reason}) else {} end))),
   by_role: ($rows | group_by([.role, .tier]) | map({role: .[0].role, tier: .[0].tier} + agg)),
   by_model: ($rows | group_by([.model, .provider]) | map({model: (.[0].model | if . == "" then "(unknown)" else . end), provider: (.[0].provider | if . == "" then "-" else . end)} + agg)),
   by_session: ($rows | group_by(.session) | map({session: (.[0].session | if . == "" then "(none)" else . end), origin: (map(.origin) | unique | join("+")), first: (map(.ts) | min), last: (map(.ts) | max)} + agg)),
   by_origin: ($rows | group_by(.origin) | map({origin: .[0].origin, runs: length})),
   cache: {hit_rate: (if $inputside > 0 then ($rows | map(select(.tq != "unavailable") | .cache_read) | add) / $inputside else null end),
           input_side_tokens: $inputside, read: ($meas | map(.cache_read) | add // 0), write: ($meas | map(.cache_write) | add // 0),
           saving_usd: (if ($meas | any(.cache_read > 0 and .cache_saving_usd == null)) then null else ($meas | map(.cache_saving_usd // 0) | add) end)},
   host_estimate: {usd: (if ($hc | length) == 0 then null else ($hc | add) end), runs: ($hc | length), note: "Claude Code client-side estimate, not billed"},
   billed_usd: null,
   coverage: {ledger_lines: $nlines, executions: ($nid + ($anon | length)), duplicates_collapsed: ($nlines - ($rows | length)), unmeasured_runs: $T.unmeasured, priced_runs: $T.priced, unpriced_runs: $T.unpriced, spawns_registered: $spawns},
   warnings: $warn,
   partial: ($T.unpriced > 0 or ($warn | length) > 0)}'

USAGE_TXT='
def pad($w): . + ([range(0; ($w - length))] | map(" ") | join(""));
def table($rows): ($rows | transpose | map(map(length) | max)) as $w | $rows[] | . as $r | [range(0; $r | length) as $i | $r[$i] | tostring | pad($w[$i])] | join("  ") | sub(" +$"; "");
def usd($x): if $x == null then "-" else ((($x * 10000) | round) as $m | "$\(($m / 10000) | floor).\((("0000" + (($m % 10000) | tostring)) | .[-4:]))") end;
def pct($x): if $x == null then "-" else ((($x * 1000) | round) as $m | "\(($m / 10) | floor).\($m % 10)%") end;
def cost($a): if $a.cost_usd == null then "-" else usd($a.cost_usd) + (if $a.partial then "*" else "" end) end;
def row($k; $a): [$k, ($a.runs | tostring), ($a.in | tostring), ($a.out | tostring), ($a.cache_read | tostring), ($a.cache_write | tostring), cost($a)];
if .empty then "no usage recorded" else
"usage: \(.scope)",
"",
table([["role", "tier", "runs", "in", "out", "cache_read", "cache_write", "est_usd"]] + (.by_role | map([.role, .tier] + row("x"; .)[1:])) + [["TOTAL", "-"] + row("x"; .totals)[1:]]),
"",
table([["model", "provider", "runs", "in", "out", "cache_read", "cache_write", "est_usd"]] + (.by_model | map([.model, .provider] + row("x"; .)[1:]))),
(if (.by_session | length) > 1 then "", table([["session", "origin", "runs", "in", "out", "cache_read", "cache_write", "est_usd"]] + (.by_session | map([.session, .origin] + row("x"; .)[1:]))) else empty end),
"",
"cache hit rate: \(pct(.cache.hit_rate))  (cache_read \(.cache.read) of \(.cache.input_side_tokens) input-side tokens = in + cache_read + cache_write)"
  + (if .cache.saving_usd != null and .cache.read > 0 then "; saved about \(usd(.cache.saving_usd)) vs uncached input (API-equivalent)" else "" end),
"estimated cost (API-equivalent, tokens x \(.pricing.source)): \(usd(.totals.cost_usd))"
  + (if .totals.cost_usd == null then " - not computed" elif .partial then "  PARTIAL: \(.coverage.priced_runs) of \(.totals.runs) run(s) priced; the total is a lower bound" else "" end),
(if .host_estimate.usd != null then "host-reported estimate: \(usd(.host_estimate.usd)) over \(.host_estimate.runs) run(s) (\(.host_estimate.note); kept apart from the line above)" else empty end),
"billed: unavailable - no source reports it; with a Claude Code subscription nothing is billed per token, so the figure above is only what the same tokens would cost at API rates",
"coverage: \(.coverage.executions) execution(s), \(.coverage.ledger_lines) ledger line(s)" + (if .coverage.duplicates_collapsed > 0 then ", \(.coverage.duplicates_collapsed) duplicate/superseded line(s) collapsed" else "" end)
  + "; origin " + (.by_origin | map("\(.origin) \(.runs)") | join(", ")),
(.warnings[] | "WARNING: " + .),
(if .partial then "TOTAL IS PARTIAL: see the warnings; token counts and cost are lower bounds" else "totals complete for the data recorded (execution coverage cannot be proven for runs that never logged)" end)
end'

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  log)
    role=""; tier=""; host=""; model=""; tin=0; tout=0; cr=0; cw=0; slug=""; id=""; source=""; force=0; tq=""; cest=""; sess=""; prov=""; origin="sdk"; kind="snapshot"; status=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --role) role="$2"; shift ;; --tier) tier="$2"; shift ;; --host) host="$2"; shift ;; --model) model="$2"; shift ;;
        --in) tin="$2"; shift ;; --out) tout="$2"; shift ;; --cache-read) cr="$2"; shift ;; --cache-write) cw="$2"; shift ;;
        --slug) slug="$2"; shift ;; --id) id="$2"; shift ;; --source) source="$2"; shift ;; --tq) tq="$2"; shift ;; --cost-est) cest="$2"; shift ;; --force) force=1 ;;
        --session) sess="$2"; shift ;; --provider) prov="$2"; shift ;; --origin) origin="$2"; shift ;; --kind) kind="$2"; shift ;; --status) status="$2"; shift ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
      esac
      shift
    done
    [ "${USAGE_LOG:-}" = 1 ] || [ "$force" = 1 ] || exit 0
    [ -n "$role" ] || { echo "--role is required" >&2; exit 2; }
    case "$origin" in sdk|observed) ;; *) echo "--origin must be sdk or observed" >&2; exit 2 ;; esac
    case "$kind" in snapshot|final) ;; *) echo "--kind must be snapshot or final" >&2; exit 2 ;; esac
    [ -n "$slug" ] || slug="$(current_slug)"
    mkdir -p "$work/$slug"; file="$work/$slug/usage.jsonl"
    line="$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg role "$role" --arg tier "$tier" --arg host "$host" --arg model "$model" \
      --arg id "$id" --arg source "$source" --arg tq "$tq" --arg cest "$cest" --arg sess "$sess" --arg prov "$prov" --arg origin "$origin" --arg kind "$kind" --arg status "$status" \
      --argjson i "${tin:-0}" --argjson o "${tout:-0}" --argjson cr "${cr:-0}" --argjson cw "${cw:-0}" \
      '{v:2, ts:$ts, role:$role, tier:$tier, host:$host, model:$model, provider:$prov, session:$sess, id:$id, origin:$origin, kind:$kind, source:$source, in:$i, out:$o, cache_read:$cr, cache_write:$cw}
       + (if $tq != "" then {tq:$tq} else {} end) + (if $status != "" then {status:$status} else {} end)
       + (if ($cest | test("^[0-9]+([.][0-9]+)?$")) then {cost_est_usd:($cest | tonumber), cost_src:"host-estimate"} else {} end)')" || { echo "usage.sh: bad number in an argument" >&2; exit 2; }
    # agents finish at the same time: the replace-then-append runs under a lock, or lines of parallel agents are lost
    log_line "$line" "$file" ;;
  window)   # the start of the open task (ISO UTC), or nothing: where its share of a cumulative session transcript begins
    slug="$(current_slug)"; sf="$top/$KIT_DIR/.sdd/state.json"
    [ -f "$sf" ] && jq -r --arg s "$slug" 'select(.task == $s) | .startedAt // empty' "$sf" 2>/dev/null | head -1 ;;
  reconcile)   # subagent runs the hook could not read (transcript not written yet): fill them in from the transcript now on disk. Prints how many.
    slug=""; dir="${CLAUDE_TRANSCRIPT_DIR:-}"
    while [ $# -gt 0 ]; do case "$1" in --slug) slug="$2"; shift ;; --dir) dir="$2"; shift ;; *) echo "unknown option $1" >&2; exit 2 ;; esac; shift; done
    [ -n "$dir" ] || dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$top" | sed 's/[^A-Za-z0-9]/-/g')"
    [ -n "$slug" ] || slug="$(current_slug)"; file="$work/$slug/usage.jsonl"
    n=0; [ -d "$dir" ] && [ -f "$file" ] || { echo 0; exit 0; }
    while IFS="$(printf '\t')" read -r aid sid; do
      a="$dir/$sid/subagents/agent-$aid.jsonl"; [ -f "$a" ] || continue
      aj="$(extract_json "$a")"; [ -n "$aj" ] && [ "$(jq .messages <<< "$aj")" -gt 0 ] || continue
      meta="${a%.jsonl}.meta.json"; role="$(jq -r '.agentType // empty' "$meta" 2>/dev/null)"; role="${role##*:}"; [ -n "$role" ] || role=subagent
      prov="$(jq -r .provider <<< "$aj")"
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        log_line "$(jq -nc --argjson m "$m" --argjson j "$aj" --arg id "$aid" --arg role "$role" --arg s "$sid" --arg p "$prov" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{v:2, ts:($j.last_ts // $ts | sub("\\.[0-9]+"; "")), role:$role, tier:"", host:"claude", model:$m.model, provider:$p, session:$s, id:$id, origin:"observed", kind:"final", source:"reconcile", in:$m.in, out:$m.out, cache_read:$m.cache_read, cache_write:$m.cache_write}')" "$file"
        n=$((n + 1))
      done < <(jq -c '(.by_model | if length == 0 then [{model:"",in:0,out:0,cache_read:0,cache_write:0}] else . end)[]' <<< "$aj")
    done < <(jq -r 'select(.tq == "unavailable" and (.id // "") != "" and (.session // "") != "" and (.id | startswith("rr-") | not)) | [.id, .session] | @tsv' "$file" 2>/dev/null | sort -u)
    echo "$n" ;;
  extract)
    [ -f "${1:-}" ] || { echo "usage.sh extract <transcript> [--since TS]" >&2; exit 2; }
    extract_json "$1" "$([ "${2:-}" = --since ] && printf '%s' "${3:-}")" | { read -r j && [ -n "$j" ] && printf '%s\n' "$j" || exit 1; } ;;
  context)
    tf=""; topn=5; json=0
    while [ $# -gt 0 ]; do case "$1" in --top) topn="${2:-5}"; shift ;; --json) json=1 ;; -*) echo "unknown option $1" >&2; exit 2 ;; *) tf="$1" ;; esac; shift; done
    case "$topn" in ''|*[!0-9]*) topn=5 ;; esac
    if [ -z "$tf" ]; then
      cdir="${CLAUDE_TRANSCRIPT_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$top" | sed 's/[^A-Za-z0-9]/-/g')}"
      tf="$(ls -t "$cdir"/*.jsonl 2>/dev/null | head -1)"
    fi
    [ -f "$tf" ] || { echo "context: no transcript (Claude Code only; pass a path)" >&2; exit 1; }
    res="$(jq -cs --argjson top "$topn" '
      def sz: if type == "string" then length elif type == "array" then (map(if type == "object" then ((.text // "") | length) else (tostring | length) end) | add // 0) else (tostring | length) end;
      [ .[] | select(type == "object") ] as $rec
      | ( [ $rec[] | select(.type == "assistant") | .message.content[]? | select(type == "object" and .type == "tool_use")
            | {key: .id, value: {name: .name, label: ((.input.command // .input.file_path // .input.pattern // .input.description // "") | tostring | gsub("[\n\r]"; " ") | .[0:70])}} ] | from_entries ) as $use
      # turns after record i: distinct requests (requestId, else message id) of assistant records with usage, counted once at their first record
      | ( reduce range(0; $rec | length) as $i ({seen: {}, first: []};
            ($rec[$i]) as $r
            | if $r.type == "assistant" and (($r.message.usage // null) | type) == "object" and (($r.requestId // $r.message.id // null) != null) and (.seen[$r.requestId // $r.message.id] | not)
              then .seen[$r.requestId // $r.message.id] = true | .first += [1] else .first += [0] end) ) as $acc
      | ($acc.first | add // 0) as $turns
      | ( reduce range(0; $rec | length) as $i ({c: 0, after: []}; .c += $acc.first[$i] | .after += [.c]) ).after as $cum
      | [ range(0; $rec | length) as $i | $rec[$i] | select(.type == "user") | .message.content? | arrays | .[] | select(type == "object" and .type == "tool_result")
          | {tool: ($use[.tool_use_id].name // "?"), label: ($use[.tool_use_id].label // ""), tok: ((.content | sz) / 4 | floor), later: ($turns - $cum[$i])} | .reread = .tok * .later ] as $r
      | ($r | map(.tok) | add // 0) as $tt
      | {transcript_turns: $turns, results: ($r | length), result_tokens: $tt, reread_tokens: ($r | map(.reread) | add // 0),
         by_tool: ($r | group_by(.tool) | map({tool: .[0].tool, calls: length, tokens: (map(.tok) | add), reread: (map(.reread) | add), share: (if $tt > 0 then ((map(.tok) | add) * 100 / $tt | floor) else 0 end)}) | sort_by(-.reread)),
         largest: ($r | sort_by(-.reread) | .[0:$top] | map({tool, label, tokens: .tok, later_turns: .later, reread}))}' "$tf" 2>/dev/null)" || res=""
    [ -n "$res" ] || { echo "context: could not read $tf" >&2; exit 1; }
    if [ "$json" = 1 ]; then printf '%s\n' "$res"; else
      printf '%s\n' "$res" | jq -r '"session context: \(.transcript_turns) turns, \(.results) tool results, ~\(.result_tokens) tokens of results; carrying them cost ~\(.reread_tokens) re-read tokens (tokens x the turns after each result)"'
      printf '%s\n' "$res" | jq -r '(["tool", "calls", "~tokens", "share", "~re-read"] | @tsv), (.by_tool[] | [.tool, .calls, .tokens, "\(.share)%", .reread] | @tsv)' | column -t -s "$(printf '\t')" 2>/dev/null
      printf '%s\n' "$res" | jq -r '"", "largest results by re-read cost:", (.largest[] | "  \(.tool)  ~\(.tokens) tokens x \(.later_turns) later turns = \(.reread)   \(.label)")'
    fi ;;
  prices)
    pf="${TELEMETRY_PRICES:-$top/$KIT_DIR/pricing.json}"; json=0; [ "${1:-}" = --json ] && json=1
    if [ ! -f "$pf" ]; then
      [ "$json" = 1 ] && echo '{"status":"missing","source":null}' || echo "pricing: none ($pf not found; TELEMETRY_PRICES unset): costs are not computed, tokens are still counted"
      exit 0
    fi
    jq -e . "$pf" >/dev/null 2>&1 || { [ "$json" = 1 ] && echo '{"status":"unreadable"}' || echo "pricing: $pf is not valid JSON: costs are not computed"; exit 1; }
    jq -c --arg src "$pf" '
      (if (.models? | type) == "array" then {version: (.version // 2), currency: (.currency // "USD"), n: (.models | length), ids: (.models | map(.model) | unique)}
       else {version: 1, currency: "USD", n: length, ids: keys} end) as $s
      | {status: "ok", source: $src, version: $s.version, currency: $s.currency, entries: $s.n, models: $s.ids}' "$pf" |
      if [ "$json" = 1 ]; then cat; else jq -r '"pricing: \(.source)\n  format version \(.version), currency \(.currency), \(.entries) entr(y/ies), \(.models | length) model(s): \(.models | join(", "))\n  USD per million tokens; API-equivalent estimate, never a bill"'; fi ;;
  scan)
    sid=""; since=""; dir="${CLAUDE_TRANSCRIPT_DIR:-}"; slug=""
    while [ $# -gt 0 ]; do case "$1" in --session) sid="$2"; shift ;; --since) since="$2"; shift ;; --dir) dir="$2"; shift ;; --slug) slug="$2"; shift ;; *) echo "unknown option $1" >&2; exit 2 ;; esac; shift; done
    [ -n "$dir" ] || dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$top" | sed 's/[^A-Za-z0-9]/-/g')"
    [ -d "$dir" ] || { echo "scan: no transcript directory at $dir (Claude Code only; pass --dir)" >&2; exit 1; }
    [ -n "$slug" ] || slug="$(current_slug)"
    mkdir -p "$work/$slug"; file="$work/$slug/usage.jsonl"
    if [ -n "$sid" ]; then list="$dir/$sid.jsonl"
    elif [ -n "$since" ]; then list="$(find "$dir" -maxdepth 1 -name '*.jsonl' -newermt "$since" 2>/dev/null | sort)"
    else list="$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)"; fi
    n=0; win=""
    [ -f "$top/$KIT_DIR/.sdd/state.json" ] && win="$(jq -r --arg s "$slug" 'select(.task == $s) | .startedAt // empty' "$top/$KIT_DIR/.sdd/state.json" 2>/dev/null | head -1)"
    # one ledger line per (execution, model); ids are the hooks' ids, so a run the hook already recorded is not counted again
    emit_obs() {  # $1 = extract json, $2 = id, $3 = role, $4 = session, $5 = kind, $6 = provider
      local j="$1" m
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        log_line "$(jq -nc --argjson m "$m" --argjson j "$j" --arg id "$2" --arg role "$3" --arg s "$4" --arg k "$5" --arg p "$6" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{v:2, ts:($j.last_ts // $ts), role:$role, tier:"", host:"claude", model:$m.model, provider:$p, session:$s, id:$id, origin:"observed", kind:$k, source:"scan", in:$m.in, out:$m.out, cache_read:$m.cache_read, cache_write:$m.cache_write}')" "$file"
        n=$((n + 1))
      done < <(jq -c '(.by_model | if length == 0 then [{model:"",in:0,out:0,cache_read:0,cache_write:0}] else . end)[]' <<< "$j")
    }
    for f in $list; do
      [ -f "$f" ] || { echo "scan: no transcript $f" >&2; continue; }
      s="$(basename "$f" .jsonl)"; j="$(extract_json "$f" "$win")"; [ -n "$j" ] || continue
      [ "$(jq .messages <<< "$j")" -gt 0 ] && emit_obs "$j" "session-$s" orchestrator "$s" snapshot "$(jq -r .provider <<< "$j")"
      for a in "$dir/$s"/subagents/agent-*.jsonl; do
        [ -f "$a" ] || continue
        aid="$(basename "$a" .jsonl)"; aid="${aid#agent-}"; meta="${a%.jsonl}.meta.json"
        role="$(jq -r '.agentType // empty' "$meta" 2>/dev/null)"; role="${role##*:}"; [ -n "$role" ] || role=subagent
        fin="$(jq -r 'if .finished == true then "final" else "snapshot" end' "$meta" 2>/dev/null)"; [ -n "$fin" ] || fin=snapshot
        aj="$(extract_json "$a")"; [ -n "$aj" ] || continue
        # a subagent of an earlier task of the same session belongs to that task's ledger, not to this one
        [ -z "$win" ] || [ "$(jq -r --arg w "$win" '(.last_ts // "" | sub("\\.[0-9]+"; "")) >= $w' <<< "$aj")" = true ] || continue
        [ "$(jq .messages <<< "$aj")" -gt 0 ] && emit_obs "$aj" "$aid" "$role" "$s" "$fin" "$(jq -r .provider <<< "$aj")"
      done
    done
    echo "scan: $n ledger line(s) written to $KIT_DIR/work/$slug/usage.jsonl (origin observed)" ;;
  report)
    slug=""; project=0; sfilter=""; json=0; asmodel=""
    while [ $# -gt 0 ]; do case "$1" in --project) project=1 ;; --session) sfilter="$2"; shift ;; --json) json=1 ;; --as-model) asmodel="$2"; shift ;; -*) echo "unknown option $1" >&2; exit 2 ;; *) slug="$1" ;; esac; shift; done
    if [ -n "$slug" ]; then files="$work/$slug/usage.jsonl"; scope="task $slug"; else files="$(ls "$work"/*/usage.jsonl 2>/dev/null)"; scope="every open task"; fi
    if [ "$project" = 1 ]; then
      if [ -n "$slug" ]; then files="$files $(ls "$work/_archive/$slug.usage.jsonl" 2>/dev/null)"; scope="task $slug (with archive)"
      else files="$files $(ls "$work"/_archive/*.usage.jsonl 2>/dev/null)"; scope="project: open and archived tasks"; fi
    fi
    # shellcheck disable=SC2086
    [ -n "${files// /}" ] && cat $files 2>/dev/null | grep -q . || { if [ "$json" = 1 ]; then echo '{"empty":true}'; else echo "no usage recorded (set USAGE_LOG=1 in sdkit.env)"; fi; exit 0; }
    pf="${TELEMETRY_PRICES:-$top/$KIT_DIR/pricing.json}"; pt=null; psrc="none"
    if [ -f "$pf" ]; then pt="$(jq -c . "$pf" 2>/dev/null)" && psrc="$pf" || { pt=null; psrc="unreadable: $pf"; }; fi
    spawns=null; if [ -n "$slug" ] && [ -f "$work/$slug/state.json" ]; then spawns="$(jq -c '.spawns // null | if type == "number" then . else null end' "$work/$slug/state.json" 2>/dev/null || echo null)"; fi
    if [ "$sfilter" = current ]; then
      # shellcheck disable=SC2086
      sfilter="$(cat $files 2>/dev/null | jq -rs 'map(select(type == "object" and (.session // "") != "")) | sort_by(.ts) | last.session // ""')"
      [ -n "$sfilter" ] || { echo "report: no ledger line carries a session id yet" >&2; exit 0; }
      scope="$scope, session $sfilter (the one with the newest record)"
    elif [ -n "$sfilter" ]; then scope="$scope, session $sfilter"; fi
    # shellcheck disable=SC2086
    res="$(cat $files 2>/dev/null | jq -s --argjson pt "$pt" --arg psrc "$psrc" --argjson spawns "$spawns" --arg sf "$sfilter" --arg scope "$scope" --arg asm "$asmodel" "$USAGE_JQ")" || { echo "report: could not read the ledger" >&2; exit 1; }
    if [ "$json" = 1 ]; then printf '%s\n' "$res"; exit 0; fi
    printf '%s\n' "$res" | jq -r "$USAGE_TXT"
    ;;
  budget)
    slug="${1:-}"; [ -n "$slug" ] || slug="$(current_slug)"
    case "${TOKEN_BUDGET_TASK:-}" in ''|*[!0-9]*|0) exit 0 ;; esac
    file="$work/$slug/usage.jsonl"; [ -f "$file" ] || exit 0
    used="$(jq -rs 'map(.in + .out + .cache_write) | add // 0' "$file")"
    warn="${TOKEN_BUDGET_WARN_PCT:-70}"; case "$warn" in ''|*[!0-9]*) warn=70 ;; esac
    pct=$(( used * 100 / TOKEN_BUDGET_TASK ))
    echo "token budget for $slug: $used of $TOKEN_BUDGET_TASK used (${pct}%)"
    [ "$pct" -ge 100 ] && exit 4
    [ "$pct" -ge "$warn" ] && exit 3
    exit 0 ;;
  *) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
