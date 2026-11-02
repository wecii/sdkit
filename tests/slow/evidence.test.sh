#!/usr/bin/env bash
# F04 tests: independent evidence for high risk (verifier + reviewer + security-auditor), trust by registered execution, staleness, spoofing,
# duplicates, interrupted runs, concurrency, atomic refusals, profile regressions, adapter claims. Run: tests/slow/evidence.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (should have failed)"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

ksum() { (cd "$KIT" && find scripts hooks core agents adapters skills bin tests/run.sh -type f | sort | xargs shasum | shasum | cut -d' ' -f1); }
KSUM0="$(ksum)"
SDD="$KIT/scripts/sdd.sh"; WF="$KIT/scripts/workflow.sh"; PV="$KIT/scripts/parse-verdict.sh"; RR="$KIT/scripts/run-role.sh"
export SDKIT_GREEN="${TMPDIR:-/tmp}/sdkit-green.$$"   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }
export VERIFY_BASE=main

newrepo() {  # newrepo <name> [extra sdkit.env lines]
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
use() { cd "$1" || exit 1; export CLAUDE_PROJECT_DIR="$1"; EV="$1/.sdkit/work/t1/events.jsonl"; ST="$1/.sdkit/.sdd/state.json"; unset SDKIT_HOST; }
last_reason() { jq -r 'select(.type=="phase.reject") | .reason // "none"' "$EV" 2>/dev/null | tail -1; }
# green <risk> [profile]: a task in phase green on a changed file
green() {
  "$SDD" start t1 --risk "$1" ${2:+--profile "$2"} --proposal openspec/changes/t1/proposal.md >/dev/null && "$SDD" advance proposed >/dev/null \
    && sdd_red >/dev/null && echo "x$RANDOM" >> src/a.sh && sdd_green >/dev/null
}
# green_repo <name> <risk> [profile]: a repo with the task in phase green on a changed file. Built once per risk/profile (about 6 s), then copied.
green_repo() {
  local n="$1" k="tpl-$2-${3:-std}"
  if [ ! -d "$T/$k" ]; then local t; t="$(newrepo "$k")"; ( use "$t"; green "$2" ${3:+"$3"} ) >/dev/null 2>&1; fi
  cp -R "$T/$k" "$T/$n"; echo "$T/$n"
}

# the four answers a role can give
cat > "$T/ver-pass" <<'X'
DOD
- D1 a | PASS | t:1
FINDINGS
- none
VERIFY
- command: v | result: green | ok
VERDICT: PASS
X
cat > "$T/rev-pass" <<'X'
- MINOR | src/a.sh:1 | naming | a nit | rename
SUMMARY: 0 blockers, 0 major, 1 minor
VERDICT: PASS
X
cat > "$T/rev-block" <<'X'
- BLOCKER | src/a.sh:1 | error handling | swallowed | handle it
SUMMARY: 1 blockers, 0 major, 0 minor
VERDICT: BLOCK
X
cat > "$T/aud-pass" <<'X'
NO FINDINGS
- checked authz on src/a.sh
SUMMARY: 0 critical, 0 high, 0 medium, 0 low
VERDICT: PASS
X
cat > "$T/aud-block" <<'X'
- HIGH | src/a.sh:1 | IDOR | GET /x?id=2 | reads another user | check ownership
SUMMARY: 0 critical, 1 high, 0 medium, 0 low
VERDICT: BLOCK
X
# the Claude Code path: PreToolUse(Agent) registers the spawn, SubagentStop records the answer under the host's agent_id
spawn() { jq -nc --arg r "$1" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{subagent_type:$r,prompt:"x"}}' | "$KIT/hooks/guard-budget.sh"; }
stop() { jq -nc --arg r "$1" --arg id "$3" --arg m "$(cat "$2")" '{hook_event_name:"SubagentStop",agent_type:$r,agent_id:$id,last_assistant_message:$m}' | "$KIT/hooks/record-verdict.sh"; }
# run <role> <answer-file> <agent-id>: a complete trusted run on the current diff
run() { spawn "$1" && stop "$1" "$2" "$3"; }
all_pass() { run verifier "$T/ver-pass" a-ver && run reviewer "$T/rev-pass" a-rev && run security-auditor "$T/aud-pass" a-aud; }
ev_state() { "$SDD" evidence --json | jq -r --arg r "$1" '.[] | select(.role==$r) | .state'; }

echo "role verdict blocks (parse-verdict --role)"
check "reviewer PASS parses"                            "$PV" "$T/rev-pass" --role reviewer
eq "reviewer BLOCK exits 1"                             "$("$PV" "$T/rev-block" --role reviewer >/dev/null; echo $?)" 1
check "auditor PASS parses"                             "$PV" "$T/aud-pass" --role security-auditor
eq "auditor BLOCK exits 1"                              "$("$PV" "$T/aud-block" --role security-auditor >/dev/null; echo $?)" 1
eq "a reviewer block read as an auditor block is malformed (wrong role)" "$("$PV" "$T/rev-pass" --role security-auditor >/dev/null; echo $?)" 2
eq "an auditor block read as a reviewer block is malformed"              "$("$PV" "$T/aud-pass" --role reviewer >/dev/null; echo $?)" 2
sed 's/VERDICT: BLOCK/VERDICT: PASS/' "$T/rev-block" > "$T/rev-lie";  eq "reviewer PASS with a BLOCKER is inconsistent" "$("$PV" "$T/rev-lie" --role reviewer >/dev/null; echo $?)" 2
sed 's/VERDICT: BLOCK/VERDICT: PASS/' "$T/aud-block" > "$T/aud-lie";  eq "auditor PASS with a HIGH finding is inconsistent" "$("$PV" "$T/aud-lie" --role security-auditor >/dev/null; echo $?)" 2
sed 's/1 blockers/0 blockers/' "$T/rev-block" > "$T/rev-hide";         eq "a SUMMARY that hides a finding is malformed" "$("$PV" "$T/rev-hide" --role reviewer >/dev/null; echo $?)" 2
grep -v '^VERDICT' "$T/rev-pass" > "$T/rev-nov";                       eq "no VERDICT line is malformed" "$("$PV" "$T/rev-nov" --role reviewer >/dev/null; echo $?)" 2
{ cat "$T/rev-pass"; echo "VERDICT: PASS"; } > "$T/rev-two";           eq "two VERDICT lines are malformed" "$("$PV" "$T/rev-two" --role reviewer >/dev/null; echo $?)" 2
printf 'SUMMARY: 0 critical, 0 high, 0 medium, 0 low\nVERDICT: PASS\n' > "$T/aud-silent"; eq "an auditor that says neither findings nor NO FINDINGS is malformed" "$("$PV" "$T/aud-silent" --role security-auditor >/dev/null; echo $?)" 2
eq "the verifier block is unchanged"                    "$("$PV" "$T/ver-pass" >/dev/null; echo $?)" 0

echo "high risk: nothing reaches verified without three trusted PASSes"
R="$(green_repo hi high)"; use "$R"
eq "high risk requires three roles"                     "$("$WF" evidence-roles)" "verifier reviewer security-auditor"
eq "policy --json lists them"                           "$("$SDD" policy --json | jq -r '.evidence_roles | join(",")')" "verifier,reviewer,security-auditor"
nocheck "no evidence at all: verified refused"          "$SDD" advance verified
run verifier "$T/ver-pass" a-ver >/dev/null
nocheck "verifier only: verified refused"               "$SDD" advance verified
eq "…for the missing reviewer"                          "$(last_reason)" no-evidence
run reviewer "$T/rev-pass" a-rev >/dev/null
nocheck "no security-auditor: verified refused"         "$SDD" advance verified
eq "…naming the auditor"                                "$("$SDD" advance verified 2>&1 | grep -c 'security-auditor')" 1
run security-auditor "$T/aud-pass" a-aud >/dev/null
check "all three trusted PASSes: verified accepted"     "$SDD" advance verified
eq "the text view lists every role and marks the required ones" "$("$SDD" evidence 2>&1 | grep -c '(required)')" 3
eq "every role's evidence is valid"                     "$("$SDD" evidence --json | jq -r '[.[].state] | unique | join(",")')" valid
eq "the attestation carries the evidence"               "$(jq -r '.evidence | [.[].trust] | unique | join(",")' .sdkit/attestations/t1.json)" spawned
check "ci-check accepts the attestation"                "$SDD" ci-check
check "pr is accepted while nothing changed"            "$SDD" advance pr
check "done is accepted"                                "$SDD" advance done
nocheck "evidence after the task is done is refused"    "$SDD" _evidence reviewer PASS --source manual
eq "…as 'no task' (exit 4)"                             "$("$SDD" _evidence reviewer PASS --source manual >/dev/null 2>&1; echo $?)" 4

echo "each failure mode, one at a time"
fresh() { R="$(green_repo "$1" high)"; use "$R"; }
fresh blk1; run verifier "$T/ver-pass" a1 >/dev/null; run reviewer "$T/rev-block" a2 >/dev/null; run security-auditor "$T/aud-pass" a3 >/dev/null
nocheck "reviewer BLOCK: refused"                       "$SDD" advance verified
eq "…evidence-block"                                    "$(last_reason)" evidence-block
fresh blk2; run verifier "$T/ver-pass" a1 >/dev/null; run reviewer "$T/rev-pass" a2 >/dev/null; run security-auditor "$T/aud-block" a3 >/dev/null
nocheck "security-auditor BLOCK: refused"               "$SDD" advance verified
eq "…evidence-block"                                    "$(last_reason)" evidence-block
fresh mal; run verifier "$T/ver-pass" a1 >/dev/null; run reviewer "$T/rev-pass" a2 >/dev/null
out="$(spawn security-auditor; stop security-auditor "$T/rev-pass" a3)"
check "a malformed auditor answer is reported to the orchestrator" grep -q 'NOT recorded' <<< "$out"
eq "…and records nothing"                               "$(ev_state security-auditor)" missing
nocheck "…so verified is refused"                       "$SDD" advance verified
# wrong task
fresh wt; spawn reviewer; eq "evidence for another task is refused" "$(stop reviewer "$T/rev-pass" a2 >/dev/null; "$SDD" _evidence reviewer PASS --task other --source hook --run zz >/dev/null; echo $?)" 1
all_pass >/dev/null; jq '.evidence.reviewer.task="other"' "$ST" > "$ST.x" && mv "$ST.x" "$ST"
eq "evidence copied from another task is 'wrong-task'"  "$(ev_state reviewer)" wrong-task
nocheck "…and does not satisfy the gate"                "$SDD" advance verified
eq "…reason task-mismatch"                              "$(last_reason)" task-mismatch
# stale
fresh st; all_pass >/dev/null; echo "late edit" >> src/a.sh
eq "an edit after the PASSes makes all three stale"     "$("$SDD" evidence --json | jq -r '[.[].state] | unique | join(",")')" stale
nocheck "stale PASS never satisfies verified"           "$SDD" advance verified
eq "…stale-verdict (the verifier's own check comes first)" "$(last_reason)" stale-verdict
run verifier "$T/ver-pass" b-ver >/dev/null
nocheck "re-verified verifier alone is not enough"      "$SDD" advance verified
eq "…the reviewer is still stale"                       "$(last_reason)" stale-evidence
run reviewer "$T/rev-pass" b-rev >/dev/null; run security-auditor "$T/aud-pass" b-aud >/dev/null
check "re-running the roles replaces the stale PASSes, no reset" "$SDD" advance verified
# stale after verified
echo "after verified" >> src/a.sh
nocheck "pr refused once the diff moved"                "$SDD" advance pr
eq "…stale-evidence"                                    "$(last_reason)" stale-evidence
eq "the phase did not move"                             "$("$SDD" phase)" verified
# newer BLOCK beats an older PASS
fresh nb; all_pass >/dev/null; run reviewer "$T/rev-block" c-rev >/dev/null
nocheck "a newer BLOCK replaces the older PASS"         "$SDD" advance verified
eq "…evidence-block"                                    "$(last_reason)" evidence-block
# a BLOCK between verified and done
fresh nb2; all_pass >/dev/null; "$SDD" advance verified >/dev/null; "$SDD" advance pr >/dev/null; run security-auditor "$T/aud-block" d-aud >/dev/null
nocheck "a BLOCK after verified stops done"            "$SDD" advance done
eq "…evidence-block"                                    "$(last_reason)" evidence-block
eq "the task is still open at pr"                       "$("$SDD" phase)" pr
# done checks what was verified, not the merged diff
fresh dn; all_pass >/dev/null; "$SDD" advance verified >/dev/null; "$SDD" advance pr >/dev/null
git add -A; git commit -qm work; git checkout -q main; git merge -q --ff-only feat 2>/dev/null; git checkout -q feat
check "done after the merge moved the base still passes" "$SDD" advance done

echo "spoofed identity is refused or never trusted"
fresh sp; run verifier "$T/ver-pass" a1 >/dev/null
eq "a run-role claim without a registered run is refused" "$("$SDD" _evidence reviewer PASS --source run-role --run fake >/dev/null; echo $?)" 1
eq "…and recorded nothing"                              "$(ev_state reviewer)" missing
parse_out="$("$PV" "$T/rev-pass" --role reviewer --record --source run-role --run fake; echo "rc=$?")"
check "parse-verdict --record reports the refusal (exit 3)" grep -q 'rc=3' <<< "$parse_out"
"$PV" "$T/rev-pass" --role reviewer --record >/dev/null
eq "a bare --record is recorded as manual"              "$("$SDD" evidence --json | jq -r '.[] | select(.role=="reviewer") | .trust')" manual
eq "…and is untrusted"                                  "$(ev_state reviewer)" untrusted
"$PV" "$T/aud-pass" --role security-auditor --record --source hook --run guess >/dev/null
eq "a hook claim without a spawn registration is 'unregistered'" "$("$SDD" evidence --json | jq -r '.[] | select(.role=="security-auditor") | .trust')" unregistered
nocheck "manual and unregistered evidence do not open the gate" "$SDD" advance verified
eq "…untrusted-evidence"                                "$(last_reason)" untrusted-evidence
spawn reviewer; stop security-auditor "$T/aud-pass" a9 >/dev/null
eq "a spawn registered for one role cannot back another" "$("$SDD" evidence --json | jq -r '.[] | select(.role=="security-auditor") | .trust')" unregistered
run reviewer "$T/rev-pass" a2 >/dev/null; stop security-auditor "$T/aud-pass" a2 >/dev/null
eq "one agent run under two roles is a conflict"        "$("$SDD" _evidence security-auditor PASS --source hook --run a2 >/dev/null; echo $?)" 1
jq '.evidence["security-auditor"]={result:"PASS",fingerprint:.evidence.reviewer.fingerprint,task:.task,trust:"spawned",run:.evidence.reviewer.run}' "$ST" > "$ST.x" && mv "$ST.x" "$ST"
eq "…and a state that shares a run between roles is flagged" "$(ev_state security-auditor)" conflict
for c in "$KIT/scripts/sdd.sh _evidence reviewer PASS" "$KIT/scripts/sdd.sh _spawn reviewer" "$KIT/scripts/sdd.sh _verdict PASS"; do
  eq "guard-pr denies '${c##*/}' from the model's shell" "$(jq -nc --arg c "$c" '{tool_input:{command:$c}}' | "$KIT/hooks/guard-pr.sh" | jq -r '.hookSpecificOutput.permissionDecision')" deny
done
"$SDD" abort >/dev/null

echo "review findings: older registrations, unreadable state, replay beyond the log, formatting dodges"
fresh rv; spawn reviewer; echo "more" >> src/a.sh; spawn reviewer
stop reviewer "$T/rev-pass" x1 >/dev/null
eq "an older-diff registration still open: the record is refused" "$(ev_state reviewer)" missing
check "…and logged as stale-at-record"                  jq -e '.evidenceLog[] | select(.reason=="stale-at-record")' "$ST"
run reviewer "$T/rev-pass" x2 >/dev/null; eq "re-running after it is clean is trusted" "$(ev_state reviewer)" valid
run verifier "$T/ver-pass" x3 >/dev/null; jq '.evidence["security-auditor"]="x"' "$ST" > "$ST.x" && mv "$ST.x" "$ST"
nocheck "a state the evidence query cannot read never opens the gate" "$SDD" advance verified
fresh rp; run reviewer "$T/rev-pass" rid >/dev/null; for i in $(seq 1 45); do "$SDD" _evidence reviewer BLOCK >/dev/null; done
spawn reviewer; stop reviewer "$T/rev-pass" rid >/dev/null
eq "a run id cannot be replayed after the log rolled over" "$(ev_state reviewer)" block
for v in '* BLOCKER | a:1 | r | w | f' '- **BLOCKER** | a:1 | r | w | f' '1. BLOCKER | a:1 | r | w | f'; do
  printf '%s\nSUMMARY: 0 blockers, 0 major, 0 minor\nVERDICT: PASS\n' "$v" > "$T/dodge"
  eq "a reformatted finding is still counted: '$v'" "$("$PV" "$T/dodge" --role reviewer >/dev/null; echo $?)" 2
done
printf '%s\n  VERDICT: BLOCK\n' "$(cat "$T/rev-pass")" > "$T/dodge"
eq "an indented second VERDICT is a second VERDICT"      "$("$PV" "$T/dodge" --role reviewer >/dev/null; echo $?)" 2
"$SDD" abort >/dev/null

echo "duplicates, history and a log of every attempt"
fresh du; run verifier "$T/ver-pass" a1 >/dev/null
spawn reviewer; stop reviewer "$T/rev-pass" a2 >/dev/null
spawn reviewer; stop reviewer "$T/rev-block" a2 >/dev/null
eq "the same run id twice: the second is refused"       "$(ev_state reviewer)" valid
eq "…the log keeps both attempts"                       "$(jq '[.evidenceLog[] | select(.run=="a2")] | length' "$ST")" 2
eq "…one accepted"                                      "$(jq '[.evidenceLog[] | select(.run=="a2" and .accepted)] | length' "$ST")" 1
"$PV" "$T/rev-pass" --role reviewer --record >/dev/null
eq "a manual PASS does not displace a trusted PASS of this diff" "$(ev_state reviewer)" valid
"$PV" "$T/rev-block" --role reviewer --record >/dev/null
eq "a manual BLOCK always lands"                        "$(ev_state reviewer)" block
eq "the log is capped"                                  "$(for i in $(seq 1 50); do "$SDD" _evidence reviewer BLOCK >/dev/null; done; jq '.evidenceLog | length' "$ST")" 40
"$SDD" abort >/dev/null

echo "interrupted runs through run-role.sh (a fake host CLI)"
mkdir -p "$T/bin"; cat > "$T/bin/claude" <<'X'
#!/usr/bin/env bash
# fake host: prints FAKE_ANSWER (a file) as the result; FAKE_RC is its exit status; FAKE_EDIT appends to a file in the repo while "running"
[ -n "${FAKE_EDIT:-}" ] && echo edited >> "$FAKE_EDIT"
[ "${FAKE_RC:-0}" = 0 ] || { echo boom >&2; exit "$FAKE_RC"; }
jq -n --arg r "$(cat "$FAKE_ANSWER")" '{result:$r, usage:{input_tokens:1,output_tokens:1}}'
X
chmod +x "$T/bin/claude"; export PATH="$T/bin:$PATH"
printf 'x\n' > "$T/handoff"
fresh rr
rr() { local role="$1" ans="$2"; shift 2; FAKE_ANSWER="$ans" "$RR" "$role" --handoff "$T/handoff" --host claude --cwd "$R" "$@"; }
FAKE_RC=7 rr reviewer "$T/rev-pass" >/dev/null 2>&1; rc=$?
eq "a failed run exits with the host's status"          "$rc" 7
eq "…records no evidence"                               "$(ev_state reviewer)" missing
eq "…and releases its registration"                     "$(jq '.spawns | length' "$ST")" 0
check "…and logs the interruption"                      jq -e '.evidenceLog[] | select(.reason=="interrupted")' "$ST"
rr reviewer "$T/rev-pass" >/dev/null 2>&1; eq "a good run exits 0" "$?" 0
eq "run-role records the verdict as spawned"            "$("$SDD" evidence --json | jq -r '.[] | select(.role=="reviewer") | .trust')" spawned
rr security-auditor "$T/rev-pass" >/dev/null 2>&1; eq "an answer in the wrong role's format exits 6" "$?" 6
eq "…records nothing"                                   "$(ev_state security-auditor)" missing
eq "…and releases the registration"                     "$(jq '[.spawns[] | select(.role=="security-auditor")] | length' "$ST")" 0
FAKE_EDIT="$R/src/a.sh" rr security-auditor "$T/aud-pass" >/dev/null 2>&1; eq "the diff changing while the role runs exits 6" "$?" 6
eq "…the verdict is not trusted (it judged another diff)" "$(ev_state security-auditor)" missing
check "…and the log says stale-at-record"               jq -e '.evidenceLog[] | select(.reason=="stale-at-record")' "$ST"
rr verifier "$T/ver-pass" >/dev/null 2>&1; rr reviewer "$T/rev-pass" >/dev/null 2>&1; rr security-auditor "$T/aud-pass" >/dev/null 2>&1
eq "run-role alone yields a gate that opens"            "$("$SDD" advance verified 2>&1 | tail -1)" "phase: verified"
"$SDD" abort >/dev/null
rr reviewer "$T/rev-pass" >/dev/null 2>&1; eq "no open task: run-role runs as before (exit 0)" "$?" 0
nocheck "…and creates no state"                         test -e .sdkit/.sdd/state.json

echo "lower risk: a reviewer keeps its free-form answer"
fresh lw; "$SDD" abort >/dev/null; green medium
printf 'No findings.\n' > "$T/free"
rr reviewer "$T/free" >/dev/null 2>&1; eq "medium: a free-form reviewer answer exits 0 (not an evidence role below high)" "$?" 0
eq "…and registers nothing"                             "$(jq '.spawns // [] | length' "$ST")" 0
"$SDD" abort >/dev/null

echo "refusals do not mutate the state; races stay safe"
fresh at; run verifier "$T/ver-pass" a1 >/dev/null
before="$(cat "$ST")"
"$SDD" advance verified >/dev/null 2>&1
eq "a refused advance leaves state.json byte-identical" "$(cat "$ST")" "$before"
nocheck "…and writes no attestation"                    test -e .sdkit/attestations/t1.json
all_pass >/dev/null
( "$SDD" advance verified >"$T/p1" 2>&1 & "$SDD" advance verified >"$T/p2" 2>&1 & wait )
eq "two verified advances at once: one wins"            "$(cat "$T/p1" "$T/p2" | grep -c '^phase: verified')" 1
eq "…the history has one verified entry"                "$(jq '[.history[] | select(.phase=="verified")] | length' "$ST")" 1
( "$SDD" advance pr >"$T/p1" 2>&1 & "$SDD" advance pr >"$T/p2" 2>&1 & wait )
eq "two pr advances at once: one wins"                  "$(cat "$T/p1" "$T/p2" | grep -c '^phase: pr')" 1
( "$SDD" advance done >"$T/p1" 2>&1 & "$SDD" advance done >"$T/p2" 2>&1 & wait )
eq "two completions at once: exactly one closes the task" "$(cat "$T/p1" "$T/p2" | grep -c 'task closed')" 1
nocheck "…and the state is gone"                        test -e .sdkit/.sdd/state.json
fresh cc; all_pass >/dev/null
( for i in 1 2 3 4 5 6; do "$SDD" _evidence reviewer BLOCK --source manual >/dev/null 2>&1 & done; wait )
check "six concurrent evidence writes leave valid JSON" jq -e . "$ST"
eq "…and none is lost from the log"                     "$(jq '[.evidenceLog[] | select(.source=="manual")] | length' "$ST")" 6
eq "…evseq counted every accepted write"                "$(jq '.evseq' "$ST")" 9

echo "profiles and lower risks keep their weight"
R="$(newrepo lo)"; use "$R"; green low
eq "low standard: no independent evidence required"     "$("$WF" evidence-roles | wc -l | tr -d ' ')" 0
check "low standard verifies with no agent run at all"  "$SDD" advance verified
eq "…zero registrations were needed"                    "$(jq '.spawns // [] | length' "$ST")" 0
"$SDD" abort >/dev/null; green medium
eq "medium: only the verifier, as before"               "$("$WF" evidence-roles | wc -l | tr -d ' ')" 0
nocheck "medium without a verdict is still refused"     "$SDD" advance verified
"$SDD" _verdict PASS >/dev/null
check "medium accepts the legacy hand-recorded verdict" "$SDD" advance verified
"$SDD" abort >/dev/null; green low high-assurance
eq "high-assurance at low risk asks for the verifier only" "$("$WF" evidence-roles | wc -l | tr -d ' ')" 0
nocheck "high-assurance low without a verdict: refused" "$SDD" advance verified
"$SDD" abort >/dev/null; green high high-assurance
"$SDD" _verdict PASS >/dev/null
nocheck "high-assurance + high: a hand-recorded verifier verdict alone is refused" "$SDD" advance verified
eq "…untrusted-evidence"                                "$(last_reason)" untrusted-evidence
"$SDD" abort >/dev/null
nocheck "profile small cannot carry high risk"          "$SDD" start t1 --risk high --profile small --proposal openspec/changes/t1/proposal.md
R="$(newrepo fl 'RISK_FLOOR_GLOBS=high:src/*')"; use "$R"; green medium >/dev/null 2>&1
nocheck "a floor-high file with a medium label is refused (the floor still holds)" "$SDD" advance verified
"$SDD" abort >/dev/null

echo "ci-check (the server-side backstop) for high risk"
R="$(green_repo ci high)"; use "$R"; all_pass >/dev/null; "$SDD" advance verified >/dev/null
A=.sdkit/attestations/t1.json
check "complete attestation passes"                     "$SDD" ci-check
cp $A "$T/att"; jq 'del(.evidence.reviewer)' "$T/att" > $A
nocheck "an attestation without the reviewer fails"     "$SDD" ci-check
jq '.evidence.reviewer.trust="manual"' "$T/att" > $A
nocheck "a manual reviewer in the attestation fails"    "$SDD" ci-check
jq 'del(.evidence)' "$T/att" > $A
nocheck "a pre-F04 high-risk attestation fails"         "$SDD" ci-check
cp "$T/att" $A
"$SDD" abort >/dev/null

echo "F04.1: adversarial runtime cases (category A: ordinary agent output and workflow commands)"
nostop() { jq -nc --arg r "$1" --arg id "$2" '{hook_event_name:"SubagentStop",agent_type:$r,agent_id:$id,last_assistant_message:""}' | "$KIT/hooks/record-verdict.sh"; }
R="$(green_repo adv high)"; use "$R"
nocheck "a run-role claim with no registered spawn is refused"      "$SDD" _evidence reviewer PASS --source run-role --run forged
nocheck "…even for a made-up run id that looks like a run-role id"  "$SDD" _evidence security-auditor PASS --source run-role --run rr-1-2-3
"$SDD" _evidence reviewer PASS --source hook --run h1 >/dev/null
eq "a hook claim with an agent_id but no spawn is only 'untrusted'" "$(ev_state reviewer)" untrusted
run verifier "$T/ver-pass" same >/dev/null; spawn reviewer; stop reviewer "$T/rev-pass" same >/dev/null
eq "one agent_id under two roles is refused (role-conflict)"        "$(jq -r '[.evidenceLog[] | select(.reason=="role-conflict")] | length' "$ST")" 1
spawn security-auditor; stop security-auditor "$T/aud-pass" "" >/dev/null
eq "a SubagentStop without agent_id is never trusted"               "$(ev_state security-auditor)" untrusted
nocheck "…so verified is refused"                                   "$SDD" advance verified
# interrupted agent: stops with no answer; its registration must not be consumed by a later, different run
R="$(green_repo intr high)"; use "$R"
spawn reviewer; nostop reviewer a-int
eq "an interrupted agent leaves no open registration"               "$(jq '.spawns | length' "$ST")" 0
eq "…and no evidence"                                               "$(ev_state reviewer)" missing
eq "…and the interruption is logged"                                "$(jq -r '.evidenceLog[-1].reason' "$ST")" interrupted
echo "late edit" >> src/a.sh; run reviewer "$T/rev-pass" a-ok >/dev/null
eq "the next real run after the interruption is trusted"            "$(ev_state reviewer)" valid
spawn reviewer; spawn reviewer; nostop reviewer a-int2
eq "an interrupt closes exactly one registration"                   "$(jq '.spawns | length' "$ST")" 1
nostop reviewer ""
eq "a stop with no answer and no agent_id closes nothing"           "$(jq '.spawns | length' "$ST")" 1
eq "_spawn-close with no run and no role is a no-op"                "$("$SDD" _spawn-close >/dev/null 2>&1; echo $?)" 0
# parallel stops of the same role on the same diff: the state stays valid, trust is never granted twice for one registration
R="$(green_repo par high)"; use "$R"
for i in 1 2 3 4; do spawn reviewer; done; for i in 1 2 3 4; do stop reviewer "$T/rev-pass" p$i >/dev/null & done; wait
check "state.json is valid JSON after parallel records"             jq -e . "$ST"
eq "all registrations were consumed"                                "$(jq '.spawns | length' "$ST")" 0
# category B, documented: the CI trusts a committed attestation file; a forged one passes. Mitigation is review (CODEOWNERS), not code.
R="$(newrepo forge)"; use "$R"; echo y >> src/a.sh; fpf="$("$SDD" fingerprint)"; mkdir -p .sdkit/attestations
jq -n --arg fp "$fpf" '{task:"x",risk:"high",verdict:"PASS",fingerprint:$fp,evidence:{verifier:{result:"PASS",trust:"spawned",fingerprint:$fp},reviewer:{result:"PASS",trust:"spawned",fingerprint:$fp},"security-auditor":{result:"PASS",trust:"spawned",fingerprint:$fp}}}' > .sdkit/attestations/x.json
check "KNOWN LIMIT (category B): a hand-forged attestation for this diff passes ci-check" "$SDD" ci-check
echo y2 >> src/a.sh
nocheck "…but only for the exact diff it names (any later edit fails it)" "$SDD" ci-check

echo "adapters: claims match the shipped files"
check "build-adapters --check is clean"                 "$KIT/bin/build-adapters.sh" --check
sum1="$(cd "$KIT" && find agents adapters -type f | sort | xargs shasum | shasum)"; "$KIT/bin/build-adapters.sh" >/dev/null; sum2="$(cd "$KIT" && find agents adapters -type f | sort | xargs shasum | shasum)"
eq "generation is deterministic"                        "$sum1" "$sum2"
eq "capabilities table has one row per execution path"  "$("$WF" capabilities --json | jq length)" 4
eq "only Claude Code and run-role.sh claim a trusted identity" "$("$WF" capabilities --json | jq -r '[.[] | select(.trusted_identity | test("^none|attestation") | not) | .path] | join(";")')" "claude-code;run-role.sh (any host)"
eq "host-native subagents claim no spawn contract"      "$("$WF" capabilities --json | jq -r '.[] | select(.path | test("host-native")) | .spawn_contract')" none
eq "…and no automatic record"                           "$("$WF" capabilities --json | jq -r '.[] | select(.path | test("host-native")) | .evidence_record')" manual
eq "no non-Claude adapter wires a SubagentStop/spawn hook" "$(cd "$KIT" && grep -l 'record-verdict\|guard-budget\|SubagentStop' adapters/*/hooks.json adapters/*/settings.json adapters/*/plugins/* adapters/codex/config.toml.snippet 2>/dev/null | wc -l | tr -d ' ')" 0
check "Claude Code wires the spawn registration"        jq -e '.hooks.PreToolUse[] | select(.matcher|test("Agent")) | .hooks[].command | select(contains("guard-budget.sh"))' "$KIT/hooks/hooks.json"
check "…and the SubagentStop recorder"                  jq -e '.hooks.SubagentStop[].hooks[].command | select(contains("record-verdict.sh"))' "$KIT/hooks/hooks.json"
check "run-role.sh registers and records"               grep -q '_spawn "\$base"' "$KIT/scripts/run-role.sh"
echo "the central gate does not care which adapter you are"
for h in codex opencode cursor gemini; do
  R="$(newrepo "ad-$h")"; use "$R"; export SDKIT_HOST=$h; green high; "$PV" "$T/ver-pass" --record >/dev/null; "$PV" "$T/rev-pass" --role reviewer --record >/dev/null; "$PV" "$T/aud-pass" --role security-auditor --record >/dev/null
  nocheck "$h: hand-recorded evidence is refused at high risk" "$SDD" advance verified
  "$SDD" abort >/dev/null; unset SDKIT_HOST
done

echo "tests leave the kit untouched"
eq "no kit source, hook, role or adapter changed during this run" "$(ksum)" "$KSUM0"

echo; echo "evidence tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
