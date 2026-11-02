#!/usr/bin/env bash
# F03 tests: workflow profiles, the transition table, rejection reasons, the verification gates per profile, contract policy by profile and
# boundary, interrupted agents, stale evidence, concurrent state changes, telemetry, and the legacy workflow. Run: tests/slow/workflow.test.sh
set -u
[ -n "${PSEC_ONLY:-}" ] || exec "$(dirname "$0")/../lib/psections.sh" "$0" "$@"   # independent parts run at the same time, dependent sections as one chain
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (should have failed)"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

SDD="$KIT/scripts/sdd.sh"; WF="$KIT/scripts/workflow.sh"; C="$KIT/scripts/contract.sh"; ST="$KIT/scripts/state.sh"; HK="$KIT/hooks/check-contract.sh"
export SDKIT_GREEN="${TMPDIR:-/tmp}/sdkit-green.$$"   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }
export VERIFY_BASE=main

# newrepo <name> [extra sdkit.env lines]: a repo on branch feat, TELEMETRY=1, a proposal with a DoD and (for high risk) a design scenario
newrepo() {
  local r="$T/$1"; shift; mkdir -p "$r/.sdkit" "$r/src" "$r/openspec/changes/t1"
  ( cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
    printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\n' > .sdkit/sdkit.env
    for l in "$@"; do printf '%s\n' "$l" >> .sdkit/sdkit.env; done
    printf 'TELEMETRY=1\n' > .sdkit/sdkit.local.env
    printf 'work/\n.sdd/\n.verify-cache/\nsdkit.local.env\n' > .sdkit/.gitignore
    echo a > src/a.sh; printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > openspec/changes/t1/proposal.md
    printf '# D\n## Race scenario\ntwo writers\n' > openspec/changes/t1/design.md
    git add -A && git commit -qm init && git checkout -qb feat )
  echo "$r"
}
use() { cd "$1" || exit 1; export CLAUDE_PROJECT_DIR="$1"; EV="$1/.sdkit/work/t1/events.jsonl"; }
# to <phase>: walk a task already started (intake) to <phase> with the real gates
to() {
  local want="$1" p
  for p in proposed red green; do
    case "$p" in proposed) "$SDD" advance proposed ;; red) sdd_red ;; green) echo "x=$p" >> src/a.sh; sdd_green ;; esac >/dev/null 2>&1 || return 1
    [ "$p" = "$want" ] && return 0
  done
}
phase() { "$SDD" phase; }
rejects() { jq -r 'select(.type=="phase.reject") | .reason // "none"' "$EV" 2>/dev/null | tr '\n' ' '; }
last_reason() { jq -r 'select(.type=="phase.reject") | .reason // "none"' "$EV" 2>/dev/null | tail -1; }
verdict() { "$SDD" _verdict "$1"; }

echo "the transition table"
R="$(newrepo tbl)"; use "$R"
tr_out="$("$SDD" transitions)"
eq "one line per move, plus re-verify and abort"        "$(printf '%s\n' "$tr_out" | wc -l | tr -d ' ')" 8
check "intake > proposed is listed with its rule"       grep -q 'intake > proposed .*Definition of Done' <<< "$tr_out"
check "the way back is only abort"                      grep -q 'any > (aborted)' <<< "$tr_out"
nocheck "no task: advance is refused"                   "$SDD" advance proposed
check "start (default profile)"                         "$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md
eq "the default profile is standard"                    "$(jq -r .profile .sdkit/.sdd/state.json)" standard
eq "status of a standard task is unchanged"             "$("$SDD" status)" "task=t1 risk=medium phase=intake"
# every invalid move from every phase leaves the state alone, and names why
PH="intake proposed red green verified pr done"
chk_matrix() {  # from the current phase, every target but the next must be refused, state untouched
  local cur nxt t before; cur="$(phase)"; nxt=""; local seen=0 p
  for p in $PH; do [ "$seen" = 1 ] && { nxt="$p"; break; }; [ "$p" = "$cur" ] && seen=1; done
  before="$(jq -S . .sdkit/.sdd/state.json)"
  for t in $PH bogus; do
    [ "$t" = "$nxt" ] && continue
    [ "$t" = verified ] && [ "$cur" = verified ] && continue
    [ "$t" = verified ] && [ "$cur" = pr ] && continue
    "$SDD" advance "$t" --test-cmd false >/dev/null 2>&1 && { bad "from $cur, '$t' was accepted"; return; }
  done
  eq "from $cur every other target is refused, state untouched" "$(jq -S . .sdkit/.sdd/state.json)" "$before"
}
chk_matrix
eq "intake>red is not-next"                             "$(sdd_red 2>&1 | grep -c 'Phases are not skipped')" 1
eq "reason recorded: not-next"                          "$(last_reason)" not-next
"$SDD" advance bogus >/dev/null 2>&1; eq "reason recorded: unknown-phase" "$(last_reason)" unknown-phase
mv openspec/changes/t1/proposal.md /tmp/prop.$$; "$SDD" advance proposed >/dev/null 2>&1; eq "missing artifact: no-artifact" "$(last_reason)" no-artifact
printf '# P\nno dod\n' > openspec/changes/t1/proposal.md; "$SDD" advance proposed >/dev/null 2>&1; eq "no DoD: no-dod" "$(last_reason)" no-dod
mv /tmp/prop.$$ openspec/changes/t1/proposal.md
check "intake > proposed"                               "$SDD" advance proposed
chk_matrix
"$SDD" advance red --test-cmd true >/dev/null 2>&1;     eq "passing tests are not RED: tests-pass" "$(last_reason)" tests-pass
check "proposed > red"                                  sdd_red
chk_matrix
echo 'x=1' >> src/a.sh
"$SDD" advance green >/dev/null 2>&1;  eq "failing tests are not GREEN: tests-fail" "$(last_reason)" tests-fail
check "red > green"                                     sdd_green
chk_matrix
"$SDD" advance verified >/dev/null 2>&1;                eq "medium without a verdict: no-verdict" "$(last_reason)" no-verdict
verdict BLOCK;  "$SDD" advance verified >/dev/null 2>&1; eq "a BLOCK verdict: verdict-block" "$(last_reason)" verdict-block
eq "the BLOCK message names the next step (first retry)" "$("$SDD" advance verified 2>&1 | grep -c 'one retry')" 1
"$ST" t1 init medium feat >/dev/null; "$ST" t1 retry dev >/dev/null
eq "...and, once the retry is spent, says stop"         "$("$SDD" advance verified 2>&1 | grep -c 'ask the user')" 1
verdict PASS;   echo 'x=late' >> src/a.sh; "$SDD" advance verified >/dev/null 2>&1; eq "a verdict for an older diff: stale-verdict" "$(last_reason)" stale-verdict
verdict PASS
check "green > verified (independent PASS for this diff)" "$SDD" advance verified
check "verified > verified is refused while fresh"      bash -c "! '$SDD' advance verified"
chk_matrix
echo 'x=after' >> src/a.sh
eq "an edit after verification shows in status"         "$("$SDD" status)" "task=t1 risk=medium phase=verified verdict=PASS evidence=stale"
nocheck "a push of a stale diff is refused (out-of-phase)" "$SDD" gate push
eq "reason recorded: out-of-phase"                      "$(last_reason)" out-of-phase
nocheck "re-verifying needs a verdict for the new diff" "$SDD" advance verified
verdict PASS
check "verified > verified re-verifies a stale diff"    "$SDD" advance verified
check "verified > pr"                                   "$SDD" advance pr
chk_matrix
echo 'x=afterpr' >> src/a.sh
nocheck "after pr a stale diff cannot be pushed"        "$SDD" gate push
verdict PASS
check "pr > verified re-verifies after a late edit"     "$SDD" advance verified
check "...and pr again"                                 "$SDD" advance pr
check "pr > done"                                       "$SDD" advance done
nocheck "done closes the task"                          test -f .sdkit/.sdd/state.json
check "telemetry records every rejection with a reason" bash -c "! jq -e 'select(.type==\"phase.reject\" and (.reason|not))' '$EV' >/dev/null"
check "the event file validates against the schema"     "$KIT/scripts/telemetry.sh" validate t1

echo "profiles and risk are separate"
R="$(newrepo prof)"; use "$R"
nocheck "an unknown profile is refused"                 "$SDD" start t1 --risk low --profile turbo --proposal openspec/changes/t1/proposal.md
nocheck "small is refused for medium risk"              "$SDD" start t1 --risk medium --profile small --proposal openspec/changes/t1/proposal.md
nocheck "small is refused for high risk"                "$SDD" start t1 --risk high --profile small --proposal openspec/changes/t1/proposal.md
nocheck "refusing a start leaves no state"              test -f .sdkit/.sdd/state.json
check "small is fine for low risk"                      "$SDD" start t1 --risk low --profile small --proposal openspec/changes/t1/proposal.md
eq "status shows a non-default profile"                 "$("$SDD" status)" "task=t1 risk=low phase=intake profile=small"
nocheck "a second start is refused"                     "$SDD" start t2 --risk low --proposal openspec/changes/t1/proposal.md
check "small walks the low flow to verified (verify command)" bash -c "cd '$R' && source /dev/null; '$SDD' advance proposed && '$SDD' advance red --test-cmd \"grep -q GM1 src/a.sh\" && echo GM1 >> src/a.sh && '$SDD' advance green && '$SDD' advance verified"
check "small reaches done"                              bash -c "'$SDD' advance pr && '$SDD' advance done"
echo "small never lowers the risk floor"
R="$(newrepo floor 'RISK_FLOOR_GLOBS=high:src/*')"; use "$R"
"$SDD" start t1 --risk low --profile small --proposal openspec/changes/t1/proposal.md >/dev/null
"$SDD" advance proposed >/dev/null; sdd_red >/dev/null; echo z >> src/a.sh
nocheck "small + a diff in a high-risk path: green refused" sdd_green
eq "reason recorded: risk-floor"                        "$(last_reason)" risk-floor
eq "the floor still names the label"                    "$(sdd_green 2>&1 | grep -c 'needs risk high')" 1
"$SDD" abort >/dev/null

echo "high-assurance: an independent verifier even for low risk"
R="$(newrepo ha)"; use "$R"
check "start low + high-assurance"                      "$SDD" start t1 --risk low --profile high-assurance --proposal openspec/changes/t1/proposal.md
to green
nocheck "the verify command is not enough"              "$SDD" advance verified
eq "reason: no-verdict, and it says why"                "$(last_reason) $("$SDD" advance verified 2>&1 | grep -c 'profile high-assurance')" "no-verdict 1"
verdict PASS
check "a PASS for this diff verifies it"                "$SDD" advance verified
eq "the attestation records the profile"                "$(jq -r .profile .sdkit/attestations/t1.json)" high-assurance
check "ci-check passes with the attested PASS"          "$SDD" ci-check
jq '.verdict="BLOCK"' .sdkit/attestations/t1.json > a.tmp && mv a.tmp .sdkit/attestations/t1.json
nocheck "ci-check: a low-risk high-assurance attestation needs the PASS" "$SDD" ci-check
"$SDD" abort >/dev/null
echo "high risk keeps its design-scenario gate under every profile"
R="$(newrepo hi)"; use "$R"
"$SDD" start t1 --risk high --profile high-assurance --proposal openspec/changes/t1/proposal.md >/dev/null
printf '# D\nnothing\n' > openspec/changes/t1/design.md
nocheck "no race section: proposed refused"             "$SDD" advance proposed
eq "reason: no-design"                                  "$(last_reason)" no-design
"$SDD" abort >/dev/null

echo "policy is inspectable"
R="$(newrepo pol)"; use "$R"
eq "no task: the defaults"                              "$("$WF" policy)" "task=- risk=- profile=standard verifier=verify-command contracts=off (scout/analyst: off) automatic-retries=1"
"$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md >/dev/null
eq "medium standard: verifier mandatory, contracts off" "$("$SDD" policy)" "task=t1 risk=medium profile=standard verifier=independent-verifier contracts=off (scout/analyst: off) automatic-retries=1"
eq "--json is valid and complete"                       "$("$SDD" policy --json | jq -r '[.profile,.verifier,.contracts.writing_and_deciding_roles]|join(",")')" "standard,independent-verifier,off"
"$SDD" abort >/dev/null
"$SDD" start t1 --risk low --profile high-assurance --proposal openspec/changes/t1/proposal.md >/dev/null
eq "low high-assurance: verifier mandatory, contracts required" "$("$SDD" policy)" "task=t1 risk=low profile=high-assurance verifier=independent-verifier contracts=required (scout/analyst: optional) automatic-retries=1"
eq "profiles are listed"                                "$("$WF" profiles | wc -l | tr -d ' ')" 3
"$SDD" abort >/dev/null

echo "contract policy by profile and role"
lvl() { "$WF" contracts --role "$1"; }
R="$(newrepo cp0)"; use "$R"
eq "no task, CONTRACTS unset: off"                      "$(lvl developer)" off
R="$(newrepo cp1 CONTRACTS=1)"; use "$R"
eq "no task, CONTRACTS=1: optional"                     "$(lvl developer)" optional
"$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md >/dev/null
eq "standard + CONTRACTS=1: optional (legacy)"          "$(lvl verifier)" optional
"$SDD" abort >/dev/null
"$SDD" start t1 --risk low --profile small --proposal openspec/changes/t1/proposal.md >/dev/null
eq "small + CONTRACTS=1: optional, never required"      "$(lvl developer)" optional
"$SDD" abort >/dev/null
"$SDD" start t1 --risk medium --profile high-assurance --proposal openspec/changes/t1/proposal.md >/dev/null
for role in developer test-writer devsecops engineer verifier verifier-deep reviewer security-auditor spec-driven-kit:developer; do
  eq "high-assurance: $role required"                   "$(lvl "$role")" required
done
eq "high-assurance: scout stays optional"               "$(lvl scout)" optional
eq "high-assurance: analyst stays optional"             "$(lvl analyst)" optional
eq "high-assurance: an agent that is not a kit role is optional" "$(lvl Explore)" optional
"$SDD" abort >/dev/null
R="$(newrepo cp2)"; use "$R"
"$SDD" start t1 --risk medium --profile high-assurance --proposal openspec/changes/t1/proposal.md >/dev/null
eq "high-assurance needs no CONTRACTS setting"          "$(lvl developer)" required

echo "the Claude Code hook (agent boundary)"
pre() { jq -nc --arg p "$1" --arg r "$2" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{prompt:$p,subagent_type:$r}}'; }
decision() { local o; o="$(cat)"; [ -z "$o" ] && { echo silent; return; }; printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // (if .systemMessage then "warn" else "silent" end)'; }
hand() { printf 'ROLE: %s\nCONTRACT: 1\nTASK: x\nREAD: src/a.sh\nSCOPE: writes: %s\nID: t1/%s\nREPLY-END: x\n' "$1" "${3:-none}" "$2"; }
plain="ROLE: developer
TASK: x"
eq "no marker, developer: asks (strict)"                "$(pre "$plain" developer | "$HK" | decision)" ask
eq "...the reason says what to add"                     "$(pre "$plain" developer | "$HK" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -c 'CONTRACT: 1')" 1
eq "no marker, scout: silent"                           "$(pre "$plain" scout | "$HK" | decision)" silent
eq "no marker, a non-kit agent: silent"                 "$(pre "$plain" Explore | "$HK" | decision)" silent
eq "a valid contracted handoff: silent"                 "$(pre "$(hand verifier v1)" verifier | "$HK" | decision)" silent
eq "...and it is registered"                            "$(jq -r .state .sdkit/work/t1/contracts/v1.json)" issued
eq "an invalid contracted handoff still asks"           "$(pre "$(hand verifier v1 | sed '/^READ/d')" verifier | "$HK" | decision)" ask
sed -i.bak 's/SDD_MODE=strict/SDD_MODE=guided/' .sdkit/sdkit.env
eq "guided: a warning, not a question"                  "$(pre "$plain" developer | "$HK" | decision)" warn
sed -i.bak 's/SDD_MODE=guided/SDD_MODE=off/' .sdkit/sdkit.env
eq "off: silent"                                        "$(pre "$plain" developer | "$HK" | decision)" silent
sed -i.bak 's/SDD_MODE=off/SDD_MODE=strict/' .sdkit/sdkit.env
check "the refusal is a telemetry decision"             bash -c "jq -e 'select(.type==\"workflow.decision\" and .outcome==\"missing-marker\" and .role==\"developer\")' '$EV'"
"$SDD" abort >/dev/null
echo "standard stays legacy: no contract, no question"
R="$(newrepo legacy)"; use "$R"
"$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md >/dev/null
eq "standard, CONTRACTS unset: the hook is silent"      "$(pre "$plain" developer | "$HK" | decision)" silent
echo 'CONTRACTS=1' >> .sdkit/sdkit.env
eq "standard, CONTRACTS=1, no marker: silent (legacy handoff)" "$(pre "$plain" developer | "$HK" | decision)" silent
"$SDD" abort >/dev/null

echo "run-role.sh (process boundary)"
R="$(newrepo rr)"; use "$R"
printf 'ROLE: developer\nTASK: x\n' > plain.md; hand developer d1 src/ > ctr.md
"$SDD" start t1 --risk medium --profile high-assurance --proposal openspec/changes/t1/proposal.md >/dev/null
"$KIT/scripts/run-role.sh" developer --handoff plain.md --host claude --dry-run >/dev/null 2>err.txt; rc=$?
eq "high-assurance: an uncontracted handoff exits 2"    "$rc" 2
eq "...and says why"                                    "$(grep -c 'requires a contract' err.txt)" 1
"$KIT/scripts/run-role.sh" scout --handoff plain.md --host claude --dry-run >/dev/null 2>&1; eq "a scout handoff is fine" "$?" 0
"$KIT/scripts/run-role.sh" developer --handoff ctr.md --host claude --dry-run >/dev/null 2>&1; eq "a contracted handoff is fine" "$?" 0
sed -i.bak 's/SDD_MODE=strict/SDD_MODE=guided/' .sdkit/sdkit.env
"$KIT/scripts/run-role.sh" developer --handoff plain.md --host claude --dry-run >/dev/null 2>&1; eq "guided: warns, runs" "$?" 0
"$SDD" abort >/dev/null
"$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md >/dev/null
sed -i.bak 's/SDD_MODE=guided/SDD_MODE=strict/' .sdkit/sdkit.env
"$KIT/scripts/run-role.sh" developer --handoff plain.md --host claude --dry-run >/dev/null 2>&1; eq "standard: an uncontracted handoff is as before" "$?" 0
"$SDD" abort >/dev/null

echo "a valid contract never replaces the verifier"
R="$(newrepo nover)"; use "$R"
"$SDD" start t1 --risk low --profile high-assurance --proposal openspec/changes/t1/proposal.md >/dev/null
to green
hand verifier v1 > h.md; "$C" issue h.md --role verifier >/dev/null
printf 'HANDOFF-RESULT/1 | id: t1/v1 | role: verifier | status: done | artifacts: none | blockers: none | next: -\n' | "$C" check-result - --id t1/v1 --role verifier --record >/dev/null
nocheck "a valid, done verifier contract does not verify" "$SDD" advance verified
eq "and records no verdict"                             "$(jq -r '.verdict.result // "none"' .sdkit/.sdd/state.json)" none
check "sdd.sh never mentions contracts"                 bash -c "! grep -qi contract '$KIT/scripts/sdd.sh'"

echo "interrupted agents block green and verified under high-assurance only"
R="$(newrepo intr)"; use "$R"
"$SDD" start t1 --risk medium --profile high-assurance --proposal openspec/changes/t1/proposal.md >/dev/null
"$SDD" advance proposed >/dev/null; sdd_red >/dev/null; echo q >> src/a.sh
hand developer d1 src/ > h.md; "$C" issue h.md --role developer >/dev/null
nocheck "an unanswered agent blocks green"              sdd_green
eq "reason: agents-pending, naming the id"              "$(last_reason) $(sdd_green 2>&1 | grep -c 't1/d1')" "agents-pending 1"
"$C" close t1/d1 --reason interrupted >/dev/null
check "closed (interrupted): green is possible"         sdd_green
"$ST" t1 init medium feat >/dev/null
check "the interrupted id is retried once"              "$ST" t1 retry t1/d1
nocheck "...and only once"                              "$ST" t1 retry t1/d1
hand verifier v1 > h2.md; "$C" issue h2.md --role verifier >/dev/null
verdict PASS
nocheck "a verifier still in flight blocks verified"    "$SDD" advance verified
"$C" close t1/v1 >/dev/null
check "answered or closed: verified"                    "$SDD" advance verified
"$SDD" abort >/dev/null
R="$(newrepo intr2)"; use "$R"
"$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md >/dev/null
"$SDD" advance proposed >/dev/null; sdd_red >/dev/null; echo q >> src/a.sh
hand developer d1 src/ > h.md; "$C" issue h.md --role developer >/dev/null
check "standard: a pending agent does not block (legacy)" sdd_green
"$SDD" abort >/dev/null

echo "concurrent state changes"
R="$(newrepo conc)"; use "$R"
for i in 1 2 3 4; do ( "$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md >/dev/null 2>&1; echo $? > "$T/s$i" ) & done; wait
eq "four starts at once: exactly one wins"              "$(cat "$T"/s[1-4] | grep -c '^0$')" 1
eq "...and the state is one intact task"                "$(jq -r '[.task,.phase,(.history|length)]|join(",")' .sdkit/.sdd/state.json)" "t1,intake,1"
for i in 1 2 3 4 5 6; do ( "$SDD" advance proposed >/dev/null 2>&1; echo $? > "$T/a$i" ) & done; wait
eq "six advances at once: exactly one moves the phase"  "$(cat "$T"/a[1-6] | grep -c '^0$')" 1
eq "the history has the move once"                      "$(jq -r '[.history[].phase]|join(",")' .sdkit/.sdd/state.json)" "intake,proposed"
eq "one phase.enter event for it"                       "$(jq -r 'select(.type=="phase.enter" and .to=="proposed") | .to' "$EV" | wc -l | tr -d ' ')" 1
check "a verdict recorded during an advance is not lost" bash -c "('$SDD' advance red --test-cmd 'sleep 1; false' >/dev/null 2>&1 &) ; sleep 0.3; '$SDD' _verdict PASS; wait; sleep 1.5; test \"\$(jq -r .verdict.result '$R/.sdkit/.sdd/state.json')\" = PASS && test \"\$('$SDD' phase)\" = red"
check "the event file is valid after the race"          "$KIT/scripts/telemetry.sh" validate t1
"$SDD" abort >/dev/null

echo "telemetry"
R="$(newrepo tel)"; use "$R"
"$SDD" start t1 --risk low --profile small --proposal openspec/changes/t1/proposal.md >/dev/null
eq "task.start carries the profile"                     "$(jq -r 'select(.type=="task.start") | .profile' "$EV")" small
eq "a default run adds no decision event"               "$(jq -r 'select(.type=="workflow.decision")|.type' "$EV" | wc -l | tr -d ' ')" 0
"$SDD" abort >/dev/null
rm -rf .sdkit/work
"$SDD" start t1 --risk low --profile high-assurance --proposal openspec/changes/t1/proposal.md >/dev/null
eq "high-assurance: one contract-policy decision at start" "$(jq -r 'select(.type=="workflow.decision") | "\(.source):\(.outcome):\(.profile)"' "$EV")" "contract-policy:required:high-assurance"
sdd_red >/dev/null 2>&1
eq "a rejected move: category, phase and reason"        "$(jq -r 'select(.type=="phase.reject") | "\(.category):\(.phase):\(.reason)"' "$EV")" "gate:red:not-next"
check "no event carries a prompt, a path list or test output" bash -c "! grep -qE 'Definition of Done|x=|two writers' '$EV'"
eq "summary shows the profile and the rejection"        "$("$KIT/scripts/telemetry.sh" summary t1 --json | jq -r '[.workflow.profile, (.workflow.rejections_by_reason|keys|join(","))]|join(" ")')" "high-assurance not-next"
check "the text summary has a workflow line"            bash -c "'$KIT/scripts/telemetry.sh' summary t1 | grep -q 'workflow: profile high-assurance'"
check "validate: events are all valid"                  "$KIT/scripts/telemetry.sh" validate t1
nocheck "validate rejects an unknown profile"           bash -c "echo '{\"v\":1,\"ts\":\"2026-01-01T00:00:00Z\",\"type\":\"task.start\",\"task\":\"t1\",\"run\":\"r\",\"mode\":\"live\",\"profile\":\"turbo\"}' > x.jsonl; '$KIT/scripts/telemetry.sh' validate --file x.jsonl"
"$SDD" abort >/dev/null

echo "legacy compatibility"
R="$(newrepo old)"; use "$R"
"$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md >/dev/null
jq 'del(.profile)' .sdkit/.sdd/state.json > s.tmp && mv s.tmp .sdkit/.sdd/state.json   # a task opened by an older kit
eq "a state without a profile reads as standard"        "$("$WF" policy --json | jq -r .profile)" standard
check "...and walks the whole flow"                     bash -c "cd '$R' && '$SDD' advance proposed && '$SDD' advance red --test-cmd \"grep -q GM2 src/a.sh\" && echo GM2 >> src/a.sh && '$SDD' advance green && '$SDD' _verdict PASS && '$SDD' advance verified && '$SDD' advance pr && '$SDD' advance done"
eq "its attestation names the standard profile"         "$(jq -r .profile .sdkit/attestations/t1.json)" standard
"$SDD" abort >/dev/null
cp -R "$KIT/scripts" "$T/scr-nowf"; rm "$T/scr-nowf/workflow.sh"
check "workflow.sh missing (a half-upgraded install): sdd.sh still walks a task" bash -c "cd '$R' && S='$T/scr-nowf/sdd.sh' && \$S start t1 --risk low --profile high-assurance --proposal openspec/changes/t1/proposal.md && \$S advance proposed && \$S advance red --test-cmd \"grep -q GM3 src/a.sh\" && echo GM3 >> src/a.sh && \$S advance green && \$S _verdict PASS && \$S advance verified"
"$SDD" abort >/dev/null

printf '\nworkflow tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
