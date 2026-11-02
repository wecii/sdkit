#!/usr/bin/env bash
# F02 tests: agent contracts (scripts/contract.sh), the Claude Code hook, run-role.sh integration, telemetry, the independence of the verifier and
# the phase gates, backward compatibility, and the contract benchmarks (simulated; nothing here starts a live host CLI). Run: tests/slow/contract.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

C="$KIT/scripts/contract.sh"; TL="$KIT/scripts/telemetry.sh"; ST="$KIT/scripts/state.sh"; SDD="$KIT/scripts/sdd.sh"
export SDKIT_GREEN="${TMPDIR:-/tmp}/sdkit-green.$$"   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }

# newrepo <name> [extra sdkit.local.env lines]: a repo with an open task t1, TELEMETRY=1 and CONTRACTS=1
newrepo() {
  local r="$T/$1"; shift; mkdir -p "$r/.sdkit" "$r/src" "$r/openspec/changes/t1"
  ( cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
    printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\nCONTRACTS=1\n' > .sdkit/sdkit.env
    printf 'TELEMETRY=1\n' > .sdkit/sdkit.local.env; for l in "$@"; do printf '%s\n' "$l" >> .sdkit/sdkit.local.env; done
    printf 'work/\n.sdd/\n.verify-cache/\nsdkit.local.env\n' > .sdkit/.gitignore
    echo plan > plan.md; echo a > src/a.sh; printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > openspec/changes/t1/proposal.md
    git add -A && git commit -qm init && git checkout -qb feat && CLAUDE_PROJECT_DIR="$r" "$ST" t1 init medium feat >/dev/null )
  echo "$r"
}
# hand <file> <role> <id> [writes] [extra lines...]: a contracted handoff
hand() {
  local f="$1" role="$2" id="$3" writes="${4:-src/}"; shift 4 2>/dev/null || shift $#
  { printf 'ROLE: %s     RISK: medium     PROJECT-DIR: .sdkit\nCONTRACT: 1\nTASK: do the thing\nREAD: plan.md\nSCOPE: writes: %s\nID: %s\n' "$role" "$writes" "$id"
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$f"
}
line() { printf 'HANDOFF-RESULT/1 | id: %s | role: %s | status: %s | artifacts: %s | blockers: %s | next: %s\n' "$1" "$2" "${3:-done}" "${4:-none}" "${5:-none}" "${6:--}"; }
reason() { printf '%s' "$1" | sed -n 's/.*reason=\([a-z-]*\):.*/\1/p'; }

R="$(newrepo main)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
EV="$R/.sdkit/work/t1/events.jsonl"

echo "a valid exchange"
hand h1.md developer t1/dev-1 src/
check "a valid handoff is issued"                      "$C" issue h1.md
check "the handoff is registered"                      test -f .sdkit/work/t1/contracts/dev-1.json
eq "the registry holds identity, role and scope only"  "$(jq -c 'keys' .sdkit/work/t1/contracts/dev-1.json)" '["access","handoff_bytes","id","issued","out","reason","result","retry_of","role","state","v","writes"]'
line t1/dev-1 developer done src/a.sh > r1.txt
out="$("$C" check-result r1.txt --role developer --record)"; r=$?
eq "a valid done result exits 0"                       "$r" 0
eq "and says so on one line"                           "$out" "CONTRACT=valid stage=result id=t1/dev-1 role=developer status=done"
eq "recorded as accepted"                              "$(jq -r .state .sdkit/work/t1/contracts/dev-1.json)" accepted
eq "a result inside prose is found"                    "$(printf 'I changed a.sh.\n\n`%s`\nthanks\n' "$(line t1/dev-1 developer done src/a.sh)" | "$C" check-result - --role developer >/dev/null; echo $?)" 2   # already accepted: duplicate, not malformed
eq "agent prefix on the role is ignored"               "$(reason "$(line t1/dev-1 developer | "$C" check-result - --role spec-driven-kit:developer)")" duplicate

echo "agent status is not contract validity"
for st in partial blocked failed; do
  hand "h-$st.md" developer "t1/$st" src/; "$C" issue "h-$st.md" >/dev/null
  line "t1/$st" developer "$st" none "tests do not compile" "ask the user" > "r-$st.txt"
  "$C" check-result "r-$st.txt" --role developer >/dev/null; eq "status $st is a valid contract, exit 1" "$?" 1
done
hand h-bn.md developer t1/bn src/; "$C" issue h-bn.md >/dev/null
eq "done with blockers is inconsistent"                "$(reason "$(line t1/bn developer done none "something" | "$C" check-result -)")" inconsistent
eq "blocked without blockers is inconsistent"          "$(reason "$(line t1/bn developer blocked none none | "$C" check-result -)")" inconsistent
eq "partial without blockers is inconsistent"          "$(reason "$(line t1/bn developer partial none none | "$C" check-result -)")" inconsistent

echo "malformed output"
hand h2.md developer t1/m1 src/; "$C" issue h2.md >/dev/null
eq "an empty answer is no-result"                      "$(reason "$(printf '' | "$C" check-result -)")" no-result
eq "whitespace only is no-result"                      "$(reason "$(printf '  \n\n' | "$C" check-result -)")" no-result
eq "prose without the line is malformed"               "$(reason "$(echo 'all done, trust me' | "$C" check-result -)")" malformed
eq "JSON instead of the line is malformed"             "$(reason "$(echo '{"id":"t1/m1","status":"done"}' | "$C" check-result -)")" malformed
eq "a truncated line is missing-field"                 "$(reason "$(echo 'HANDOFF-RESULT/1 | id: t1/m1 | role: developer' | "$C" check-result -)")" missing-field
eq "an empty field is missing-field"                   "$(reason "$(echo 'HANDOFF-RESULT/1 | id: t1/m1 | role: developer | status: done | artifacts:  | blockers: none' | "$C" check-result -)")" missing-field
eq "version 2 is unsupported"                          "$(reason "$(line t1/m1 developer | sed 's#RESULT/1#RESULT/2#' | "$C" check-result -)")" unsupported-version
eq "a version that is not a number is malformed"       "$(reason "$(line t1/m1 developer | sed 's#RESULT/1#RESULT/x#' | "$C" check-result -)")" malformed
eq "no version is malformed"                           "$(reason "$(line t1/m1 developer | sed 's#RESULT/1#RESULT#' | "$C" check-result -)")" malformed
eq "an unknown field is malformed"                     "$(reason "$(line t1/m1 developer | sed 's#$# | verified: yes#' | "$C" check-result -)")" malformed
eq "a field twice is malformed"                        "$(reason "$(line t1/m1 developer | sed 's#$# | status: done#' | "$C" check-result -)")" malformed
eq "a pipe inside a value is malformed"                "$(reason "$(line t1/m1 developer done none "a | b" | "$C" check-result -)")" malformed
eq "a status outside the set is bad-value"             "$(reason "$(line t1/m1 developer verified | "$C" check-result -)")" bad-value
eq "'verified' cannot be claimed as a status"          "$(reason "$(line t1/m1 developer VERIFIED | "$C" check-result -)")" bad-value
eq "an id that is not <task>/<label> is bad-value"     "$(reason "$(line m1 developer | "$C" check-result -)")" bad-value
eq "a 300-character blocker is bad-value"              "$(reason "$(line t1/m1 developer blocked none "$(printf 'x%.0s' $(seq 1 300))" | "$C" check-result -)")" bad-value
eq "two different lines are ambiguous"                 "$(reason "$( { line t1/m1 developer; line t1/m1 developer partial none why; } | "$C" check-result -)")" malformed
eq "the same line twice is one line"                   "$( { line t1/m1 developer; line t1/m1 developer; } | "$C" check-result - >/dev/null; echo $?)" 0
eq "an unreadable file is a usage error, not a pass"   "$("$C" check-result /nonexistent >/dev/null 2>&1; echo $?)" 2

echo "identity: id, task, role"
hand h3.md developer t1/i1 src/; "$C" issue h3.md >/dev/null
eq "another id than the handoff's"                     "$(reason "$(line t1/i2 developer | "$C" check-result - --id t1/i1)")" id-mismatch
eq "an id that was never issued"                       "$(reason "$(line t1/ghost developer | "$C" check-result -)")" unknown-id
eq "another task's id"                                 "$(reason "$(line other/i1 developer | "$C" check-result -)")" task-mismatch
eq "another role than the agent"                       "$(reason "$(line t1/i1 reviewer | "$C" check-result - --role developer)")" role-mismatch
eq "another role than the one issued"                  "$(reason "$(line t1/i1 reviewer | "$C" check-result -)")" role-mismatch
eq "the right one passes"                              "$(line t1/i1 developer | "$C" check-result - --id t1/i1 --role developer >/dev/null; echo $?)" 0
eq "a registry entry cannot be forged by the answer"   "$(reason "$(line t1/forged developer | "$C" check-result - --record)")" unknown-id
check "--record on an invalid result leaves it open"   test "$(jq -r .state .sdkit/work/t1/contracts/i1.json)" = issued
line t1/i1 reviewer | "$C" check-result - --record >/dev/null
eq "an unknown id leaves no registry entry"            "$(ls .sdkit/work/t1/contracts | grep -c forged)" 0

mkdir -p "$R/.sdkit/contracts"; echo '{"keep":"me"}' > "$R/.sdkit/contracts/victim.json"
line '../victim' developer | "$C" check-result - --record >/dev/null
eq "a path-like id in an answer touches no file"       "$(cat "$R/.sdkit/contracts/victim.json")" '{"keep":"me"}'

echo "handoff validation"
v() { local f="$T/hv.md"; hand "$f" "$@"; "$C" issue "$f" --check-only; }
eq "ok"                                                "$(v developer t1/v1 src/ >/dev/null; echo $?)" 0
eq "no CONTRACT line"                                  "$(printf 'ROLE: developer\nID: t1/v\nTASK: x\nSCOPE: writes: src/\n' | "$C" issue - --check-only | sed -n 's/.*reason=\([a-z-]*\):.*/\1/p')" missing-field
eq "CONTRACT 2 is unsupported"                         "$(reason "$(hand "$T/hv.md" developer t1/v2 src/; sed -i.bak 's/CONTRACT: 1/CONTRACT: 2/' "$T/hv.md"; "$C" issue "$T/hv.md" --check-only)")" unsupported-version
eq "no ID line"                                        "$(reason "$(hand "$T/hv.md" developer t1/v2 src/; grep -v '^ID:' "$T/hv.md" | "$C" issue - --check-only)")" missing-field
eq "a bad id"                                          "$(reason "$(v developer 'v 1' src/)")" bad-value
eq "a .. task part is refused"                         "$(reason "$(v developer ../x src/)")" bad-value
eq "a .. label is refused"                             "$(reason "$(v developer t1/.. src/)")" bad-value
eq "close refuses a path-like id"                      "$("$C" close 't1/../../../../etc/x' >/dev/null 2>&1; echo $?)" 2
eq "status refuses a path-like slug"                   "$("$C" status '../..' >/dev/null 2>&1; echo $?)" 2
eq "an id of another task"                             "$(reason "$(v developer t2/v1 src/)")" task-mismatch
eq "an unknown role"                                   "$(reason "$(v wizard t1/v1 src/)")" role-mismatch
eq "the session role is not spawnable"                 "$(reason "$(v orchestrator t1/v1 src/)")" role-mismatch
eq "the role the host is starting must match"          "$(reason "$(hand "$T/hv.md" developer t1/v1 src/; "$C" issue "$T/hv.md" --check-only --role reviewer)")" role-mismatch
eq "a read-only role with writes"                      "$(reason "$(v verifier t1/v1 src/)")" inconsistent
eq "a read-only role with writes: none is fine"        "$(v verifier t1/v1 none >/dev/null; echo $?)" 0
eq "a writing role with no writes"                     "$(reason "$(v developer t1/v1 none)")" missing-field
eq "-deep roles are their base role"                   "$(v verifier-deep t1/v1 none >/dev/null; echo $?)" 0
eq "an absolute write path"                            "$(reason "$(v developer t1/v1 /etc)")" unsafe-path
eq "a .. write path"                                   "$(reason "$(v developer t1/v1 src/../../x)")" unsafe-path
eq "a glob write path"                                 "$(reason "$(v developer t1/v1 'src/*')")" unsafe-path
eq "writes into .git"                                  "$(reason "$(v developer t1/v1 .git/hooks)")" unsafe-path
hand "$T/hv.md" developer t1/v1 src/; sed -i.bak 's#^READ: .*#READ: nope.md#' "$T/hv.md"
eq "READ: a missing file"                              "$(reason "$("$C" issue "$T/hv.md" --check-only)")" missing-artifact
sed -i.bak 's#^READ: .*#READ: ../etc/passwd#' "$T/hv.md"
eq "READ: a .. path"                                   "$(reason "$("$C" issue "$T/hv.md" --check-only)")" unsafe-path
ln -sf /etc "$R/escape"; sed -i.bak 's#^READ: .*#READ: escape/hosts#' "$T/hv.md"
eq "READ: a symlink out of the repository"             "$(reason "$("$C" issue "$T/hv.md" --check-only)")" unsafe-path
rm -f "$R/escape"
eq "OUT outside work/<task>/out/"                      "$(reason "$(v developer t1/v1 src/ 'OUT: src/a.sh')")" unsafe-path
eq "OUT of another task"                               "$(reason "$(v developer t1/v1 src/ 'OUT: work/t2/out/x.md')")" unsafe-path
eq "OUT under work/<task>/out/ is fine"                "$(v developer t1/v1 src/ 'OUT: work/t1/out/dev-1.md' >/dev/null; echo $?)" 0
eq "OUT with the project dir prefix is fine"           "$(v developer t1/v1 src/ 'OUT: .sdkit/work/t1/out/dev-1.md' >/dev/null; echo $?)" 0
eq "--check-only registers nothing"                    "$(ls .sdkit/work/t1/contracts | grep -c 'v1')" 0
eq "an unreadable handoff is a usage error"            "$("$C" issue /nonexistent >/dev/null 2>&1; echo $?)" 2

echo "artifacts of a result"
hand h4.md developer t1/a1 'src/,docs/x.md' 'OUT: work/t1/out/a1.md'; "$C" issue h4.md >/dev/null
mkdir -p docs .sdkit/work/t1/out; echo d > docs/x.md; echo o > .sdkit/work/t1/out/a1.md; echo z > outside.txt
art() { line t1/a1 developer done "$1" | "$C" check-result - --cwd "$R"; }
eq "an artifact in scope"                              "$(art 'src/a.sh,docs/x.md' >/dev/null; echo $?)" 0
eq "a missing artifact"                                "$(reason "$(art src/missing.sh)")" missing-artifact
eq "a file outside the writes"                         "$(reason "$(art outside.txt)")" out-of-scope
eq "an absolute artifact"                              "$(reason "$(art /etc/hosts)")" unsafe-path
eq "a .. artifact"                                     "$(reason "$(art 'src/../outside.txt')")" unsafe-path
eq "a ~ artifact"                                      "$(reason "$(art '~/x')")" unsafe-path
ln -s ../outside-dir "$R/src/link" 2>/dev/null; mkdir -p "$T/outside-dir"; echo s > "$T/outside-dir/s"; rm -f "$R/src/link"; ln -s "$T/outside-dir" "$R/src/link"
eq "a symlink that leaves the repository"              "$(reason "$(art src/link/s)")" unsafe-path
rm -f "$R/src/link"
eq "the handoff's OUT file is an allowed artifact"     "$(art '.sdkit/work/t1/out/a1.md' >/dev/null; echo $?)" 0
hand h5.md reviewer t1/a2 none; "$C" issue h5.md >/dev/null
eq "a read-only role cannot claim artifacts"           "$(reason "$(line t1/a2 reviewer done src/a.sh | "$C" check-result - --cwd "$R")")" inconsistent
eq "a read-only role with none is fine"                "$(line t1/a2 reviewer done none | "$C" check-result - --cwd "$R" >/dev/null; echo $?)" 0

echo "duplicate, stale, interrupted"
hand h6.md developer t1/d1 src/; "$C" issue h6.md >/dev/null
eq "the same id issued twice is a duplicate"           "$(reason "$("$C" issue h6.md)")" duplicate
eq "the first result is accepted"                      "$(line t1/d1 developer done src/a.sh | "$C" check-result - --record >/dev/null; echo $?)" 0
eq "a second result for the id is a duplicate"         "$(reason "$(line t1/d1 developer done src/a.sh | "$C" check-result - --record)")" duplicate
eq "an accepted id stays accepted"                     "$(jq -r .state .sdkit/work/t1/contracts/d1.json)" accepted
hand h7.md developer t1/s1 src/; "$C" issue h7.md >/dev/null
line t1/s1 developer partial none "x" | "$C" check-result - --record >/dev/null
hand h7b.md developer t1/s0 src/; "$C" issue h7b.md >/dev/null
echo bogus | "$C" check-result - --id t1/s0 --record >/dev/null
eq "an invalid answer marks the id invalid"            "$(jq -r .state .sdkit/work/t1/contracts/s0.json)" invalid
eq "...and a corrected answer can still be accepted"   "$(line t1/s0 developer | "$C" check-result - --record >/dev/null; jq -r .state .sdkit/work/t1/contracts/s0.json)" accepted
hand h8.md developer t1/s2 src/ 'RETRY-OF: s1'
eq "retry of an id that was accepted is refused"       "$(reason "$("$C" issue h8.md)")" bad-value
hand h9.md developer t1/s3 src/; "$C" issue h9.md >/dev/null; echo junk | "$C" check-result - --id t1/s3 --record >/dev/null
hand h10.md developer t1/s4 src/ 'RETRY-OF: t1/s3'
check "a retry of an invalid id is issued"             "$C" issue h10.md
eq "the old id is superseded"                          "$(jq -r .state .sdkit/work/t1/contracts/s3.json)" superseded
eq "a late result for the old id is stale"             "$(reason "$(line t1/s3 developer | "$C" check-result - --record)")" stale
hand h11.md reviewer t1/s5 none 'RETRY-OF: t1/s4'
eq "a retry must keep the role"                        "$(reason "$("$C" issue h11.md)")" role-mismatch
hand h12.md developer t1/s6 src/ 'RETRY-OF: t1/never'
eq "retry of an id never issued"                       "$(reason "$("$C" issue h12.md)")" unknown-id
hand h13.md developer t1/k1 src/; "$C" issue h13.md >/dev/null
eq "pending lists the unanswered ids"                  "$("$C" pending --role developer | grep -c 'k1')" 1
"$C" close t1/k1 --reason interrupted >/dev/null
eq "an interrupted agent: state"                       "$(jq -r .state .sdkit/work/t1/contracts/k1.json)" interrupted
eq "an answer after it is stale"                       "$(reason "$(line t1/k1 developer | "$C" check-result -)")" stale
eq "it is no longer pending"                           "$("$C" pending | grep -c 'k1')" 0
hand h14.md developer t1/k2 src/ 'RETRY-OF: k1'
check "an interrupted id can be retried"               "$C" issue h14.md
eq "closing an unknown id is an error"                 "$("$C" close t1/zzz >/dev/null 2>&1; echo $?)" 2

echo "concurrent agents"
for i in 1 2 3 4 5 6; do hand "c$i.md" developer "t1/par-$i" src/; done
for i in 1 2 3 4 5 6; do "$C" issue "c$i.md" >/dev/null & done; wait
eq "six parallel handoffs are all registered"          "$(ls .sdkit/work/t1/contracts | grep -c '^par-')" 6
for i in 1 2 3 4 5 6; do line "t1/par-$i" developer done src/a.sh > "pr$i.txt"; done
for i in 1 2 3 4 5 6; do "$C" check-result "pr$i.txt" --record >/dev/null & done; wait
eq "six parallel results are all accepted"             "$(for i in 1 2 3 4 5 6; do jq -r .state ".sdkit/work/t1/contracts/par-$i.json"; done | grep -c accepted)" 6
hand race.md developer t1/race src/; "$C" issue race.md >/dev/null; line t1/race developer done src/a.sh > race.txt
for i in 1 2 3 4 5 6 7 8; do "$C" check-result race.txt --record > "race.$i.out" 2>&1 & done; wait
eq "of eight identical results exactly one is accepted" "$(cat race.*.out | grep -c '^CONTRACT=valid')" 1
eq "the others are duplicates"                         "$(cat race.*.out | grep -c 'reason=duplicate')" 7
for i in 1 2 3 4 5 6; do hand "same$i.md" developer t1/same src/; done
for i in 1 2 3 4 5 6; do "$C" issue "same$i.md" > "same.$i.out" 2>&1 & done; wait
eq "of six issues of one id exactly one succeeds"      "$(cat same.*.out | grep -c '^CONTRACT=valid')" 1

echo "telemetry"
eq "the events file is still valid"                    "$("$TL" validate t1 | head -1 | cut -c1-3)" "ok:"
S="$("$TL" summary t1 --json)"
check "the summary has a contracts section"            jq -e '.contracts.checked > 0' <<< "$S"
eq "outcomes and reasons are counted"                  "$(jq -r '.contracts.by_reason.duplicate > 0 and .contracts.by_reason.malformed > 0' <<< "$S")" true
eq "agent statuses are counted"                        "$(jq -r '.contracts.by_status.done > 0 and .contracts.by_status.blocked > 0' <<< "$S")" true
eq "the schema version is recorded"                    "$(jq -c '.contracts.versions' <<< "$S")" "[1]"
eq "a failure/contract is counted per invalid check"   "$(jq -r '.failures.by_category.contract' <<< "$S")" "$(jq -r '.contracts.invalid' <<< "$S")"
eq "events carry the id, not the text"                 "$(jq -r 'select(.type=="contract.check") | keys[]' "$EV" | sort -u | tr '\n' ' ')" "bytes contract cv mode outcome reason role run source stage status task ts type v "
check "sizes are measured numbers"                     bash -c "jq -e 'select(.type==\"contract.check\") | .bytes | numbers' '$EV' >/dev/null"
nocheck "no event holds a prompt, answer or blocker text" bash -c "grep -q 'tests do not compile\|do the thing' '$EV'"
nocheck "a contract.check without a stage is rejected"  "$TL" emit contract.check --task t1 --outcome valid --cv 1 --strict
nocheck "an invalid check needs a reason"              "$TL" emit contract.check --task t1 --outcome invalid --stage result --cv 1 --strict
nocheck "an unknown reason is rejected"                "$TL" emit contract.check --task t1 --outcome invalid --stage result --cv 1 --reason because --strict
nocheck "an unknown agent status is rejected"          "$TL" emit contract.check --task t1 --outcome valid --stage result --cv 1 --status verified --strict
check "the render shows the contracts line"            bash -c "'$TL' summary t1 | grep -q 'contracts: .*not a verification'"
Q="$(newrepo quiet)"; sed -i.bak '/TELEMETRY/d' "$Q/.sdkit/sdkit.local.env"; rm -f "$Q/.sdkit/sdkit.local.env.bak"
( cd "$Q" && export CLAUDE_PROJECT_DIR="$Q"; hand h.md developer t1/q1 src/; "$C" issue h.md >/dev/null; line t1/q1 developer done src/a.sh | "$C" check-result - --record >/dev/null )
eq "TELEMETRY off: contracts work, no events file"     "$(test -e "$Q/.sdkit/work/t1/events.jsonl"; echo $?)" 1
eq "TELEMETRY off: the registry still records"         "$(jq -r .state "$Q/.sdkit/work/t1/contracts/q1.json")" accepted
cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"

echo "the Claude Code hook"
HK="$KIT/hooks/check-contract.sh"
pre() { jq -nc --arg p "$(cat "$1")" --arg t "${2:-spec-driven-kit:developer}" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{prompt:$p,subagent_type:$t,description:"d"}}'; }
stop() { jq -nc --arg m "$1" --arg t "${2:-spec-driven-kit:developer}" '{hook_event_name:"SubagentStop",agent_type:$t,agent_id:"ag1",last_assistant_message:$m}'; }
hand hk1.md developer t1/hk1 src/
eq "a contracted spawn is registered"                  "$(pre hk1.md | "$HK" >/dev/null; jq -r .state .sdkit/work/t1/contracts/hk1.json)" issued
eq "an invalid spawn asks first (strict)"              "$(hand hk2.md developer t1/hk2 /etc; pre hk2.md | "$HK" | jq -r .hookSpecificOutput.permissionDecision)" ask
eq "the reason names the category"                     "$(pre hk2.md | "$HK" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -c 'unsafe-path')" 1
GM="$(newrepo guided 'SDD_MODE=guided')"; OF="$(newrepo modeoff 'SDD_MODE=off')"
eq "guided mode only warns"                            "$(cd "$GM"; pre "$R/hk2.md" | CLAUDE_PROJECT_DIR="$GM" "$HK" | jq -r 'has("systemMessage")')" true
eq "SDD_MODE=off says nothing"                         "$(cd "$OF"; pre "$R/hk2.md" | CLAUDE_PROJECT_DIR="$OF" "$HK")" ""
eq "a spawn for another role than ROLE: asks"          "$(hand hk3.md developer t1/hk3 src/; pre hk3.md spec-driven-kit:reviewer | "$HK" | jq -r .hookSpecificOutput.permissionDecision)" ask
eq "a valid answer is silent"                          "$(stop "$(printf 'ok\n%s' "$(line t1/hk1 developer done src/a.sh)")" | "$HK")" ""
eq "and is recorded"                                   "$(jq -r .state .sdkit/work/t1/contracts/hk1.json)" accepted
hand hk4.md developer t1/hk4 src/; pre hk4.md | "$HK" >/dev/null
eq "a blocked agent is silent (valid contract)"        "$(stop "$(line t1/hk4 developer blocked none 'need a decision')" | "$HK")" ""
hand hk5.md developer t1/hk5 src/; pre hk5.md | "$HK" >/dev/null
eq "an answer without the line is reported"           "$(stop 'finished everything' | "$HK" | jq -r .systemMessage | grep -c 'NOT accepted')" 1
eq "a wrong-role answer is reported"                   "$(stop "$(line t1/hk5 reviewer)" | "$HK" | jq -r .systemMessage | grep -c 'role-mismatch')" 1
eq "a hook never blocks (exit 0)"                      "$(stop 'x' | "$HK" >/dev/null 2>&1; echo $?)" 0
check "the fallback reads the transcript"              bash -c "printf '%s\n' '{\"type\":\"assistant\",\"message\":{\"id\":\"m\",\"content\":[{\"type\":\"text\",\"text\":\"$(line t1/hk5 developer)\"}]}}' > '$T/tr.jsonl'; jq -nc --arg t '$T/tr.jsonl' '{hook_event_name:\"SubagentStop\",agent_type:\"developer\",agent_transcript_path:\$t}' | '$HK'; test \$(jq -r .state .sdkit/work/t1/contracts/hk5.json) = accepted"
# legacy: no contract anywhere
L="$(newrepo legacy)"
cd "$L" || exit 1; export CLAUDE_PROJECT_DIR="$L"   # (not a subshell: a failure in here must count)
  printf 'ROLE: developer\nTASK: x\nSCOPE: writes: src/\n' > old.md
  eq "legacy spawn: silent, nothing registered"        "$(pre old.md | "$HK"; ls .sdkit/work/t1/contracts 2>/dev/null | wc -l | tr -d ' ')" 0
  eq "legacy answer with nothing waiting: silent"      "$(stop 'all done' | "$HK")" ""
  eq "legacy: no events from the contract hook"        "$(cat .sdkit/work/t1/events.jsonl 2>/dev/null | grep -c contract)" 0
  hand c.md developer t1/w1 src/; pre c.md | "$HK" >/dev/null
  eq "but a waiting handoff makes a bare answer a finding" "$(stop 'all done' | "$HK" | jq -r 'has("systemMessage")')" true
  sed -i.bak '/CONTRACTS/d' .sdkit/sdkit.env
  eq "CONTRACTS off: the hook is silent"               "$(pre c.md | "$HK"; stop 'all done' | "$HK")" ""
cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"

echo "run-role.sh"
RR="$KIT/scripts/run-role.sh"
G="$(newrepo rr 'RUN_ROLE_HOST=claude' 'USAGE_LOG=1')"; cd "$G" || exit 1; export CLAUDE_PROJECT_DIR="$G"
mkdir -p "$T/fx/answers" "$T/fx/usage" "$T/fx/sim/s1" "$T/fx/fail"; echo 'a' > "$T/fx/sim/s1/new.sh"
run() { local step="$1"; shift; SDKIT_BENCH_SCENARIO="$T/fx" SDKIT_BENCH_STEP="$step" PATH="$KIT/bench/stub-host:$PATH" "$RR" "$@" --cwd "$G"; }
hand rr1.md developer t1/rr1 src/,new.sh 'READ: plan.md'
{ echo 'built it'; line t1/rr1 developer done new.sh; } > "$T/fx/answers/s1.txt"; echo '100 40 500 60' > "$T/fx/usage/s1"
run s1 developer --handoff rr1.md --out o1.md >/dev/null 2>"$T/rr.err"; eq "a contracted run with a valid answer exits 0" "$?" 0
check "the registry says accepted"                     test "$(jq -r .state .sdkit/work/t1/contracts/rr1.json)" = accepted
check "the answer is still printed and stored"         grep -q 'built it' o1.md
check "the summary goes to stderr"                     grep -q 'CONTRACT=valid stage=result' "$T/rr.err"
hand rr2.md developer t1/rr2 src/,new.sh; echo 'I did the work' > "$T/fx/answers/s2.txt"
run s2 developer --handoff rr2.md --out o2.md >/dev/null 2>&1; eq "an answer without the line exits 4" "$?" 4
check "...and the answer is kept for the orchestrator" grep -q 'I did the work' o2.md
eq "...and the id is open for a retry"                 "$(jq -r .state .sdkit/work/t1/contracts/rr2.json)" invalid
hand rr3.md developer t1/rr3 src/ 'RETRY-OF: rr2'; line t1/rr3 developer blocked none 'needs a decision' > "$T/fx/answers/s3.txt"
run s3 developer --handoff rr3.md >/dev/null 2>&1; eq "a valid blocked answer exits 5" "$?" 5
hand rr4.md developer t1/rr4 src/; echo "boom" > "$T/fx/fail/s4"
run s4 developer --handoff rr4.md >/dev/null 2>&1; eq "a host failure keeps the host's status" "$?" 7
eq "...and closes the id as interrupted"               "$(jq -r .state .sdkit/work/t1/contracts/rr4.json)" interrupted
hand rr5.md developer t1/rr5 /etc
run s1 developer --handoff rr5.md >/dev/null 2>&1; eq "an invalid handoff is not started (exit 2)" "$?" 2
eq "...so no agent ran for it"                         "$(jq -r 'select(.type=="agent.start") | .role' .sdkit/work/t1/events.jsonl | wc -l | tr -d ' ')" 4
hand rr6.md verifier t1/rr6 none; mkdir -p "$T/fx/answers"; printf 'DOD\n- D1 | PASS | t\nFINDINGS\n- none\nVERIFY\n- command: t | result: green | ok\nVERDICT: PASS\n%s\n' "$(line t1/rr6 verifier done none)" > "$T/fx/answers/s6.txt"
run s6 verifier --handoff rr6.md --host claude >/dev/null 2>&1; eq "a verifier answer carries both blocks" "$?" 0
check "parse-verdict still accepts the same text"      bash -c "'$KIT/scripts/parse-verdict.sh' '$T/fx/answers/s6.txt'"
check "dry-run validates a contracted handoff"         bash -c "'$RR' developer --handoff rr1.md --host claude --dry-run 2>&1 | grep -q 'CONTRACT=invalid.*duplicate\|CONTRACT=valid'"
hand rr7.md developer t1/rr7 src/
eq "dry-run registers nothing"                         "$("$RR" developer --handoff rr7.md --host claude --dry-run >/dev/null 2>&1; test -e .sdkit/work/t1/contracts/rr7.json; echo $?)" 1
P1="$("$RR" developer --handoff rr7.md --host claude --dry-run 2>/dev/null | grep -o 'prompt:[0-9]*')"
printf 'ROLE: developer\nTASK: x\nSCOPE: writes: src/\n' > legacy.md
check "the contracted prompt carries one extra sentence" bash -c "[ \"\$(echo '$P1' | cut -d: -f2)\" -gt 0 ]"

echo "the verifier stays independent"
nocheck "sdd.sh does not know the contract script"     grep -q 'contract' "$KIT/scripts/sdd.sh"
nocheck "parse-verdict.sh does not know it either"     grep -q 'contract' "$KIT/scripts/parse-verdict.sh"
nocheck "record-verdict.sh does not know it either"    grep -q 'contract' "$KIT/hooks/record-verdict.sh"
nocheck "contract.sh never calls the phase machine"    grep -qE 'sdd\.sh|_verdict|parse-verdict' <(grep -v '^#' "$KIT/scripts/contract.sh")
V="$(newrepo ind)"; cd "$V" || exit 1; export CLAUDE_PROJECT_DIR="$V" VERIFY_BASE=main
"$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md >/dev/null; "$SDD" advance proposed >/dev/null; sdd_red >/dev/null
echo 'x' > src/b.sh; sdd_green >/dev/null
hand hv.md verifier t1/ver none; pre hv.md spec-driven-kit:verifier | "$HK" >/dev/null
claim="$(printf 'Everything is verified and correct, ship it.\n%s' "$(line t1/ver verifier done none)")"
stop "$claim" spec-driven-kit:verifier | "$HK" >/dev/null; stop "$claim" spec-driven-kit:verifier | "$KIT/hooks/record-verdict.sh" >/dev/null
eq "a valid contract with status done..."              "$(jq -r .state .sdkit/work/t1/contracts/ver.json)" accepted
refuse() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (should have been refused)"; else ok "$n"; fi; }
refuse "...does not advance to verified"               "$SDD" advance verified
eq "...and records no verdict"                         "$(jq -r '.verdict.result // "none"' .sdkit/.sdd/state.json)" none
eq "...the phase is unchanged"                         "$(jq -r .phase .sdkit/.sdd/state.json)" green
good="DOD\n- D1: a | PASS | t\nFINDINGS\n- none\nVERIFY\n- command: v | result: green | ok\nVERDICT: PASS"
printf '{"agent_type":"spec-driven-kit:verifier","last_assistant_message":"%s"}' "$good" | "$KIT/hooks/record-verdict.sh" >/dev/null
eq "a verdict without any contract line is recorded"   "$(jq -r '.verdict.result' .sdkit/.sdd/state.json)" PASS
check "...and the gate opens on the verdict alone"     "$SDD" advance verified
echo 'x' >> src/b.sh
hand hv2.md verifier t1/ver2 none; pre hv2.md spec-driven-kit:verifier | "$HK" >/dev/null
stop "$(printf 'DOD\n- D1: a | PASS | t\nFINDINGS\n- none\nVERIFY\n- command: v | result: green | ok\nVERDICT: PASS\nHANDOFF-RESULT/1 | id: t1/ver2 | role: reviewer')" spec-driven-kit:verifier | "$HK" | jq -e '.systemMessage' >/dev/null
eq "a broken contract on a verifier is reported"       "$?" 0
eq "...but the contract never blocks the verdict"      "$(printf '{"agent_type":"spec-driven-kit:verifier","last_assistant_message":"%s\\nHANDOFF-RESULT/9 | x"}' "$good" | "$KIT/hooks/record-verdict.sh" >/dev/null; jq -r '.verdict.result' .sdkit/.sdd/state.json)" PASS

echo "backward compatibility"
cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
check "the hook list keeps every earlier hook"         bash -c "jq -e '[.hooks[][].hooks[].command] | map(select(test(\"guard-budget|record-verdict|usage-log|result-size|stop-verify\"))) | unique | length == 5' '$KIT/hooks/hooks.json'"
check "check-contract is registered on both events"    bash -c "jq -e '[.hooks.PreToolUse[] | select(.matcher==\"Agent|Task\") | .hooks[].command] | map(test(\"check-contract\")) | any' '$KIT/hooks/hooks.json' && jq -e '[.hooks.SubagentStop[].hooks[].command] | map(test(\"check-contract\")) | any' '$KIT/hooks/hooks.json'"
eq "the shared template ships CONTRACTS empty (off)"   "$(sed -n 's/^CONTRACTS=//p' "$KIT/templates/sdkit.env")" ""
eq "a handoff in the old format is not a contract"     "$(printf 'ROLE: verifier\nTASK: x\n' | "$C" issue - --check-only | sed -n 's/.*reason=\([a-z-]*\):.*/\1/p')" missing-field
eq "an old handoff goes through run-role unchanged"    "$("$RR" developer --handoff "$G/legacy.md" --host claude --dry-run 2>&1 | grep -c CONTRACT)" 0
eq "...with no registry entry"                         "$(ls .sdkit/work/t1/contracts | grep -c legacy)" 0

echo "contracts: $pass passed, $fail failed"
[ "$fail" = 0 ]
