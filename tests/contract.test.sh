#!/usr/bin/env bash
# Agent contracts (scripts/contract.sh): handoff and result validation, identity, artifacts, retry/stale/duplicate, races, telemetry, the Claude Code hook, run-role integration, and the
# fact that a contract never decides a verdict. Simulated benchmarks are only listed (bench/ and telemetry.test.sh run them). Run: tests/contract.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
PATH="$KIT/tests/stubs:$PATH"
C="$KIT/scripts/contract.sh"; TL="$KIT/scripts/telemetry.sh"; ST="$KIT/scripts/state.sh"; HK="$KIT/hooks/check-contract.sh"; RR="$KIT/scripts/run-role.sh"

# newrepo <name> [local setting...]: a repo on branch feat with an open task t1, TELEMETRY=1 and CONTRACTS=1
newrepo() {
  local r="$T/$1"; shift; mkdir -p "$r/.sdkit" "$r/src" "$r/openspec/changes/t1"
  echo plan > "$r/plan.md"; echo a > "$r/src/a.sh"; printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > "$r/openspec/changes/t1/proposal.md"
  printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\nCONTRACTS=1\n' > "$r/.sdkit/sdkit.env"
  printf 'TELEMETRY=1\n' > "$r/.sdkit/sdkit.local.env"; for l in "$@"; do printf '%s\n' "$l" >> "$r/.sdkit/sdkit.local.env"; done
  printf 'work/\n.sdd/\nsdkit.local.env\n' > "$r/.sdkit/.gitignore"
  git_repo "$r" >/dev/null; ( cd "$r" && git checkout -qb feat && CLAUDE_PROJECT_DIR="$r" "$ST" t1 init medium feat >/dev/null )
  echo "$r"
}
# hand <file> <role> <id> <writes> [extra lines...]
hand() { local f="$1" role="$2" id="$3" writes="$4"; shift 4
  { printf 'ROLE: %s     RISK: medium     PROJECT-DIR: .sdkit\nCONTRACT: 1\nTASK: do the thing\nREAD: plan.md\nSCOPE: writes: %s\nID: %s\n' "$role" "$writes" "$id"; for l in "$@"; do printf '%s\n' "$l"; done; } > "$f"; }
line() { printf 'HANDOFF-RESULT/1 | id: %s | role: %s | status: %s | artifacts: %s | blockers: %s | next: %s\n' "$1" "$2" "${3:-done}" "${4:-none}" "${5:-none}" "${6:--}"; }
reason() { printf '%s' "$1" | sed -n 's/.*reason=\([a-z-]*\):.*/\1/p'; }
res() { line "$@" | "$C" check-result - ; }   # result of a line against the registry (prints the CONTRACT= summary)
# many ids at once: issue handoffs h-<label> for t1/<label>
mk() { local l; for l in "$@"; do hand "h-$l.md" developer "t1/$l" src/; "$C" issue "h-$l.md" >/dev/null; done; }

R="$(newrepo main)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
EV="$R/.sdkit/work/t1/events.jsonl"

echo "a valid exchange"
hand h1.md developer t1/dev-1 src/
check "a valid handoff is issued and registered"      "$C" issue h1.md
check "the registry file exists"                      test -f .sdkit/work/t1/contracts/dev-1.json
line t1/dev-1 developer done src/a.sh > r1.txt
out="$("$C" check-result r1.txt --role developer --record)"
eq "a valid result: one summary line"                 "$out" "CONTRACT=valid stage=result id=t1/dev-1 role=developer status=done"
eq "recorded as accepted"                             "$(jq -r .state .sdkit/work/t1/contracts/dev-1.json)" accepted
eq "a second result for the id is a duplicate (agent prefix on role ignored)" "$(reason "$(line t1/dev-1 developer | "$C" check-result - --role spec-driven-kit:developer)")" duplicate

echo "result validation"
mk m1 m2 m3
eq "blocked is a valid contract (exit 1)"             "$(line t1/m1 developer blocked none 'tests do not compile' 'ask' | "$C" check-result - >/dev/null; echo $?)" 1
eq "done with blockers is inconsistent"               "$(reason "$(res t1/m1 developer done none something)")" inconsistent
eq "an empty answer is no-result"                     "$(reason "$(printf '' | "$C" check-result -)")" no-result
eq "prose without the line is malformed"              "$(reason "$(echo 'all done, trust me' | "$C" check-result -)")" malformed
eq "version 2 is unsupported"                         "$(reason "$(line t1/m1 developer | sed 's#RESULT/1#RESULT/2#' | "$C" check-result -)")" unsupported-version

echo "identity"
eq "another role than the one issued"                 "$(reason "$(res t1/m3 reviewer)")" role-mismatch
line t1/forged developer | "$C" check-result - --record >/dev/null
eq "an answer cannot forge a registry entry"          "$(ls .sdkit/work/t1/contracts | grep -c forged)" 0
mkdir -p .sdkit/contracts; echo '{"keep":"me"}' > .sdkit/contracts/victim.json
line '../victim' developer | "$C" check-result - --record >/dev/null
eq "a path-like id in an answer touches no file"      "$(cat .sdkit/contracts/victim.json)" '{"keep":"me"}'

echo "handoff validation"
v() { local f="$T/hv.md"; hand "$f" "$@"; "$C" issue "$f" --check-only; }
eq "no CONTRACT line"                                 "$(reason "$(printf 'ROLE: developer\nID: t1/v\nTASK: x\nSCOPE: writes: src/\n' | "$C" issue - --check-only)")" missing-field
eq "an absolute write path"                           "$(reason "$(v developer t1/v1 /etc)")" unsafe-path
eq "OUT outside work/<task>/out/"                     "$(reason "$(v developer t1/v1 src/ 'OUT: src/a.sh')")" unsafe-path
hand "$T/hv.md" developer t1/v1 src/; sed -i.bak 's#^READ: .*#READ: nope.md#' "$T/hv.md"
eq "READ: a missing file"                             "$(reason "$("$C" issue "$T/hv.md" --check-only)")" missing-artifact
eq "--check-only registers nothing"                   "$(ls .sdkit/work/t1/contracts | grep -c 'v1')" 0

echo "artifacts"
hand h4.md developer t1/a1 'src/,docs/x.md' 'OUT: work/t1/out/a1.md'; "$C" issue h4.md >/dev/null
mkdir -p docs .sdkit/work/t1/out; echo d > docs/x.md; echo z > outside.txt
art() { line t1/a1 developer done "$1" | "$C" check-result - --cwd "$R"; }
eq "artifacts in scope"                               "$(art 'src/a.sh,docs/x.md' >/dev/null; echo $?)" 0
eq "a missing artifact"                               "$(reason "$(art src/missing.sh)")" missing-artifact
eq "a file outside the writes"                        "$(reason "$(art outside.txt)")" out-of-scope
mkdir -p "$T/outside-dir"; echo s > "$T/outside-dir/s"; ln -s "$T/outside-dir" src/link
eq "a symlink that leaves the repository"             "$(reason "$(art src/link/s)")" unsafe-path
rm -f src/link
hand h5.md reviewer t1/a2 none; "$C" issue h5.md >/dev/null
eq "a read-only role cannot claim artifacts"         "$(reason "$(line t1/a2 reviewer done src/a.sh | "$C" check-result - --cwd "$R")")" inconsistent

echo "duplicate, retry, stale, interrupted"
mk d1 s1 s3 k1
eq "the same id issued twice is a duplicate"          "$(reason "$("$C" issue h-d1.md)")" duplicate
line t1/s1 developer partial none x | "$C" check-result - --record >/dev/null
echo junk | "$C" check-result - --id t1/s3 --record >/dev/null
eq "an invalid answer marks the id invalid"           "$(jq -r .state .sdkit/work/t1/contracts/s3.json)" invalid
hand h10.md developer t1/s4 src/ 'RETRY-OF: t1/s3'
check "a retry of an invalid id is issued"            "$C" issue h10.md
eq "the old id is superseded"                         "$(jq -r .state .sdkit/work/t1/contracts/s3.json)" superseded
eq "a late result for the old id is stale"            "$(reason "$(line t1/s3 developer | "$C" check-result - --record)")" stale
hand h11.md reviewer t1/s5 none 'RETRY-OF: t1/s4'
"$C" close t1/k1 --reason interrupted >/dev/null
eq "an interrupted agent: state and stale answer"     "$(jq -r .state .sdkit/work/t1/contracts/k1.json)/$(reason "$(res t1/k1 developer)")" interrupted/stale

echo "concurrent agents"
mk race; line t1/race developer done src/a.sh > race.txt
for i in 1 2 3 4; do "$C" check-result race.txt --record > "race.$i.out" 2>&1 & done; wait
eq "of four identical results exactly one is accepted" "$(cat race.*.out | grep -c '^CONTRACT=valid')" 1

echo "telemetry"
eq "the events file is valid"                         "$("$TL" validate t1 | head -1 | cut -c1-3)" "ok:"
S="$("$TL" summary t1 --json)"
eq "the summary counts checks, reasons, statuses, version" "$(jq -c '[.contracts.checked > 0, .contracts.by_reason.duplicate > 0, .contracts.by_status.done > 0, .contracts.versions]' <<< "$S")" '[true,true,true,[1]]'
eq "a failure/contract is counted per invalid check"  "$(jq -r '.failures.by_category.contract' <<< "$S")" "$(jq -r '.contracts.invalid' <<< "$S")"
eq "events carry ids and sizes, never prompt or blocker text" "$(grep -c 'tests do not compile\|do the thing' "$EV")" 0
nocheck "an invalid check needs a reason"             "$TL" emit contract.check --task t1 --outcome invalid --stage result --cv 1 --strict
nocheck "an unknown agent status is rejected"         "$TL" emit contract.check --task t1 --outcome valid --stage result --cv 1 --status verified --strict
Q="$(newrepo quiet)"; sed -i.bak '/TELEMETRY/d' "$Q/.sdkit/sdkit.local.env"
( cd "$Q" && export CLAUDE_PROJECT_DIR="$Q"; hand h.md developer t1/q1 src/; "$C" issue h.md >/dev/null; line t1/q1 developer done src/a.sh | "$C" check-result - --record >/dev/null )
eq "TELEMETRY off: registry records, no events file"  "$(jq -r .state "$Q/.sdkit/work/t1/contracts/q1.json")/$(test -e "$Q/.sdkit/work/t1/events.jsonl"; echo $?)" accepted/1

echo "the Claude Code hook"
pre() { jq -nc --arg p "$(cat "$1")" --arg t "${2:-spec-driven-kit:developer}" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{prompt:$p,subagent_type:$t,description:"d"}}'; }
stop() { jq -nc --arg m "$1" --arg t "${2:-spec-driven-kit:developer}" '{hook_event_name:"SubagentStop",agent_type:$t,agent_id:"ag1",last_assistant_message:$m}'; }
hand hk1.md developer t1/hk1 src/; hand hk2.md developer t1/hk2 /etc
eq "a contracted spawn is registered"                 "$(pre hk1.md | "$HK" >/dev/null; jq -r .state .sdkit/work/t1/contracts/hk1.json)" issued
eq "an invalid spawn asks first (strict), naming the category" "$(pre hk2.md | "$HK" | jq -r '.hookSpecificOutput | .permissionDecision + (.permissionDecisionReason | test("unsafe-path") | tostring)')" asktrue
eq "a valid answer is silent and recorded"            "$(stop "$(printf 'ok\n%s' "$(line t1/hk1 developer done src/a.sh)")" | "$HK"; jq -r .state .sdkit/work/t1/contracts/hk1.json)" accepted
hand hk5.md developer t1/hk5 src/; pre hk5.md | "$HK" >/dev/null
eq "an answer without the line is reported, hook exits 0" "$(stop 'finished everything' | "$HK" | jq -r .systemMessage | grep -c 'NOT accepted')/$(stop x | "$HK" >/dev/null 2>&1; echo $?)" 1/0
L="$(newrepo legacy)"; cd "$L" || exit 1; export CLAUDE_PROJECT_DIR="$L"
printf 'ROLE: developer\nTASK: x\nSCOPE: writes: src/\n' > old.md
eq "legacy handoff: silent, nothing registered"       "$(pre old.md | "$HK"; ls .sdkit/work/t1/contracts 2>/dev/null | wc -l | tr -d ' ')" 0
hand c.md developer t1/w1 src/; pre c.md | "$HK" >/dev/null
eq "a waiting handoff makes a bare answer a finding"  "$(stop 'all done' | "$HK" | jq -r 'has("systemMessage")')" true
sed -i.bak '/CONTRACTS/d' .sdkit/sdkit.env
eq "CONTRACTS off: the hook is silent"                "$(pre c.md | "$HK"; stop 'all done' | "$HK")" ""
cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"

echo "run-role.sh"
G="$(newrepo rr 'RUN_ROLE_HOST=claude' 'USAGE_LOG=1')"; cd "$G" || exit 1; export CLAUDE_PROJECT_DIR="$G"
mkdir -p "$T/fx/answers" "$T/fx/usage" "$T/fx/sim/s1" "$T/fx/fail"; echo a > "$T/fx/sim/s1/new.sh"
run() { local step="$1"; shift; SDKIT_BENCH_SCENARIO="$T/fx" SDKIT_BENCH_STEP="$step" PATH="$KIT/bench/stub-host:$PATH" "$RR" "$@" --cwd "$G"; }
hand rr1.md developer t1/rr1 src/,new.sh
{ echo 'built it'; line t1/rr1 developer done new.sh; } > "$T/fx/answers/s1.txt"; echo '100 40 500 60' > "$T/fx/usage/s1"
run s1 developer --handoff rr1.md --out o1.md >/dev/null 2>"$T/rr.err"; e=$?
eq "a contracted run with a valid answer: exit 0, accepted, answer kept" "$e/$(jq -r .state .sdkit/work/t1/contracts/rr1.json)/$(grep -c 'built it' o1.md)" 0/accepted/1
hand rr2.md developer t1/rr2 src/; echo 'I did the work' > "$T/fx/answers/s2.txt"
run s2 developer --handoff rr2.md --out o2.md >/dev/null 2>&1; e=$?
eq "an answer without the line: exit 4, answer kept, id invalid" "$e/$(grep -c 'I did the work' o2.md)/$(jq -r .state .sdkit/work/t1/contracts/rr2.json)" 4/1/invalid
run s4 developer --handoff rr4.md >/dev/null 2>&1; e=$?
hand rr7.md developer t1/rr7 src/
eq "dry-run validates and registers nothing"          "$("$RR" developer --handoff rr7.md --host claude --dry-run 2>&1 | grep -c 'CONTRACT=valid')/$(test -e .sdkit/work/t1/contracts/rr7.json; echo $?)" 1/1

echo "independence and compatibility"
nocheck "sdd.sh does not know the contract script"    grep -q 'contract' "$KIT/scripts/sdd.sh"
nocheck "parse-verdict.sh does not know it either"    grep -q 'contract' "$KIT/scripts/parse-verdict.sh"
nocheck "record-verdict.sh does not know it either"   grep -q 'contract' "$KIT/hooks/record-verdict.sh"
nocheck "contract.sh never calls the phase machine"   grep -qE 'sdd\.sh|_verdict|parse-verdict' <(grep -v '^#' "$KIT/scripts/contract.sh")
eq "a verdict is recorded without any contract line"  "$(cd "$R" && printf '{"agent_type":"spec-driven-kit:verifier","last_assistant_message":"DOD\\n- D1: a | PASS | t\\nFINDINGS\\n- none\\nVERIFY\\n- command: v | result: green | ok\\nVERDICT: PASS\\nHANDOFF-RESULT/9 | x"}' | "$KIT/hooks/record-verdict.sh" >/dev/null 2>&1; echo $?)" 0
check "check-contract is registered on spawn and stop" bash -c "jq -e '[.hooks.PreToolUse[] | select(.matcher==\"Agent|Task\") | .hooks[].command] | map(test(\"check-contract\")) | any' '$KIT/hooks/hooks.json' && jq -e '[.hooks.SubagentStop[].hooks[].command] | map(test(\"check-contract\")) | any' '$KIT/hooks/hooks.json'"

finish contract
