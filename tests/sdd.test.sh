#!/usr/bin/env bash
# The phase machine (scripts/sdd.sh) and its hooks end to end in one throwaway repo: strict default, test-first phases, verifier verdict, push gate, attestation + CI check, git-hook guard, modes.
# Run: tests/sdd.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"

R="$T/r"; git_repo "$R"; cd "$R"
mkdir -p .sdkit src openspec/changes/x
printf 'BASE_BRANCH=main\nSTACK=generic\n' > .sdkit/sdkit.env   # SDD_MODE unset on purpose: the default must be strict
git add -A && git commit -qm base && git checkout -qb feat
export CLAUDE_PROJECT_DIR="$R" VERIFY_BASE=main
SDD="$KIT/scripts/sdd.sh"; export SDKIT_GREEN="$T/green"   # RED fails until the test marks it green; GREEN re-runs the same command
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }
hook() { local out; out="$(printf '%s' "$2" | "$KIT/hooks/$1")"; [ -z "$out" ] && echo allow || printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision; }
edit()  { printf '{"tool_input":{"file_path":"%s/%s"}}' "$R" "$1"; }
bash_() { jq -n --arg c "$1" '{tool_input:{command:$c}}'; }
is() { eq "$1" "$3" "$2"; }   # is <name> <wanted> <got>
PUSH="$(bash_ 'git push origin feat')"
DOD='# P\n## Definition of Done\n- returns 200 on valid input\n'
verdict() { printf '{"agent_type":"spec-driven-kit:verifier","last_assistant_message":"DOD\\n- x | %s | y\\nFINDINGS\\n- none\\nVERIFY\\n- command: verify.sh | result: %s | ok\\nVERDICT: %s"}' "$1" "$3" "$2" | "$KIT/hooks/record-verdict.sh"; }

echo "no task"
is "default mode is strict"        strict "$("$SDD" mode)"
is "code edit denied"              deny  "$(hook guard-phase.sh "$(edit src/app.go)")"
is "docs edit allowed"             allow "$(hook guard-phase.sh "$(edit docs/a.md)")"
is "git push denied"               deny  "$(hook guard-pr.sh "$PUSH")"
is "plain bash allowed"            allow "$(hook guard-pr.sh "$(bash_ 'ls -la')")"
is "state tampering denied"        deny  "$(hook guard-pr.sh "$(bash_ 'echo x > .sdkit/.sdd/state.json')")"
is "git add of an attestation allowed" allow "$(hook guard-pr.sh "$(bash_ 'git add .sdkit/attestations/x.json')")"
is "attestation redirect denied"   deny  "$(hook guard-pr.sh "$(bash_ 'echo {} > .sdkit/attestations/x.json')")"

echo "intake -> proposed -> red -> green"
nocheck "start needs a risk"       "$SDD" start t1 --proposal openspec/changes/x/proposal.md
check   "start"                    "$SDD" start t1 --risk medium --proposal openspec/changes/x/proposal.md
nocheck "no DoD, no proposed"      "$SDD" advance proposed
printf "$DOD" > openspec/changes/x/proposal.md
nocheck "cannot skip to red"       sdd_red
check   "advance proposed"         "$SDD" advance proposed
is "src edit denied (test-first)"  deny  "$(hook guard-phase.sh "$(edit src/app.go)")"
is "test edit allowed"             allow "$(hook guard-phase.sh "$(edit src/app_test.go)")"
nocheck "passing tests are not RED" "$SDD" advance red --test-cmd true
mkdir -p .sdkit/work/t1; "$KIT/scripts/usage.sh" log --role orchestrator --host claude --id session-s --in 5 --out 7 --cache-read 90 --cache-write 5 --slug t1 --kind final --force
red_err="$(USAGE_LINE=1 sdd_red 2>&1 >/dev/null)"
is "failing tests are RED"    red "$("$SDD" task 2>/dev/null | jq -r .phase 2>/dev/null || jq -r .phase .sdkit/.sdd/state.json)"
is "USAGE_LINE=1: a phase move prints the running totals" "usage: orchestrator: in 100 (fresh 5, cache read 90, cache write 5), out 7, hit 90% | task total: in 100 (fresh 5, cache read 90, cache write 5), out 7, hit 90%" "$(grep '^usage:' <<< "$red_err")"
is "src edit allowed in red"       allow "$(hook guard-phase.sh "$(edit src/app.go)")"
nocheck "still failing, no green"  "$SDD" advance green
echo 'package src' > src/app.go
check   "green"                    sdd_green

echo "verification (medium needs the verifier's verdict)"
nocheck "no verdict, no verified"  "$SDD" advance verified
is "push denied before verified"   deny  "$(hook guard-pr.sh "$PUSH")"
verdict FAIL BLOCK red
nocheck "BLOCK verdict is not enough" "$SDD" advance verified
verdict PASS PASS green
echo 'package src // after verdict' > src/app.go
nocheck "verdict goes stale on edit" "$SDD" advance verified
verdict PASS PASS green
printf '{"agent_type":"developer","last_assistant_message":"VERDICT: PASS"}' | "$KIT/hooks/record-verdict.sh"
check   "verified (verdict from the verifier only)" "$SDD" advance verified
is "push allowed when verified"    allow "$(hook guard-pr.sh "$PUSH")"
echo 'package src // late' > src/app.go
is "push denied after a late edit" deny  "$(hook guard-pr.sh "$PUSH")"
echo 'package src // after verdict' > src/app.go
git add -A && git commit -qm feat
is "committing does not stale the verdict" allow "$(hook guard-pr.sh "$PUSH")"

echo "attestation + CI gate"
ATT=.sdkit/attestations/t1.json
check   "verified wrote an attestation" test -f "$ATT"
check   "ci-check passes for the attested diff" "$SDD" ci-check
echo 'package src // after attestation' > src/app.go
nocheck "ci-check fails when the diff changed" "$SDD" ci-check
echo 'package src // after verdict' > src/app.go
cp "$ATT" "$T/att.bak"; jq '.verdict=""' "$T/att.bak" > "$ATT"
nocheck "medium attestation without PASS fails" "$SDD" ci-check
cp "$T/att.bak" "$ATT"
is "attestation not editable by the model" deny "$(hook guard-phase.sh "$(edit $ATT)")"
check "advance pr"   "$SDD" advance pr
check "advance done" "$SDD" advance done
is "state cleared"   "no active task" "$("$SDD" status)"

echo "git hooks (any host) and ci-check without attestation"
echo 'package src // v3' > src/app.go; git add src/app.go
nocheck "pre-commit blocks code without a task" "$KIT/scripts/guard.sh" pre-commit
check   "SDD_SKIP=1 bypasses once"              env SDD_SKIP=1 "$KIT/scripts/guard.sh" pre-commit
git reset -q src/app.go; git checkout -q src/app.go
rm -rf .sdkit/attestations; echo 'package src // unattested' > src/new.go
nocheck "unattested code change fails ci-check" "$SDD" ci-check
rm src/new.go

echo "low risk, parse-verdict --record, modes"
printf '# P\n## Definition of Done\n1. it works\n' > openspec/changes/x/proposal.md
"$SDD" start t2 --risk low --proposal openspec/changes/x/proposal.md >/dev/null
"$SDD" advance proposed >/dev/null; sdd_red >/dev/null; sdd_green >/dev/null
check "low verifies without a verdict" "$SDD" advance verified
"$SDD" abort >/dev/null
printf '# P\n## Definition of Done\n- D1: x | Verified by: unit test\n' > openspec/changes/x/proposal.md
"$SDD" start t3 --risk medium --proposal openspec/changes/x/proposal.md >/dev/null
"$SDD" advance proposed >/dev/null; sdd_red >/dev/null; sdd_green >/dev/null
printf 'DOD\n- D1 x | PASS | t:1\nFINDINGS\n- none\nVERIFY\n- command: verify.sh | result: green | ok\nVERDICT: PASS\n' > "$T/v.txt"
"$KIT/scripts/parse-verdict.sh" "$T/v.txt" --proposal openspec/changes/x/proposal.md >/dev/null
nocheck "parse without --record records nothing" "$SDD" advance verified
"$KIT/scripts/parse-verdict.sh" "$T/v.txt" --proposal openspec/changes/x/proposal.md --record >/dev/null
check   "parse --record enables verified" "$SDD" advance verified
"$SDD" abort >/dev/null
echo SDD_MODE=guided >> .sdkit/sdkit.env
is "guided asks instead of denying" ask   "$(hook guard-phase.sh "$(edit src/app.go)")"
echo SDD_MODE=off >> .sdkit/sdkit.env
is "off disables the guards"        allow "$(hook guard-phase.sh "$(edit src/app.go)")"
finish sdd
