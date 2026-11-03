#!/usr/bin/env bash
# The task benchmark harness (bench/tbench.sh), simulated only: registry and integrity refusals, strategy rules, metrics parsing, a few simulated runs (success, tests-only tamper, crash),
# immutability, report arithmetic and the fail-closed real-run gate. No model, no network. Fixtures and full validation of all tasks are too slow here (bench/ owns them). Run: tests/tbench.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
TB="$KIT/bench/tbench.sh"
res() { echo "$1/runs/$2/result.json"; }
mkcopy() { local d="$T/$1"; mkdir -p "$d"; cp -R "$KIT/bench/tasks" "$d/tasks"; cp -R "$KIT/bench/evaluator" "$d/evaluator"; cp -R "$KIT/bench/strategies" "$d/strategies"; echo "$d"; }
tbc() { local d="$1"; shift; SDKIT_TBENCH_TASKS="$d/tasks" SDKIT_TBENCH_EVALUATOR="$d/evaluator" SDKIT_TBENCH_STRATEGIES="$d/strategies" "$TB" "$@"; }
tbrun() { "$TB" run --simulate --out "$@"; }

# the slow simulated runs go first, in parallel
O="$T/o"
tbrun "$O" --task T01 --strategy baseline --run-id r-one >/dev/null 2>&1 &
tbrun "$O" --task T01 --strategy sdkit-high-assurance --run-id r-two --sim-metrics none >/dev/null 2>&1 &
tbrun "$O" --task T01 --strategy sdkit-standard --run-id tamper --sim-force tests-only >/dev/null 2>&1 &
tbrun "$O" --task T01 --strategy baseline --run-id crash --sim-force crash >/dev/null 2>&1 &
BG=$!

echo "registry and integrity"
eq "six tasks, 2 low / 2 medium / 2 high"             "$("$TB" tasks | cut -f2 | sort | uniq -c | tr -s ' ' | paste -sd, -)" " 2 high, 2 low, 2 medium"
check "a shipped task validates"                      "$TB" validate T01
C="$(mkcopy c)"; echo "# edited" >> "$C/tasks/T03-paginated-api/starter/app/api.py"
eq "starter change: run refuses with 5 (checksum mismatch)" "$(rc tbc "$C" run --simulate --task T03 --strategy baseline --out "$T/o-mm")" 5
check "...and created no run"                         bash -c "[ -z \"\$(ls '$T/o-mm/runs' 2>/dev/null)\" ]"
echo "# edited" >> "$C/evaluator/T04-cache-race/hidden/test_hidden.py"
eq "hidden test change after sealing is detected"     "$(rc tbc "$C" validate T04)" 5
jq '.title = "changed"' "$C/tasks/T05-authz-bypass/task.json" > "$C/x" && mv "$C/x" "$C/tasks/T05-authz-bypass/task.json"
eq "sealing a changed manifest under the SAME version is refused" "$(rc tbc "$C" seal T05)" 5

echo "strategies"
check "the three strategies validate"                 "$TB" strategies
C="$T/s1"; mkdir -p "$C"; cp -R "$KIT/bench/strategies" "$C/strategies"; jq '.env = {SDD_MODE: "off"}' "$C/strategies/sdkit-standard.json" > "$C/x" && mv "$C/x" "$C/strategies/sdkit-standard.json"
nocheck "a strategy that turns SDD enforcement off is rejected" env SDKIT_TBENCH_STRATEGIES="$C/strategies" "$TB" strategies
C="$T/s2"; mkdir -p "$C"; cp -R "$KIT/bench/strategies" "$C/strategies"; jq '.profile = "standard"' "$C/strategies/baseline.json" > "$C/x" && mv "$C/x" "$C/strategies/baseline.json"
nocheck "a baseline may not carry an SDKit profile"   env SDKIT_TBENCH_STRATEGIES="$C/strategies" "$TB" strategies

echo "metrics parsing"
ing() { printf '%s' "$1" > "$T/m.json"; "$TB" ingest "$T/m.json" "${@:2}"; }
M="$(ing '{"tokens":{"in":100,"out":50,"cache_read":10,"cache_write":5},"tokens_quality":"measured","llm_calls":4}')"
eq "full counts: total = in+out+cache, measured"      "$(jq -c '[.tokens.total, .tokens.total_basis, .tokens.quality]' <<< "$M")" '[165,"all-four","measured"]'
M="$(ing '{}')"
eq "empty metrics: null, never 0, marked unavailable" "$(jq -c '[.tokens.total, .completeness.tokens]' <<< "$M")" '[null,"unavailable"]'
M="$(ing '{"tokens":{"in":100,"out":50},"tokens_quality":"measured"}')"
eq "no cache counts: cache null and total a lower bound" "$(jq -r '[.tokens.cache_read, (.tokens.total_basis | test("lower bound"))] | tostring' <<< "$M")" '[null,true]'
M="$(ing '{"tokens":{"in":100},"tokens_quality":"measured"}')"
eq "missing output tokens: nothing invented"          "$(jq -c '[.tokens.in, .tokens.total, .tokens.quality]' <<< "$M")" '[null,null,"unavailable"]'
M="$(ing '{"tokens":{"in":-1,"out":"many"},"llm_calls":1.5,"tokens_quality":"measured"}')"
eq "invalid numbers become null with warnings"        "$(jq -c '[.tokens.in, .tokens.out, .llm_calls, (.warnings | length >= 3)]' <<< "$M")" '[null,null,null,true]'
M="$(ing '{"tokens":{"in":10,"out":5}}')"
eq "unlabeled usage is estimated, never measured"     "$(jq -r .tokens.quality <<< "$M")" estimated
M="$(ing '{"billing":"subscription","cost":{"provider_usd":2.5}}')"
eq "subscription: USD kept as estimate, no provider cost" "$(jq -c '[.cost.provider_usd, .cost.estimated_usd]' <<< "$M")" '[null,2.5]'
printf '{"m":{"in":3,"out":15,"cache_read":0.3,"cache_write":3.75}}' > "$T/prices.json"
M="$(ing '{"model":"m","tokens":{"in":1000000,"out":100000,"cache_read":0,"cache_write":0},"tokens_quality":"measured"}' --prices "$T/prices.json")"
eq "estimated cost comes only from a price table"     "$(jq '.cost.estimated_usd' <<< "$M")" 4.5
M="$(ing '{"model":"unpriced","tokens":{"in":1,"out":1},"tokens_quality":"measured"}' --prices "$T/prices.json")"
eq "unpriced model: no cost"                          "$(jq '.cost.estimated_usd' <<< "$M")" null

echo "usage errors and the real-run gate"
eq "a run needs exactly one task and strategy for a run id" "$(rc "$TB" run --simulate --task all --strategy baseline --out "$T/u" --run-id x)" 2
eq "results may not be written inside the kit"        "$(rc "$TB" run --simulate --task T01 --strategy baseline --out "$KIT/bench/zz-out")" 2
eq "no mode chosen is a usage error"                  "$(rc "$TB" run --task T01 --out "$T/u")" 2
eq "--real without --yes is refused"                  "$(rc "$TB" run --real --task T01 --strategy baseline --out "$T/r1")" 3
eq "--real without isolation is refused, with reason" "$(env -u SDKIT_TBENCH_ISOLATION_CMD "$TB" run --real --yes --task T01 --strategy baseline --out "$T/r1" 2>&1 | grep -c 'hidden-test isolation cannot be claimed')" 1
eq "a no-op wrapper is not isolation"                 "$(rc env SDKIT_TBENCH_ISOLATION_CMD=env "$TB" preflight)" 3
printf '#!/bin/sh\ncase "$*" in *evaluator*) exit 126 ;; esac\nexec "$@"\n' > "$T/deny.sh"; chmod +x "$T/deny.sh"
eq "a wrapper that hides the evaluator passes the probe" "$(rc "$TB" preflight --isolation-cmd "$T/deny.sh")" 0
eq "with isolation F05-A still starts no agent"       "$(rc env SDKIT_TBENCH_ISOLATION_CMD="$T/deny.sh" "$TB" run --real --yes --task T01 --strategy baseline --out "$T/r1")" 3
check "...nothing was run"                            bash -c "[ -z \"\$(ls '$T/r1/runs' 2>/dev/null)\" ]"

wait "$BG" 2>/dev/null; wait
echo "simulated runs"
R="$(res "$O" r-one)"
eq "a successful run is stored with identity and labels" "$(jq -r '[.run_id, .simulated, (.label | test("NOT A MEASUREMENT")), (.task.id + "@" + (.task.version | tostring)), .success] | join(",")' "$R")" "r-one,true,true,T01@1,true"
eq "starter commit and tree recorded, tree equals the manifest" "$(jq -r '[(.starter.commit | length), .starter.tree] | join(",")' "$R")" "40,$(jq -r .starter.tree "$KIT/bench/tasks/T01-null-handling/task.json")"
eq "evaluation has public, hidden and per-requirement outcomes" "$(jq -e '.evaluation.public.outcome and .evaluation.hidden.requirements.R1' "$R" >/dev/null; echo $?)" 0
eq "environment metadata has no host or user name"    "$(jq -r '.environment | has("os") and (has("hostname") or has("user") | not)' "$R")" true
eq "a successful run leaves no workspace behind"      "$(ls "$O/work" 2>/dev/null | wc -l | tr -d ' ')" 0
eq "missing metrics: still scored, usage null not 0"  "$(jq -c '[.success, .metrics.tokens.total, .metrics.tokens.quality]' "$(res "$O" r-two)")" '[true,null,"unavailable"]'
eq "SDKit strategy differences vs baseline are listed" "$(jq -r '.strategy.differs_from_baseline | map(.key) | index("profile") != null' "$(res "$O" r-two)")" true
eq "changing only the tests cannot pass"              "$(jq -r '[.success, .failure_category, .evaluation.public.outcome] | join(",")' "$(res "$O" tamper)")" "false,tests-only-change,pass"
eq "an agent crash is a failed run, recorded"         "$(jq -r '.failure_category + "/" + (.success | tostring)' "$(res "$O" crash)")" "agent-crash/false"
check "a failed run keeps its workspace and diagnostics" test -d "$O/runs/crash/diagnostics/workspace" -a -f "$O/runs/crash/agent.log"
check "no workspace holds hidden tests or references" bash -c "! find '$O' -path '*workspace*' \( -name 'test_hidden*' -o -name hidden_tests -o -name variants \) | grep -q ."
eq "duplicate run id is refused (exit 4)"             "$(rc "$TB" run --simulate --task T01 --strategy baseline --out "$O" --run-id r-one)" 4
eq "...and the original result is unchanged"          "$(jq -r .run_id "$R")" r-one
mkdir -p "$T/o9/runs/crashed"; echo 999999 > "$T/o9/runs/crashed/RUNNING"
eq "a hard-crashed run is reported as incomplete"     "$("$TB" verify "$T/o9" | grep -c '^incomplete')" 1

echo "result immutability"
eq "verify passes on untouched results"               "$(rc "$TB" verify "$O")" 0
check "sealed result files are read-only"             bash -c "[ ! -w '$R' ]"
cp -R "$O" "$T/ox"; chmod -R u+w "$T/ox"; jq '.success = false' "$T/ox/runs/r-one/result.json" > "$T/y" && cp "$T/y" "$T/ox/runs/r-one/result.json"
eq "editing a sealed result is detected (exit 6)"     "$(rc "$TB" verify "$T/ox")" 6
eq "the report names the altered run and excludes it" "$("$TB" report --results "$T/ox" --stdout-only | grep -c 'changed after writing.*r-one')" 1

echo "reporting"
JR="$("$TB" report --results "$O" --json --stdout-only)"
eq "simulated results allow no conclusions, no real partition" "$(jq -c '[.runs_total, .conclusions_allowed, .real]' <<< "$JR")" "[4,false,null]"
eq "failures stay in the denominator"                 "$(jq -c '.simulated.strategies.baseline | [.runs, .successes, .failures]' <<< "$JR")" "[2,1,1]"
eq "a token sum is withheld when a run lacks usage"   "$(jq -c '.simulated.strategies["sdkit-high-assurance"].tokens_total | [.complete, .sum]' <<< "$JR")" "[false,null]"
check "the report states that results are simulated, never ranks" bash -c "r=\$('$TB' report --results '$O' --stdout-only); echo \"\$r\" | grep -q 'SIMULATED / NO REAL MEASUREMENTS' && ! echo \"\$r\" | grep -iE 'winner|best strategy|rank 1'"
# real results are built from a simulated one
RR="$T/real"; mkdir -p "$RR/runs"
mkreal() {  # <id> <strategy> <task> <success> <tokens> <category|null>
  local d="$RR/runs/$1"; mkdir -p "$d"
  jq --arg id "$1" --arg s "$2" --arg t "$3" --argjson ok "$4" --argjson tok "$5" --argjson cat "$6" \
    '.run_id = $id | .simulated = false | .label = null | .mode = "real" | .strategy.name = $s | .task.id = $t | .success = $ok | .failure_category = $cat
     | .outcome = (if $ok then "success" else "failure" end) | .duration_s = 100 | .metrics.tokens.total = $tok | .metrics.tokens.quality = "measured"
     | .metrics.completeness.tokens = "measured" | .metrics.cost.provider_usd = null | .metrics.cost.estimated_usd = null | .evaluation.hidden.requirements = {}' "$R" > "$d/result.json"
  ( cd "$d" && shasum -a 256 result.json | cut -d' ' -f1 > result.sha256 )
}
mkreal b1 baseline T01 true 1000 null; mkreal b2 baseline T02 true 1000 null
mkreal c1 sdkit-standard T01 true 400 null; mkreal c2 sdkit-standard T02 false 400 '"hidden-fail"'
RJ="$("$TB" report --results "$RR" --json --stdout-only --min-n 1)"
eq "real results enable conclusions"                  "$(jq .conclusions_allowed <<< "$RJ")" true
eq "token ratio and success delta (pp)"               "$(jq -c '.real.comparison_vs_baseline[0] | [.tokens_median_ratio, .success_delta_pp]' <<< "$RJ")" "[0.4,-50]"
eq "cheaper but less correct is flagged"              "$(jq -r '.real.comparison_vs_baseline[0].flags | map(select(test("cheaper but less correct"))) | length' <<< "$RJ")" 1
eq "cost per success = all-run tokens / successes"    "$(jq '.real.strategies.baseline.cost_per_success.tokens.value' <<< "$RJ")" 1000
cp -R "$O/runs/r-one" "$RR/runs/f-sim"; chmod -R u+w "$RR/runs/f-sim"; jq '.run_id = "f-sim"' "$R" > "$T/y" && cp "$T/y" "$RR/runs/f-sim/result.json"; ( cd "$RR/runs/f-sim" && shasum -a 256 result.json | cut -d' ' -f1 > result.sha256 )
eq "simulated runs never leak into real figures"      "$("$TB" report --results "$RR" --json --stdout-only --min-n 1 | jq -c '[.real.runs, .simulated.runs]')" "[4,1]"

finish tbench
