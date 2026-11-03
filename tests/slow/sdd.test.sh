#!/usr/bin/env bash
# End-to-end check of the phase machine and its hooks in a throwaway repo. Run: tests/slow/sdd.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
expect() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
refuse() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name (should have failed)"; else ok "$name"; fi; }

cd "$T" && git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p .agentkit src openspec/changes/x
printf 'BASE_BRANCH=main\nSTACK=generic\n' > .agentkit/project.env   # SDD_MODE unset on purpose: the default must be strict
echo base > README.md && git add -A && git commit -qm base && git checkout -qb feat
export CLAUDE_PROJECT_DIR="$T" VERIFY_BASE=main
SDD="$KIT/scripts/sdd.sh"
export SDKIT_GREEN="${TMPDIR:-/tmp}/sdkit-green.$$"   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }

hook() {  # hook <script> <json>  -> prints the permission decision, or "allow" when the hook stayed silent
  local out; out="$(printf '%s' "$2" | "$KIT/hooks/$1")"
  [ -z "$out" ] && echo allow || printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision
}
edit()  { printf '{"tool_input":{"file_path":"%s/%s"}}' "$T" "$1"; }
bash_() { jq -n --arg c "$1" '{tool_input:{command:$c}}'; }
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$3', want '$2')"; }

echo "no task"
is "default mode is strict" strict "$("$SDD" mode)"
is "code edit denied"            deny  "$(hook guard-phase.sh "$(edit src/app.go)")"
is "docs edit allowed"           allow "$(hook guard-phase.sh "$(edit docs/a.md)")"
is "git push denied"             deny  "$(hook guard-pr.sh "$(bash_ 'git push origin feat')")"
is "gh pr create denied"         deny  "$(hook guard-pr.sh "$(bash_ 'gh pr create --fill')")"
is "plain bash allowed"          allow "$(hook guard-pr.sh "$(bash_ 'ls -la')")"
is "state tampering denied"      deny  "$(hook guard-pr.sh "$(bash_ 'echo x > .agentkit/.sdd/state.json')")"
is "git add attestation allowed"  allow "$(hook guard-pr.sh "$(bash_ 'git add .agentkit/attestations/x.json')")"
is "git commit attestation allowed" allow "$(hook guard-pr.sh "$(bash_ 'git commit -m "docs: add .agentkit/attestations/x.json" -- .agentkit/attestations/x.json')")"
is "attestation named in PR text allowed" allow "$(hook guard-pr.sh "$(bash_ 'echo "see .agentkit/attestations/x.json -> ok"')")"
is "attestation redirect denied"  deny  "$(hook guard-pr.sh "$(bash_ 'echo {} > .agentkit/attestations/x.json')")"
is "attestation sed -i denied"    deny  "$(hook guard-pr.sh "$(bash_ 'sed -i s/a/b/ .agentkit/attestations/x.json')")"
is "attestation rm denied"        deny  "$(hook guard-pr.sh "$(bash_ 'rm .agentkit/attestations/x.json')")"

echo "intake"
refuse "start needs a risk"      "$SDD" start t1 --proposal openspec/changes/x/proposal.md
expect "start"                   "$SDD" start t1 --risk medium --proposal openspec/changes/x/proposal.md
is "code edit denied in intake"  deny  "$(hook guard-phase.sh "$(edit src/app.go)")"
refuse "no DoD, no proposed"     "$SDD" advance proposed
printf '# P\n## Definition of Done\n- returns 200 on valid input\n' > openspec/changes/x/proposal.md
refuse "cannot skip to red"      sdd_red
expect "advance proposed"        "$SDD" advance proposed

echo "proposed = test-first"
is "src edit denied"             deny  "$(hook guard-phase.sh "$(edit src/app.go)")"
is "test edit allowed"           allow "$(hook guard-phase.sh "$(edit src/app_test.go)")"
is "tests/ dir allowed"          allow "$(hook guard-phase.sh "$(edit tests/it.py)")"
refuse "passing tests are not RED" "$SDD" advance red --test-cmd true
expect "failing tests are RED"   sdd_red
is "src edit allowed in red"     allow "$(hook guard-phase.sh "$(edit src/app.go)")"
refuse "still failing, no green" "$SDD" advance green
echo 'package src' > src/app.go
expect "green"                   sdd_green

echo "verification (medium needs an independent verdict)"
refuse "no verdict, no verified" "$SDD" advance verified
is "push denied before verified" deny  "$(hook guard-pr.sh "$(bash_ 'git push origin feat')")"
# the hook records only a block parse-verdict.sh accepts: structure, a PASS/FAIL per DoD item, a verdict that follows from them
blk='DOD\n- x | FAIL | y\nFINDINGS\n- none\nVERIFY\n- command: verify.sh | result: red | broken\nVERDICT: BLOCK'
agent="{\"agent_type\":\"spec-driven-kit:verifier\",\"last_assistant_message\":\"$blk\"}"
pass_agent="{\"agent_type\":\"spec-driven-kit:verifier\",\"last_assistant_message\":\"DOD\\n- x | PASS | y\\nFINDINGS\\n- none\\nVERIFY\\n- command: verify.sh | result: green | ok\\nVERDICT: PASS\"}"
printf '%s' "$agent" | "$KIT/hooks/record-verdict.sh"
refuse "BLOCK verdict is not enough" "$SDD" advance verified
printf '%s' "$pass_agent" | "$KIT/hooks/record-verdict.sh"
echo 'package src // changed after the verdict' > src/app.go
refuse "verdict goes stale on edit" "$SDD" advance verified
printf '%s' "$pass_agent" | "$KIT/hooks/record-verdict.sh"
printf '{"agent_type":"developer","last_assistant_message":"VERDICT: PASS"}' | "$KIT/hooks/record-verdict.sh"
expect "verdict from the verifier" "$SDD" advance verified
is "push allowed when verified"  allow "$(hook guard-pr.sh "$(bash_ 'git push origin feat')")"
echo 'package src // late edit' > src/app.go
is "push denied after a late edit" deny "$(hook guard-pr.sh "$(bash_ 'git push origin feat')")"
echo 'package src // changed after the verdict' > src/app.go
git add -A && git commit -qm feat
is "commit does not stale the verdict" allow "$(hook guard-pr.sh "$(bash_ 'git push origin feat')")"
echo "attestation + CI gate (server side)"
ATT=.agentkit/attestations/t1.json
expect "advance verified wrote an attestation" test -f "$ATT"
expect "ci-check passes for the attested diff"  "$SDD" ci-check
echo 'package src // after attestation' > src/app.go
refuse "ci-check fails when the diff changed"   "$SDD" ci-check
echo 'package src // changed after the verdict' > src/app.go
expect "ci-check passes again when restored"    "$SDD" ci-check
cp "$ATT" "$T/att.bak"; jq '.verdict=""' "$T/att.bak" > "$ATT"
refuse "medium attestation without PASS fails"  "$SDD" ci-check
cp "$T/att.bak" "$ATT"
is "attestation is not editable by the model" deny "$(hook guard-phase.sh "$(edit .agentkit/attestations/t1.json)")"
is "attestation is not writable via bash"     deny "$(hook guard-pr.sh "$(bash_ 'echo {} > .agentkit/attestations/t1.json')")"
expect "advance pr"              "$SDD" advance pr
expect "advance done"            "$SDD" advance done
is "state cleared"               "no active task" "$("$SDD" status)"

echo "git hooks (any host)"
GUARD="$KIT/scripts/guard.sh"
echo 'package src // v3' > src/app.go; git add src/app.go
refuse "pre-commit blocks code without a task" "$GUARD" pre-commit
refuse "pre-push blocks without a task"        env -i PATH="$PATH" HOME="$HOME" CLAUDE_PROJECT_DIR="$T" "$GUARD" pre-push
SDD_SKIP=1 "$GUARD" pre-commit >/dev/null 2>&1 && ok "SDD_SKIP=1 bypasses once" || bad "SDD_SKIP=1 bypasses once"
git reset -q src/app.go; git checkout -q src/app.go 2>/dev/null

echo "parse-verdict --record (hosts without SubagentStop)"
printf '# P\n## Definition of Done\n- D1: x | Verified by: unit test\n' > openspec/changes/x/proposal.md
"$SDD" start t3 --risk medium --proposal openspec/changes/x/proposal.md >/dev/null
"$SDD" advance proposed >/dev/null; sdd_red >/dev/null; sdd_green >/dev/null
cat > "$T/v.txt" <<'X'
DOD
- D1 x | PASS | t_test.go:1
FINDINGS
- none
VERIFY
- command: verify.sh | result: green | ok
VERDICT: PASS
X
"$KIT/scripts/parse-verdict.sh" "$T/v.txt" --proposal openspec/changes/x/proposal.md >/dev/null
refuse "parse without --record records nothing" "$SDD" advance verified
"$KIT/scripts/parse-verdict.sh" "$T/v.txt" --proposal openspec/changes/x/proposal.md --record >/dev/null
expect "parse --record enables verified"         "$SDD" advance verified
"$SDD" abort >/dev/null

echo "glob patterns are not expanded against the working directory"
mkdir -p notes; echo x > README.md; echo x > .agentkit/CLAUDE.md
is "docs pattern still matches a new .md file" allow "$(hook guard-phase.sh "$(edit notes/new.md)")"
is "project dir pattern still matches new files" allow "$(hook guard-phase.sh "$(edit .agentkit/brand-new.txt)")"
printf 'SECRET_GLOBS=.env*\n' >> .agentkit/project.env; touch .env.example; git add -f .env.example
refuse "pre-commit still blocks a secret glob" "$KIT/scripts/guard.sh" pre-commit
git reset -q .env.example; rm -f .env.example notes/new.md; rmdir notes

echo "ci-check without any attestation"
rm -rf .agentkit/attestations; echo 'package src // unattested' > src/new.go
refuse "unattested code change fails"           "$SDD" ci-check
rm src/new.go; git stash -q -u 2>/dev/null; git checkout -q main && git checkout -qb docsonly
echo '# doc only' > docs-note.md
expect "docs-only change needs no attestation"  "$SDD" ci-check
rm -f docs-note.md; git checkout -q feat; git stash pop -q 2>/dev/null; git branch -qD docsonly

echo "low risk and modes"
printf '# P\n## Definition of Done\n1. it works\n' > openspec/changes/x/proposal.md
"$SDD" start t2 --risk low --proposal openspec/changes/x/proposal.md >/dev/null
"$SDD" advance proposed >/dev/null; sdd_red >/dev/null; sdd_green >/dev/null
expect "low verifies without a verdict" "$SDD" advance verified
"$SDD" abort >/dev/null
echo SDD_MODE=guided >> .agentkit/project.env
is "guided asks instead of denying" ask "$(hook guard-phase.sh "$(edit src/app.go)")"
echo SDD_MODE=off >> .agentkit/project.env
is "off disables the guards"     allow "$(hook guard-phase.sh "$(edit src/app.go)")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
