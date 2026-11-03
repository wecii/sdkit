#!/usr/bin/env bash
# Review findings that used to get around the gates: CI settings from the PR, fail-open fingerprint/base, RED/GREEN command swap,
# unnormalised paths, slug traversal, hook-only commands behind a variable, skipped git hooks, other bullet styles. Run: tests/gate-security.test.sh
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
expect() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
refuse() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$name (should have failed)"; else ok "$name"; fi; }
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$3', want '$2')"; }
SDD="$KIT/scripts/sdd.sh"
hook() { local out; out="$(printf '%s' "$2" | "$KIT/hooks/$1")"; [ -z "$out" ] && echo allow || printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision; }
edit() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }
bash_() { jq -n --arg c "$1" '{tool_input:{command:$c}}'; }

R="$T/r"; mkdir -p "$R" && cd "$R" || exit 1
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p .sdkit src docs openspec/changes/x
printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\n' > .sdkit/sdkit.env
printf 'work/\n.sdd/\n' > .sdkit/.gitignore
echo base > src/app.py; echo base > README.md
git add -A && git commit -qm base && git checkout -qb feat
export CLAUDE_PROJECT_DIR="$R" VERIFY_BASE=main
printf '# P\n## Definition of Done\n- D1: it works | Verified by: unit test\n' > openspec/changes/x/proposal.md

echo "fingerprint"
echo change >> src/app.py
fp1="$("$SDD" fingerprint)"; is "is 64 hex characters" 64 "${#fp1}"
refuse "an unknown base is an error, not an empty diff" env VERIFY_BASE=origin/nope "$SDD" fingerprint

echo "ci-check fails closed"
refuse "unknown base fails" env VERIFY_BASE=origin/nope "$SDD" ci-check
printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\nSDD_FREE_GLOBS=*\n' > .sdkit/sdkit.env
refuse "PR sets SDD_FREE_GLOBS=*: the base's settings still judge it" "$SDD" ci-check
printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\n' > .sdkit/sdkit.env

echo "GREEN is bound to the RED command"
"$SDD" start t1 --risk low --proposal openspec/changes/x/proposal.md >/dev/null; "$SDD" advance proposed >/dev/null
"$SDD" advance red --test-cmd 'grep -q fixed src/app.py' >/dev/null 2>&1
refuse "a different --test-cmd at green is refused" "$SDD" advance green --test-cmd true
echo fixed >> src/app.py
expect "the RED command, now passing, moves to green" "$SDD" advance green
"$SDD" abort >/dev/null

echo "paths are normalised before the gate"
is "docs/../src is code"            deny "$(hook guard-phase.sh "$(edit "$R/docs/../src/app.py")")"
is ".sdkit/./.sdd is the state"     deny "$(hook guard-phase.sh "$(edit "$R/.sdkit/./.sdd/state.json")")"
is "a plain docs edit stays free"   allow "$(hook guard-phase.sh "$(edit "$R/docs/a.md")")"

echo "slug"
refuse "a slug with a path is refused" "$SDD" start ../../x --risk low --proposal openspec/changes/x/proposal.md

echo "hook-only commands and skipped git hooks"
is "_evidence behind a variable"       deny "$(hook guard-pr.sh "$(bash_ 'S=_evidence; bash .sdkit/scripts/sdd.sh $S verifier PASS')")"
is "git push --no-verify"              deny "$(hook guard-pr.sh "$(bash_ 'git push --no-verify origin feat')")"
is "git -c core.hooksPath=/dev/null"   deny "$(hook guard-pr.sh "$(bash_ 'git -c core.hooksPath=/dev/null commit -m x')")"
is "gh api .../pulls"                  deny "$(hook guard-pr.sh "$(bash_ 'gh api repos/o/r/pulls -f head=x -f base=main')")"
is "a commit message about push is fine" allow "$(hook guard-pr.sh "$(bash_ 'git commit -m "fix push retry"')")"

echo "git pre-commit sees deletions"
git add -A >/dev/null 2>&1; git commit -qm wip --no-verify >/dev/null 2>&1
git rm -q src/app.py
refuse "deleting code without a task is blocked" "$KIT/scripts/guard.sh" pre-commit
git reset -q src/app.py; git checkout -q src/app.py

echo "parse-verdict: every bullet style counts"
PV="$KIT/scripts/parse-verdict.sh"
printf 'DOD\n- D1 a | PASS | t\n* D2 b | FAIL | t\nFINDINGS\n- none\nVERIFY\n- command: v | result: green | ok\nVERDICT: PASS\n' > "$T/v1.txt"
is "a FAIL written as '* ' makes PASS malformed" 2 "$("$PV" "$T/v1.txt" >/dev/null; echo $?)"

printf '\ngate-security tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
