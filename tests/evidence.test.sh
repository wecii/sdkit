#!/usr/bin/env bash
# High-risk independent evidence: verdict parsing per role, three trusted PASSes before verified, BLOCK/malformed/spoofed/stale/duplicate evidence, run-role interruptions, ci-check on the attestation, lighter risks.
# Run: tests/evidence.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
SDD="$KIT/scripts/sdd.sh"; WF="$KIT/scripts/workflow.sh"; PV="$KIT/scripts/parse-verdict.sh"; RR="$KIT/scripts/run-role.sh"
export SDKIT_GREEN="$T/green"   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
export VERIFY_BASE=main
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }

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

echo "role verdict blocks (parse-verdict --role)"
check "reviewer PASS parses"                          "$PV" "$T/rev-pass" --role reviewer
eq "reviewer BLOCK exits 1"                           "$(rc "$PV" "$T/rev-block" --role reviewer)" 1
eq "an answer in the wrong role's format is malformed" "$(rc "$PV" "$T/rev-pass" --role security-auditor)" 2
sed 's/VERDICT: BLOCK/VERDICT: PASS/' "$T/rev-block" > "$T/rev-lie"
eq "PASS with a BLOCKER is inconsistent"              "$(rc "$PV" "$T/rev-lie" --role reviewer)" 2

# one repo, one high-risk task in phase green, shared by everything below
R="$T/repo"; mkdir -p "$R/.sdkit" "$R/src" "$R/openspec/changes/t1"
( cd "$R" && git init -q -b main . && git config user.email t@t && git config user.name t
  printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\n' > .sdkit/sdkit.env
  printf 'TELEMETRY=1\n' > .sdkit/sdkit.local.env
  printf 'work/\n.sdd/\n.verify-cache/\nsdkit.local.env\n' > .sdkit/.gitignore
  echo a > src/a.sh; printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > openspec/changes/t1/proposal.md
  printf '# D\n## Race scenario\ntwo writers\n' > openspec/changes/t1/design.md
  git add -A && git commit -qm init && git checkout -qb feat )
cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"; unset SDKIT_HOST
EV="$R/.sdkit/work/t1/events.jsonl"; ST="$R/.sdkit/.sdd/state.json"
last_reason() { jq -r 'select(.type=="phase.reject") | .reason // "none"' "$EV" 2>/dev/null | tail -1; }
# the Claude Code path: PreToolUse(Agent) registers the spawn, SubagentStop records the answer under the host's agent_id
spawn() { jq -nc --arg r "$1" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{subagent_type:$r,prompt:"x"}}' | "$KIT/hooks/guard-budget.sh"; }
stop() { jq -nc --arg r "$1" --arg id "$3" --arg m "$(cat "$2")" '{hook_event_name:"SubagentStop",agent_type:$r,agent_id:$id,last_assistant_message:$m}' | "$KIT/hooks/record-verdict.sh"; }
run() { spawn "$1" && stop "$1" "$2" "$3"; }   # run <role> <answer-file> <agent-id>
ev_state() { "$SDD" evidence --json | jq -r --arg r "$1" '.[] | select(.role==$r) | .state'; }
ev_trust() { "$SDD" evidence --json | jq -r --arg r "$1" '.[] | select(.role==$r) | .trust'; }
"$SDD" start t1 --risk high --proposal openspec/changes/t1/proposal.md >/dev/null && "$SDD" advance proposed >/dev/null \
  && sdd_red >/dev/null && echo "x" >> src/a.sh && sdd_green >/dev/null

echo "high risk: nothing reaches verified without three trusted PASSes"
eq "high risk requires three roles"                   "$("$WF" evidence-roles)" "verifier reviewer security-auditor"
nocheck "no evidence at all: verified refused"        "$SDD" advance verified
run verifier "$T/ver-pass" a-ver >/dev/null; run reviewer "$T/rev-block" a-rev >/dev/null
nocheck "a reviewer BLOCK: verified refused"          "$SDD" advance verified
eq "…evidence-block"                                  "$(last_reason)" evidence-block
run reviewer "$T/rev-pass" b-rev >/dev/null
out="$(spawn security-auditor; stop security-auditor "$T/rev-pass" a-bad)"
check "a malformed auditor answer is reported, not recorded" grep -q 'NOT recorded' <<< "$out"

echo "spoofed or manual evidence never counts"
eq "a run-role claim without a registered run is refused" "$(rc "$SDD" _evidence security-auditor PASS --source run-role --run fake)" 1
"$PV" "$T/aud-pass" --role security-auditor --record >/dev/null
eq "a bare --record is manual and untrusted"          "$(ev_trust security-auditor)/$(ev_state security-auditor)" manual/untrusted
nocheck "manual evidence does not open the gate"      "$SDD" advance verified
eq "…untrusted-evidence"                              "$(last_reason)" untrusted-evidence
eq "guard-pr denies 'sdd.sh _evidence' from the model's shell" "$(jq -nc --arg c "$KIT/scripts/sdd.sh _evidence reviewer PASS" '{tool_input:{command:$c}}' | "$KIT/hooks/guard-pr.sh" | jq -r '.hookSpecificOutput.permissionDecision')" deny

echo "a failed role run (run-role.sh with a fake host CLI) records nothing; an edit makes evidence stale"
mkdir -p "$T/bin"; cat > "$T/bin/claude" <<'X'
#!/usr/bin/env bash
# fake host: prints FAKE_ANSWER (a file) as the result; FAKE_RC is its exit status
[ "${FAKE_RC:-0}" = 0 ] || { echo boom >&2; exit "$FAKE_RC"; }
jq -n --arg r "$(cat "$FAKE_ANSWER")" '{result:$r, usage:{input_tokens:1,output_tokens:1}}'
X
chmod +x "$T/bin/claude"; export PATH="$T/bin:$PATH"; echo x > "$T/handoff"
rr() { local role="$1" ans="$2"; shift 2; FAKE_ANSWER="$ans" "$RR" "$role" --handoff "$T/handoff" --host claude --cwd "$R" "$@"; }
jq '.spawns=[]' "$ST" > "$ST.x" && mv "$ST.x" "$ST"   # drop the registration left open by the malformed answer
FAKE_RC=7 rr security-auditor "$T/aud-pass" >/dev/null 2>&1; r=$?
eq "a failed run exits with the host's status"        "$r" 7
check "…and logs the interruption"                    jq -e '.evidenceLog[] | select(.reason=="interrupted")' "$ST"
echo "late edit" >> src/a.sh
nocheck "stale evidence never satisfies verified"     "$SDD" advance verified

echo "re-running the roles on the current diff opens the gate"
run verifier "$T/ver-pass" c-ver >/dev/null; run reviewer "$T/rev-pass" c-rev >/dev/null
rr security-auditor "$T/aud-pass" >/dev/null 2>&1; r=$?
eq "run-role records a good run (exit 0)"             "$r" 0
check "all three trusted PASSes: verified accepted"   "$SDD" advance verified
A=.sdkit/attestations/t1.json
eq "the attestation carries the trusted evidence"     "$(jq -r '.evidence | [.[].trust] | unique | join(",")' $A)" spawned
check "ci-check accepts the attestation"              "$SDD" ci-check
cp $A "$T/att"; jq 'del(.evidence.reviewer)' "$T/att" > $A
nocheck "an attestation without the reviewer fails"   "$SDD" ci-check
cp "$T/att" $A
check "pr then done are accepted"                     bash -c "'$SDD' advance pr && '$SDD' advance done"
eq "evidence after the task is done is 'no task' (4)" "$(rc "$SDD" _evidence reviewer PASS --source manual)" 4

finish evidence
