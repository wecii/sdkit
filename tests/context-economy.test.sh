#!/usr/bin/env bash
# Context economy: capped.sh (command output kept short), the guard-noisy hook, usage.sh context, the phase-boundary note and the wiring.
# Run: tests/context-economy.test.sh
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }

repo="$T/repo"; mkdir -p "$repo/.sdkit" && cd "$repo" && git init -q -b main . && git config user.email t@t && git config user.name t
printf 'STACK=none\nNOISY_CMD_PATTERNS="npm test*,go test*,pytest*"\n' > .sdkit/sdkit.env; : > .gitignore; git add -A; git commit -qm i
export CLAUDE_PROJECT_DIR="$repo"
C="$KIT/scripts/capped.sh"

echo "capped.sh"
out="$("$C" -- echo hello)"; check "short output is printed whole"            test "$out" = hello
"$C" -- bash -c 'exit 7' >/dev/null 2>&1; check "the exit code is kept"       test $? = 7
out="$("$C" --lines 10 -- bash -c 'for i in $(seq 1 300); do echo "row $i"; done; echo "FAIL: boom"; exit 1')"; rc=$?
check "long output: summary names the line count"      bash -c "grep -q '301 lines' <<< '$out'"
check "long output: failure line is kept"              bash -c "grep -q 'FAIL: boom' <<< '$out'"
check "long output: capped well under the original"    test "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -lt 25
log="$(printf '%s\n' "$out" | sed -n 's/.*Full output: //p')"
check "the full log is stored and complete"            test "$(wc -l < "$repo/$log" | tr -d ' ')" = 301
out="$("$C" --lines 10 -- bash -c 'seq 1 100; exit 4' )"; "$C" --lines 10 -- bash -c 'seq 1 100; exit 4' >/dev/null; check "exit code survives capping" test $? = 4
"$C" >/dev/null 2>&1; check "no command is a usage error"  test $? = 2

echo "guard-noisy hook"
H="$KIT/hooks/guard-noisy.sh"
dec() { local o; o="$(jq -n --arg c "$1" --arg a "${2:-}" '{tool_name:"Bash",agent_type:$a,tool_input:{command:$c}}' | "$H")"; [ -n "$o" ] && jq -r '.hookSpecificOutput.permissionDecision' <<< "$o" || echo pass; }
check "a matching command asks"                         test "$(dec 'npm test')" = ask
check "the reason names capped.sh"                      bash -c "jq -n '{tool_name:\"Bash\",tool_input:{command:\"go test ./...\"}}' | '$H' | grep -q capped.sh"
check "cd prefix does not hide it"                      test "$(dec 'cd app && go test ./...')" = ask
check "a non-matching command passes"                   test "$(dec 'ls -la')" = pass
check "already wrapped passes"                          test "$(dec "$C -- npm test")" = pass
check "piped to tail passes"                            test "$(dec 'npm test 2>&1 | tail -20')" = pass
check "redirected to a file passes"                     test "$(dec 'pytest > /tmp/o.log 2>&1')" = pass
check "a subagent call passes"                          test "$(dec 'npm test' developer)" = pass
printf 'STACK=none\n' > .sdkit/sdkit.env
check "off when NOISY_CMD_PATTERNS is empty"            test "$(dec 'npm test')" = pass
printf 'STACK=none\nNOISY_CMD_PATTERNS="npm test*"\nSDD_MODE=off\n' > .sdkit/sdkit.env
check "off with SDD_MODE=off"                           test "$(dec 'npm test')" = pass

echo "usage.sh context"
cat > "$T/t.jsonl" <<'JL'
{"type":"assistant","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":1},"content":[{"type":"tool_use","id":"u1","name":"Bash","input":{"command":"npm test"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u1","content":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}]}}
{"type":"assistant","requestId":"r2","message":{"id":"m2","usage":{"input_tokens":1},"content":[{"type":"tool_use","id":"u2","name":"Read","input":{"file_path":"/a/b.go"}}]}}
{"type":"assistant","requestId":"r2","message":{"id":"m2","usage":{"input_tokens":1},"content":[{"type":"text","text":"second record of the same request"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"u2","content":[{"type":"text","text":"yy"}]}]}}
{"type":"assistant","requestId":"r3","message":{"id":"m3","usage":{"input_tokens":1},"content":[{"type":"text","text":"done"}]}}
JL
j="$("$KIT/scripts/usage.sh" context "$T/t.jsonl" --json)"
btok=$(( $(jq -r 'select(.type=="user" and (.message.content[0].tool_use_id=="u1")) | .message.content[0].content | length' "$T/t.jsonl") / 4 ))
check "a request split over records counts one turn"    test "$(jq .transcript_turns <<< "$j")" = 3
check "both results are found"                          test "$(jq .results <<< "$j")" = 2
check "the Bash result is chars/4 tokens"               test "$(jq '.by_tool[] | select(.tool=="Bash") | .tokens' <<< "$j")" = "$btok"
check "re-read = tokens x the 2 turns after it"         test "$(jq '.by_tool[] | select(.tool=="Bash") | .reread' <<< "$j")" = "$(( btok * 2 ))"
check "the label is the command, not the output"        test "$(jq -r '.largest[0].label' <<< "$j")" = "npm test"
check "text mode prints the table"                      bash -c "'$KIT/scripts/usage.sh' context '$T/t.jsonl' | grep -q 'largest results'"
nocheck "no transcript is an error"                     "$KIT/scripts/usage.sh" context "$T/none.jsonl"

echo "report: cache hit rate in the text"
repo2="$T/repo2"; mkdir -p "$repo2/.sdkit"; ( cd "$repo2" && git init -q -b main . && git config user.email t@t && git config user.name t && printf 'STACK=none\nUSAGE_LOG=1\n' > .sdkit/sdkit.env && git add -A && git commit -qm i )
( cd "$repo2" && CLAUDE_PROJECT_DIR="$repo2" "$KIT/scripts/usage.sh" log --role orchestrator --in 1000 --out 500 --cache-read 9000 --cache-write 500 --slug t1 --session s1 --id o1 >/dev/null 2>&1 )
check "session text shows cache hit 85.7%"              bash -c "cd '$repo2' && CLAUDE_PROJECT_DIR='$repo2' '$KIT/scripts/report.sh' session s1 | grep -q 'cache hit 85.7%'"

echo "phase-boundary note"
bash -n "$KIT/scripts/sdd.sh" && ok "sdd.sh parses"
check "the note is wired for proposed and green"        bash -c "grep -q 'CONTEXT_HINT' '$KIT/scripts/sdd.sh' && grep -q 'proposed) echo \"boundary' '$KIT/scripts/sdd.sh'"

echo "wiring"
for f in hooks/hooks.json templates/settings.copy.json adapters/cursor/hooks.json adapters/gemini/settings.json; do check "$f registers guard-noisy" grep -q guard-noisy "$KIT/$f"; check "$f is valid JSON" jq -e . "$KIT/$f"; done
check "OpenCode plugin runs guard-noisy"                grep -q guard-noisy "$KIT/adapters/opencode/plugins/spec-driven-kit-guard.js"
check "executables"                                     test -x "$KIT/scripts/capped.sh" -a -x "$KIT/hooks/guard-noisy.sh"
check "templates carry the new settings"                bash -c "grep -q '^NOISY_CMD_PATTERNS=' '$KIT/templates/sdkit.env' && grep -q '^CAPPED_LINES=' '$KIT/templates/sdkit.local.env' && grep -q '^CONTEXT_HINT=' '$KIT/templates/sdkit.local.env'"
check "SKILL.md stays short (<= 140 lines)"             test "$(wc -l < "$KIT/skills/spec-driven-dev/SKILL.md")" -le 140
check "versions agree"                                  test "$(jq -r .version "$KIT/.claude-plugin/plugin.json")" = "$(jq -r '.plugins[0].version' "$KIT/.claude-plugin/marketplace.json")"

echo; echo "context-economy: $pass passed, $fail failed"; [ "$fail" = 0 ]
