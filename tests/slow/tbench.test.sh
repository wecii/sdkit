#!/usr/bin/env bash
# F05-A tests: the task benchmark harness (bench/tbench.sh). Deterministic and free: no model, no network; the only "agent" is the simulation fixture.
# Covers: manifests, checksums, task fixtures, workspace isolation, hidden-test separation, strategies, metrics parsing, missing usage, interruption,
# timeouts, duplicate run ids, result immutability, report arithmetic, failure accounting, simulation labeling, the real-run gate, and an untouched source tree.
# Run: tests/slow/tbench.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
TB="$KIT/bench/tbench.sh"
T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
res() { echo "$1/runs/$2/result.json"; }

snapshot() { ( cd "$KIT" && { git status --porcelain -- bench scripts tests docs 2>/dev/null; find bench -type f ! -name .DS_Store -exec shasum {} + | LC_ALL=C sort; } | shasum | cut -d' ' -f1 ); }
BEFORE="$(snapshot)"

# a writable copy of the task registry, for tests that corrupt things
mkcopy() { local d="$T/$1"; mkdir -p "$d"; cp -R "$KIT/bench/tasks" "$d/tasks"; cp -R "$KIT/bench/evaluator" "$d/evaluator"; cp -R "$KIT/bench/strategies" "$d/strategies"; echo "$d"; }
tbc() { local d="$1"; shift; SDKIT_TBENCH_TASKS="$d/tasks" SDKIT_TBENCH_EVALUATOR="$d/evaluator" SDKIT_TBENCH_STRATEGIES="$d/strategies" "$TB" "$@"; }

echo "task registry and manifests"
check "six tasks are registered"                      bash -c "[ \$('$TB' tasks | wc -l) -eq 6 ]"
check "every shipped task validates (schema, checksums, tree, registry, coverage)" "$TB" validate
eq "difficulty mix is 2 low, 2 medium, 2 high"        "$("$TB" tasks | cut -f2 | sort | uniq -c | tr -s ' ' | paste -sd, -)" " 2 high, 2 low, 2 medium"
C="$(mkcopy c1)"
jq 'del(.risk)' "$C/tasks/T01-null-handling/task.json" > "$C/x" && mv "$C/x" "$C/tasks/T01-null-handling/task.json"
eq "a manifest without risk is invalid"               "$(rc tbc "$C" validate T01)" 1
C="$(mkcopy c1b)"; jq '.id = "X1"' "$C/tasks/T02-input-validation/task.json" > "$C/x" && mv "$C/x" "$C/tasks/T02-input-validation/task.json"
check "a malformed task id is reported"               bash -c "SDKIT_TBENCH_TASKS='$C/tasks' SDKIT_TBENCH_EVALUATOR='$C/evaluator' '$TB' validate all 2>&1 | grep -q 'id must look like'"
C="$(mkcopy c2)"; echo "# edited" >> "$C/tasks/T03-paginated-api/starter/app/api.py"
eq "starter content change: checksum mismatch (exit 5)" "$(rc tbc "$C" validate T03)" 5
nocheck "starter mismatch: run refuses before doing anything" tbc "$C" run --simulate --task T03 --strategy baseline --out "$T/o-mismatch"
eq "starter mismatch: run exits 5"                    "$(rc tbc "$C" run --simulate --task T03 --strategy baseline --out "$T/o-mismatch")" 5
check "starter mismatch: no run directory was created" bash -c "[ -z \"\$(ls '$T/o-mismatch/runs' 2>/dev/null)\" ]"
C="$(mkcopy c3)"; echo "# edited" >> "$C/evaluator/T04-cache-race/hidden/test_hidden.py"
eq "hidden test change after sealing is detected"     "$(rc tbc "$C" validate T04)" 5
C="$(mkcopy c4)"; jq '.version = 2 | .title = "changed"' "$C/tasks/T05-authz-bypass/task.json" > "$C/x" && mv "$C/x" "$C/tasks/T05-authz-bypass/task.json"
eq "a new version must be sealed before use"          "$(rc tbc "$C" validate T05)" 1
eq "sealing a changed manifest under the SAME version is refused" "$(C2="$(mkcopy c4b)"; jq '.title = "changed"' "$C2/tasks/T05-authz-bypass/task.json" > "$C2/x" && mv "$C2/x" "$C2/tasks/T05-authz-bypass/task.json"; rc tbc "$C2" seal T05)" 5
C="$(mkcopy c5)"; echo "see bench/evaluator for the tests" >> "$C/tasks/T06-order-consistency/task.md"
nocheck "an agent-visible file naming the evaluator is rejected" tbc "$C" validate T06

echo "fixtures: defective starters, solvable, not solvable by editing tests"
FX="$("$TB" fixtures 2>&1)"
eq "fixtures: every starter fails the hidden tests"   "$(printf '%s\n' "$FX" | grep -c 'starter: public=pass hidden=fail')" 6
eq "fixtures: every partial fix is still rejected"    "$(printf '%s\n' "$FX" | grep -c 'partial: public=pass hidden=fail')" 6
eq "fixtures: every reference passes both suites"     "$(printf '%s\n' "$FX" | grep -c 'reference: public=pass hidden=pass')" 6
eq "fixtures: gutting the visible tests does not help" "$(printf '%s\n' "$FX" | grep -c 'tamper: public=pass hidden=fail')" 6
check "fixtures: no FAIL line"                        bash -c "! printf '%s\n' '$FX' | grep -q '^FAIL'"
check "the hidden tests cover every requirement"      bash -c "for d in '$KIT'/bench/tasks/*/; do for r in \$(jq -r '.requirements[].id' \$d/task.json); do grep -rq test_\${r}_ '$KIT'/bench/evaluator/\$(basename \$d)/hidden || exit 1; done; done"
check "no reference or hidden file is inside a starter" bash -c "cd '$KIT/bench'; for d in evaluator/*/; do for f in \$(find \$d/hidden \$d/variants -type f ! -name .DS_Store); do h=\$(shasum \$f | cut -d' ' -f1); find tasks/*/starter -type f -exec shasum {} + | grep -q \$h && exit 1; done; done; exit 0"
check "starter and hidden tests are separate trees"   bash -c "! find '$KIT/bench/tasks' -path '*starter*' -name 'test_hidden*' | grep -q ."

echo "strategies"
check "the three strategies validate"                  "$TB" strategies
eq "there are exactly baseline, sdkit-standard, sdkit-high-assurance" "$(ls "$KIT/bench/strategies" | paste -sd, -)" "baseline.json,sdkit-high-assurance.json,sdkit-standard.json"
C="$(mkcopy s1)"; jq '.env = {SDD_MODE: "off"}' "$C/strategies/sdkit-standard.json" > "$C/x" && mv "$C/x" "$C/strategies/sdkit-standard.json"
check "a strategy that turns SDD enforcement off is rejected" bash -c "! SDKIT_TBENCH_STRATEGIES='$C/strategies' '$TB' strategies"
C="$(mkcopy s2)"; jq '.env = {RISK_FLOOR_GLOBS: ""}' "$C/strategies/sdkit-high-assurance.json" > "$C/x" && mv "$C/x" "$C/strategies/sdkit-high-assurance.json"
check "a strategy that clears the risk floor is rejected" bash -c "! SDKIT_TBENCH_STRATEGIES='$C/strategies' '$TB' strategies"
C="$(mkcopy s3)"; jq '.risk_floor = "off"' "$C/strategies/sdkit-standard.json" > "$C/x" && mv "$C/x" "$C/strategies/sdkit-standard.json"
check "SDKit strategies must inherit the risk floor"  bash -c "! SDKIT_TBENCH_STRATEGIES='$C/strategies' '$TB' strategies"
C="$(mkcopy s4)"; jq '.profile = "standard"' "$C/strategies/baseline.json" > "$C/x" && mv "$C/x" "$C/strategies/baseline.json"
check "a baseline may not carry an SDKit profile"     bash -c "! SDKIT_TBENCH_STRATEGIES='$C/strategies' '$TB' strategies"
eq "every strategy states the common model/tools/task" "$(jq -s -r 'map(.same_as_other_strategies | index("model") != null and index("tools") != null) | all' "$KIT"/bench/strategies/*.json)" true

echo "metrics parsing"
ing() { printf '%s' "$1" > "$T/m.json"; "$TB" ingest "$T/m.json" "${@:2}"; }
M="$(ing '{"tokens":{"in":100,"out":50,"cache_read":10,"cache_write":5},"tokens_quality":"measured","llm_calls":4,"agent_calls":2,"retries":1,"quality":{"llm_calls":"measured","agent_calls":"measured","retries":"measured"}}')"
eq "total = in+out+cache"                             "$(jq .tokens.total <<< "$M")" 165
eq "full counts: basis all-four"                      "$(jq -r .tokens.total_basis <<< "$M")" all-four
eq "quality is carried"                               "$(jq -r .tokens.quality <<< "$M")" measured
M="$(ing '{}')"
eq "empty metrics: tokens null (never 0)"             "$(jq -c '[.tokens.in, .tokens.out, .tokens.total]' <<< "$M")" "[null,null,null]"
eq "empty metrics: marked unavailable"                "$(jq -r '.completeness.tokens + "/" + .completeness.llm_calls + "/" + .completeness.cost_provider' <<< "$M")" "unavailable/unavailable/unavailable"
M="$(ing '{"tokens":{"in":100,"out":50},"tokens_quality":"measured"}')"
eq "no cache counts: cache null, not 0"               "$(jq -c '[.tokens.cache_read, .tokens.cache_write]' <<< "$M")" "[null,null]"
check "no cache counts: total flagged as a lower bound" bash -c "jq -r .tokens.total_basis <<< '$M' | grep -q 'lower bound'"
M="$(ing '{"tokens":{"in":100},"tokens_quality":"measured"}')"
eq "missing output tokens: everything unavailable, nothing invented" "$(jq -c '[.tokens.in, .tokens.total, .tokens.quality]' <<< "$M")" '[null,null,"unavailable"]'
M="$(ing '{"tokens":{"in":-1,"out":"many"},"llm_calls":1.5,"tokens_quality":"measured"}')"
eq "invalid numbers become null"                      "$(jq -c '[.tokens.in, .tokens.out, .llm_calls]' <<< "$M")" "[null,null,null]"
check "invalid numbers produce warnings"              bash -c "jq -e '.warnings | length >= 3' <<< '$M'"
M="$(ing '{"tokens":{"in":10,"out":5}}')"
eq "unlabeled usage is estimated, never measured"     "$(jq -r .tokens.quality <<< "$M")" estimated
M="$(ing '{"tokens":{"in":10,"out":5},"tokens_quality":"unavailable"}')"
eq "a source that says unavailable wins over numbers" "$(jq -r '.tokens.quality + (.tokens.in | tostring)' <<< "$M")" unavailablenull
M="$(ing '{"billing":"subscription","cost":{"provider_usd":2.5}}')"
eq "subscription: no provider (metered) cost"        "$(jq '.cost.provider_usd' <<< "$M")" null
eq "subscription: the USD is kept as an estimate"     "$(jq '.cost.estimated_usd' <<< "$M")" 2.5
M="$(ing '{"billing":"metered","cost":{"provider_usd":2.5}}')"
eq "metered: provider cost is measured"               "$(jq -r '.cost.provider_quality' <<< "$M")" measured
printf '{"m":{"in":3,"out":15,"cache_read":0.3,"cache_write":3.75}}' > "$T/prices.json"
M="$(ing '{"model":"m","tokens":{"in":1000000,"out":100000,"cache_read":0,"cache_write":0},"tokens_quality":"measured"}' --prices "$T/prices.json")"
eq "estimated cost comes only from a price table"     "$(jq '.cost.estimated_usd' <<< "$M")" 4.5
M="$(ing '{"model":"unpriced","tokens":{"in":1,"out":1},"tokens_quality":"measured"}' --prices "$T/prices.json")"
eq "unpriced model: no cost"                          "$(jq '.cost.estimated_usd' <<< "$M")" null
# telemetry summary converter, against a real summary produced by telemetry.sh
TR="$T/tele"; mkdir -p "$TR/.sdkit"; ( cd "$TR" && git init -q -b main . && git config user.email t@t && git config user.name t && printf 'STACK=generic\n' > .sdkit/sdkit.env && printf 'TELEMETRY=1\n' > .sdkit/sdkit.local.env && echo a > a && git add -A && git commit -qm i )
( cd "$TR" && export CLAUDE_PROJECT_DIR="$TR" && TL="$KIT/scripts/telemetry.sh"
  "$TL" emit task.start --task tt --risk medium --profile standard && "$TL" emit agent.start --task tt --role developer --span a1 --host claude
  "$TL" emit agent.end --task tt --role developer --span a1 --host claude --in 1000 --out 200 --cache-read 300 --cache-write 50 --q tokens=actual --dur-ms 900
  "$TL" emit agent.start --task tt --role verifier --span a2 --host codex
  "$TL" emit agent.end --task tt --role verifier --span a2 --host codex --dur-ms 400
  "$TL" emit task.end --task tt --outcome done && "$TL" summary tt --json > "$T/tsum.json" )
M="$("$TB" ingest "$T/tsum.json" --telemetry)"
eq "telemetry: tokens come from the measured agent only" "$(jq -c '[.tokens.in, .tokens.out, .tokens.quality]' <<< "$M")" '[1000,200,"measured"]'
eq "telemetry: the agent without usage is flagged"    "$(jq -r '.warnings | map(select(test("lower bound"))) | length > 0' <<< "$M")" true
eq "telemetry: LLM calls stay unavailable"            "$(jq '.llm_calls' <<< "$M")" null
eq "telemetry: agent calls are counted"               "$(jq '.agent_calls' <<< "$M")" 2
eq "telemetry: phases carried"                        "$(jq -r '.phases | length > 0' <<< "$M")" true

echo "simulated runs: persistence, labeling, isolation"
O="$T/o1"
check "a single simulated run completes"              "$TB" run --simulate --task T01 --strategy baseline --out "$O" --run-id r-one
R="$(res "$O" r-one)"
eq "the run is stored with a unique id"               "$(jq -r .run_id "$R")" r-one
eq "simulated: flagged in the result"                 "$(jq -r '.simulated' "$R")" true
check "simulated: the result carries a visible label" bash -c "jq -r .label '$R' | grep -q 'NOT A MEASUREMENT'"
eq "simulated: no hidden-test isolation is claimed"   "$(jq -r '.isolation.hidden_test_isolation' "$R" | cut -c1-11)" "not claimed"
eq "task identity is recorded"                        "$(jq -r '.task.id + "@" + (.task.version | tostring)' "$R")" "T01@1"
eq "starter commit is recorded"                       "$(jq -r '.starter.commit | length' "$R")" 40
eq "starter tree equals the manifest"                 "$(jq -r .starter.tree "$R")" "$(jq -r .starter.tree "$KIT/bench/tasks/T01-null-handling/task.json")"
eq "task checksums are recorded"                      "$(jq -r '.task.checksums.visible_sha256 | length' "$R")" 64
eq "runner commit and evaluator revision recorded"    "$(jq -r '(.runner.commit | length > 0) and (.evaluator.code_sha256 | length == 64)' "$R")" true
check "environment metadata is recorded without host or user names" bash -c "jq -e '.environment | has(\"os\") and has(\"arch\") and has(\"python\") and (has(\"hostname\") or has(\"user\") | not)' '$R'"
eq "timestamps recorded"                              "$(jq -r '(.started | test("^20.*Z$")) and (.ended | test("Z$"))' "$R")" true
eq "strategy differences vs baseline are recorded"    "$(jq -r '.strategy.differs_from_baseline | length' "$R")" 0
check "evaluation has public, hidden, per-requirement outcomes" bash -c "jq -e '.evaluation.public.outcome and .evaluation.hidden.requirements.R1' '$R'"
eq "code changes captured"                            "$(jq -r '.changes.files >= 1 and .changes.insertions > 0' "$R")" true
check "a successful run leaves no workspace behind"   bash -c "[ -z \"\$(ls '$O/work' 2>/dev/null)\" ]"
tbrun() { "$TB" run --simulate --out "$1" "${@:2}"; }
tbrun "$T/o2" --task T01 --strategy sdkit-standard --run-id d1 >/dev/null; "$TB" run --simulate --task T01 --strategy sdkit-high-assurance --out "$T/o2" --run-id d2 >/dev/null
eq "strategy differences are listed for SDKit"        "$(jq -r '.strategy.differs_from_baseline | map(.key) | index("profile") != null' "$(res "$T/o2" d2)")" true
eq "same starter commit for every strategy"           "$(jq -r .starter.commit "$(res "$T/o2" d1)")" "$(jq -r .starter.commit "$(res "$T/o2" d2)")"
eq "same starter commit as the baseline run"          "$(jq -r .starter.commit "$(res "$T/o2" d1)")" "$(jq -r .starter.commit "$R")"
# isolation between runs
tbrun "$T/o3" --task T03 --strategy baseline --run-id i1 --sim-force starter --keep-workspace >/dev/null
tbrun "$T/o3" --task T03 --strategy baseline --run-id i2 --sim-force reference --keep-workspace >/dev/null
W1="$T/o3/runs/i1/diagnostics/workspace"; W2="$T/o3/runs/i2/diagnostics/workspace"
check "each run had its own workspace"                bash -c "[ -d '$W1' ] && [ -d '$W2' ] && [ '$W1' != '$W2' ]"
eq "the first run's workspace has no solution"        "$(grep -c 'sorted' "$W1/app/api.py")" 0
eq "the second run's workspace has the solution"      "$(grep -c 'sorted' "$W2/app/api.py" | tr -d ' ' | sed 's/^[1-9][0-9]*$/yes/')" yes
eq "each workspace is its own git repository"         "$(git -C "$W1" rev-parse --show-toplevel)" "$(cd "$W1" && pwd -P)"
eq "workspaces start from the same commit"            "$(git -C "$W1" rev-parse HEAD)" "$(git -C "$W2" rev-parse HEAD)"
check "the shipped starter still matches its sealed tree" "$TB" validate T03
check "no workspace holds hidden tests or references" bash -c "! find '$T/o1' '$T/o2' '$T/o3' -path '*workspace*' \( -name 'test_hidden*' -o -name hidden_tests -o -name variants \) | grep -q ."
check "failed-run diagnostics are preserved"          bash -c "[ -f '$T/o3/runs/i1/diagnostics/changes.patch' ] && [ -f '$T/o3/runs/i1/agent.log' ] && [ -f '$T/o3/runs/i1/hidden.log' ]"
check "the agent's environment shows no evaluator path or hidden test" bash -c "! grep -E 'evaluator|hidden_tests|variants/|$KIT/bench' '$T/o3/runs/i1/agent.log' | grep -v '^PATH=' | grep -q ."
check "the agent sees only the allowlisted variables" bash -c "sed -n '/--- environment/,/--- end environment/p' '$T/o3/runs/i1/agent.log' | grep -E '^[A-Z_]+=' | cut -d= -f1 | grep -vE '^(PATH|HOME|LANG|TZ|PYTHONDONTWRITEBYTECODE|PYTHONHASHSEED|PWD|SHLVL|OLDPWD|_|LC_.*|__CF_.*|SDKIT_TBENCH_(RUN_ID|PROMPT|OUT|STRATEGY|SIM_VARIANT|PAYLOAD|SIM_SRC))\$' | wc -l | grep -q '^ *0\$'"
tbrun "$T/o4" --task T03 --strategy baseline --run-id tamper --sim-force tests-only >/dev/null
eq "changing only the tests cannot pass"              "$(jq -r '.success' "$(res "$T/o4" tamper)")" false
eq "…and is categorized as such"                      "$(jq -r '.failure_category' "$(res "$T/o4" tamper)")" tests-only-change
eq "…the pristine public tests still ran"             "$(jq -r '.evaluation.public.outcome' "$(res "$T/o4" tamper)")" pass

echo "failure handling"
tbrun "$T/o5" --task T01 --strategy baseline --run-id crash --sim-force crash >/dev/null
eq "an agent crash is a failed run, recorded"         "$(jq -r '.failure_category + "/" + (.success | tostring)' "$(res "$T/o5" crash)")" "agent-crash/false"
tbrun "$T/o5" --task T01 --strategy baseline --run-id hang --sim-force hang --agent-timeout 2 >/dev/null
eq "a hung agent is killed at the timeout"            "$(jq -r '.failure_category + "/" + (.agent.timed_out | tostring)' "$(res "$T/o5" hang)")" "agent-timeout/true"
check "the timeout fired quickly"                     bash -c "[ \$(jq '.agent.duration_s < 20' '$(res "$T/o5" hang)') = true ]"
tbrun "$T/o5" --task T01 --strategy baseline --run-id flood --sim-force flood >/dev/null
eq "runaway output is cut at the limit"               "$(jq -r '.failure_category' "$(res "$T/o5" flood)")" agent-output-limit
check "the agent log respects the output limit"       bash -c "[ \$(wc -c < '$T/o5/runs/flood/agent.log') -le 1200000 ]"
tbrun "$T/o5" --task T01 --strategy baseline --run-id nochange --sim-force starter >/dev/null
eq "an agent that changes nothing is 'no-change'"     "$(jq -r '.failure_category' "$(res "$T/o5" nochange)")" no-change
eq "a failed run still gets its workspace kept"       "$([ -d "$T/o5/runs/crash/diagnostics/workspace" ] && echo yes)" yes
tbrun "$T/o5" --task T01 --strategy baseline --run-id partial --sim-force partial >/dev/null
eq "a partial fix fails the hidden tests"             "$(jq -r '.failure_category + "/" + .evaluation.hidden.outcome' "$(res "$T/o5" partial)")" "hidden-fail/fail"
eq "…and reports which requirements are unmet"        "$(jq -r '.evaluation.hidden.requirements | map(select(. != "pass")) | length > 0' "$(res "$T/o5" partial)")" true
tbrun "$T/o6" --task T01 --strategy baseline --run-id nom --sim-metrics none >/dev/null
eq "missing metrics: the run is scored, usage is null" "$(jq -c '[.success, .metrics.tokens.total, .metrics.tokens.quality]' "$(res "$T/o6" nom)")" '[true,null,"unavailable"]'
tbrun "$T/o6" --task T01 --strategy baseline --run-id inv --sim-metrics invalid >/dev/null
eq "invalid metrics: null with warnings, run unaffected" "$(jq -c '[.success, .metrics.tokens.total, (.metrics.warnings | length > 0)]' "$(res "$T/o6" inv)")" '[true,null,true]'
eq "…and the missing usage was not turned into zero"  "$(jq -r '.metrics.tokens.in' "$(res "$T/o6" nom)")" null
eq "duplicate run id is refused (exit 4)"             "$(rc "$TB" run --simulate --task T01 --strategy baseline --out "$T/o6" --run-id nom)" 4
eq "…and the original result is unchanged"            "$(jq -r .run_id "$(res "$T/o6" nom)")" nom
eq "a run id needs exactly one task and strategy"     "$(rc "$TB" run --simulate --task all --strategy baseline --out "$T/o6" --run-id x)" 2
eq "results may not be written inside the kit"        "$(rc "$TB" run --simulate --task T01 --strategy baseline --out "$KIT/bench/zz-out")" 2
check "…and nothing was created there"                bash -c "[ ! -e '$KIT/bench/zz-out' ]"
eq "no mode chosen is a usage error"                  "$(rc "$TB" run --task T01 --out "$T/o7")" 2
# interruption: SIGTERM while the agent hangs
"$TB" run --simulate --task T01 --strategy baseline --out "$T/o8" --run-id intr --sim-force hang > "$T/o8.log" 2>&1 &
BG=$!; i=0; while [ $i -lt 100 ] && ! [ -f "$T/o8/runs/intr/RUNNING" ]; do sleep 0.1; i=$((i + 1)); done; sleep 1
check "a running run is marked while in progress"     test -f "$T/o8/runs/intr/RUNNING"
kill -TERM "$BG"; wait "$BG"; IRC=$?
eq "an interrupted harness exits 130"                 "$IRC" 130
eq "the interrupted run is recorded as such"          "$(jq -r '.outcome + "/" + .failure_category + "/" + (.success | tostring)' "$(res "$T/o8" intr)")" "interrupted/interrupted/false"
check "…the marker is gone and the result is sealed"  bash -c "[ ! -e '$T/o8/runs/intr/RUNNING' ] && [ -f '$T/o8/runs/intr/result.sha256' ]"
check "…no agent process is left behind"              bash -c "! pgrep -f 'sim-agent.sh' >/dev/null || ! pgrep -f '$T/o8' >/dev/null"
check "…its workspace was kept for diagnosis"         test -d "$T/o8/runs/intr/diagnostics/workspace"
# a hard crash (SIGKILL) leaves a RUNNING marker and no result
mkdir -p "$T/o9/runs/crashed"; echo "999999" > "$T/o9/runs/crashed/RUNNING"
tbrun "$T/o9" --task T01 --strategy baseline --run-id fine >/dev/null
eq "a crashed run is reported as incomplete, not dropped" "$("$TB" report --results "$T/o9" --stdout-only | grep -c 'never completed.*crashed')" 1
eq "verify lists the incomplete run"                  "$("$TB" verify "$T/o9" | grep -c '^incomplete')" 1

echo "result immutability"
eq "verify passes on untouched results"               "$(rc "$TB" verify "$T/o2")" 0
check "sealed result files are read-only"             bash -c "[ ! -w '$T/o2/runs/d1/result.json' ]"
cp -R "$T/o2" "$T/o2x"; chmod -R u+w "$T/o2x"; jq '.success = false' "$T/o2x/runs/d1/result.json" > "$T/o2x/y" && cp "$T/o2x/y" "$T/o2x/runs/d1/result.json"
eq "editing a sealed result is detected (exit 6)"     "$(rc "$TB" verify "$T/o2x")" 6
eq "the report excludes and names the altered run"    "$("$TB" report --results "$T/o2x" --stdout-only | grep -c 'changed after writing.*d1')" 1
eq "the altered run is not in the report totals"      "$("$TB" report --results "$T/o2x" --json --stdout-only | jq -r '.simulated.runs')" 1
eq "a new run id never overwrites (exit 4)"           "$(rc "$TB" run --simulate --task T01 --strategy sdkit-standard --out "$T/o2" --run-id d1)" 4

echo "reporting"
tbrun "$T/full" --task all --strategy all --run-id-prefix f >/dev/null
JR="$("$TB" report --results "$T/full" --json --stdout-only)"
eq "18 runs aggregated"                               "$(jq .runs_total <<< "$JR")" 18
eq "simulated results allow no conclusions"           "$(jq .conclusions_allowed <<< "$JR")" false
eq "no real partition when everything is simulated"   "$(jq .real <<< "$JR")" null
check "the report states that results are simulated"  bash -c "'$TB' report --results '$T/full' --stdout-only | grep -q 'SIMULATED / NO REAL MEASUREMENTS'"
eq "success rate counts failures in the denominator"  "$(jq '.simulated.strategies.baseline | [.runs, .successes, .failures]' -c <<< "$JR")" "[6,2,4]"
eq "baseline success rate is 2/6"                     "$(jq '.simulated.strategies.baseline.success_rate' <<< "$JR")" 0.3333
eq "high-assurance succeeded on all"                  "$(jq '.simulated.strategies["sdkit-high-assurance"].success_rate' <<< "$JR")" 1
eq "failure categories are counted"                   "$(jq -c '.simulated.strategies.baseline.failure_categories' <<< "$JR")" '{"hidden-fail":4}'
eq "tokens: a sum is withheld when a run lacks usage" "$(jq '.simulated.strategies.baseline.tokens_total | [.known, .runs, .complete, .sum]' -c <<< "$JR")" "[5,6,false,null]"
eq "tokens: complete groups get a sum"                "$(jq '.simulated.strategies["sdkit-standard"].tokens_total.complete' <<< "$JR")" true
eq "cost per success: withheld while data is missing" "$(jq '.simulated.strategies.baseline.cost_per_success.tokens.value' <<< "$JR")" null
check "…with the reason stated"                       bash -c "jq -r '.simulated.strategies.baseline.cost_per_success.tokens.reason' <<< '$JR' | grep -q 'unavailable for 1 of 6'"
SS="$(jq '.simulated.strategies["sdkit-standard"]' <<< "$JR")"
eq "cost per success = all-run total / successes"     "$(jq -n --argjson s "$SS" '($s.tokens_total.sum / $s.successes * 100 | round) / 100 == $s.cost_per_success.tokens.value')" true
eq "…it includes the failed run's tokens"             "$(jq '.tokens_total.sum > (.tokens_total_successful_runs.sum)' <<< "$SS")" true
eq "estimated and provider cost are separate fields"  "$(jq '.cost_per_success | has("provider_usd") and has("estimated_usd")' <<< "$SS")" true
eq "unavailable LLM calls are counted as such"        "$(jq -c '.completeness.llm_calls' <<< "$SS")" '{"measured":0,"estimated":0,"unavailable":6}'
JR3="$("$TB" report --results "$T/full" --json --stdout-only --min-n 7)"
eq "small samples withhold per-success figures"       "$(jq -r '.simulated.strategies["sdkit-standard"].cost_per_success.tokens.reason' <<< "$JR3" | cut -c1-16)" "sample too small"
eq "comparison flags nothing when the strategy is better" "$(jq -c '.simulated.comparison_vs_baseline | map(.flags | map(select(test("LESS CORRECT")))) | flatten | length' <<< "$JR")" 0
eq "comparison covers only paired tasks"              "$(jq -c '.simulated.comparison_vs_baseline[0].paired_tasks' <<< "$JR")" 6
check "the report never ranks strategies"             bash -c "! '$TB' report --results '$T/full' --stdout-only | grep -iE 'winner|best strategy|rank 1'"
# real vs simulated: a real result must dominate and a cheaper-but-worse strategy must be flagged
RR="$T/real"; mkdir -p "$RR/runs"
mkreal() {  # <id> <strategy> <task> <success> <tokens|null> <category|null>
  local d="$RR/runs/$1"; mkdir -p "$d"
  jq --arg id "$1" --arg s "$2" --arg t "$3" --argjson ok "$4" --argjson tok "$5" --argjson cat "$6" \
    '.run_id = $id | .simulated = false | .label = null | .mode = "real" | .strategy.name = $s | .task.id = $t | .success = $ok | .failure_category = $cat
     | .outcome = (if $ok then "success" else "failure" end) | .duration_s = 100
     | .metrics.tokens.total = $tok | .metrics.tokens.quality = (if $tok == null then "unavailable" else "measured" end)
     | .metrics.completeness.tokens = (if $tok == null then "unavailable" else "measured" end) | .metrics.cost.provider_usd = null | .metrics.cost.estimated_usd = null
     | .evaluation.hidden.requirements = {}' "$(res "$T/full" f-T01-baseline-r1)" > "$d/result.json"
  ( cd "$d" && shasum -a 256 result.json | cut -d' ' -f1 > result.sha256 )
}
for n in 1 2 3 4 5; do mkreal "b$n" baseline "T0$n" "$([ $n -le 4 ] && echo true || echo false)" 1000 "$([ $n -le 4 ] && echo null || echo '"hidden-fail"')"; done
for n in 1 2 3 4 5; do mkreal "c$n" sdkit-standard "T0$n" "$([ $n -le 2 ] && echo true || echo false)" 400 "$([ $n -le 2 ] && echo null || echo '"hidden-fail"')"; done
mkreal u1 baseline T05 true null null
RJ="$("$TB" report --results "$RR" --json --stdout-only)"
eq "real results enable conclusions"                  "$(jq .conclusions_allowed <<< "$RJ")" true
eq "a failed run stays in the success denominator"    "$(jq -c '.real.strategies.baseline | [.runs, .successes]' <<< "$RJ")" "[6,5]"
eq "a run without usage keeps the token total incomplete" "$(jq '.real.strategies.baseline.tokens_total.complete' <<< "$RJ")" false
eq "cheaper but less correct is flagged"              "$(jq -r '.real.comparison_vs_baseline[0].flags | map(select(test("cheaper but less correct"))) | length' <<< "$RJ")" 0
eq "(tokens ratio is withheld because baseline has a null-usage run)" "$(jq '.real.comparison_vs_baseline[0].tokens_median_ratio' <<< "$RJ")" null
rm -rf "$RR/runs/u1"
RJ="$("$TB" report --results "$RR" --json --stdout-only)"
eq "complete data yields a token ratio"               "$(jq '.real.comparison_vs_baseline[0].tokens_median_ratio' <<< "$RJ")" 0.4
eq "less-correct-and-cheaper is flagged as such"      "$(jq -r '.real.comparison_vs_baseline[0].flags | map(select(test("cheaper but less correct"))) | length' <<< "$RJ")" 1
eq "…and as less correct"                             "$(jq -r '.real.comparison_vs_baseline[0].flags | map(select(test("LESS CORRECT"))) | length' <<< "$RJ")" 1
eq "success delta is in percentage points"            "$(jq '.real.comparison_vs_baseline[0].success_delta_pp' <<< "$RJ")" -40
eq "cost per success (tokens) = 5000/4 for baseline, n=5" "$(jq '.real.strategies.baseline.cost_per_success.tokens.value' <<< "$RJ")" 1250
eq "no notice of simulation for real-only data"       "$(jq .notice <<< "$RJ")" null
cp -R "$T/full/runs/f-T01-baseline-r1" "$RR/runs/f-sim"; chmod -R u+w "$RR/runs/f-sim"
jq '.run_id = "f-sim"' "$RR/runs/f-sim/result.json" > "$RR/y" && cp "$RR/y" "$RR/runs/f-sim/result.json"; ( cd "$RR/runs/f-sim" && shasum -a 256 result.json | cut -d' ' -f1 > result.sha256 )
RJ="$("$TB" report --results "$RR" --json --stdout-only)"
eq "simulated runs never leak into real figures"      "$(jq -c '[.real.runs, .simulated.runs]' <<< "$RJ")" "[10,1]"
eq "report files are written, not overwritten"        "$("$TB" report --results "$RR" >/dev/null 2>&1; "$TB" report --results "$RR" >/dev/null 2>&1; ls "$RR/reports" | grep -c '\.md$')" 2
check "report JSON and Markdown are produced"         bash -c "ls '$RR/reports'/*.json >/dev/null && jq . '$RR/reports'/*.json >/dev/null"
check "the report lists measurement limitations"      bash -c "'$TB' report --results '$RR' --stdout-only | grep -q 'Measurement limitations'"
eq "an empty results directory reports cleanly"       "$(mkdir -p "$T/empty/runs"; "$TB" report --results "$T/empty" --json --stdout-only | jq .runs_total)" 0

echo "real runs fail closed"
eq "--real without --yes is refused"                  "$(rc "$TB" run --real --task T01 --strategy baseline --out "$T/r1")" 3
eq "--real without any isolation is refused"          "$(rc env -u SDKIT_TBENCH_ISOLATION_CMD "$TB" run --real --yes --task T01 --strategy baseline --out "$T/r1")" 3
eq "…and says why (refused, nothing run)"             "$(env -u SDKIT_TBENCH_ISOLATION_CMD "$TB" run --real --yes --task T01 --strategy baseline --out "$T/r1" 2>&1 | grep -c 'hidden-test isolation cannot be claimed')" 1
eq "a no-op wrapper is not isolation"                 "$(rc env SDKIT_TBENCH_ISOLATION_CMD="env" "$TB" preflight)" 3
check "…it names the readable evaluator asset"        bash -c "SDKIT_TBENCH_ISOLATION_CMD=env '$TB' preflight 2>&1 | grep -q 'NOT ISOLATED'"
printf '#!/bin/sh\ncase "$*" in *evaluator*) exit 126 ;; esac\nexec "$@"\n' > "$T/deny-evaluator.sh"; chmod +x "$T/deny-evaluator.sh"
eq "a wrapper that hides the evaluator passes the probe" "$(rc "$TB" preflight --isolation-cmd "$T/deny-evaluator.sh")" 0
eq "a broken wrapper is refused"                      "$(rc "$TB" preflight --isolation-cmd /nonexistent/wrapper)" 3
eq "with isolation in place F05-A still starts no real agent (stops after the gate)"   "$(rc env SDKIT_TBENCH_ISOLATION_CMD="$T/deny-evaluator.sh" "$TB" run --real --yes --task T01 --strategy baseline --out "$T/r1")" 3
check "…nothing was run"                              bash -c "[ -z \"\$(ls '$T/r1/runs' 2>/dev/null)\" ]"

echo "existing suites and tree hygiene"
check "bash -n on the new scripts"                    bash -c "bash -n '$KIT/bench/tbench.sh' && bash -n '$KIT/bench/lib/sim-agent.sh' && bash -n '$KIT/tests/slow/tbench.test.sh'"
check "JSON files are valid"                          bash -c "for f in '$KIT'/bench/tasks/*/task.json '$KIT'/bench/tasks/registry.json '$KIT'/bench/strategies/*.json '$KIT'/bench/sim/sim.json; do jq . \$f >/dev/null || exit 1; done"
check "the runner compiles"                           python3 -c "import ast,sys; ast.parse(open('$KIT/bench/lib/runlimited.py').read())"
check "adapters are in sync"                          "$KIT/bin/build-adapters.sh" --check
if command -v shellcheck >/dev/null; then check "shellcheck" shellcheck -S warning "$KIT/bench/tbench.sh" "$KIT/bench/lib/sim-agent.sh"; else ok "shellcheck not installed: skipped"; fi
eq "the source tree is unchanged by this test run"   "$(snapshot)" "$BEFORE"
check "no bytecode or result files appeared in the tree" bash -c "! find '$KIT/bench' -name __pycache__ -o -name '*.pyc' | grep -q ."

echo "tbench: $pass passed, $fail failed"
[ "$fail" = 0 ]
