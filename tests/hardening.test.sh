#!/usr/bin/env bash
# F00.5 regression tests: verdict validation (B2), the record flow per host (B1), concurrent state and ledger writes (D4),
# env files that are parsed and never executed (R1/D1), active task resolution (D2), lookup cache and untracked files (B3),
# one default stack (B4). Each section reproduces the failure the audit found.
# Run: tests/hardening.test.sh
set -u
[ -n "${PSEC_ONLY:-}" ] || exec "$(dirname "$0")/lib/psections.sh" "$0" "$@"   # independent parts run at the same time, dependent sections as one chain
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

# newrepo <name>: a git repo with .sdkit/sdkit.env (BASE_BRANCH=main, SDD_MODE=strict) and one commit; prints its path
newrepo() {
  local r="$T/$1"; mkdir -p "$r/.sdkit"
  ( cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
    printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\n' > .sdkit/sdkit.env
    printf 'work/\n.sdd/\n.verify-cache/\n' > .sdkit/.gitignore
    echo a > a.txt && git add -A && git commit -qm init )
  echo "$r"
}

GOOD_PASS='DOD
- D1 handles retry | PASS | retry_test.go:12
FINDINGS
- none
VERIFY
- command: verify.sh | result: green | ok
VERDICT: PASS'
CONTRADICTORY='DOD
- D1 handles retry | FAIL | retry_test.go:12
FINDINGS
- none
VERIFY
- command: verify.sh | result: red | broken
VERDICT: PASS'
GOOD_BLOCK='DOD
- D1 handles retry | FAIL | retry_test.go:12
FINDINGS
- CONFIRMED | a.go:4 | racy | two writers
VERIFY
- command: verify.sh | result: red | broken
VERDICT: BLOCK'

stop_json() { jq -nc --arg m "$1" '{hook_event_name:"SubagentStop",agent_type:"spec-driven-kit:verifier",last_assistant_message:$m}'; }
verdict_of() { jq -r '.verdict.result // "none"' "$1/.sdkit/.sdd/state.json"; }

echo "B2: the verifier hook records only what parse-verdict.sh accepts"
r="$(newrepo b2)"; cd "$r" || exit 1
"$KIT/scripts/sdd.sh" start t1 --risk medium --proposal p.md >/dev/null
stop_json "$CONTRADICTORY" | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/record-verdict.sh" >"$T/out" 2>&1; hrc=$?
eq "contradictory PASS is not recorded"            "$(verdict_of "$r")" none
eq "the hook still exits 0 on a rejected verdict"  "$hrc" 0
check "the orchestrator is told the block was malformed"  grep -q 'MALFORMED' "$T/out"
stop_json "VERDICT: PASS" | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/record-verdict.sh" >/dev/null 2>&1
eq "a bare VERDICT line is not recorded"           "$(verdict_of "$r")" none
stop_json "$GOOD_PASS" | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/record-verdict.sh" >/dev/null 2>&1
eq "a well-formed PASS is recorded"                "$(verdict_of "$r")" PASS
stop_json "$GOOD_BLOCK" | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/record-verdict.sh" >/dev/null 2>&1
eq "a well-formed BLOCK replaces it"               "$(verdict_of "$r")" BLOCK
stop_json "$CONTRADICTORY" | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/record-verdict.sh" >/dev/null 2>&1
eq "a later malformed block leaves the verdict alone"  "$(verdict_of "$r")" BLOCK
# the hook counts the DoD items of the task's proposal, like parse-verdict.sh --proposal
printf '## Definition of Done\n- D1: a | Verified by: unit test\n- D2: b | Verified by: unit test\n' > p.md
"$KIT/scripts/sdd.sh" abort >/dev/null; "$KIT/scripts/sdd.sh" start t1 --risk medium --proposal p.md >/dev/null
stop_json "$GOOD_PASS" | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/record-verdict.sh" >/dev/null 2>&1
eq "a verifier that skipped a DoD item is not recorded"  "$(verdict_of "$r")" none
# fallback: no last_assistant_message, the answer is in the agent transcript
"$KIT/scripts/sdd.sh" abort >/dev/null; "$KIT/scripts/sdd.sh" start t1 --risk medium --proposal nope.md >/dev/null
jq -nc --arg m "$GOOD_PASS" '{type:"assistant",message:{content:[{type:"text",text:$m}]}}' > "$T/transcript.jsonl"
jq -nc --arg p "$T/transcript.jsonl" '{hook_event_name:"SubagentStop",agent_type:"verifier",agent_transcript_path:$p}' | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/record-verdict.sh" >/dev/null 2>&1
eq "the transcript fallback records a well-formed verdict"  "$(verdict_of "$r")" PASS
"$KIT/scripts/sdd.sh" abort >/dev/null

echo "B1: the record flow matches the host"
pr_json() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
decision() { jq -rs '(.[0].hookSpecificOutput.permissionDecision) // "allow"'; }
eq "claude: --record by hand is denied (the hook records)"  "$(pr_json 'scripts/parse-verdict.sh - --record' | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/guard-pr.sh" | decision)" deny
eq "other host: --record is the only way, allowed"          "$(pr_json 'scripts/parse-verdict.sh - --record' | SDKIT_HOST=cursor CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/guard-pr.sh" | decision)" allow
eq "other host: sdd.sh _verdict stays denied"               "$(pr_json 'scripts/sdd.sh _verdict PASS' | SDKIT_HOST=cursor CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/guard-pr.sh" | decision)" deny
eq "other host: editing .sdd by hand stays denied"          "$(pr_json 'echo x > .sdkit/.sdd/state.json' | SDKIT_HOST=gemini CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/guard-pr.sh" | decision)" deny
pj="$(jq -nc '{tool_name:"run_shell_command",tool_input:{command:"scripts/parse-verdict.sh - --record"}}')"
eq "gemini through adapt.sh: --record is allowed"           "$(printf '%s' "$pj" | GEMINI_PROJECT_DIR="$r" "$KIT/hooks/adapt.sh" gemini guard-pr.sh >/dev/null 2>&1; echo $?)" 0
check "the skill tells Claude Code not to pass --record"    grep -q 'Claude Code: do not pass `--record`' "$KIT/skills/spec-driven-dev/SKILL.md"
check "the skill tells other hosts to pass --record"        grep -q 'other hosts: pass `--record`' "$KIT/skills/spec-driven-dev/SKILL.md"

echo "D4: concurrent writers"
r="$(newrepo d4)"; cd "$r" || exit 1
S="$KIT/scripts/state.sh"; U="$KIT/scripts/usage.sh"
"$S" s init low main >/dev/null
for i in $(seq 30); do "$S" s spawn >/dev/null 2>&1 & done; wait
eq "30 parallel spawns are all counted"            "$(jq -r .spawns .sdkit/work/s/state.json)" 30
for i in $(seq 30); do "$S" s task "T$i" done >/dev/null 2>&1 & done; wait
eq "30 parallel task updates all land"             "$(jq -r '.tasks|length' .sdkit/work/s/state.json)" 30
check "state.json is still valid JSON"             jq -e . .sdkit/work/s/state.json
for i in $(seq 30); do "$U" log --role r --id "agent-$i" --in 1 --slug s --force >/dev/null 2>&1 & done; wait
eq "30 parallel ledger lines (distinct ids) all land"  "$(wc -l < .sdkit/work/s/usage.jsonl | tr -d ' ')" 30
for i in $(seq 30); do "$U" log --role r --id same --in 1 --slug s --force >/dev/null 2>&1 & done; wait
eq "a repeated id still keeps exactly one line"    "$(grep -c '"id":"same"' .sdkit/work/s/usage.jsonl)" 1
eq "and the other 30 lines survive"                "$(wc -l < .sdkit/work/s/usage.jsonl | tr -d ' ')" 31
for i in $(seq 20); do "$U" log --role r --in 1 --slug s2 --force >/dev/null 2>&1 & done; wait
eq "20 parallel id-less lines all land"            "$(wc -l < .sdkit/work/s2/usage.jsonl | tr -d ' ')" 20
"$KIT/scripts/sdd.sh" start t --risk medium --proposal p.md >/dev/null
for i in $(seq 20); do "$KIT/scripts/sdd.sh" _verdict PASS >/dev/null 2>&1 & done; wait
check "sdd state survives parallel verdicts"       jq -e '.verdict.result == "PASS"' .sdkit/.sdd/state.json
check "no lock directory is left behind"           test -z "$(find .sdkit -name '*.lock' 2>/dev/null)"
# a lock whose owner died must not wedge the next writer
mkdir -p .sdkit/work/s/state.json.lock; echo 999999 > .sdkit/work/s/state.json.lock/pid
t0=$(date +%s); "$S" s spawn >/dev/null 2>&1; t1=$(date +%s)
check "a stale lock (dead owner) is broken in time"  test $((t1 - t0)) -lt 15
"$KIT/scripts/sdd.sh" abort >/dev/null

echo "R1/D1: env files are parsed, never executed"
r="$(newrepo r1)"; cd "$r" || exit 1
rm -f "$T/PWNED"
cat > .sdkit/sdkit.env <<X
BASE_BRANCH=main
STACK=generic
PLAIN=value
QUOTED="two words"
SINGLE='no \$expansion here'
GLOBS=.env*,*credentials*,*.pem
WITH_COMMENT=kept # a trailing comment
REF=\$PLAIN/sub
BRACED="\${PLAIN}-x"
export EXPORTED=yes
: "\${DEFAULTED:=fallback}"
: "\${PLAIN:=ignored}"
EVIL1=\$(touch $T/PWNED)
EVIL2=\`touch $T/PWNED\`
EVIL3="\$(touch $T/PWNED)"
EVIL4=x; touch $T/PWNED
EVIL5=a b
touch $T/PWNED
PATH=/nonexistent
X
printf 'PLAIN=local\n' > .sdkit/sdkit.local.env
cat > "$T/probe.sh" <<X
. "$KIT/scripts/env.sh"; sdkit_env_load "\$1" 2>"$T/env.err"
printf '%s\n' "\$PLAIN|\$QUOTED|\$SINGLE|\$GLOBS|\$WITH_COMMENT|\$REF|\$BRACED|\$EXPORTED|\$DEFAULTED|\${EVIL1:-}\${EVIL2:-}\${EVIL3:-}\${EVIL4:-}\${EVIL5:-}"
X
out="$(bash "$T/probe.sh" "$r")"
check "no config line executed anything"           test ! -e "$T/PWNED"
eq "plain, quoted, single-quoted, glob, comment, \$VAR, \${VAR}, export, := all keep their meaning" \
   "$out" 'local|two words|no $expansion here|.env*,*credentials*,*.pem|kept|value/sub|value-x|yes|fallback|'
nocheck "PATH cannot be set from a config file"    bash -c ". '$KIT/scripts/env.sh'; sdkit_env_load '$r' 2>/dev/null; [ \"\$PATH\" = /nonexistent ]"
check "unsupported lines are reported, not silent" grep -q 'unsupported' "$T/env.err"
check "the report names file and line, not the content"  bash -c "grep -q 'sdkit.env:1[0-9]' '$T/env.err' && ! grep -q PWNED '$T/env.err'"
check "the exported setting reaches child processes"  bash -c ". '$KIT/scripts/env.sh'; sdkit_env_load '$r' 2>/dev/null; bash -c '[ \"\$EXPORTED\" = yes ]'"
# the real entry points use it
rm -f "$T/PWNED"; printf 'BASE_BRANCH=main\nSDD_MODE=guided\nEVIL=$(touch %s)\n' "$T/PWNED" > .sdkit/sdkit.env; : > .sdkit/sdkit.local.env
eq "sdd.sh reads SDD_MODE and runs nothing"        "$("$KIT/scripts/sdd.sh" mode 2>/dev/null)" guided
echo '{}' | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/session-context.sh" >/dev/null 2>&1
"$KIT/scripts/state.sh" x init >/dev/null 2>&1; "$KIT/scripts/usage.sh" report >/dev/null 2>&1; "$KIT/scripts/memory.sh" status >/dev/null 2>&1
"$KIT/scripts/guard.sh" pre-commit >/dev/null 2>&1; "$KIT/scripts/resolve-base.sh" >/dev/null 2>&1; "$KIT/scripts/lookup-cache.sh" get x q >/dev/null 2>&1
( cd "$r" && "$KIT/scripts/run-role.sh" scout --handoff a.txt --host claude --dry-run >/dev/null 2>&1 )
check "hooks and scripts executed nothing from the env file"  test ! -e "$T/PWNED"
nocheck "no script or hook sources an env file any more"  bash -c "cd '$KIT' && grep -rnE '(^|[;&(] *)(\\.|source) +\"?[^ ]*(sdkit(\\.local)?\\.env|project\\.env|KIT_ENV|ENV_FILE|ENV_OLD|env_file)' hooks scripts bin stacks adapters/git"
printf 'BASE_BRANCH=main\nSTACK=generic\n' > .sdkit/sdkit.env

echo "D2: the active task comes from the SDD state"
r="$(newrepo d2)"; cd "$r" || exit 1
printf 'BASE_BRANCH=main\nSTACK=generic\nMAX_SPAWNS=100\nUSAGE_LOG=1\n' > .sdkit/sdkit.env
"$KIT/scripts/state.sh" task-b init low main >/dev/null; sleep 1; "$KIT/scripts/state.sh" task-a init low main >/dev/null   # task-a is the newest file
"$KIT/scripts/sdd.sh" start task-b --risk low --proposal p.md >/dev/null
agent='{"tool_name":"Agent","tool_input":{}}'
printf '%s' "$agent" | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/guard-budget.sh" >/dev/null 2>&1
eq "the spawn is counted on the SDD task, not the newest file"  "$(jq -r '.spawns // 0' .sdkit/work/task-b/state.json)" 1
eq "and not on the other task"                     "$(jq -r '.spawns // 0' .sdkit/work/task-a/state.json)" 0
"$KIT/scripts/usage.sh" log --role dev --in 5 --out 5 >/dev/null 2>&1
eq "the ledger default slug is the SDD task too"   "$(wc -l < .sdkit/work/task-b/usage.jsonl 2>/dev/null | tr -d ' ')" 1
"$KIT/scripts/sdd.sh" abort >/dev/null
printf '%s' "$agent" | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/guard-budget.sh" >/dev/null 2>&1
eq "no SDD task: falls back to the newest state file (task-b, just written)"  "$(jq -r '.spawns // 0' .sdkit/work/task-b/state.json)" 2
"$KIT/scripts/sdd.sh" start ghost --risk low --proposal p.md >/dev/null
printf '%s' "$agent" | CLAUDE_PROJECT_DIR="$r" "$KIT/hooks/guard-budget.sh" >/dev/null 2>&1
eq "SDD task without a work state: falls back too"  "$(jq -r '.spawns // 0' .sdkit/work/task-b/state.json)" 3
eq "the other task was never touched"              "$(jq -r '.spawns // 0' .sdkit/work/task-a/state.json)" 0
"$KIT/scripts/sdd.sh" abort >/dev/null
check "sdd.sh task prints the open task"           bash -c "'$KIT/scripts/sdd.sh' start zed --risk low --proposal p.md >/dev/null; [ \"\$('$KIT/scripts/sdd.sh' task)\" = zed ]; '$KIT/scripts/sdd.sh' abort >/dev/null"

echo "B3: the lookup cache sees untracked files"
r="$(newrepo b3)"; cd "$r" || exit 1
L="$KIT/scripts/lookup-cache.sh"
echo "answer" | "$L" put t "where is X"
check "unchanged tree: hit"                        "$L" get t "where is X"
echo new > untracked.txt
nocheck "a new untracked file invalidates"         "$L" get t "where is X"
echo "answer" | "$L" put t "where is X"
check "same untracked file: hit"                   "$L" get t "where is X"
echo changed > untracked.txt
nocheck "editing the untracked file invalidates"   "$L" get t "where is X"
echo "answer" | "$L" put t "where is X"
check "the cache's own files do not invalidate it" "$L" get t "where is X"
echo "answer" | "$L" put t "where is X"; echo more > a.txt
nocheck "a tracked edit still invalidates"         "$L" get t "where is X"

echo "B4: one default stack"
nocheck "no script or hook hardcodes another default" bash -c "cd '$KIT' && grep -rnE 'STACK:-[a-z]' hooks scripts bin stacks"
eq "env.sh defaults to go, the documented default"  "$(bash -c ". '$KIT/scripts/env.sh'; echo \$SDKIT_DEFAULT_STACK")" go
r="$(newrepo b4)"; cd "$r" || exit 1
printf 'BASE_BRANCH=main\n' > .sdkit/sdkit.env
eq "STACK unset resolves to the default after loading"  "$(bash -c ". '$KIT/scripts/env.sh'; sdkit_env_load '$r'; echo \$STACK")" go
eq "doctor flags a missing STACK"                  "$("$KIT/bin/doctor.sh" "$r" 2>&1 | grep -c 'STACK is not set')" 1
printf 'BASE_BRANCH=main\nSTACK=python\n' > .sdkit/sdkit.env
eq "an explicit STACK wins"                        "$(bash -c ". '$KIT/scripts/env.sh'; sdkit_env_load '$r'; echo \$STACK")" python

echo
echo "hardening tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
