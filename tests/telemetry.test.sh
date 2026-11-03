#!/usr/bin/env bash
# Telemetry (F01), slim: event schema and validation, run ids, off by default, missing usage data, failure isolation, the phase machine / run-role /
# usage hook boundaries, and the benchmark entry point's refusals (a simulated run takes ~2 min, so none runs here). Run: tests/telemetry.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
PATH="$KIT/tests/stubs:$PATH"
TL="$KIT/scripts/telemetry.sh"; SDD="$KIT/scripts/sdd.sh"; ST="$KIT/scripts/state.sh"
# newrepo <name> [extra local settings...]: a git repo on branch feat with TELEMETRY=1 and a proposal for task x; prints its path
newrepo() {
  local r="$T/$1"; shift; mkdir -p "$r/.sdkit/work" "$r/openspec/changes/x"
  git_repo "$r" >/dev/null
  ( cd "$r" && printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\n' > .sdkit/sdkit.env
    printf 'TELEMETRY=1\n' > .sdkit/sdkit.local.env; for l in "$@"; do printf '%s\n' "$l" >> .sdkit/sdkit.local.env; done
    printf 'work/\n.sdd/\n.verify-cache/\n' > .sdkit/.gitignore
    printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > openspec/changes/x/proposal.md
    git add -A && git commit -qm cfg && git checkout -qb feat )
  echo "$r"
}
ev() { echo "$1/.sdkit/work/$2/events.jsonl"; }
export VERIFY_BASE=main

echo "schema and validation"
R="$(newrepo main)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
check "a minimal event is accepted"                    "$TL" emit task.start --task t1 --risk medium --strict
check "an agent.end with every field is accepted"      "$TL" emit agent.end --task t1 --role developer --host claude --model m --tier standard --in 10 --out 5 --cache-read 2 --cache-write 1 --dur-ms 900 --tool-calls 3 --span s1 --q tokens=actual --strict
eq "each event is one JSON line with v=1, mode live"   "$(jq -r 'select(.v == 1) | .mode' "$(ev "$R" t1)" | tr '\n' ' ')" "live live "
nocheck "unknown type is rejected (--strict)"          "$TL" emit nonsense --task t1 --strict
nocheck "a negative number is rejected"                "$TL" emit agent.end --task t1 --role x --out -4 --strict
check "validate accepts the file"                      "$TL" validate t1
printf 'not json\n{"v":2,"type":"retry"}\n' >> "$(ev "$R" t1)"
V="$("$TL" validate t1 2>&1)"; vrc=$?
eq "validate flags corrupt lines, naming line and rule" "$vrc/$(grep -c 'line 3: not JSON\|line 4: v must be 1' <<< "$V")" 1/2

echo "off by default"
O="$(newrepo off)"; sed -i.bak '/TELEMETRY/d' "$O/.sdkit/sdkit.local.env"
( cd "$O" && export CLAUDE_PROJECT_DIR="$O" && "$TL" emit task.start --task t1 && "$SDD" start x --risk low --proposal openspec/changes/x/proposal.md && "$SDD" advance proposed ) >/dev/null 2>&1
check "TELEMETRY unset: no events, even through the phase machine" test ! -e "$(ev "$O" t1)" -a ! -e "$(ev "$O" x)"
( cd "$O" && CLAUDE_PROJECT_DIR="$O" "$TL" emit task.start --task t1 --force )
check "--force writes anyway"                          test -s "$(ev "$O" t1)"

echo "correlation ids and concurrency"
"$TL" emit task.start --task c1 --risk low; "$TL" emit phase.enter --task c1 --to proposed; "$TL" emit retry --task c1
eq "one run id across the task's events"               "$(jq -r .run "$(ev "$R" c1)" | sort -u | wc -l | tr -d ' ')" 1
r1="$(jq -r .run "$(ev "$R" c1)" | head -1)"
"$TL" emit task.start --task c1 --risk low; "$TL" emit retry --task c1
eq "a new task.start starts a new run"                 "$(jq -r .run "$(ev "$R" c1)" | sort -u | wc -l | tr -d ' ')" 2
eq "summary covers the latest run; --run an earlier"   "$("$TL" summary c1 --json | jq '.retries')/$("$TL" summary c1 --run "$r1" --json | jq -r '[.phases[].phase] | join(",")')" "1/intake,proposed"
for i in $(seq 1 10); do "$TL" emit agent.end --task par --role developer --span "p$i" --in 5 --out 2 --q tokens=actual & done; wait
eq "10 parallel events: 10 lines, none lost, tokens add up" "$(wc -l < "$(ev "$R" par)" | tr -d ' ') $("$TL" summary par --json | jq -r '"\(.agents.finished) \(.tokens.in)"')" "10 10 50"
check "the parallel file validates"                    "$TL" validate par

echo "missing or incomplete usage data"
"$TL" emit task.start --task m1; "$TL" emit agent.end --task m1 --role scout --host codex
eq "no numbers given: unavailable, no token field"     "$(jq -r 'select(.type=="agent.end") | "\(.q.tokens) \(.q.duration) \(has("in") or has("out"))"' "$(ev "$R" m1)")" "unavailable unavailable false"
"$TL" emit agent.end --task m1 --role developer --in 100 --out 20 --q tokens=actual
eq "summary: 1 measured / 1 unmeasured, incomplete, only measured counted" "$("$TL" summary m1 --json | jq -r '"\(.tokens.runs_measured)/\(.tokens.runs_unmeasured) \(.tokens.complete) \(.tokens.in) \(.cost.quality)"')" "1/1 false 100 unavailable"
echo '{"claude-x":{"in":3,"out":15,"cache_read":0.3,"cache_write":3.75}}' > "$R/.sdkit/pricing.json"
"$TL" emit agent.end --task m3 --role developer --model claude-x --in 1000000 --out 1000000 --q tokens=actual
"$TL" emit agent.end --task m3 --role verifier --model other-model --in 5 --out 5 --q tokens=actual
eq "cost: priced from the user's table, as an estimate" "$("$TL" summary m3 --json | jq -r '"\(.cost.usd) \(.cost.quality) \(.cost.unpriced_runs)"')" "18 estimated 1"
rm -f "$R/.sdkit/pricing.json"

echo "failure isolation"
eq "no jq: emit exits 0"                               "$(cd "$R" && PATH=/nonexistent CLAUDE_PROJECT_DIR="$R" /bin/bash "$TL" emit task.start --task iso; echo $?)" 0
eq "invalid event without --strict: exit 0"            "$(rc "$TL" emit bogus-type)" 0
# a broken telemetry script must not change what the phase machine does
KC="$T/kitcopy"; mkdir -p "$KC/.claude-plugin" && cp -R "$KIT/scripts" "$KC/scripts" && cp "$KIT"/.claude-plugin/plugin.json "$KC/.claude-plugin/"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 7\n' > "$KC/scripts/telemetry.sh"; chmod +x "$KC/scripts/telemetry.sh"
I="$(newrepo broken)"
( cd "$I" && export CLAUDE_PROJECT_DIR="$I"
  eq "broken telemetry.sh: start works, a refusal is still a refusal" "$(rc "$KC/scripts/sdd.sh" start x --risk low --proposal openspec/changes/x/proposal.md)$(rc "$KC/scripts/sdd.sh" advance red --test-cmd true)" 01 )

echo "the phase machine, state.sh and the gate emit events"
P="$(newrepo phases)"; cd "$P" || exit 1; export CLAUDE_PROJECT_DIR="$P"
export SDKIT_GREEN="$T/green"   # RED fails until the test marks it green
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }
"$SDD" start x --risk medium --proposal openspec/changes/x/proposal.md >/dev/null
sdd_red >/dev/null 2>&1                                              # skipping a phase: refused
"$SDD" advance proposed >/dev/null
"$SDD" advance red --test-cmd true >/dev/null 2>&1                   # passing test is not red: refused
sdd_red >/dev/null
echo ok > src.txt; sdd_green >/dev/null
"$ST" x init medium feat >/dev/null; "$ST" x retry T1 >/dev/null; "$ST" x retry T1 >/dev/null 2>&1
printf 'DOD\n- D1 a | PASS | t\nFINDINGS\n- none\nVERIFY\n- command: v | result: green | ok\nVERDICT: PASS\n' | "$KIT/scripts/parse-verdict.sh" - --proposal openspec/changes/x/proposal.md --record >/dev/null
"$SDD" advance verified >/dev/null; "$SDD" advance pr >/dev/null; "$SDD" advance done >/dev/null
S="$("$TL" summary x --json)"
eq "phases in order"                                   "$(jq -r '[.phases[].phase] | join(">")' <<< "$S")" "intake>proposed>red>green>verified>pr>done"
eq "status, verified, risk"                            "$(jq -r '"\(.status) \(.verified) \(.risk)"' <<< "$S")" "completed true medium"
eq "test results: red fail, green pass"                "$(jq -r '.tests | map("\(.phase):\(.outcome)") | sort | join(",")' <<< "$S")" "green:pass,red:fail,red:pass"
eq "gate rejections counted (phase skip, passing red)" "$(jq .failures.gate_rejections <<< "$S")" 2
eq "retry counted once, exhausted retry is a block"    "$(jq -r '"\(.retries) \(.failures.by_category["verdict-block"])"' <<< "$S")" "1 1"
eq "verification result is the verifier's PASS"        "$(jq -r '.verification.final' <<< "$S")" PASS
check "every stored event is valid"                    "$TL" validate x

echo "run-role.sh and the usage hook"
H="$(newrepo roles 'USAGE_LOG=1' 'RUN_ROLE_HOST=claude')"; mkdir -p "$H/.sdkit/work/h1/out"
cd "$H" || exit 1; export CLAUDE_PROJECT_DIR="$H"
"$ST" h1 init medium feat >/dev/null
printf 'do it\n' > "$H/hand.md"
mkdir -p "$T/fx/answers" "$T/fx/usage"; echo 'built' > "$T/fx/answers/s1.txt"; echo '100 40 500 60' > "$T/fx/usage/s1"
run() { SDKIT_BENCH_SCENARIO="$T/fx" SDKIT_BENCH_STEP="$1" PATH="$KIT/bench/stub-host:$PATH" "$KIT/scripts/run-role.sh" "$2" --handoff hand.md --cwd "$H" --out "$H/o.md" >/dev/null 2>&1; }
run s1 developer
S1="$("$TL" summary h1 --json)"
eq "run-role: start+end tied by one span"              "$(jq -r 'select(.type|startswith("agent.")) | .type' "$(ev "$H" h1)" | sort | tr '\n' ' ')/$(jq -r 'select(.type|startswith("agent.")) | .span' "$(ev "$H" h1)" | sort -u | wc -l | tr -d ' ')" "agent.end agent.start /1"
eq "run-role: claude usage is actual, cache included"  "$(jq -r '.agents.by_role[0] | "\(.in) \(.out) \(.cache_read) \(.cache_write)"' <<< "$S1")" "100 40 500 60"
eq "run-role: ledger got the same numbers"             "$(jq -s 'map(.in + .out) | add' "$H/.sdkit/work/h1/usage.jsonl")" 140
run s2 developer                                      # claude host, no usage file: the host printed none
eq "run-role: no usage printed is unavailable, not 0"  "$(jq -r 'select(.type=="agent.end") | .q.tokens' "$(ev "$H" h1)" | tail -1)" unavailable
printf '%s\n' '{"type":"assistant","timestamp":"2026-10-30T10:00:00.100Z","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":1},"content":[{"type":"tool_use","id":"u1"},{"type":"tool_use","id":"u2"}]}}' \
  '{"type":"assistant","timestamp":"2026-10-30T10:00:09.900Z","message":{"id":"m2","model":"claude-x","usage":{"input_tokens":20,"output_tokens":7},"content":[{"type":"text","text":"x"}]}}' > "$T/tr.jsonl"
J="$(jq -nc --arg t "$T/tr.jsonl" '{hook_event_name:"SubagentStop",agent_type:"reviewer",agent_id:"ag7",agent_transcript_path:$t}')"
printf '%s' "$J" | "$KIT/hooks/usage-log.sh" >/dev/null 2>&1; printf '%s' "$J" | "$KIT/hooks/usage-log.sh" >/dev/null 2>&1
eq "hook: tokens, tool calls, estimated duration"      "$(jq -r 'select(.span=="ag7") | "\(.in) \(.out) \(.q.tokens) \(.tool_calls) \(.dur_ms) \(.q.duration)"' "$(ev "$H" h1)" | sort -u)" "30 12 actual 2 9000 estimated"
eq "the same span twice counts once"                   "$("$TL" summary h1 --json | jq '[.agents.by_role[] | select(.role=="reviewer") | .runs] | add')" 1

echo "benchmark entry point"
BN="$KIT/bench/run.sh"
eq "four scenarios"                                    "$("$BN" list | wc -l | tr -d ' ')" 4
eq "real mode refuses without --host"                  "$(rc "$BN" run low-single-file --real --yes)" 2
eq "real mode refuses without --yes (no tty)"          "$("$BN" run low-single-file --real --host claude </dev/null >/dev/null 2>&1; echo $?)" 2
eq "simulated mode refuses --host"                     "$(rc "$BN" run low-single-file --host claude)" 2

finish telemetry
