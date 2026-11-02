#!/usr/bin/env bash
# Value Report tests: task and session reports, terminal states, savings arithmetic and honesty, deduplication, idempotency, display safety, exports,
# the hooks, and the guarantee that reporting calls no model. Deterministic: fixture ledgers and events only, no host CLI, no network. Run: tests/slow/report.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"; RP="$KIT/scripts/report.sh"; US="$KIT/scripts/usage.sh"; TL="$KIT/scripts/telemetry.sh"; SDD="$KIT/scripts/sdd.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (missing '$3')"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then failed=$((failed + 1)); echo "  FAIL $1 (found '$3')"; else pass=$((pass + 1)); echo "  ok   $1"; fi; }

# no model may be reached: every host CLI on PATH is a trap that leaves a marker
mkdir -p "$T/trap"; for c in claude codex opencode cursor-agent gemini curl; do printf '#!/bin/sh\necho %s >> "%s/called"\nexit 1\n' "$c" "$T" > "$T/trap/$c"; chmod +x "$T/trap/$c"; done
export PATH="$T/trap:$PATH"

# mk <name> [baseline-model] [pricing yes|no]: a scratch project with a priced ledger, events, routing, context and selection records for task t1
mk() {
  R="$T/$1"; mkdir -p "$R/.sdkit/work/t1"; cd "$R" && git init -q . && git config user.email t@t && git config user.name t
  printf 'STACK=generic\nTELEMETRY=1\nUSAGE_LOG=1\nVALUE_REPORT=on\nREPORT_BASELINE_MODEL=%s\n' "${2-m-big}" > .sdkit/sdkit.env; echo x > f; git add -A; git commit -qm i
  export CLAUDE_PROJECT_DIR="$R"
  [ "${3:-yes}" = yes ] && cat > .sdkit/pricing.json <<'J'
{"version":2,"currency":"USD","models":[{"model":"m-big","in":15,"out":75,"cache_read":1.5,"cache_write":18.75},{"model":"m-small","in":3,"out":15,"cache_read":0.3,"cache_write":3.75}]}
J
  L() { "$US" log "$@" --slug t1 >/dev/null; }
  L --role orchestrator --model m-big --in 1000 --out 2000 --cache-read 50000 --cache-write 4000 --id session-s1 --session s1 --kind final
  L --role developer --model m-small --in 2000 --out 5000 --cache-read 20000 --cache-write 3000 --id a1 --session s1 --kind final
  L --role verifier --model m-small --in 500 --out 800 --id a2 --session s1 --kind final
  E() { "$TL" emit "$@" --task t1 >/dev/null 2>&1; }
  E task.start --risk medium --profile standard --phase intake; E phase.enter --from intake --to proposed
  E test.result --phase red --outcome fail --dur-ms 1000; E test.result --phase green --outcome pass --dur-ms 2000
  E phase.reject --phase verified --category gate --reason no-verdict
  E verify.result --outcome PASS --source verifier --role verifier; E phase.enter --from green --to verified; E task.end --outcome completed
  printf '{"type":"decision","id":"d1","role":"verifier","action":"execute","reason":"ROLE_CAPABILITY_MATCH","budget":{"task":1}}\n{"type":"decision","id":"d2","role":"verifier","action":"reuse","reason":"EVIDENCE_REUSED","budget":{}}\n{"type":"decision","id":"d3","role":"reviewer","action":"stop","reason":"DUPLICATE_COMPLETED","budget":{}}\n' > .sdkit/work/t1/routing.jsonl
  printf '{"full_bytes":8000,"shown_bytes":1000,"kind":"output"}\n' > .sdkit/work/t1/context.jsonl
  printf '{"ran":1,"cached":2,"skipped_suites":9,"cached_s":12,"ran_s":3}\n' > .sdkit/work/t1/selection.jsonl
}
J() { jq -r "$1" "$(ls "$R"/.sdkit/work/_reports/task/t1@*.json | head -1)"; }

echo "# normal completion"
mk n
out="$("$RP" finalize --status completed --slug t1 2>&1)"
has "compact report is printed"               "$out" "SDKit Value Report"
has "terminal status is explicit"             "$out" "t1 ended COMPLETED"
has "roles are listed"                        "$out" "developer [subagent] m-small"
has "the next step is named"                  "$out" "sdkit report task t1 --detailed"
eq  "status stored"                           "$(J .task.status)" completed
eq  "executions counted by distinct id"       "$(J .executions.total)" 3
eq  "all token categories kept apart"         "$(J '[.tokens.in,.tokens.out,.tokens.cache_read,.tokens.cache_write]|join(",")')" "3500,7800,70000,7000"
eq  "cache reads are not newly generated"     "$(J '.tokens.fresh')" 18300
eq  "total is the sum of the four categories" "$(J '.tokens.total')" 88300
eq  "cost from the canonical resolver"        "$(J '.cost.api_equivalent_usd')" 0.4268
eq  "billed is never invented"                "$(J '.cost.billed|startswith("unavailable")')" true
eq  "test results: red failure is expected"   "$(J '[.task.tests.passed,.task.tests.failed,.task.tests.red_expected]|join(",")')" "1,0,1"
eq  "quality gate from the recorded verdict"  "$(J '.task.quality_gates.state')" Passed
eq  "primary model is the busiest one"        "$(J '.task.primary_model')" m-big

echo "# routing savings (hand-computed: developer 0.09825 vs 0.49125, verifier 0.0135 vs 0.0675 => 0.447)"
eq  "routing delta"                           "$(J '.savings.routing.delta_usd')" 0.447
eq  "savings expose their baseline source"    "$(J '.savings.cost.components[0].source|test("baseline model m-big")')" true
eq  "savings are labelled estimated"          "$(J '.savings.cost.kind')" estimated
eq  "savings state their confidence"          "$(J '.savings.cost.confidence')" low
eq  "savings state their coverage"            "$(J '.savings.cost.coverage|test("2 run")')" true

echo "# evidence reuse, skipped executions, optimizations only when observed"
eq  "reuse counted"                           "$(J '.savings.avoided.by_class.evidence_reuse')" 1
eq  "duplicate skip counted"                  "$(J '.savings.avoided.by_class.skipped_redundant')" 1
eq  "reuse priced from this task's own run"   "$(J '[.savings.avoided.items[]|select(.cls=="evidence_reuse")|.quantified][0]')" true
eq  "no comparable run => counted, not priced" "$(J '[.savings.avoided.items[]|select(.cls=="skipped_redundant")|.quantified][0]')" false
eq  "token baseline = actual + avoided"       "$(J '.savings.tokens.baseline_tokens')" 19600
eq  "token rate"                              "$(J '.savings.tokens.rate_pct')" 6.6
eq  "tokens and dollars are separate figures" "$(J '[.savings.tokens.rate_pct,.savings.cost.rate_pct]|unique|length')" 2
d="$("$RP" task t1 --detailed)"
for o in "Intelligent routing" "Evidence reuse" "Skipped redundant agents" "Test selection" "Context optimization" "Budget enforcement" "Workflow enforcement"; do has "optimization listed: $o" "$d" "$o"; done
has "heuristic is labelled and kept out of the rate" "$d" "heuristic, not in the savings rate"
has "cache saving is shown apart from SDKit's"       "$d" "provider prompt caching, not SDKit"
has "test selection reports time apart from tokens"  "$d" "no token claim"

echo "# idempotency"
sha1="$(shasum "$R"/.sdkit/work/_reports/task/t1@*.json | cut -d' ' -f1)"
out2="$("$RP" finalize --status completed --slug t1 2>&1)"
has "second finalize does nothing"            "$out2" "already exists"
eq  "report file unchanged"                   "$(shasum "$R"/.sdkit/work/_reports/task/t1@*.json | cut -d' ' -f1)" "$sha1"
eq  "one index line per report"               "$(grep -c . .sdkit/work/_reports/index.jsonl)" 1
"$RP" finalize --status completed --slug t1 --force --quiet; eq "--force rewrites, still one index line" "$(grep -c . .sdkit/work/_reports/index.jsonl)" 1
eq  "regenerate keeps the key"                "$("$RP" regenerate task t1 | grep -c regenerated)" 1
eq  "regenerated flag set"                    "$(J .regenerated)" true

echo "# failed, blocked, partial: never described as success"
for st in failed blocked aborted; do
  mk "s-$st"; o="$("$RP" finalize --status $st --slug t1 2>&1)"; U="$(printf '%s' "$st" | tr a-z A-Z)"
  has "$st is stated"                         "$o" "t1 ended $U"; hasnt "$st never says COMPLETED" "$o" "COMPLETED"
  eq  "$st stored as terminal"                "$(J '.task.terminal')" true
done
mk part; "$TL" emit contract.check --task t1 --contract c1 --cv 1 --stage result --outcome valid --status partial --role developer >/dev/null 2>&1
"$RP" finalize --status completed --slug t1 --quiet
eq  "a partial agent result makes the task partial" "$(J .task.status)" partial
eq  "the requested status is kept"            "$(J .task.status_requested)" completed
mk live; eq "an open task is a live view, not terminal" "$("$RP" task t1 --json | jq -r '.task.terminal')" false
eq  "live view is not stored"                 "$(ls .sdkit/work/_reports/task 2>/dev/null | wc -l | tr -d ' ')" 0
has "live view says so"                       "$("$RP" task t1)" "t1 is IN-PROGRESS"
eq  "an open task's quality gate is pending, not 'Not run'"  "$("$RP" task t1 --json | jq -r '.task.quality_gates.state')" Pending
eq  "role purposes stay short and are never cut mid-word"    "$("$RP" task t1 --json | jq -r '[.roles[].purpose // empty | select(length > 112)] | length')" 0

echo "# missing pricing, missing baseline, negative savings"
mk nop m-big no; "$RP" finalize --status completed --slug t1 --quiet
eq  "no pricing => cost unavailable, not zero" "$(J '.cost.state')" unavailable
eq  "no pricing => savings N/A"               "$(J '.savings.cost.state')" na
has "N/A wording"                             "$("$RP" task t1)" "N/A — insufficient baseline data"
mk nob ""; "$RP" finalize --status completed --slug t1 --quiet
eq  "no baseline model => routing N/A"        "$(J '.savings.routing.state')" na
eq  "routing reason is given"                 "$(J '.savings.routing.reason')" "no REPORT_BASELINE_MODEL configured"
has "the missing setting is a warning"        "$(J '.warnings|join(" ")')" "REPORT_BASELINE_MODEL is not set"
mk neg m-small; "$RP" finalize --status completed --slug t1 --quiet
eq  "orchestrator on a dearer model: routing is 0 for baseline-model runs" "$(J '.savings.routing.on_baseline')" 2
mk reg m-small
"$US" log --role developer --model m-big --in 1000 --out 1000 --id a9 --session s1 --kind final --slug t1 >/dev/null
printf '' > .sdkit/work/t1/routing.jsonl
"$RP" finalize --status completed --slug t1 --quiet
eq  "a run on a dearer model is a regression" "$(J '.savings.cost.regression')" true
eq  "negative savings are shown"              "$(J '.savings.cost.saved_usd < 0')" true
has "text says REGRESSION"                    "$("$RP" task t1)" "REGRESSION"

echo "# unavailable is not zero; unpriced runs are partial"
mk unav; "$US" log --role scout --model m-small --id a7 --session s1 --kind final --tq unavailable --slug t1 >/dev/null; "$RP" finalize --status completed --slug t1 --quiet
eq  "unmeasured run is counted as unmeasured" "$(J '.executions.unmeasured')" 1
eq  "tokens state is partial, not recorded"   "$(J '.tokens.state')" partial
eq  "role row tokens are null (N/A)"          "$(J '[.roles[]|select(.role=="scout")|.tokens]|.[0]')" null
mk none; rm -f .sdkit/work/t1/usage.jsonl; "$RP" finalize --status completed --slug t1 --quiet
eq  "no ledger at all => tokens unavailable"  "$(J '.tokens.state')" unavailable
eq  "...and no role is invented"              "$(J '.roles|length')" 0

echo "# duplicates, multiple agents and subagents, host agents"
mk dup
l="$(sed -n 2p .sdkit/work/t1/usage.jsonl)"; printf '%s\n%s\n' "$l" "$l" >> .sdkit/work/t1/usage.jsonl
"$US" log --role reviewer --model m-small --in 100 --out 100 --id rr-1-2 --session s1 --kind final --slug t1 >/dev/null
"$US" log --role developer --model m-big --in 10 --out 10 --id a5 --session s1 --kind final --slug t1 >/dev/null
"$RP" finalize --status completed --slug t1 --quiet
eq  "duplicate ledger lines are not counted twice" "$(J '[.roles[]|select(.role=="developer" and .model=="m-small")|.runs]|.[0]')" 1
eq  "the same role on two models is two rows"  "$(J '[.roles[]|select(.role=="developer")]|length')" 2
eq  "a run-role execution is a host-agent"     "$(J '[.roles[]|select(.role=="reviewer")|.kind]|.[0]')" host-agent
eq  "kinds are distinguished"                  "$(J '[.roles[].kind]|unique|join(",")')" "host-agent,orchestrator,subagent"
eq  "total tokens ignore the duplicates"       "$(J .tokens.total)" "$((88300 + 200 + 20))"

echo "# terminal display safety"
mk esc; esc="$(printf '\033')"; "$US" log --role "ev${esc}[31mil" --model "m${esc}]0;x" --in 1 --out 1 --id a8 --session s1 --kind final --slug t1 >/dev/null
"$RP" finalize --status completed --slug t1 --quiet
o="$("$RP" task t1 --detailed; "$RP" task t1; "$RP" task t1 --markdown)"
eq  "no escape character reaches the terminal" "$(printf '%s' "$o" | LC_ALL=C grep -c "$esc")" 0
eq  "no escape character is stored"            "$(LC_ALL=C grep -c "$esc" .sdkit/work/_reports/task/t1@*.json)" 0
mk pipe; "$US" log --role "a|b" --model m-small --in 1 --out 1 --id a8 --session s1 --kind final --slug t1 >/dev/null; "$RP" finalize --status completed --slug t1 --quiet
eq  "a pipe in a name cannot break a Markdown row" "$("$RP" task t1 --markdown | grep -c '^| a/b ')" 1

echo "# exports"
mk ex; "$RP" finalize --status completed --slug t1 --quiet
eq  "--json is valid JSON"                     "$("$RP" task t1 --json | jq -e . >/dev/null 2>&1; echo $?)" 0
eq  "--json carries the schema"                "$("$RP" task t1 --json | jq -r .schema)" value-report/1
md="$("$RP" task t1 --markdown)"
for h in "### A. Task Overview" "### B. Agent & Role Breakdown" "### C. Token & Cost Breakdown" "### D. SDKit Optimization Impact" "| Metric | Value |" "| Estimated API-Equivalent Cost |"; do has "markdown has: $h" "$md" "$h"; done
eq  "latest shows the newest stored report"   "$("$RP" latest --json | jq -r .task.id)" t1
has "history lists the report"                "$("$RP" history)" "t1"
eq  "stored report is small"                  "$([ "$(wc -c < "$(ls .sdkit/work/_reports/task/*.json | head -1)")" -lt 20000 ] && echo yes)" yes
eq  "no prompt or transcript text is stored"  "$(grep -ciE '"prompt"|transcript_path|"message"|"content"' .sdkit/work/_reports/task/*.json)" 0

echo "# sessions"
mk ses; "$RP" finalize --status completed --slug t1 --quiet
mkdir -p .sdkit/work/t2; "$US" log --role developer --model m-small --in 100 --out 100 --id b1 --session s1 --kind final --slug t2 >/dev/null
"$US" log --role developer --model m-small --in 7 --out 7 --id c1 --session s9 --kind final --slug t2 >/dev/null
live="$("$RP" session s1 --json)"
eq  "unended session is not claimed as ended"  "$(jq -r .session.state <<< "$live")" running
has "and says so"                              "$(jq -r .session.note <<< "$live")" "still running"
eq  "session sums unique executions across tasks" "$(jq -r .executions.total <<< "$live")" 4
eq  "session tokens = the sum of both tasks"   "$(jq -r .tokens.total <<< "$live")" "$((88300 + 200))"
eq  "other sessions are excluded"              "$(jq -r '[.roles[].runs]|add' <<< "$live")" 4
eq  "the task report of the session is listed" "$(jq -r .tasks.completed <<< "$live")" 1
"$RP" session-end --session s1 --reason logout --quiet
e="$("$RP" session s1 --json)"
eq  "a true end signal marks it ended"         "$(jq -r .session.state <<< "$e")" ended
eq  "end reason kept"                          "$(jq -r .session.end_reason <<< "$e")" logout
before="$(shasum < .sdkit/work/_reports/session/s1.json)"; "$RP" session-end --session s1 --reason logout --quiet
eq  "repeated session-end keeps one stored report" "$(ls .sdkit/work/_reports/session | wc -l | tr -d ' ')" 1
eq  "session savings: routing from session rows" "$(jq -r .savings.routing_usd <<< "$e")" "$(jq -r .savings.routing.delta_usd <<< "$e")"
has "session text"                             "$("$RP" session s1)" "SDKit Session Summary"
echo "# interrupted sessions are recovered, never called ended"
"$US" log --role developer --model m-small --in 5 --out 5 --id d1 --session s10 --kind final --slug t2 >/dev/null
"$RP" recover --session s10 --quiet
eq  "an older session without an end signal is recovered" "$(jq -r .session.state .sdkit/work/_reports/session/s9.json)" interrupted
eq  "the current session is left alone"        "$([ -f .sdkit/work/_reports/session/s10.json ] && echo stored || echo none)" none
eq  "an ended session is not overwritten by recovery" "$(jq -r .session.state .sdkit/work/_reports/session/s1.json)" ended
has "interrupted wording"                      "$("$RP" session s9)" "[not a confirmed session end]"
"$RP" regenerate session s9 >/dev/null; eq "an interrupted session can be regenerated and stays interrupted" "$(jq -r .session.state .sdkit/work/_reports/session/s9.json)" interrupted
eq  "a child/nested run shares one id and is counted once" "$("$RP" session s1 --json | jq -r '.executions.total')" 4

echo "# hooks and workflow integration"
mk hk
echo '{"hook_event_name":"SessionEnd","session_id":"s1","reason":"other"}' | "$KIT/hooks/value-report.sh" >/dev/null 2>&1; eq "SessionEnd hook stores the summary" "$(jq -r .session.state .sdkit/work/_reports/session/s1.json)" ended
eq  "hook writes nothing on stdout"            "$(echo '{"hook_event_name":"SessionStart","session_id":"zz"}' | "$KIT/hooks/value-report.sh" 2>/dev/null | wc -c | tr -d ' ')" 0
sed -i.bak '/VALUE_REPORT/d' .sdkit/sdkit.env; rm -f .sdkit/sdkit.env.bak; rm -rf .sdkit/work/_reports
echo '{"hook_event_name":"SessionEnd","session_id":"s1"}' | "$KIT/hooks/value-report.sh" >/dev/null 2>&1; "$RP" finalize --status completed --slug t1
eq  "off by default: nothing is written"       "$(ls .sdkit/work/_reports 2>/dev/null | wc -l | tr -d ' ')" 0
mk sd; printf '## Definition of Done\n- D1: x | Verified by: unit test\n' > prop.md
export PATH="$KIT/tests/stubs:$PATH"
"$SDD" start t1 --risk low --proposal prop.md >/dev/null 2>&1
o="$("$SDD" abort failed 2>&1)"
has "sdd.sh abort failed prints a FAILED report" "$o" "t1 ended FAILED"
has "sdd.sh still says what it always said"      "$o" "task aborted"
eq  "stored as failed"                           "$(J .task.status)" failed
"$SDD" start t1 --risk low --proposal prop.md >/dev/null 2>&1; o="$("$SDD" abort 2>&1)"
has "plain abort is reported as aborted"         "$o" "t1 ended ABORTED"
mk sd2; sed -i.bak '/VALUE_REPORT/d' .sdkit/sdkit.env; rm -f .sdkit/sdkit.env.bak; printf '## Definition of Done\n- D1: x | Verified by: unit test\n' > prop.md
"$SDD" start t1 --risk low --proposal prop.md >/dev/null 2>&1; o="$("$SDD" abort 2>&1)"
eq  "VALUE_REPORT off: sdd output is exactly as before" "$o" "task aborted"

echo "# test selection records what it did"
mk ts; cp "$KIT/scripts/test-select.sh" "$KIT/scripts/env.sh" . 2>/dev/null; mkdir -p scripts tests; cp "$KIT/scripts/test-select.sh" "$KIT/scripts/env.sh" scripts/
printf '@all => true ;; true\n^a\\.txt$ => true\n' > tests/test-map.conf; echo a > a.txt; mkdir -p .sdkit/work/t1; echo '{}' > .sdkit/work/t1/state.json
bash scripts/test-select.sh run --files a.txt >/dev/null 2>&1; bash scripts/test-select.sh run --files a.txt >/dev/null 2>&1
eq  "selection.jsonl gets a line per run"      "$(grep -c . .sdkit/work/t1/selection.jsonl)" 3
eq  "the second run reused the cache"          "$(tail -1 .sdkit/work/t1/selection.jsonl | jq .cached)" 1

echo "# no model call, and the overhead"
eq  "no host CLI or network tool was called"   "$([ -e "$T/called" ] && cat "$T/called" || echo none)" none
eq  "the script names no host CLI"             "$(grep -cE '(^|[^a-z_-])(claude|codex|opencode|gemini|cursor-agent|curl|wget) ' "$RP")" 0
mk perf; s0="$(date +%s)"; for i in 1 2 3 4 5; do "$RP" finalize --status completed --slug t1 --force --quiet; done; s1="$(date +%s)"
echo "  info: 5 task reports with a 3-run ledger took $((s1 - s0))s"; eq "report generation is not pathologically slow (5 in under 40s)" "$([ $((s1 - s0)) -lt 40 ] && echo yes)" yes

echo "# export to <project-dir>/reports at the end signal"
mk ex; printf 'REPORT_EXPORT=on\n' >> .sdkit/sdkit.env
"$RP" finalize --status completed --slug t1 --quiet
eq  "REPORT_EXPORT=on: the task report is also written under the task id"  "$(jq -r '.task.id' .sdkit/reports/t1.json 2>/dev/null)" t1
has "...with a readable markdown copy"                                      "$(cat .sdkit/reports/t1.md 2>/dev/null)" "t1"
eq  "...and the working copy stays in work/_reports"                        "$(ls .sdkit/work/_reports/task/t1@*.json 2>/dev/null | head -1 | grep -c .)" 1
rm -rf .sdkit/reports; "$RP" finalize --status completed --slug t1 --quiet
eq  "a second end signal (report exists) still restores a missing export"   "$([ -f .sdkit/reports/t1.json ] && echo yes)" yes
mk ex2; "$RP" finalize --status completed --slug t1 --quiet
eq  "without REPORT_EXPORT nothing is exported"                              "$([ -e .sdkit/reports ] && echo yes || echo no)" no
mk ex3; printf 'REPORT_EXPORT=on\n' >> .sdkit/sdkit.env; "$RP" finalize --status completed --slug t1 --quiet; rm -rf .sdkit/reports
"$RP" session-end --session s1 --reason other --quiet
eq  "a session that served a task is not exported on its own (the task report covers it)" "$([ -e .sdkit/reports/s1.json ] && echo yes || echo no)" no
mk ex4; printf 'REPORT_EXPORT=on\n' >> .sdkit/sdkit.env; "$US" log --role orchestrator --model m-small --in 10 --out 10 --id session-only --session only1 --kind final --slug _misc >/dev/null
"$RP" session-end --session only1 --reason other --quiet
eq  "a session with no task is exported under its session id"               "$(jq -r '.session.id // .session // empty' .sdkit/reports/only1.json 2>/dev/null | head -1)" only1

echo "report: $pass passed, $failed failed"; [ "$failed" = 0 ]
