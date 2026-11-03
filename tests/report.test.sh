#!/usr/bin/env bash
# Value Report, slim: a finalized task report (tokens, cost, routing savings, avoided work), idempotency, terminal states never read as success, missing
# pricing / baseline, display safety, session reports, the SessionEnd hook, abort, REPORT_EXPORT, and that reporting never calls a model.
# Fixture ledgers and events only. Run: tests/report.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
RP="$KIT/scripts/report.sh"; US="$KIT/scripts/usage.sh"; TL="$KIT/scripts/telemetry.sh"; SDD="$KIT/scripts/sdd.sh"
has()   { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1 (found '$3')"; else ok "$1"; fi; }

# no model may be reached: every host CLI on PATH is a trap that leaves a marker
mkdir -p "$T/trap"; for c in claude codex opencode cursor-agent gemini curl; do printf '#!/bin/sh\necho %s >> "%s/called"\nexit 1\n' "$c" "$T" > "$T/trap/$c"; chmod +x "$T/trap/$c"; done
export PATH="$T/trap:$KIT/tests/stubs:$PATH"

# mk <name> [baseline-model] [pricing yes|no]: a scratch project with a priced ledger, events, routing, context and selection records for task t1
mk() {
  R="$T/$1"; git_repo "$R"; mkdir -p "$R/.sdkit/work/t1"; cd "$R" || exit 1
  printf 'STACK=generic\nTELEMETRY=1\nUSAGE_LOG=1\nVALUE_REPORT=on\nREPORT_BASELINE_MODEL=%s\n' "${2-m-big}" > .sdkit/sdkit.env
  export CLAUDE_PROJECT_DIR="$R"
  [ "${3:-yes}" = yes ] && cat > .sdkit/pricing.json <<'J'
{"version":2,"currency":"USD","models":[{"model":"m-big","in":15,"out":75,"cache_read":1.5,"cache_write":18.75},{"model":"m-small","in":3,"out":15,"cache_read":0.3,"cache_write":3.75}]}
J
  L() { "$US" log "$@" --slug t1 >/dev/null; }
  L --role orchestrator --model m-big --in 1000 --out 2000 --cache-read 50000 --cache-write 4000 --id session-s1 --session s1 --kind final
  L --role developer --model m-small --in 2000 --out 5000 --cache-read 20000 --cache-write 3000 --id a1 --session s1 --kind final
  L --role verifier --model m-small --in 500 --out 800 --id a2 --session s1 --kind final
  E() { "$TL" emit "$@" --task t1 >/dev/null 2>&1; }
  E task.start --risk medium --profile standard --phase intake
  E test.result --phase red --outcome fail --dur-ms 1000; E test.result --phase green --outcome pass --dur-ms 2000
  E verify.result --outcome PASS --source verifier --role verifier; E task.end --outcome completed
  printf '{"type":"decision","id":"d1","role":"verifier","action":"execute","reason":"ROLE_CAPABILITY_MATCH","budget":{"task":1}}\n{"type":"decision","id":"d2","role":"verifier","action":"reuse","reason":"EVIDENCE_REUSED","budget":{}}\n{"type":"decision","id":"d3","role":"reviewer","action":"stop","reason":"DUPLICATE_COMPLETED","budget":{}}\n' > .sdkit/work/t1/routing.jsonl
  printf '{"full_bytes":8000,"shown_bytes":1000,"kind":"output"}\n' > .sdkit/work/t1/context.jsonl
  printf '{"ran":1,"cached":2,"skipped_suites":9,"cached_s":12,"ran_s":3}\n' > .sdkit/work/t1/selection.jsonl
}
J() { jq -r "$1" "$(ls "$R"/.sdkit/work/_reports/task/t1@*.json | head -1)"; }

echo "# normal completion: tokens, cost, savings, avoided work"
mk n
out="$("$RP" finalize --status completed --slug t1 2>&1)"
has "compact report names the terminal status and roles" "$out" "t1 ended COMPLETED"
has "...and the next step"                    "$out" "sdkit report task t1 --detailed"
eq  "status, executions by distinct id, primary model" "$(J '[.task.status,.executions.total,.task.primary_model]|join(",")')" completed,3,m-big
eq  "four token categories kept apart, fresh excludes cache" "$(J '[.tokens.in,.tokens.out,.tokens.cache_read,.tokens.cache_write,.tokens.fresh,.tokens.total]|join(",")')" "3500,7800,70000,7000,18300,88300"
eq  "cost from the canonical resolver; billed never invented" "$(J '[.cost.api_equivalent_usd,(.cost.billed|startswith("unavailable"))]|join(",")')" "0.4268,true"
eq  "tests: red failure is expected; gate from the verdict" "$(J '[.task.tests.passed,.task.tests.failed,.task.tests.red_expected,.task.quality_gates.state]|join(",")')" "1,0,1,Passed"
# hand-computed: developer 0.09825 vs 0.49125, verifier 0.0135 vs 0.0675 => 0.447
eq  "routing delta vs the baseline model, labelled estimated" "$(J '[.savings.routing.delta_usd,.savings.cost.kind,.savings.cost.confidence,(.savings.cost.components[0].source|test("baseline model m-big"))]|join(",")')" "0.447,estimated,low,true"
eq  "reuse and duplicate skip counted; only the comparable one priced" "$(J '[.savings.avoided.by_class.evidence_reuse,.savings.avoided.by_class.skipped_redundant,([.savings.avoided.items[]|select(.cls=="evidence_reuse")|.quantified][0]),([.savings.avoided.items[]|select(.cls=="skipped_redundant")|.quantified][0])]|join(",")')" "1,1,true,false"
eq  "token baseline = actual + avoided; token and dollar rates differ" "$(J '[.savings.tokens.baseline_tokens,.savings.tokens.rate_pct,([.savings.tokens.rate_pct,.savings.cost.rate_pct]|unique|length)]|join(",")')" "19600,6.6,2"
d="$("$RP" task t1 --detailed)"
for o in "Intelligent routing" "Evidence reuse" "Test selection" "Context optimization"; do has "optimization listed: $o" "$d" "$o"; done
has "provider caching is not credited to SDKit"  "$d" "provider prompt caching, not SDKit"

echo "# idempotency"
sha1="$(shasum "$R"/.sdkit/work/_reports/task/t1@*.json | cut -d' ' -f1)"
has "second finalize does nothing"            "$("$RP" finalize --status completed --slug t1 2>&1)" "already exists"
eq  "report unchanged, one index line"        "$(shasum "$R"/.sdkit/work/_reports/task/t1@*.json | cut -d' ' -f1) $(grep -c . .sdkit/work/_reports/index.jsonl)" "$sha1 1"
"$RP" finalize --status completed --slug t1 --force --quiet; "$RP" regenerate task t1 >/dev/null
eq  "--force and regenerate keep one index line, flag regenerated" "$(grep -c . .sdkit/work/_reports/index.jsonl) $(J .regenerated)" "1 true"

echo "# failed and partial are never described as success"
mk s-failed; o="$("$RP" finalize --status failed --slug t1 2>&1)"
has "failed is stated"                        "$o" "t1 ended FAILED"; hasnt "failed never says COMPLETED" "$o" "COMPLETED"
eq  "stored as terminal"                      "$(J '.task.terminal')" true
"$TL" emit contract.check --task t1 --contract c1 --cv 1 --stage result --outcome valid --status partial --role developer >/dev/null 2>&1
"$RP" finalize --status completed --slug t1 --force --quiet
eq  "a partial agent result makes a requested-completed task partial" "$(J '[.task.status,.task.status_requested]|join(",")')" partial,completed

echo "# missing pricing and baseline: unavailable, not zero"
mk nop "" no; "$RP" finalize --status completed --slug t1 --quiet
eq  "no pricing: cost unavailable, savings N/A" "$(J '[.cost.state,.savings.cost.state]|join(",")')" unavailable,na
eq  "no baseline model: routing N/A with a reason and a warning" "$(J '[.savings.routing.state,.savings.routing.reason,(.warnings|join(" ")|contains("REPORT_BASELINE_MODEL is not set"))]|join("|")')" "na|no REPORT_BASELINE_MODEL configured|true"

echo "# regression, unmeasured runs, duplicates and display safety"
mk var m-small
"$US" log --role developer --model m-big --in 1000 --out 1000 --id a9 --session s1 --kind final --slug t1 >/dev/null
"$US" log --role scout --model m-small --id a7 --session s1 --kind final --tq unavailable --slug t1 >/dev/null
"$US" log --role reviewer --model m-small --in 100 --out 100 --id rr-1-2 --session s1 --kind final --slug t1 >/dev/null
l="$(sed -n 2p .sdkit/work/t1/usage.jsonl)"; printf '%s\n%s\n' "$l" "$l" >> .sdkit/work/t1/usage.jsonl
esc="$(printf '\033')"; "$US" log --role "ev${esc}[31m|il" --model "m${esc}]0;x" --in 1 --out 1 --id a8 --session s1 --kind final --slug t1 >/dev/null
printf '' > .sdkit/work/t1/routing.jsonl; "$RP" finalize --status completed --slug t1 --quiet
eq  "a run on a dearer model is a shown regression" "$(J '[.savings.cost.regression,(.savings.cost.saved_usd < 0)]|join(",")')" true,true
eq  "an unmeasured run: counted, tokens partial, role row null" "$(J '[.executions.unmeasured,.tokens.state,([.roles[]|select(.role=="scout")|.tokens]|.[0]|tostring)]|join(",")')" "1,partial,null"
eq  "duplicate ledger lines count once; run-role execution is a host-agent" "$(J '[([.roles[]|select(.role=="developer" and .model=="m-small")|.runs]|add),([.roles[]|select(.role=="reviewer")|.kind]|.[0])]|join(",")')" "1,host-agent"
o="$("$RP" task t1 --detailed; "$RP" task t1; "$RP" task t1 --markdown)"
eq  "no escape character reaches the terminal or the stored report" "$(printf '%s' "$o" | LC_ALL=C grep -c "$esc") $(LC_ALL=C grep -c "$esc" .sdkit/work/_reports/task/t1@*.json)" "0 0"
md="$("$RP" task t1 --markdown)"
eq  "a pipe in a name cannot break a Markdown row" "$(printf '%s\n' "$md" | grep -c '/il ')" 1
for h in "### A. Task Overview" "### C. Token & Cost Breakdown" "### D. SDKit Optimization Impact"; do has "markdown has: $h" "$md" "$h"; done
eq  "--json carries the schema; no prompt or transcript text is stored" "$("$RP" task t1 --json | jq -r .schema) $(grep -ciE '"prompt"|transcript_path|"message"|"content"' .sdkit/work/_reports/task/*.json)" "value-report/1 0"

echo "# sessions"
mkdir -p .sdkit/work/t2; "$US" log --role developer --model m-small --in 100 --out 100 --id b1 --session s9 --kind final --slug t2 >/dev/null
"$US" log --role developer --model m-small --in 7 --out 7 --id c1 --session s9 --kind final --slug t2 >/dev/null
eq  "unended session is running; sums only its own executions" "$("$RP" session s9 --json | jq -r '[.session.state,.executions.total,.tokens.total]|join(",")')" "running,2,214"
"$RP" session-end --session s1 --reason logout --quiet
eq  "a true end signal marks it ended, reason kept" "$("$RP" session s1 --json | jq -r '[.session.state,.session.end_reason]|join(",")')" ended,logout
"$US" log --role developer --model m-small --in 5 --out 5 --id d1 --session s10 --kind final --slug t2 >/dev/null
"$RP" recover --session s10 --quiet
eq  "recovery marks an older session interrupted, leaves the current one and ended ones alone" "$(jq -r .session.state .sdkit/work/_reports/session/s9.json)/$([ -f .sdkit/work/_reports/session/s10.json ] && echo stored || echo none)/$(jq -r .session.state .sdkit/work/_reports/session/s1.json)" interrupted/none/ended
has "interrupted wording"                     "$("$RP" session s9)" "[not a confirmed session end]"

echo "# hooks, abort and export"
rm -rf .sdkit/work/_reports
echo '{"hook_event_name":"SessionEnd","session_id":"s1","reason":"other"}' | "$KIT/hooks/value-report.sh" >/dev/null 2>&1
eq  "SessionEnd hook stores the summary"      "$(jq -r .session.state .sdkit/work/_reports/session/s1.json)" ended
sed -i.bak '/VALUE_REPORT/d' .sdkit/sdkit.env; rm -rf .sdkit/work/_reports
echo '{"hook_event_name":"SessionEnd","session_id":"s1"}' | "$KIT/hooks/value-report.sh" >/dev/null 2>&1; "$RP" finalize --status completed --slug t1 >/dev/null 2>&1
eq  "VALUE_REPORT off: nothing is written"    "$(ls .sdkit/work/_reports 2>/dev/null | wc -l | tr -d ' ')" 0
eq  "...and nothing is exported without REPORT_EXPORT" "$([ -e .sdkit/reports ] && echo yes || echo no)" no
printf 'VALUE_REPORT=on\nREPORT_EXPORT=on\n' >> .sdkit/sdkit.env; printf '## Definition of Done\n- D1: x | Verified by: unit test\n' > prop.md
"$SDD" start t1 --risk low --proposal prop.md >/dev/null 2>&1
o="$("$SDD" abort failed 2>&1)"
has "sdd.sh abort failed prints a FAILED report" "$o" "t1 ended FAILED"
eq  "...stored as failed, and exported as json and markdown" "$(J .task.status) $(jq -r '.task.id' .sdkit/reports/t1.json 2>/dev/null) $(grep -c t1 .sdkit/reports/t1.md 2>/dev/null | grep -c '[1-9]')" "failed t1 1"

echo "# no model call"
eq  "no host CLI or network tool was called"  "$([ -e "$T/called" ] && cat "$T/called" || echo none)" none

finish report
