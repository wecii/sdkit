#!/usr/bin/env bash
# F07 tests: usage and cost accounting. Deterministic: fixture transcripts and ledgers only, no host CLI, no network, no LLM.
# Covers the transcript parser, the ledger (snapshots, finals, duplicates), pricing (resolution, dates, providers, unknown models, recalculation),
# cost and cache arithmetic, coverage warnings, the Claude hook, scan, and compatibility with the older readers. Run: tests/usage.test.sh
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
US="$KIT/scripts/usage.sh"
newrepo() { local r="$T/$1"; mkdir -p "$r/.sdkit"; ( cd "$r" && git init -q -b main . && printf 'BASE_BRANCH=main\nSTACK=generic\nUSAGE_LOG=1\n' > .sdkit/sdkit.env ); echo "$r"; }
rj() { "$US" report "$@" --json; }                       # report as JSON
jv() { local f="$1"; shift; jq -r "$f" <<< "$("$@")"; }  # jq filter over a command's output
# price tables
P1='{"version":2,"currency":"USD","models":[{"model":"m-a","provider":"anthropic","effective_from":"2026-01-01","in":3,"out":15,"cache_read":0.3,"cache_write":3.75}]}'
# a ledger line: ln <id> <role> <model> <in> <out> <cr> <cw> [extra json]
ln() { local x="${8:-}"; [ -n "$x" ] || x='{}'; jq -nc --arg id "$1" --arg role "$2" --arg m "$3" --argjson i "$4" --argjson o "$5" --argjson cr "$6" --argjson cw "$7" --argjson x "$x" \
  '{v:2, ts:"2026-03-01T10:00:00Z", role:$role, tier:"", host:"claude", model:$m, provider:"anthropic", session:"s1", id:$id, origin:"sdk", kind:"final", source:"t", in:$i, out:$o, cache_read:$cr, cache_write:$cw} + $x'; }

echo "transcript parser (extract)"
R="$(newrepo ex)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
asst() { jq -nc --arg id "$1" --arg m "${2:-m-a}" --argjson o "$3" --arg u "${4:-u-$1-$3}" --argjson cr "${5:-0}" \
  '{type:"assistant", uuid:$u, sessionId:"sess1", timestamp:"2026-03-01T10:00:00.000Z", message:({model:$m, usage:{input_tokens:2, output_tokens:$o, cache_read_input_tokens:$cr, cache_creation_input_tokens:10}} + (if $id == "" then {} else {id:$id} end))}'; }
{ asst msg1 m-a 1; asst msg1 m-a 40; asst msg1 m-a 200; asst msg2 m-a 7; } > "$T/stream.jsonl"
eq "a streamed message counts its LAST (largest) output, not the first"   "$(jv .out "$US" extract "$T/stream.jsonl")" 207
eq "...and each message id only once (input and cache write)"            "$(jv '[.in,.cache_write]|join(",")' "$US" extract "$T/stream.jsonl")" "4,20"
{ asst "" m-a 5 ua; asst "" m-a 6 ub; asst "" m-a 7 uc; } > "$T/noid.jsonl"
{ jq -nc '{type:"assistant",uuid:"x1",requestId:"req_1",message:{id:"msgA",model:"m-a",usage:{input_tokens:5,output_tokens:10,cache_read_input_tokens:100,cache_creation_input_tokens:7}}}'
  jq -nc '{type:"assistant",uuid:"x2",requestId:"req_1",message:{id:"msgB",model:"m-a",usage:{input_tokens:5,output_tokens:30,cache_read_input_tokens:100,cache_creation_input_tokens:7}}}'
  jq -nc '{type:"assistant",uuid:"x3",requestId:"req_2",message:{id:"msgB",model:"m-a",usage:{input_tokens:1,output_tokens:2,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}'; } > "$T/req.jsonl"
eq "records of one requestId count once (max), another requestId separately" "$(jv '[.messages,.in,.out,.cache_read,.cache_write]|join(",")' "$US" extract "$T/req.jsonl")" "2,6,32,100,7"
eq "messages without an id are not merged into one"                      "$(jv .messages "$US" extract "$T/noid.jsonl")" 3
eq "...their output is summed"                                           "$(jv .out "$US" extract "$T/noid.jsonl")" 18
{ asst m1 '<synthetic>' 0; asst m2 m-a 9; } > "$T/syn.jsonl"
eq "synthetic messages count nothing"                                    "$(jv '[.messages,.out]|join(",")' "$US" extract "$T/syn.jsonl")" "1,9"
{ asst m1 m-a 10; asst m2 m-b 20; asst m3 m-a 30; } > "$T/multi.jsonl"
eq "usage is split per model"                                            "$(jv '.by_model|map("\(.model):\(.out)")|join(",")' "$US" extract "$T/multi.jsonl")" "m-a:40,m-b:20"
eq "the session id and provider come from the transcript"                "$(jv '[.session,.provider]|join(",")' "$US" extract "$T/stream.jsonl")" "sess1,"
printf 'not json\n' > "$T/bad.jsonl"
nocheck "an unreadable transcript yields nothing, not zeros"             bash -c "'$US' extract '$T/bad.jsonl' | grep -q ."

echo "pricing: missing table, unknown model, no invented prices"
R="$(newrepo price)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
{ ln e1 developer m-a 1000 2000 100000 10000; ln e2 analyst m-x 500 500 0 0; } > /dev/null
mkdir -p .sdkit/work/t1; { ln e1 developer m-a 1000 2000 100000 10000; ln e2 analyst m-x 500 500 0 0; } > .sdkit/work/t1/usage.jsonl
eq "no pricing.json: cost is null, never 0"                              "$(jv '.totals.cost_usd' "$US" report t1 --json)" null
eq "...tokens are still counted"                                         "$(jv '[.totals.in,.totals.out,.totals.cache_read,.totals.cache_write]|join(",")' "$US" report t1 --json)" "1500,2500,100000,10000"
eq "...and the total is PARTIAL"                                         "$(jv '.partial' "$US" report t1 --json)" true
check "...with an explicit warning"                                      bash -c "'$US' report t1 | grep -q 'WARNING: no pricing table'"
check "...and the text says cost is not computed"                        bash -c "'$US' report t1 | grep -q 'not computed'"
eq "prices: says none"                                                   "$("$US" prices | grep -c '^pricing: none')" 1
printf '%s' "$P1" > .sdkit/pricing.json
eq "unknown model: that run is unpriced with a reason"                   "$(jv '.coverage.unpriced_runs' "$US" report t1 --json)" 1
check "...named in a warning"                                            bash -c "'$US' report t1 | grep -q 'WARNING: 1 run(s) not priced (unknown_model): m-x'"
eq "...the priced run is still costed (0.1005)"                          "$(jv '.totals.cost_usd' "$US" report t1 --json)" 0.1005
eq "...and the total is flagged PARTIAL"                                 "$(jv '.partial' "$US" report t1 --json)" true
check "...the text marks the figure as a lower bound"                    bash -c "'$US' report t1 | grep -q 'PARTIAL: 1 of 2 run(s) priced'"
eq "a model with no model id cannot be priced"                           "$({ ln e3 developer '' 1 1 0 0; } > .sdkit/work/t1/usage.jsonl; jv '.warnings|map(select(contains("no model id")))|length' "$US" report t1 --json)" 1

echo "cost and cache arithmetic (hand computed)"
mkdir -p .sdkit/work/c1; ln c1 orchestrator m-a 1000 2000 100000 10000 > .sdkit/work/c1/usage.jsonl
# (1000*3 + 2000*15 + 100000*0.3 + 10000*3.75) / 1e6 = 0.1005
eq "cost = tokens x rate / 1e6, all four kinds"                          "$(jv '.totals.cost_usd' "$US" report c1 --json)" 0.1005
eq "cache hit rate = cache_read / (in + cache_read + cache_write)"       "$(jv '.cache.hit_rate*100000|round' "$US" report c1 --json)" 90090
eq "...printed to one decimal"                                           "$("$US" report c1 | grep -o 'cache hit rate: [0-9.]*%')" "cache hit rate: 90.1%"
# saving = 100000 * (3 - 0.3) / 1e6 = 0.27
eq "cache saving = cache_read x (in rate - cache_read rate)"             "$(jv '.cache.saving_usd' "$US" report c1 --json)" 0.27
check "the line is labelled API-equivalent, billed unavailable"          bash -c "'$US' report c1 | grep -q 'API-equivalent' && '$US' report c1 | grep -q '^billed: unavailable'"
eq "billed is null in the JSON"                                          "$(jv '.billed_usd' "$US" report c1 --json)" null
mkdir -p .sdkit/work/c2; ln c2 orchestrator m-a 1 0 0 0 > .sdkit/work/c2/usage.jsonl
eq "full precision is kept internally (1 token = 0.000003)"              "$(jv '.totals.cost_usd' "$US" report c2 --json)" 0.000003
eq "...and rounded only for display"                                     "$("$US" report c2 | grep -o ': \$[0-9.]*$' | head -1)" ': $0.0000'
eq "a clean run is not partial"                                          "$(jv '.partial' "$US" report c1 --json)" false
printf '%s' '{"version":2,"models":[{"model":"m-a","in":3,"out":15}]}' > .sdkit/pricing.json
eq "a missing rate for tokens that exist leaves the run unpriced"        "$(jv '.warnings|map(select(contains("missing_rate:cache_read+cache_write")))|length' "$US" report c1 --json)" 1
eq "...but not when those tokens are zero"                               "$(ln c3 orchestrator m-a 10 10 0 0 > .sdkit/work/c2/usage.jsonl; jv '.totals.cost_usd' "$US" report c2 --json)" 0.00018
printf '%s' "$P1" > .sdkit/pricing.json

echo "pricing: versions, effective dates, providers, resolution order"
mkdir -p .sdkit/work/p1
V2='{"version":2,"models":[
 {"model":"m-a","provider":"anthropic","effective_from":"2026-01-01","effective_to":"2026-02-28","in":3,"out":15,"cache_read":0.3,"cache_write":3.75},
 {"model":"m-a","provider":"anthropic","effective_from":"2026-03-01","in":6,"out":30,"cache_read":0.6,"cache_write":7.5},
 {"model":"m-a","provider":"bedrock","effective_from":"2026-01-01","in":4,"out":20,"cache_read":0.4,"cache_write":5}]}'
printf '%s' "$V2" > .sdkit/pricing.json
one() { ln p1 developer m-a 1000000 0 0 0 "$1" > .sdkit/work/p1/usage.jsonl; jv '.totals.cost_usd' "$US" report p1 --json; }
eq "the price in force on the record date is used (old window)"           "$(one '{"ts":"2026-02-10T00:00:00Z"}')" 3
eq "...the newer window after its start"                                 "$(one '{"ts":"2026-03-05T00:00:00Z"}')" 6
eq "a date before every window is unpriced, not guessed"                 "$(one '{"ts":"2025-06-01T00:00:00Z"}')" null
check "...with the reason"                                               bash -c "'$US' report p1 | grep -q not_effective_on_record_date"
eq "a provider-specific rate applies to that provider"                   "$(one '{"provider":"bedrock","ts":"2026-03-05T00:00:00Z"}')" 4
eq "a provider with no entry is not priced at another provider's rate"   "$(one '{"provider":"vertex","ts":"2026-03-05T00:00:00Z"}')" null
printf '%s' '{"version":2,"models":[{"model":"m-a","provider":"bedrock","in":4,"out":20,"cache_read":0.4,"cache_write":5}]}' > .sdkit/pricing.json
eq "...provider_mismatch when only other providers are priced"           "$(one '{"provider":"vertex"}')" null
check "...and says so"                                                   bash -c "'$US' report p1 | grep -q provider_mismatch"
printf '%s' '{"version":2,"models":[{"model":"m-a","provider":"bedrock","in":4,"out":20},{"model":"m-a","provider":"anthropic","in":3,"out":15}]}' > .sdkit/pricing.json
eq "an unknown provider with two different candidates is ambiguous"      "$(one '{"provider":""}')" null
check "...and says so"                                                   bash -c "'$US' report p1 | grep -q ambiguous_provider"
printf '%s' '{"m-a":{"in":2,"out":10}}' > .sdkit/pricing.json
eq "the flat version-1 table still works"                                "$(one '{}')" 2
printf '%s' '{"models":[{"model":"m-a","in":9,"out":9}]}' > .sdkit/pricing.json
eq "a dated model id (-YYYYMMDD) falls back to the base id"              "$(ln p1 developer m-a-20260101 1000000 0 0 0 > .sdkit/work/p1/usage.jsonl; jv '.totals.cost_usd' "$US" report p1 --json)" 9
printf '{ broken' > .sdkit/pricing.json
check "an unreadable table is reported, never treated as free"           bash -c "'$US' report p1 | grep -q 'pricing table unreadable'"
eq "...cost null"                                                        "$(jv '.totals.cost_usd' "$US" report p1 --json)" null
printf '%s' '{"version":2,"currency":"EUR","models":[{"model":"m-a","in":1,"out":1}]}' > .sdkit/pricing.json
check "a non-USD table is flagged"                                       bash -c "'$US' report p1 | grep -q 'currency is EUR'"
printf '%s' '{"version":2,"models":[{"model":"m-a","in":1,"out":1}]}' > .sdkit/pricing.json
eq "TELEMETRY_PRICES overrides <project-dir>/pricing.json"               "$(printf '%s' '{"m-a":{"in":7,"out":0}}' > "$T/alt.json"; TELEMETRY_PRICES="$T/alt.json" jv '.totals.cost_usd' "$US" report p1 --json)" 7
eq "prices: lists the models"                                            "$(printf '%s' "$P1" > .sdkit/pricing.json; "$US" prices | grep -c 'm-a')" 1
eq "sdkit_prices_flat collapses a v2 table for the older readers"        "$(. "$KIT/scripts/env.sh"; sdkit_prices_flat .sdkit/pricing.json | jq -c '.["m-a"]')" '{"in":3,"out":15,"cache_read":0.3,"cache_write":3.75}'
eq "...and passes a v1 table through"                                    "$(printf '%s' '{"m":{"in":1}}' > "$T/v1.json"; . "$KIT/scripts/env.sh"; sdkit_prices_flat "$T/v1.json")" '{"m":{"in":1}}'
eq "...and returns {} for a missing file"                                "$(. "$KIT/scripts/env.sh"; sdkit_prices_flat "$T/none.json")" '{}'

echo "recalculation after a pricing update"
mkdir -p .sdkit/work/r1; ln r1 developer m-a 1000000 0 0 0 > .sdkit/work/r1/usage.jsonl
printf '%s' '{"version":2,"models":[{"model":"m-a","in":3,"out":0}]}' > .sdkit/pricing.json; a="$(jv '.totals.cost_usd' "$US" report r1 --json)"
printf '%s' '{"version":2,"models":[{"model":"m-a","in":5,"out":0}]}' > .sdkit/pricing.json; b="$(jv '.totals.cost_usd' "$US" report r1 --json)"
eq "the same ledger is re-priced by the new table"                       "$a,$b" "3,5"
eq "no cost is stored in the ledger"                                     "$(jq -r 'has("cost_usd")' .sdkit/work/r1/usage.jsonl)" false
printf '%s' '{"version":2,"models":[]}' > .sdkit/pricing.json
check "an empty table gives no cost and says why"                        bash -c "'$US' report r1 | grep -q 'not priced (pricing_table_has_no_models)'"

echo "the ledger: snapshots, finals, duplicates, interruptions"
R="$(newrepo led)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"; printf '%s' "$P1" > .sdkit/pricing.json
L=".sdkit/work/s1/usage.jsonl"
lg() { "$US" log --slug s1 --role "$1" --id "$2" --model "$3" --in "$4" --out "$5" --cache-read 0 --cache-write 0 "${@:6}"; }
lg orchestrator session-x m-a 10 10 --session x; lg orchestrator session-x m-a 20 20 --session x; lg orchestrator session-x m-a 30 30 --session x
eq "repeated snapshots of one id leave one line"                         "$(grep -c . "$L")" 1
eq "...holding the latest reading, counted once"                         "$(jv '[.totals.in,.totals.runs]|join(",")' "$US" report s1 --json)" "30,1"
lg orchestrator session-x m-a 5 5 --session x
eq "a smaller (late) snapshot never replaces a larger one"               "$(jq -r .in "$L")" 30
lg orchestrator session-x m-a 40 40 --session x --kind final
lg orchestrator session-x m-a 99 99 --session x --kind snapshot
eq "a snapshot never replaces a final line"                              "$(jq -r .in "$L")" 40
lg orchestrator session-x m-b 7 7 --session x
eq "the same id on another model is its own line"                        "$(grep -c . "$L")" 2
eq "...but still one execution"                                          "$(jv '.totals.runs' "$US" report s1 --json)" 1
rm -f "$L"
{ ln d1 developer m-a 100 100 0 0; ln d1 developer m-a 100 100 0 0; ln d1 developer m-a 100 100 0 0 '{"kind":"snapshot"}'; } > /dev/null
mkdir -p .sdkit/work/s1; { ln d1 developer m-a 100 100 0 0; ln d1 developer m-a 100 100 0 0; ln d2 reviewer m-a 50 50 0 0; } > "$L"
eq "duplicate subagent lines already on disk are collapsed at report"    "$(jv '[.totals.in,.totals.runs,.coverage.duplicates_collapsed]|join(",")' "$US" report s1 --json)" "150,2,1"
check "...and the collapse is disclosed"                                 bash -c "'$US' report s1 | grep -q '1 duplicate/superseded line(s) collapsed'"
{ ln d1 developer m-a 100 100 0 0 '{"kind":"snapshot"}'; ln d1 developer m-a 120 100 0 0 '{"kind":"final"}'; ln d1 developer m-a 130 100 0 0 '{"kind":"snapshot"}'; } > "$L"
# stabilization (P2.2): a final that reads LOWER than a snapshot is still the end of the run, but counters only grow, so the larger value is kept (before: 120)
eq "on disk too: the final is promoted and keeps the larger counters"    "$(jv .totals.in "$US" report s1 --json)" 130
{ ln d1 developer m-a 100 100 0 0; ln d1 developer m-a 0 0 0 0 '{"tq":"unavailable"}'; } > "$L"
eq "an unavailable mark never beats real numbers"                        "$(jv '[.totals.in,.totals.unmeasured]|join(",")' "$US" report s1 --json)" "100,0"
rm -f "$L"
lg developer ex1 m-a 0 0 --tq unavailable --status interrupted --kind final
eq "an interrupted run is unmeasured, never zero cost"                   "$(jv '[.totals.unmeasured,(.totals.cost_usd|tostring)]|join(",")' "$US" report s1 --json)" "1,null"
check "...with the existing warning text"                                bash -c "'$US' report s1 | grep -q '1 run(s) reported no token usage: their zeros above are unmeasured'"
lg developer ex1 m-a 11 22 --kind final
eq "real numbers for the same run replace the mark"                      "$(jv '[.totals.in,.totals.out,.totals.unmeasured]|join(",")' "$US" report s1 --json)" "11,22,0"
rm -f "$L"
{ printf 'garbage line\n'; } > "$L"; lg developer ex2 m-a 1 1 --kind final
eq "a corrupt line in the ledger does not stop a replace"                "$(grep -c '"id":"ex2"' "$L")" 1
rm -f "$L"
eq "20 parallel writers keep all 20 executions"                          "$(for i in $(seq 1 20); do lg developer "par$i" m-a 1 1 --kind final & done; wait; jv .totals.runs "$US" report s1 --json)" 20
nocheck "a bad number is refused"                                        "$US" log --slug s1 --role x --in abc
nocheck "a bad origin is refused"                                        "$US" log --slug s1 --role x --origin guess
eq "USAGE_LOG unset: log is a silent no-op"                              "$(sed -i.bak '/USAGE_LOG/d' .sdkit/sdkit.env; rm -f .sdkit/work/s2/usage.jsonl; "$US" log --slug s2 --role x --in 1; ls .sdkit/work/s2 2>/dev/null | wc -l | tr -d ' ')" 0
printf 'USAGE_LOG=1\n' >> .sdkit/sdkit.env

echo "multiple models, sessions, origins"
rm -f "$L"
lg orchestrator session-m m-a 1000000 0 --session s1; lg orchestrator session-m m-b 1000000 0 --session s1
printf '%s' '{"version":2,"models":[{"model":"m-a","in":3,"out":0},{"model":"m-b","in":10,"out":0}]}' > .sdkit/pricing.json
eq "each model is priced at its own rate"                                "$(jv '.by_model|map("\(.model)=\(.cost_usd)")|join(",")' "$US" report s1 --json)" "m-a=3,m-b=10"
eq "...and the total is the sum"                                         "$(jv .totals.cost_usd "$US" report s1 --json)" 13
rm -f "$L"
{ ln o1 orchestrator m-a 100 10 0 0 '{"id":"session-s1","session":"s1","ts":"2026-03-01T10:00:00Z"}'; ln a1 analyst m-a 50 5 0 0 '{"session":"s1"}'
  ln o2 orchestrator m-a 200 20 0 0 '{"id":"session-s2","session":"s2","ts":"2026-03-02T10:00:00Z","origin":"observed"}'; } > "$L"
printf '%s' "$P1" > .sdkit/pricing.json
eq "--session narrows to one session"                                    "$(jv '[.totals.in,.totals.runs]|join(",")' "$US" report s1 --session s1 --json)" "150,2"
eq "...the other session separately"                                     "$(jv '.totals.in' "$US" report s1 --session s2 --json)" 200
eq "--session current picks the session of the newest record"            "$(jv .totals.in "$US" report s1 --session current --json)" 200
eq "everything together"                                                 "$(jv .totals.in "$US" report s1 --json)" 350
eq "sessions are listed when there are several"                          "$("$US" report s1 | grep -c '^s[12] ')" 2
eq "origins are told apart (sdk vs observed)"                            "$(jv '.by_origin|map("\(.origin)=\(.runs)")|join(",")' "$US" report s1 --json)" "observed=1,sdk=2"
rm -f "$L"
{ ln a1 analyst m-a 50 5 0 0 '{"session":"s9"}'; ln a2 developer m-a 50 5 0 0 '{"session":"s9"}'; } > "$L"
check "partial session: agent runs with no orchestrator record warn"      bash -c "'$US' report s1 | grep -q 'session s9 has agent runs but no orchestrator record'"
eq "...and the total is partial"                                         "$(jv .partial "$US" report s1 --json)" true

echo "missing agent executions"
rm -f "$L"; ln a1 analyst m-a 10 1 0 0 > "$L"; ln o1 orchestrator m-a 10 1 0 0 '{"id":"session-s1"}' >> "$L"
printf '{"spawns":3}\n' > .sdkit/work/s1/state.json
check "spawns counted but not in the ledger are reported as missing"     bash -c "'$US' report s1 | grep -q '3 subagent spawn(s) were counted for this task but only 1 have a ledger record: 2 execution(s) are missing'"
printf '{"spawns":1}\n' > .sdkit/work/s1/state.json
nocheck "no warning when every spawn has a record"                       bash -c "'$US' report s1 | grep -q 'spawn(s) were counted'"
rm -f .sdkit/work/s1/state.json
echo '{"ts":"2026-01-01T00:00:00Z","role":"developer","tier":"","host":"h","model":"m-a","id":"","source":"","in":5,"out":5,"cache_read":0,"cache_write":0}' > "$L"
eq "a pre-F07 line (no session, origin, kind) still reports"             "$(jv '[.totals.in,.totals.priced]|join(",")' "$US" report s1 --json)" "5,1"
check "...with a warning that it cannot be deduplicated"                 bash -c "'$US' report s1 | grep -q '1 legacy line(s) have no execution id'"

echo "project scope and archive"
rm -f "$L"; ln a1 developer m-a 10 1 0 0 > "$L"; mkdir -p .sdkit/work/_archive; ln z9 developer m-a 90 1 0 0 > .sdkit/work/_archive/old.usage.jsonl
eq "default scope is the open tasks only (unchanged)"                    "$(jv .totals.in "$US" report --json)" 10
eq "--project adds archived tasks"                                       "$(jv .totals.in "$US" report --project --json)" 100
eq "no ledger: the old message"                                          "$(cd "$T" && mkdir -p empty/.sdkit && cd empty && git init -q . && printf 'USAGE_LOG=1\n' > .sdkit/sdkit.env && CLAUDE_PROJECT_DIR="$T/empty" "$US" report)" "no usage recorded (set USAGE_LOG=1 in sdkit.env)"

echo "the Claude hook"
HK="$KIT/hooks/usage-log.sh"
R="$(newrepo hook)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"; printf '%s' "$P1" > .sdkit/pricing.json; mkdir -p .sdkit/work/h1
printf '{"spawns":0}' > .sdkit/work/h1/state.json
sess="$T/sess"; mkdir -p "$sess/main/subagents"
{ asst om1 m-a 10; asst om1 m-a 100; asst om2 m-b 50; } > "$sess/main.jsonl"
{ asst sa1 m-a 5; asst sa1 m-a 60; } > "$sess/main/subagents/agent-ag1.jsonl"
stop() { jq -nc --arg t "$sess/main.jsonl" --arg a "${1:-}" --arg id "${2:-}" --arg ty "${3:-analyst}" '{hook_event_name:"SubagentStop", session_id:"sess1", transcript_path:$t, agent_type:$ty, agent_id:$id} + (if $a == "" then {} else {agent_transcript_path:$a} end)' | "$HK"; }
turn() { jq -nc --arg t "$sess/main.jsonl" '{hook_event_name:"Stop", session_id:"sess1", transcript_path:$t}' | "$HK"; }
stop "$sess/main/subagents/agent-ag1.jsonl" ag1 "spec-driven-kit:analyst"
eq "SubagentStop with an agent path logs the subagent (role, id, kind)"  "$(jq -r '[.role,.id,.kind,.session,.origin]|join(",")' .sdkit/work/h1/usage.jsonl | head -1)" "analyst,ag1,final,sess1,sdk"
eq "...with its streamed output counted at the max (60)"                 "$(jq -r .out .sdkit/work/h1/usage.jsonl | head -1)" 60
eq "...the provider read from the transcript (none shown: empty)"        "$(jq -r .provider .sdkit/work/h1/usage.jsonl | head -1)" ""
stop "" ag1 analyst
eq "no agent path: the transcript is found under <session>/subagents/"   "$(grep -c '"id":"ag1"' .sdkit/work/h1/usage.jsonl)" 1
rm -f .sdkit/work/h1/usage.jsonl
stop "" agX analyst
eq "an unreadable subagent leaves an unmeasured mark, not nothing"       "$(jq -r '[.id,.tq,.kind]|join(",")' .sdkit/work/h1/usage.jsonl)" "agX,unavailable,final"
eq "the parent transcript is never booked under a subagent"              "$(grep -c '"out":150' .sdkit/work/h1/usage.jsonl)" 0
rm -f .sdkit/work/h1/usage.jsonl
turn
eq "Stop logs the orchestrator as a snapshot, one line per model"        "$(jq -rs 'map("\(.model):\(.out):\(.kind)")|sort|join(",")' .sdkit/work/h1/usage.jsonl)" "m-a:100:snapshot,m-b:50:snapshot"
{ asst om1 m-a 100; asst om2 m-b 50; asst om3 m-a 25; } > "$sess/main.jsonl"; turn
eq "the next turn replaces its own snapshot (no growth in lines)"        "$(grep -c . .sdkit/work/h1/usage.jsonl)" 2
eq "...with the larger reading"                                          "$(jq -rs 'map(select(.model=="m-a").out)|add' .sdkit/work/h1/usage.jsonl)" 125
eq "the session total is therefore each message once (175)"              "$(jv .totals.out "$US" report h1 --json)" 175
USAGE_LOG=1 TELEMETRY= bash -c "echo '{}' | '$HK'"; eq "an empty payload exits 0 silently" "$?" 0
rm -f .sdkit/work/h1/usage.jsonl; stop "$sess/main/subagents/agent-ag1.jsonl" ag1 analyst; turn
eq "orchestrator + analyst are both accounted"                           "$(jv '.by_role|map(.role)|sort|join(",")' "$US" report h1 --json)" "analyst,orchestrator"
eq "...the hook runs again without duplicating anything"                 "$(stop "$sess/main/subagents/agent-ag1.jsonl" ag1 analyst; turn; jv '[.totals.runs,.coverage.duplicates_collapsed]|join(",")' "$US" report h1 --json)" "2,0"

echo "the usage line (USAGE_LINE=1)"
um() { USAGE_LINE=1 stop "$@" | jq -r '.systemMessage // empty'; }
{ asst sl1 m-a 1800 u1 8000; } > "$sess/main/subagents/agent-ag2.jsonl"
eq "a finished subagent prints in, out and cache hit"                    "$(um "$sess/main/subagents/agent-ag2.jsonl" ag2 spec-driven-kit:verifier)" "[sdkit] verifier done — in: 8.0k, out: 1.8k, cache hit: 99%"
eq "an unreadable transcript says so instead of showing numbers"        "$(um "" agNone verifier)" "[sdkit] verifier done — token usage not available (the host gave no data)"
eq "off unless USAGE_LINE=1"                                             "$(stop "$sess/main/subagents/agent-ag2.jsonl" ag2 verifier)" ""
eq "works without USAGE_LOG"                                             "$(USAGE_LOG= USAGE_LINE=1 stop "$sess/main/subagents/agent-ag2.jsonl" ag2 verifier | jq -r .systemMessage)" "[sdkit] verifier done — in: 8.0k, out: 1.8k, cache hit: 99%"
eq "a Stop (not a subagent) prints no line"                              "$(USAGE_LINE=1 turn)" ""

echo "scan: sessions the hooks never saw"
tr="$T/proj"; mkdir -p "$tr/sessA/subagents"
{ asst x1 m-a 30; asst x2 m-a 40; } > "$tr/sessA.jsonl"; { asst y1 m-a 5; asst y1 m-a 15; } > "$tr/sessA/subagents/agent-agA.jsonl"
printf '{"agentType":"spec-driven-kit:reviewer","finished":true}' > "$tr/sessA/subagents/agent-agA.meta.json"
R="$(newrepo scan)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"; printf '%s' "$P1" > .sdkit/pricing.json
"$US" scan --dir "$tr" --session sessA --slug sc >/dev/null
eq "scan logs the orchestrator and the subagent as observed"             "$(jv '.by_origin|map("\(.origin)=\(.runs)")|join(",")' "$US" report sc --json)" "observed=2"
eq "...role from the subagent's meta file, final from finished:true"    "$(jq -rs 'map(select(.id=="agA"))|map("\(.role):\(.kind)")|join(",")' .sdkit/work/sc/usage.jsonl)" "reviewer:final"
eq "...tokens at the max per message"                                    "$(jv .totals.out "$US" report sc --json)" 85
"$US" scan --dir "$tr" --session sessA --slug sc >/dev/null
eq "scanning again changes nothing (stable ids)"                         "$(jv '[.totals.runs,.totals.out]|join(",")' "$US" report sc --json)" "2,85"
rm -f .sdkit/work/sc/usage.jsonl
jq -nc '{hook_event_name:"Stop",session_id:"sessA",transcript_path:"'"$tr"'/sessA.jsonl"}' | "$HK"
"$US" scan --dir "$tr" --session sessA --slug sc >/dev/null
eq "a session the hook already logged is not counted twice by scan"      "$(jv '[.totals.runs,.totals.out]|join(",")' "$US" report sc --json)" "2,85"
nocheck "scan without a transcript directory fails clearly"              "$US" scan --dir "$T/nowhere"

echo "older readers and workflows keep working"
R="$(newrepo compat)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
printf 'TELEMETRY=1\n' >> .sdkit/sdkit.env
"$US" log --slug k1 --role developer --id k --model m-a --in 1000000 --out 0 --kind final >/dev/null
printf '%s' '{"version":2,"models":[{"model":"m-a","effective_from":"2026-01-01","in":3,"out":15}]}' > .sdkit/pricing.json
"$KIT/scripts/telemetry.sh" emit agent.end --task k1 --role developer --model m-a --in 1000000 --out 0 --q tokens=actual >/dev/null
eq "telemetry.sh summary reads a v2 table (same numbers)"                "$("$KIT/scripts/telemetry.sh" summary k1 --json | jq -r '.cost.usd')" 3
eq "the old 'log' options still work (no --id, no session)"              "$("$US" log --slug k2 --role developer --in 3 --out 4 >/dev/null; jq -r '[.role,.in,.out,.id]|join(",")' .sdkit/work/k2/usage.jsonl)" "developer,3,4,"
eq "token budget still counts in + out + cache_write"                    "$(printf 'TOKEN_BUDGET_TASK=100\n' >> .sdkit/sdkit.env; "$US" log --slug k3 --role d --in 10 --out 20 --cache-read 999 --cache-write 5 >/dev/null; "$US" budget k3 | grep -o '[0-9]* of 100')" "35 of 100"
check "the report's old headline strings survive"                         bash -c "'$US' report k3 | grep -q 'cache hit rate:'"

echo "a session that serves several tasks, and a subagent the hook could not read"
R="$(newrepo win)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"; mkdir -p .sdkit/work/w1 .sdkit/.sdd; echo '{}' > .sdkit/work/w1/state.json
printf '{"task":"w1","startedAt":"2026-03-01T10:00:00Z"}' > .sdkit/.sdd/state.json
atx() { jq -nc --arg id "$1" --argjson o "$2" --arg ts "$3" '{type:"assistant", uuid:("u-"+$id), sessionId:"sessW", timestamp:$ts, message:{id:$id, model:"m-a", usage:{input_tokens:1, output_tokens:$o, cache_read_input_tokens:1000, cache_creation_input_tokens:10}}}'; }
{ atx e1 100 "2026-03-01T09:00:00.500Z"; atx e2 40 "2026-03-01T10:00:00.200Z"; atx e3 7 "2026-03-01T11:00:00.000Z"; } > "$T/win.jsonl"
eq "extract --since counts only the requests from the task start on"       "$(jv '[.messages,.out,.cache_read]|join(",")' "$US" extract "$T/win.jsonl" --since 2026-03-01T10:00:00Z)" "2,47,2000"
eq "...without --since the whole session counts"                            "$(jv .out "$US" extract "$T/win.jsonl")" 147
eq "window prints the open task's start"                                    "$("$US" window)" "2026-03-01T10:00:00Z"
printf '{"task":"other","startedAt":"2026-03-01T10:00:00Z"}' > .sdkit/.sdd/state.json
eq "...nothing when the open task is not the active slug's"                 "$("$US" window)" ""
printf '{"task":"w1","startedAt":"2026-03-01T10:00:00Z"}' > .sdkit/.sdd/state.json
jq -nc --arg t "$T/win.jsonl" '{hook_event_name:"Stop", session_id:"sessW", transcript_path:$t}' | "$HK"
eq "the Stop hook books the orchestrator from the task start (47, not 147)" "$(jq -rs 'map(.out)|add' .sdkit/work/w1/usage.jsonl)" 47
# a subagent whose payload has no agent_type: the role comes from the .meta.json next to its transcript
mkdir -p "$T/tdir/sessW/subagents"; { atx s1 25 "2026-03-01T10:30:00.000Z"; } > "$T/tdir/sessW/subagents/agent-agM.jsonl"
printf '{"agentType":"spec-driven-kit:analyst","finished":true}' > "$T/tdir/sessW/subagents/agent-agM.meta.json"
rm -f .sdkit/work/w1/usage.jsonl
jq -nc --arg a "$T/tdir/sessW/subagents/agent-agM.jsonl" '{hook_event_name:"SubagentStop", session_id:"sessW", transcript_path:"/none", agent_transcript_path:$a, agent_id:"agM"}' | "$HK"
eq "a SubagentStop without agent_type takes the role from the meta file"    "$(jq -r '[.role,.id,.out]|join(",")' .sdkit/work/w1/usage.jsonl)" "analyst,agM,25"
# the hook ran before the transcript existed: unmeasured mark; reconcile fills it in later
rm -f .sdkit/work/w1/usage.jsonl; { atx s2 60 "2026-03-01T10:40:00.000Z"; } > "$T/tdir/sessW/subagents/agent-agL.jsonl.later"
jq -nc '{hook_event_name:"SubagentStop", session_id:"sessW", transcript_path:"/none", agent_id:"agL"}' | "$HK"
eq "an unreadable subagent without a type is an unmeasured 'subagent'"      "$(jq -r '[.role,.tq]|join(",")' .sdkit/work/w1/usage.jsonl)" "subagent,unavailable"
mv "$T/tdir/sessW/subagents/agent-agL.jsonl.later" "$T/tdir/sessW/subagents/agent-agL.jsonl"
printf '{"agentType":"spec-driven-kit:reviewer"}' > "$T/tdir/sessW/subagents/agent-agL.meta.json"
eq "reconcile reports the lines it wrote"                                   "$(CLAUDE_TRANSCRIPT_DIR="$T/tdir" "$US" reconcile --slug w1)" 1
eq "...the unmeasured mark is replaced by the measured run (role, tokens)"  "$(jq -rs 'map("\(.role):\(.tq // "actual"):\(.out)")|join(",")' .sdkit/work/w1/usage.jsonl)" "reviewer:actual:60"
eq "...and a second reconcile finds nothing left to do"                     "$(CLAUDE_TRANSCRIPT_DIR="$T/tdir" "$US" reconcile --slug w1)" 0

echo
echo "usage: $pass passed, $fail failed"
[ "$fail" = 0 ]
