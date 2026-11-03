#!/usr/bin/env bash
# Workflow (F03), slim: the transition table with a rejection reason per refused move, workflow profiles (small is low risk only, high-assurance needs an
# independent verifier), the policy and contract levels by role, the Claude Code agent-boundary hook and run-role.sh against a high-assurance task,
# pending agents blocking green, concurrent starts, and a state from an older kit. One scratch repo for the whole file. Run: tests/workflow.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
PATH="$KIT/tests/stubs:$PATH"
SDD="$KIT/scripts/sdd.sh"; WF="$KIT/scripts/workflow.sh"; C="$KIT/scripts/contract.sh"; HK="$KIT/hooks/check-contract.sh"
export SDKIT_GREEN="$T/green" VERIFY_BASE=main   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }

R="$T/wf"; mkdir -p "$R/.sdkit" "$R/src" "$R/openspec/changes/t1"
printf 'a\n' > "$R/src/a.sh"; printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > "$R/openspec/changes/t1/proposal.md"
printf '# D\n## Race scenario\ntwo writers\n' > "$R/openspec/changes/t1/design.md"
printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\n' > "$R/.sdkit/sdkit.env"; printf 'TELEMETRY=1\n' > "$R/.sdkit/sdkit.local.env"
printf 'work/\n.sdd/\n.verify-cache/\nsdkit.local.env\n' > "$R/.sdkit/.gitignore"
git_repo "$R"; cd "$R" && git checkout -qb feat || exit 1
export CLAUDE_PROJECT_DIR="$R"; EV="$R/.sdkit/work/t1/events.jsonl"; PROP=openspec/changes/t1/proposal.md
phase() { "$SDD" phase; }
last_reason() { jq -r 'select(.type=="phase.reject") | .reason // "none"' "$EV" 2>/dev/null | tail -1; }
verdict() { "$SDD" _verdict "$1"; }
hand() { printf 'ROLE: %s\nCONTRACT: 1\nTASK: x\nREAD: src/a.sh\nSCOPE: writes: %s\nID: t1/%s\nREPLY-END: x\n' "$1" "${3:-none}" "$2"; }

echo "the transition table and its rejection reasons (standard, medium)"
eq "one line per move, plus re-verify and abort"        "$("$SDD" transitions | wc -l | tr -d ' ')" 8
nocheck "no task: advance is refused"                   "$SDD" advance proposed
check "start (default profile standard)"                "$SDD" start t1 --risk medium --proposal $PROP
eq "status of a standard task is unchanged"             "$("$SDD" status)" "task=t1 risk=medium phase=intake"
sdd_red >/dev/null 2>&1;                                eq "skipping a phase: not-next" "$(last_reason)" not-next
printf '# P\nno dod\n' > $PROP; "$SDD" advance proposed >/dev/null 2>&1; eq "no DoD: no-dod" "$(last_reason)" no-dod
printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > $PROP
check "intake > proposed"                               "$SDD" advance proposed
"$SDD" advance red --test-cmd true >/dev/null 2>&1;     eq "passing tests are not RED: tests-pass" "$(last_reason)" tests-pass
check "proposed > red"                                  sdd_red
echo 'x=1' >> src/a.sh
"$SDD" advance green >/dev/null 2>&1;                   eq "failing tests are not GREEN: tests-fail" "$(last_reason)" tests-fail
check "red > green"                                     sdd_green
"$SDD" advance verified >/dev/null 2>&1;                eq "medium without a verdict: no-verdict" "$(last_reason)" no-verdict
verdict BLOCK; "$SDD" advance verified >/dev/null 2>&1; eq "a BLOCK verdict: verdict-block" "$(last_reason)" verdict-block
verdict PASS;  echo 'x=late' >> src/a.sh; "$SDD" advance verified >/dev/null 2>&1; eq "a verdict for an older diff: stale-verdict" "$(last_reason)" stale-verdict
verdict PASS
check "green > verified (independent PASS for this diff)" "$SDD" advance verified
echo 'x=after' >> src/a.sh
eq "an edit after verification shows as stale evidence" "$("$SDD" status)" "task=t1 risk=medium phase=verified verdict=PASS evidence=stale"
nocheck "a push of a stale diff is refused"             "$SDD" gate push
eq "reason recorded: out-of-phase"                      "$(last_reason)" out-of-phase
verdict PASS
check "verified > verified re-verifies the new diff"    "$SDD" advance verified
check "verified > pr > done"                            bash -c "'$SDD' advance pr && '$SDD' advance done"
nocheck "done closes the task"                          test -f .sdkit/.sdd/state.json
check "every rejection carries a reason; events validate" bash -c "! jq -e 'select(.type==\"phase.reject\" and (.reason|not))' '$EV' >/dev/null && '$KIT/scripts/telemetry.sh' validate t1"

echo "profiles and risk are separate"
nocheck "an unknown profile is refused"                 "$SDD" start t1 --risk low --profile turbo --proposal $PROP
nocheck "small is refused for medium risk"              "$SDD" start t1 --risk medium --profile small --proposal $PROP
nocheck "refusing a start leaves no state"              test -f .sdkit/.sdd/state.json
check "small is fine for low risk"                      "$SDD" start t1 --risk low --profile small --proposal $PROP
eq "status shows a non-default profile"                 "$("$SDD" status)" "task=t1 risk=low phase=intake profile=small"
nocheck "a second start is refused while a task is open" "$SDD" start t2 --risk low --proposal $PROP
"$SDD" abort >/dev/null
echo "high-assurance: an independent verifier even for low risk"
"$SDD" start t1 --risk low --profile high-assurance --proposal $PROP >/dev/null
eq "policy: verifier mandatory, contracts required"     "$("$SDD" policy)" "task=t1 risk=low profile=high-assurance verifier=independent-verifier contracts=required (scout/analyst: optional) automatic-retries=1"
"$SDD" advance proposed >/dev/null 2>&1; sdd_red >/dev/null 2>&1; echo 'x=ha' >> src/a.sh; sdd_green >/dev/null 2>&1
nocheck "the verify command is not enough"              "$SDD" advance verified
eq "...it says why"                                     "$(last_reason) $("$SDD" advance verified 2>&1 | grep -c 'profile high-assurance')" "no-verdict 1"
verdict PASS
check "a PASS for this diff verifies it"                "$SDD" advance verified
eq "the attestation records the profile"                "$(jq -r .profile .sdkit/attestations/t1.json)" high-assurance
"$SDD" abort >/dev/null

echo "contract levels by profile and role, and the agent-boundary hook (high-assurance task stays open for the next sections)"
eq "no task, CONTRACTS unset: off"                      "$("$WF" contracts --role developer)" off
"$SDD" start t1 --risk medium --profile high-assurance --proposal $PROP >/dev/null
eq "high-assurance: writing/deciding roles and plugin-prefixed names are required; scout optional; non-kit agent optional" "$(for r in developer verifier reviewer spec-driven-kit:developer scout Explore; do "$WF" contracts --role "$r"; done | tr '\n' ' ')" "required required required required optional optional "
pre() { jq -nc --arg p "$1" --arg r "$2" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{prompt:$p,subagent_type:$r}}'; }
decision() { local o; o="$(cat)"; [ -z "$o" ] && { echo silent; return; }; printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // (if .systemMessage then "warn" else "silent" end)'; }
plain="ROLE: developer
TASK: x"
eq "no marker, developer: asks (strict), naming what to add" "$(pre "$plain" developer | "$HK" | decision) $(pre "$plain" developer | "$HK" | jq -r .hookSpecificOutput.permissionDecisionReason | grep -c 'CONTRACT: 1')" "ask 1"
eq "no marker, scout and a non-kit agent: silent"       "$(pre "$plain" scout | "$HK" | decision) $(pre "$plain" Explore | "$HK" | decision)" "silent silent"
eq "a valid contracted handoff: silent, and registered" "$(pre "$(hand verifier v1)" verifier | "$HK" | decision) $(jq -r .state .sdkit/work/t1/contracts/v1.json)" "silent issued"
eq "an invalid contracted handoff still asks"           "$(pre "$(hand verifier v1 | sed '/^READ/d')" verifier | "$HK" | decision)" ask
sed -i.bak 's/SDD_MODE=strict/SDD_MODE=guided/' .sdkit/sdkit.env
eq "guided: a warning, not a question"                  "$(pre "$plain" developer | "$HK" | decision)" warn
sed -i.bak 's/SDD_MODE=guided/SDD_MODE=strict/' .sdkit/sdkit.env
check "the refusal is a telemetry decision"             bash -c "jq -e 'select(.type==\"workflow.decision\" and .outcome==\"missing-marker\" and .role==\"developer\")' '$EV'"
printf 'ROLE: developer\nTASK: x\n' > plain.md; hand developer d1 src/ > ctr.md
"$KIT/scripts/run-role.sh" developer --handoff plain.md --host claude --dry-run >/dev/null 2>err.txt; rrc=$?
eq "run-role.sh: an uncontracted handoff exits 2 and says why" "$rrc $(grep -c 'requires a contract' err.txt)" "2 1"
eq "run-role.sh: a scout handoff and a contracted one are fine" "$(rc "$KIT/scripts/run-role.sh" scout --handoff plain.md --host claude --dry-run)$(rc "$KIT/scripts/run-role.sh" developer --handoff ctr.md --host claude --dry-run)" 00
"$SDD" abort >/dev/null

echo "a valid contract never replaces the verifier; pending agents block green only under high-assurance"
"$SDD" start t1 --risk medium --profile high-assurance --proposal $PROP >/dev/null
"$SDD" advance proposed >/dev/null; sdd_red >/dev/null; echo q >> src/a.sh
"$C" close t1/v1 >/dev/null 2>&1   # v1 was registered by the hook section
hand developer d1 src/ > h.md; "$C" issue h.md --role developer >/dev/null
nocheck "an unanswered agent blocks green"              sdd_green
eq "reason: agents-pending, naming the id"              "$(last_reason) $(sdd_green 2>&1 | grep -c 't1/d1')" "agents-pending 1"
"$C" close t1/d1 --reason interrupted >/dev/null
check "closed (interrupted): green is possible"         sdd_green
hand verifier v2 > h2.md; "$C" issue h2.md --role verifier >/dev/null
printf 'HANDOFF-RESULT/1 | id: t1/v2 | role: verifier | status: done | artifacts: none | blockers: none | next: -\n' | "$C" check-result - --id t1/v2 --role verifier --record >/dev/null
nocheck "a valid, done verifier contract does not verify" "$SDD" advance verified
eq "...and records no verdict"                          "$(jq -r '.verdict.result // "none"' .sdkit/.sdd/state.json)" none
"$SDD" abort >/dev/null
"$SDD" start t1 --risk medium --proposal $PROP >/dev/null
"$SDD" advance proposed >/dev/null; sdd_red >/dev/null; echo q2 >> src/a.sh
hand developer d9 src/ > h.md; "$C" issue h.md --role developer >/dev/null
check "standard: a pending agent does not block (legacy)" sdd_green
"$SDD" abort >/dev/null

echo "concurrent starts and an older kit's state"
for i in 1 2 3; do ( "$SDD" start t1 --risk medium --proposal $PROP >/dev/null 2>&1; echo $? > "$T/s$i" ) & done; wait
eq "three starts at once: exactly one wins, one intact task" "$(cat "$T"/s[1-3] | grep -c '^0$') $(jq -r '[.task,.phase,(.history|length)]|join(",")' .sdkit/.sdd/state.json)" "1 t1,intake,1"
jq 'del(.profile)' .sdkit/.sdd/state.json > s.tmp && mv s.tmp .sdkit/.sdd/state.json   # a task opened by an older kit
eq "a state without a profile reads as standard"        "$("$WF" policy --json | jq -r .profile)" standard
"$SDD" abort >/dev/null

finish workflow
