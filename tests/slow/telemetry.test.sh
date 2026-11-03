#!/usr/bin/env bash
# F01 tests: event schema and validation, correlation ids, concurrent recording, missing usage data, failure isolation, the instrumented
# boundaries (phase machine, state.sh, run-role.sh, hooks), the summary, and the benchmark framework (deterministic only: nothing here
# starts a real host CLI). Run: tests/slow/telemetry.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

TL="$KIT/scripts/telemetry.sh"
# newrepo <name> [extra settings...]: a git repo with TELEMETRY=1; prints its path
newrepo() {
  local r="$T/$1"; shift; mkdir -p "$r/.sdkit"
  ( cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
    printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\n' > .sdkit/sdkit.env
    printf 'TELEMETRY=1\n' > .sdkit/sdkit.local.env; for l in "$@"; do printf '%s\n' "$l" >> .sdkit/sdkit.local.env; done
    printf 'work/\n.sdd/\n.verify-cache/\n' > .sdkit/.gitignore
    echo a > a.txt && git add -A && git commit -qm init && git checkout -qb feat )
  echo "$r"
}
ev() { echo "$1/.sdkit/work/$2/events.jsonl"; }

echo "schema and validation"
R="$(newrepo schema)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
check "a minimal event is accepted"                    "$TL" emit task.start --task t1 --risk medium --strict
check "an agent.end with every field is accepted"      "$TL" emit agent.end --task t1 --role developer --host claude --model m --tier standard --in 10 --out 5 --cache-read 2 --cache-write 1 --dur-ms 900 --tool-calls 3 --span s1 --q tokens=actual --strict
eq "each event is one JSON line with v=1"              "$(jq -c 'select(.v == 1)' "$(ev "$R" t1)" | wc -l | tr -d ' ')" 2
eq "ts is UTC to the second"                           "$(jq -r '.ts' "$(ev "$R" t1)" | head -1 | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$')" 1
eq "mode defaults to live"                             "$(jq -r '.mode' "$(ev "$R" t1)" | sort -u)" live
nocheck "unknown type is rejected (--strict)"          "$TL" emit nonsense --task t1 --strict
nocheck "a non-numeric number is rejected"             "$TL" emit agent.end --task t1 --role x --in abc --strict
nocheck "a negative number is rejected"                "$TL" emit agent.end --task t1 --role x --out -4 --strict
nocheck "an unknown failure category is rejected"      "$TL" emit failure --task t1 --category whatever --strict
nocheck "an unknown quality is rejected"               "$TL" emit task.start --task t1 --q duration=guess --strict
nocheck "agent.end needs a role"                       "$TL" emit agent.end --task t1 --strict
nocheck "failure needs a category"                     "$TL" emit failure --task t1 --strict
nocheck "a task slug with a slash is rejected"         "$TL" emit task.start --task ../x --strict
check "validate accepts the file"                      "$TL" validate t1
printf 'not json\n{"v":2,"type":"retry"}\n' >> "$(ev "$R" t1)"
nocheck "validate flags corrupt lines"                 "$TL" validate t1
check "validate names the line"                        bash -c "'$TL' validate t1 | grep -q 'line 3: not JSON'"
check "validate names the rule"                        bash -c "'$TL' validate t1 | grep -q 'line 4: v must be 1'"
eq "a long note is cut, newlines flattened"            "$("$TL" emit failure --task n1 --category other --note "$(printf 'a\nb%0300d' 0)" --strict; jq -r '.note | length' "$(ev "$R" n1)")" 160
check "no prompt-like field exists in the schema"      bash -c "! grep -qiE 'prompt|content|secret|token_value' '$TL' | grep -v '^#' || true"

echo "off by default, local only"
O="$(newrepo off)"; sed -i.bak '/TELEMETRY/d' "$O/.sdkit/sdkit.local.env"; rm -f "$O/.sdkit/sdkit.local.env.bak"
( cd "$O" && CLAUDE_PROJECT_DIR="$O" "$TL" emit task.start --task t1 )
check "TELEMETRY unset: nothing is written"            test ! -e "$(ev "$O" t1)"
( cd "$O" && CLAUDE_PROJECT_DIR="$O" "$TL" emit task.start --task t1 --force )
check "--force writes anyway"                          test -s "$(ev "$O" t1)"
check "the shipped template turns it on (measurement)" bash -c "grep -qE '^TELEMETRY=1\$' '$KIT/templates/sdkit.local.env'"

echo "correlation ids"
cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
"$TL" emit task.start --task c1 --risk low; "$TL" emit phase.enter --task c1 --to proposed; "$TL" emit retry --task c1
eq "one run id across the task's events"               "$(jq -r .run "$(ev "$R" c1)" | sort -u | wc -l | tr -d ' ')" 1
r1="$(jq -r .run "$(ev "$R" c1)" | head -1)"
eq "run-id prints the same id"                         "$("$TL" run-id c1)" "$r1"
sleep 1; "$TL" emit task.start --task c1 --risk low; "$TL" emit retry --task c1
eq "a new task.start starts a new run"                 "$(jq -r .run "$(ev "$R" c1)" | sort -u | wc -l | tr -d ' ')" 2
eq "summary covers the latest run only"                "$("$TL" summary c1 --json | jq '.retries')" 1
eq "--run selects an earlier run"                      "$("$TL" summary c1 --run "$r1" --json | jq '.retries')" 1
eq "--run: the earlier run's phases"                   "$("$TL" summary c1 --run "$r1" --json | jq '[.phases[].phase] | join(",")' -r)" "intake,proposed"
eq "SDKIT_RUN_ID overrides the run"                    "$(SDKIT_RUN_ID=bench-1 "$TL" emit retry --task c1; jq -r '.run' "$(ev "$R" c1)" | tail -1)" bench-1
eq "span ties start and end"                           "$("$TL" emit agent.start --task c2 --role scout --span x1; "$TL" emit agent.end --task c2 --role scout --span x1 --in 1 --out 1; jq -r .span "$(ev "$R" c2)" | sort -u)" x1
eq "an end per span: the last snapshot wins"           "$("$TL" emit agent.end --task c2 --role scout --span x1 --in 9 --out 9 --q tokens=actual; "$TL" summary c2 --json | jq '.tokens.in')" 9

echo "concurrent recording"
cd "$R" || exit 1
for i in $(seq 1 40); do "$TL" emit agent.end --task par --role developer --span "p$i" --in 5 --out 2 --q tokens=actual & done; wait
eq "40 parallel events, 40 lines"                      "$(wc -l < "$(ev "$R" par)" | tr -d ' ')" 40
check "every line is valid"                            "$TL" validate par
eq "no event lost in the summary"                      "$("$TL" summary par --json | jq '.agents.finished')" 40
eq "tokens add up"                                     "$("$TL" summary par --json | jq '.tokens.in')" 200
for i in $(seq 1 20); do "$TL" run-id race >/dev/null & done; wait
eq "20 parallel first uses make one run id"            "$(for i in 1 2 3; do "$TL" run-id race; done | sort -u | wc -l | tr -d ' ')" 1

echo "missing or incomplete usage data"
"$TL" emit task.start --task m1; "$TL" emit agent.end --task m1 --role scout --host codex
eq "no numbers given: tokens are unavailable"          "$(jq -r 'select(.type=="agent.end") | .q.tokens' "$(ev "$R" m1)")" unavailable
eq "no numbers given: no token field is written"       "$(jq -r 'select(.type=="agent.end") | has("in") or has("out")' "$(ev "$R" m1)")" false
eq "no duration given: marked unavailable"             "$(jq -r 'select(.type=="agent.end") | .q.duration' "$(ev "$R" m1)")" unavailable
"$TL" emit agent.end --task m1 --role developer --in 100 --out 20 --q tokens=actual
eq "summary: 1 of 2 runs measured"                     "$("$TL" summary m1 --json | jq -r '"\(.tokens.runs_measured)/\(.tokens.runs_unmeasured)"')" 1/1
eq "summary: totals flagged incomplete"                "$("$TL" summary m1 --json | jq '.tokens.complete')" false
eq "summary: totals count only measured runs"          "$("$TL" summary m1 --json | jq '.tokens.in')" 100
check "text summary says INCOMPLETE"                   bash -c "'$TL' summary m1 | grep -q INCOMPLETE"
eq "claiming actual without numbers is overridden"     "$("$TL" emit agent.end --task m2 --role x --q tokens=actual --q duration=actual; jq -r '.q.tokens + "," + .q.duration' "$(ev "$R" m2)")" unavailable,unavailable
eq "no events at all: a message, not a crash"          "$("$TL" summary nothing-here | head -1 | cut -c1-23)" "no events recorded for "
eq "cost is unavailable without a price table"         "$("$TL" summary m1 --json | jq -r '.cost.quality')" unavailable
echo '{"claude-x":{"in":3,"out":15,"cache_read":0.3,"cache_write":3.75}}' > "$R/.sdkit/pricing.json"
"$TL" emit agent.end --task m3 --role developer --model claude-x --in 1000000 --out 1000000 --q tokens=actual
"$TL" emit agent.end --task m3 --role verifier --model other-model --in 5 --out 5 --q tokens=actual
eq "cost: priced from the user's table, as an estimate" "$("$TL" summary m3 --json | jq -r '"\(.cost.usd) \(.cost.quality) \(.cost.unpriced_runs)"')" "18 estimated 1"
rm -f "$R/.sdkit/pricing.json"

echo "failure isolation"
eq "no jq: emit exits 0"                               "$(cd "$R" && PATH=/nonexistent CLAUDE_PROJECT_DIR="$R" /bin/bash "$TL" emit task.start --task iso; echo $?)" 0
chmod 555 "$R/.sdkit/work" 2>/dev/null
eq "unwritable work dir: emit exits 0"                 "$(rc "$TL" emit task.start --task cannot-create)" 0
chmod 755 "$R/.sdkit/work"
eq "invalid event without --strict: exit 0"            "$(rc "$TL" emit bogus-type)" 0
eq "bad numbers without --strict: exit 0"              "$(rc "$TL" emit agent.end --role x --in abc)" 0
# a broken telemetry script must not change what the phase machine does
KC="$T/kitcopy"; mkdir -p "$KC" && cp -R "$KIT/scripts" "$KC/scripts" && mkdir -p "$KC/.claude-plugin" && cp "$KIT"/.claude-plugin/plugin.json "$KC/.claude-plugin/"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 7\n' > "$KC/scripts/telemetry.sh"; chmod +x "$KC/scripts/telemetry.sh"
I="$(newrepo broken)"; mkdir -p "$I/openspec/changes/x"; printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > "$I/openspec/changes/x/proposal.md"
( cd "$I" && export CLAUDE_PROJECT_DIR="$I" VERIFY_BASE=main
  eq "broken telemetry.sh: start still works"          "$(rc "$KC/scripts/sdd.sh" start x --risk low --proposal openspec/changes/x/proposal.md)" 0
  eq "broken telemetry.sh: advance still works"        "$(rc "$KC/scripts/sdd.sh" advance proposed)" 0
  eq "broken telemetry.sh: a refusal is still a refusal" "$(rc "$KC/scripts/sdd.sh" advance red --test-cmd true)" 1
  eq "broken telemetry.sh: state.sh still works"       "$(rc "$KC/scripts/state.sh" x init low feat)" 0
  eq "broken telemetry.sh: retry still counts"         "$(rc "$KC/scripts/state.sh" x retry T1)" 0
  eq "broken telemetry.sh: retry exhausted still exit 1" "$(rc "$KC/scripts/state.sh" x retry T1)" 1 )
# a telemetry script that is missing entirely
rm -f "$KC/scripts/telemetry.sh"
( cd "$I" && export CLAUDE_PROJECT_DIR="$I" VERIFY_BASE=main
  eq "missing telemetry.sh: status still works"        "$(rc "$KC/scripts/sdd.sh" status)" 0 )

echo "the phase machine, state.sh and the gate emit events"
P="$(newrepo phases)"; mkdir -p "$P/openspec/changes/x"; printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > "$P/openspec/changes/x/proposal.md"
cd "$P" || exit 1; export CLAUDE_PROJECT_DIR="$P" VERIFY_BASE=main
SDD="$KIT/scripts/sdd.sh"; ST="$KIT/scripts/state.sh"
export SDKIT_GREEN="${TMPDIR:-/tmp}/sdkit-green.$$"   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }
"$ST" x init medium feat >/dev/null
"$SDD" start x --risk medium --proposal openspec/changes/x/proposal.md >/dev/null
sdd_red >/dev/null 2>&1                 # skipping a phase: refused
"$SDD" gate edit src/app.go >/dev/null 2>&1                          # code edit in intake: refused
"$SDD" advance proposed >/dev/null
"$SDD" advance red --test-cmd true >/dev/null 2>&1                   # passing test is not red: refused
sdd_red >/dev/null
echo ok > src.txt; sdd_green >/dev/null
"$ST" x retry T1 >/dev/null; "$ST" x retry T1 >/dev/null 2>&1
printf 'DOD\n- D1 a | PASS | t\nFINDINGS\n- none\nVERIFY\n- command: v | result: green | ok\nVERDICT: PASS\n' | "$KIT/scripts/parse-verdict.sh" - --proposal openspec/changes/x/proposal.md --record >/dev/null
"$SDD" advance verified >/dev/null; "$SDD" advance pr >/dev/null; "$SDD" advance done >/dev/null
S="$("$TL" summary x --json)"
eq "phases in order"                                   "$(jq -r '[.phases[].phase] | join(">")' <<< "$S")" "intake>proposed>red>green>verified>pr>done"
eq "status completed and verified"                     "$(jq -r '"\(.status) \(.verified)"' <<< "$S")" "completed true"
eq "risk is recorded"                                  "$(jq -r .risk <<< "$S")" medium
eq "test results: red fail, green pass"                "$(jq -r '.tests | map("\(.phase):\(.outcome)") | sort | join(",")' <<< "$S")" "green:pass,red:fail,red:pass"
eq "gate rejections counted (phase skip, edit, red)"   "$(jq .failures.gate_rejections <<< "$S")" 3
eq "retry counted once"                                "$(jq .retries <<< "$S")" 1
eq "exhausted retry is a verdict-block failure"        "$(jq -r '.failures.by_category["verdict-block"]' <<< "$S")" 1
eq "verification result is the verifier's PASS"        "$(jq -r '.verification.final' <<< "$S")" PASS
check "every stored event is valid"                    "$TL" validate x
check "tests carry a duration"                         bash -c "jq -e 'select(.type==\"test.result\") | .dur_ms' '$(ev "$P" x)' >/dev/null"
"$TL" archive x >/dev/null; rm -rf "$P/.sdkit/work/x"
check "archive outlives work/<slug>"                   test -s "$P/.sdkit/work/_archive/x.events.jsonl"
check "archived task still listed"                     bash -c "'$TL' list | grep -q '^x .*archive'"
check "archived summary readable from the file"        bash -c "'$TL' summary --file '$P/.sdkit/work/_archive/x.events.jsonl' | grep -q 'status completed'"
# abort
"$SDD" start y --risk low --proposal openspec/changes/x/proposal.md >/dev/null; "$SDD" abort >/dev/null
eq "abort is a task.end aborted"                       "$("$TL" summary y --json | jq -r .status)" aborted

echo "backward compatibility"
B="$(newrepo compat)"; sed -i.bak '/TELEMETRY/d' "$B/.sdkit/sdkit.local.env"; rm -f "$B/.sdkit/sdkit.local.env.bak"; mkdir -p "$B/openspec/changes/x"
printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > "$B/openspec/changes/x/proposal.md"
cd "$B" || exit 1; export CLAUDE_PROJECT_DIR="$B" VERIFY_BASE=main
"$ST" x init low feat >/dev/null; "$SDD" start x --risk low --proposal openspec/changes/x/proposal.md >/dev/null; "$SDD" advance proposed >/dev/null; sdd_red >/dev/null
check "a repo without TELEMETRY writes no events file" test ! -e "$(ev "$B" x)"
check "state.sh retry unchanged"                       "$ST" x retry T1
nocheck "state.sh second retry unchanged"              "$ST" x retry T1
check "the usage ledger is still the token ledger"     bash -c "printf 'USAGE_LOG=1\n' >> .sdkit/sdkit.local.env; '$KIT/scripts/usage.sh' log --role developer --in 5 --out 2 --slug x && '$KIT/scripts/usage.sh' report x | grep -q developer"
cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
eq "an old events file without run.id still summarises" "$(rm -f "$R/.sdkit/work/par/run.id"; "$TL" summary par --json | jq '.agents.finished')" 40

echo "run-role.sh and the hooks"
H="$(newrepo roles 'USAGE_LOG=1' 'RUN_ROLE_HOST=claude' 'VERIFIER_HOST=codex')"; mkdir -p "$H/.sdkit/work/h1/out"
cd "$H" || exit 1; export CLAUDE_PROJECT_DIR="$H"
"$ST" h1 init medium feat >/dev/null; "$SDD" start h1 --risk medium --proposal openspec/changes/h1/proposal.md >/dev/null 2>&1
printf 'do it\n' > "$H/hand.md"
mkdir -p "$T/fx/answers" "$T/fx/usage"; echo 'built' > "$T/fx/answers/s1.txt"; echo '100 40 500 60' > "$T/fx/usage/s1"
run() { SDKIT_BENCH_SCENARIO="$T/fx" SDKIT_BENCH_STEP="$1" PATH="$KIT/bench/stub-host:$PATH" "$KIT/scripts/run-role.sh" "$2" --handoff hand.md --cwd "$H" --out "$H/o.md" >/dev/null 2>&1; }
run s1 developer
S1="$("$TL" summary h1 --json)"
eq "run-role: one agent.start and one agent.end"       "$(jq -r 'select(.type=="agent.start" or .type=="agent.end") | .type' "$(ev "$H" h1)" | sort | tr '\n' ' ')" "agent.end agent.start "
eq "run-role: span ties them"                          "$(jq -r 'select(.type|startswith("agent.")) | .span' "$(ev "$H" h1)" | sort -u | wc -l | tr -d ' ')" 1
eq "run-role: claude usage is actual, cache included"  "$(jq -r '.agents.by_role[0] | "\(.in) \(.out) \(.cache_read) \(.cache_write)"' <<< "$S1")" "100 40 500 60"
eq "run-role: the ledger got the same numbers"         "$(jq -s 'map(.in + .out) | add' "$H/.sdkit/work/h1/usage.jsonl")" 140
eq "run-role: a duration was measured"                 "$(jq -r 'select(.type=="agent.end") | .q.duration' "$(ev "$H" h1)")" actual
eq "run-role: no model configured, none invented"      "$(jq -r 'select(.type=="agent.end") | has("model")' "$(ev "$H" h1)")" false
run s2 developer                                      # claude host, no usage file: the host printed none
eq "run-role: a host that prints no usage is unavailable, not 0" "$(jq -r 'select(.type=="agent.end") | .q.tokens' "$(ev "$H" h1)" | tail -1)" unavailable
run s3 verifier                                       # VERIFIER_HOST=codex: no token output
eq "run-role: codex run is unavailable too"            "$(jq -r 'select(.type=="agent.end" and .role=="verifier") | .q.tokens + " " + .host' "$(ev "$H" h1)")" "unavailable codex"
check "summary names the unmeasured runs"              bash -c "'$TL' summary h1 | grep -q 'measured 1 of 3 runs'"
ul() { SDKIT_BENCH_SCENARIO="$T/fx" SDKIT_BENCH_STEP="$1" USAGE_LINE=1 PATH="$KIT/bench/stub-host:$PATH" "$KIT/scripts/run-role.sh" "$2" --handoff hand.md --cwd "$H" --out "$H/o2.md" 2>&1 >/dev/null | grep '^\[sdkit\]'; }
eq "run-role: USAGE_LINE=1 prints in, out and cache hit"   "$(ul s1 developer)" "[sdkit] developer done — in: 660, out: 40, cache hit: 75%"
eq "run-role: no usage data says so, no numbers"           "$(ul s2 developer)" "[sdkit] developer done — token usage not available (claude gave no data)"
mkdir -p "$T/onlyjq" && ln -sf "$(command -v jq)" "$T/onlyjq/jq"
eq "run-role: host missing is a failure"               "$(PATH="$T/onlyjq:/usr/bin:/bin" SDKIT_BENCH_STEP=s9 "$KIT/scripts/run-role.sh" developer --handoff hand.md --cwd "$H" --host gemini >/dev/null 2>&1; "$TL" summary h1 --json | jq -r '.failures.by_category["host-missing"]')" 1
# hooks
printf '%s\n' '{"type":"assistant","timestamp":"2026-10-30T10:00:00.100Z","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":1},"content":[{"type":"tool_use","id":"u1"},{"type":"tool_use","id":"u2"}]}}' \
  '{"type":"assistant","timestamp":"2026-10-30T10:00:09.900Z","message":{"id":"m2","model":"claude-x","usage":{"input_tokens":20,"output_tokens":7},"content":[{"type":"text","text":"x"}]}}' > "$T/tr.jsonl"
J="$(jq -nc --arg t "$T/tr.jsonl" '{hook_event_name:"SubagentStop",agent_type:"reviewer",agent_id:"ag7",agent_transcript_path:$t}')"
eq "usage-log hook exits 0"                            "$(printf '%s' "$J" | "$KIT/hooks/usage-log.sh" >/dev/null 2>&1; echo $?)" 0
eq "hook event: tokens summed, actual"                 "$(jq -r 'select(.span=="ag7") | "\(.in) \(.out) \(.q.tokens)"' "$(ev "$H" h1)")" "30 12 actual"
eq "hook event: tool calls counted"                    "$(jq -r 'select(.span=="ag7") | "\(.tool_calls) \(.q.tool_calls)"' "$(ev "$H" h1)")" "2 actual"
eq "hook event: duration is an estimate"               "$(jq -r 'select(.span=="ag7") | "\(.dur_ms) \(.q.duration)"' "$(ev "$H" h1)")" "9000 estimated"
printf '%s' "$J" | "$KIT/hooks/usage-log.sh" >/dev/null 2>&1
eq "the same span twice counts once"                   "$("$TL" summary h1 --json | jq '[.agents.by_role[] | select(.role=="reviewer") | .runs] | add')" 1
eq "the ledger path is unchanged (USAGE_LOG on)"       "$(jq -s '[.[] | select(.id=="ag7")] | length' "$H/.sdkit/work/h1/usage.jsonl")" 1
eq "usage-log with both settings off writes nothing"   "$(L="$(newrepo hookoff)"; sed -i.bak '/TELEMETRY/d' "$L/.sdkit/sdkit.local.env"; rm -f "$L/.sdkit/sdkit.local.env.bak"; printf '%s' "$J" | CLAUDE_PROJECT_DIR="$L" "$KIT/hooks/usage-log.sh"; ls "$L/.sdkit/work" 2>/dev/null | wc -l | tr -d ' ')" 0
JB='{"hook_event_name":"SubagentStop","agent_type":"verifier","last_assistant_message":"VERDICT: PASS"}'
printf '%s' "$JB" | "$KIT/hooks/record-verdict.sh" >/dev/null 2>&1
eq "record-verdict: a malformed verdict is a failure"  "$(jq -s '[.[] | select(.type=="failure" and .category=="verdict-malformed" and .source=="verifier")] | length' "$H/.sdkit/work/h1/events.jsonl")" 1
eq "record-verdict: and a malformed verification"      "$("$TL" summary h1 --json | jq -r '[.verification.results[].outcome] | join(",")')" malformed
eq "a hook cannot be broken by an unwritable store"    "$(chmod 555 "$H/.sdkit/work/h1"; printf '%s' "$J" | "$KIT/hooks/usage-log.sh" >/dev/null 2>&1; echo $?; chmod 755 "$H/.sdkit/work/h1")" 0

echo "benchmarks (simulated; nothing here starts a live host)"
BN="$KIT/bench/run.sh"
eq "four scenarios"                                    "$("$BN" list | wc -l | tr -d ' ')" 4
for s in low-single-file medium-multi-file high-independent-verify multi-agent-handoff; do
  "$BN" run "$s" --out "$T/b1" >/dev/null 2>&1; "$BN" run "$s" --out "$T/b2" >/dev/null 2>&1
  eq "$s: reaches done, verified"                      "$(jq -r '"\(.mode) \(.summary.status) \(.summary.verified)"' "$T/b1/$s.simulated.json" 2>/dev/null)" "simulated completed true"
  eq "$s: reproducible"                                "$(jq -S -c .deterministic "$T/b1/$s.simulated.json" 2>/dev/null | shasum | cut -c1-12)" "$(jq -S -c .deterministic "$T/b2/$s.simulated.json" 2>/dev/null | shasum | cut -c1-12)"
  check "$s: every event valid"                        bash -c "jq -e '.summary.events > 0' '$T/b1/$s.simulated.json'"
done
J1="$T/b1"
eq "low risk: one agent, no verifier"                  "$(jq -r '.summary.agents.by_role | map(.role) | join(",")' "$J1/low-single-file.simulated.json")" developer
eq "low risk: verified by the verify command"          "$(jq -r '.summary.verification.results[0].source' "$J1/low-single-file.simulated.json")" verify-cmd
eq "medium: an independent verifier PASS"              "$(jq -r '.summary.verification.final' "$J1/medium-multi-file.simulated.json")" PASS
eq "high: BLOCK, the one retry, then PASS"             "$(jq -r '"\(.summary.verification.results | map(.outcome) | join(">")) retries=\(.summary.retries)"' "$J1/high-independent-verify.simulated.json")" "BLOCK>PASS retries=1"
eq "high: the block is counted as a failure"           "$(jq -r '.summary.failures.by_category["verdict-block"]' "$J1/high-independent-verify.simulated.json")" 1
eq "multi-agent: 7 agents"                             "$(jq -r '.summary.agents.finished' "$J1/multi-agent-handoff.simulated.json")" 7
eq "multi-agent: hosts without usage are not counted"  "$(jq -r '"\(.summary.tokens.runs_measured)/\(.summary.tokens.runs_unmeasured) \(.summary.tokens.complete)"' "$J1/multi-agent-handoff.simulated.json")" "4/3 false"
eq "simulated results never claim a price"             "$(jq -r '.summary.cost.quality' "$J1/multi-agent-handoff.simulated.json")" unavailable
eq "timing is kept apart from the deterministic part"  "$(jq -r '.deterministic | has("timing") or has("wall_ms")' "$J1/low-single-file.simulated.json")" false
check "compare works on two results"                   bash -c "'$BN' compare '$T/b1/high-independent-verify.simulated.json' '$T/b2/high-independent-verify.simulated.json' | grep -q 'retries'"
eq "real mode refuses without --host"                  "$(rc "$BN" run low-single-file --real --yes)" 2
eq "real mode refuses without --yes (no tty)"          "$("$BN" run low-single-file --real --host claude </dev/null >/dev/null 2>&1; echo $?)" 2
eq "simulated mode refuses --host"                     "$(rc "$BN" run low-single-file --host claude)" 2
nocheck "no test starts a real run"                    bash -c "grep -nE 'run[^#]*--real[^#]*--yes' '$KIT/tests/'*.sh | grep -v 'nocheck\\|eq \\|refuses'"
nocheck "an unknown scenario fails"                    "$BN" run no-such-scenario

echo "telemetry: $pass passed, $fail failed"
[ "$fail" = 0 ]
