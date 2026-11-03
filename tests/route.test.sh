#!/usr/bin/env bash
# Deterministic orchestration (scripts/route.sh) and its consumer run-role.sh: configuration, routing by risk/role, overrides and floors, evidence reuse and standing BLOCKs, duplicates, retry/escalation by failure class, budgets, routing off. Fake CLI only.
# Run: tests/route.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
RT="$KIT/scripts/route.sh"; SDD="$KIT/scripts/sdd.sh"; RR="$KIT/scripts/run-role.sh"; US="$KIT/scripts/usage.sh"
export SDKIT_GREEN="$T/green" VERIFY_BASE=main SDKIT_ROUTE_NO_SLEEP=1
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }
# newrepo <name> [sdkit.env line]...: routing on, a proposal, on branch feat
newrepo() {
  local r="$T/$1"; shift; mkdir -p "$r/.sdkit" "$r/src" "$r/openspec/changes/t1"
  ( cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
    printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\nRUN_ROLE_HOST=claude\nROUTING=on\nTELEMETRY=1\n' > .sdkit/sdkit.env
    for l in "$@"; do printf '%s\n' "$l" >> .sdkit/sdkit.env; done
    : > .sdkit/sdkit.local.env; printf 'work/\n.sdd/\n.verify-cache/\nsdkit.local.env\n' > .sdkit/.gitignore
    echo a > src/a.sh; printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > openspec/changes/t1/proposal.md
    printf '# D\n## Race scenario\ntwo writers\n' > openspec/changes/t1/design.md
    git add -A && git commit -qm init && git checkout -qb feat ); echo "$r"; }
use() { cd "$1" || exit 1; export CLAUDE_PROJECT_DIR="$1"; R="$1"; ST="$1/.sdkit/.sdd/state.json"; LED="$1/.sdkit/work/_misc/routing.jsonl"; }
local_env() { printf '%s\n' "$@" >> "$R/.sdkit/sdkit.local.env"; }
green() { "$KIT/scripts/state.sh" t1 init "$1" feat >/dev/null; "$SDD" start t1 --risk "$1" --proposal openspec/changes/t1/proposal.md >/dev/null && "$SDD" advance proposed >/dev/null \
    && sdd_red >/dev/null && echo "x$RANDOM" >> src/a.sh && sdd_green >/dev/null; }
j() { local f="$1"; shift; "$@" 2>/dev/null | jq -r "$f"; }
dec() { "$RT" decide --json "$@"; }
# fake host CLI: prints FAKE_ANSWER as the result; FAKE_RC/FAKE_ERR make it fail; FAKE_NOUSAGE drops usage; every call is counted
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'X'
#!/usr/bin/env bash
echo x >> "${FAKE_CALLS:-/dev/null}"
[ "${FAKE_RC:-0}" = 0 ] || { echo "${FAKE_ERR:-boom}" >&2; exit "$FAKE_RC"; }
if [ -n "${FAKE_NOUSAGE:-}" ]; then jq -n --arg r "$(cat "$FAKE_ANSWER")" '{result:$r}'; else jq -n --arg r "$(cat "$FAKE_ANSWER")" '{result:$r, usage:{input_tokens:100,output_tokens:50}}'; fi
X
chmod +x "$T/bin/claude"; export PATH="$T/bin:$PATH"
printf 'DOD\n- D1 a | PASS | t:1\nFINDINGS\n- none\nVERIFY\n- command: v | result: green | ok\nVERDICT: PASS\n' > "$T/ver-pass"
printf -- '- HIGH | src/a.sh:1 | IDOR | GET /x?id=2 | reads another user | check ownership\nSUMMARY: 0 critical, 1 high, 0 medium, 0 low\nVERDICT: BLOCK\n' > "$T/aud-block"
printf 'NO FINDINGS\n- checked authz\nSUMMARY: 0 critical, 0 high, 0 medium, 0 low\nVERDICT: PASS\n' > "$T/aud-pass"
printf 'do the thing\n' > "$T/handoff"; printf 'do another thing\n' > "$T/handoff2"
export FAKE_CALLS="$T/calls"; calls() { [ -f "$FAKE_CALLS" ] && wc -l < "$FAKE_CALLS" | tr -d ' ' || echo 0; }

echo "configuration, registry, routing by risk and role (no open task)"
use "$(newrepo rt)"
check "default configuration validates"                   "$RT" validate
printf 'ROUTE_POLICY=sideways\n' >> .sdkit/sdkit.env; eq "a bad setting fails validation (2)" "$(rc "$RT" validate)" 2
sed -i.bak '$d' .sdkit/sdkit.env
eq "developer: the role's own tier, whatever the risk"    "$(j '.tier' dec --role developer --risk high)" standard
eq "verifier at high risk: strong model, risk floor"      "$(j '[.tier, .model, .reason] | join(",")' dec --role verifier --risk high)" "strong,opus,RISK_FLOOR_APPLIED"
eq "unknown role is refused (2) with a reason"            "$(j .reason dec --role nosuchrole --risk low):$(rc "$RT" decide --role nosuchrole --risk low)" "UNKNOWN_ROLE:2"
eq "--model in the registry is applied"                   "$(j '[.model, .reason] | join(",")' dec --role developer --risk low --model opus)" "opus,OVERRIDE_APPLIED"
eq "--model below a gate role's floor is refused (2)"     "$(j .reason dec --role verifier --risk low --model haiku):$(rc "$RT" decide --role verifier --risk low --model haiku)" "OVERRIDE_BELOW_FLOOR:2"
printf '[{"id":"claude:strong","adapter":"claude","model":"opus","tier":"strong","status":"disabled"}]' > .sdkit/models.json
eq "no compatible model: refused, a lower tier is never substituted" "$(j '[.reason, (.model // "")] | join(",")' dec --role verifier --risk high)" "NO_COMPATIBLE_MODEL,"
rm .sdkit/models.json
sed -i.bak -E '/RUN_ROLE_HOST|FALLBACK/d' .sdkit/sdkit.env
eq "NO_ADAPTER when nothing names a host (refused, not guessed)" "$(j .reason dec --role developer --risk low):$(rc "$RT" decide --role developer --risk low)" "NO_ADAPTER:2"

echo "retry and escalation by failure class (no open task)"
use "$(newrepo rty)"
ask() { local o; o="$(dec --role "${1:-developer}" --risk medium --handoff "$T/handoff" --reserve --pid $$)"; jq -r .decision_id <<< "$o" > "$T/lastid"; echo "$o"; }
fail_with() { printf '%s' "$2" > "$T/err.txt"; "$RT" outcome --decision "$(cat "$T/lastid")" --rc "$1" --stderr "$T/err.txt" ${3:+--prc "$3"} >/dev/null; }
resetled() { rm -rf "$R/.sdkit/work"; rm -f "$T/lastid"; }
ask >/dev/null; fail_with 1 "503 Service Unavailable"
eq "transient: retry on the same model, reason says why"  "$(ask | jq -r '[.action, .reason, .model, .attempt] | join(",")')" "retry,RETRY_TRANSIENT,sonnet,2"
fail_with 1 "502 bad gateway"; ask >/dev/null; fail_with 1 "network down"
eq "retries are bounded (ROUTE_MAX_RETRIES)"              "$(ask | jq -r '[.action, .reason] | join(",")')" "stop,RETRIES_EXHAUSTED"
resetled; ask >/dev/null; fail_with 6 "no verdict"; ask >/dev/null; fail_with 6 ""
eq "malformed output: one retry, then escalation to the next tier" "$(ask | jq -r '[.action, .reason, .model] | join(",")')" "escalate,ESCALATE_INVALID_OUTPUT,opus"
resetled; ask security-auditor >/dev/null; fail_with 0 "" 1
eq "a security BLOCK outcome stops, also on another provider" "$(ask security-auditor | jq -r .reason):$(dec --role security-auditor --risk medium --handoff "$T/handoff" --host codex | jq -r .reason)" "SECURITY_BLOCK:SECURITY_BLOCK"

echo "scheduling on a high-risk task: gates, reuse, stale, standing BLOCK, duplicates"
use "$(newrepo hi USAGE_LOG=1)"; LED="$R/.sdkit/work/t1/routing.jsonl"; green high || bad "could not open a high-risk task"
eq "high risk: verifier, reviewer, security-auditor are mandatory; developer is not" "$(for r in verifier reviewer security-auditor developer; do j '.mandatory' dec --role $r; done | paste -sd, -)" "true,true,true,false"
rr() { local role="$1" ans="$2"; shift 2; FAKE_ANSWER="$ans" "$RR" "$role" --handoff "$T/handoff" --cwd "$R" "$@"; }
rr verifier "$T/ver-pass" >/dev/null 2>"$T/err"; st=$?
eq "run-role executes the decision and records trusted evidence" "$st:$(jq -r '.evidence.verifier | [.result, .trust] | join(",")' "$ST")" "0:PASS,spawned"
check "...announcing the strong model chosen by the decision" grep -q 'routing: execute claude/opus tier=strong' "$T/err"
eq "...an outcome with measured tokens is in the ledger"  "$(jq -rs '[.[] | select(.type=="outcome")] | last | [.class, .tokens_quality, .tokens.in] | join(",")' "$R/.sdkit/work/t1/routing.jsonl")" "OK,actual,100"
rr verifier "$T/ver-pass" >/dev/null 2>"$T/err"; st=$?
eq "valid evidence for this diff is reused: exit 7, not a failure, no second call" "$st:$(calls):$(grep -c 'NOT A FAILURE' "$T/err")" "7:1:1"
eq "decide agrees: reuse, EVIDENCE_REUSED, exit 7"        "$(j '[.action, .reason] | join(",")' dec --role verifier --handoff "$T/handoff"):$(rc "$RT" decide --role verifier --handoff "$T/handoff")" "reuse,EVIDENCE_REUSED:7"
rr verifier "$T/ver-pass" --rerun "second look" >/dev/null 2>&1
eq "an explicit --rerun reason runs it again and is recorded" "$(calls):$(jq -rs '[.[] | select(.type=="decision" and .action=="execute")] | last | .reason' "$R/.sdkit/work/t1/routing.jsonl")" "2:RERUN_REQUESTED"
echo "edit$RANDOM" >> src/a.sh
eq "a changed diff makes the evidence stale: execute"     "$(j '.action' dec --role verifier --handoff "$T/handoff"):$("$SDD" evidence --json | jq -r '.[] | select(.role=="verifier") | .state')" "execute:stale"
rr security-auditor "$T/aud-block" >/dev/null 2>&1; st=$?
n0="$(calls)"; rr security-auditor "$T/aud-pass" >/dev/null 2>"$T/err"; st2=$?
eq "a security BLOCK is evidence (exit 0); run-role then refuses to turn it into a PASS (8)" "$st:$st2:$(calls)" "0:8:$n0"
echo "edit$RANDOM" >> src/a.sh
eq "after the diff changes the BLOCK no longer stands"    "$(j '.action' dec --role security-auditor --handoff "$T/handoff")" execute
# duplicates: a live pid keeps a request in flight; a dead one is closed as interrupted and retried
o1="$(dec --role developer --handoff "$T/handoff" --reserve --pid $$)"; o2="$(dec --role developer --handoff "$T/handoff" --reserve --pid $$)"
eq "an identical in-flight request is a duplicate" "$(jq -r .action <<< "$o1"):$(jq -r .reason <<< "$o2")" "execute:DUPLICATE_IN_FLIGHT"
"$RT" outcome --decision "$(jq -r .decision_id <<< "$o1")" --rc 0 >/dev/null
eq "a completed identical request is a duplicate (8) unless a reason to rerun is given" "$(j .reason dec --role developer --handoff "$T/handoff"):$(rc "$RT" decide --role developer --handoff "$T/handoff"):$(j .reason dec --role developer --handoff "$T/handoff" --rerun why)" "DUPLICATE_COMPLETED:8:RERUN_REQUESTED"

echo "budgets (same task)"
"$US" log --role developer --model sonnet --in 10000 --out 1000 --slug t1 --force --tq actual >/dev/null
local_env TOKEN_BUDGET_TASK=10000
n0="$(calls)"; FAKE_ANSWER="$T/ver-pass" "$RR" verifier --handoff "$T/handoff2" --cwd "$R" >/dev/null 2>"$T/err"; st=$?
eq "over a hard token budget a mandatory role is stopped (3), nothing started, recovery printed" "$st:$(calls):$(grep -q ignore-budget "$T/err" && echo 1)" "3:$n0:1"
: > .sdkit/sdkit.local.env; local_env TOKEN_BUDGET_TASK=15000 TOKEN_BUDGET_WARN_PCT=70
rm -f .sdkit/work/t1/usage.jsonl; "$US" log --role developer --model sonnet --in 0 --out 0 --slug t1 --force --tq unavailable >/dev/null
eq "unreported usage is null, not 0: advisory, never exhausts" "$(j '[.budget.task_tokens.used, .budget.accounting, .budget.task_tokens.enforcement, .action] | map(tostring) | join(",")' dec --role developer)" "null,unavailable,advisory,execute"
: > .sdkit/sdkit.local.env; rm -f .sdkit/work/t1/usage.jsonl

echo "run-role integration and failure classification"
printf 'third\n' > "$T/handoff3"
FAKE_RC=1 FAKE_ERR="503 Service Unavailable" rr developer "$T/ver-pass" --handoff "$T/handoff3" --rerun x >/dev/null 2>&1; st=$?
cls="$(jq -rs '[.[] | select(.type=="outcome")] | .[-1].class' "$LED")"
FAKE_ANSWER="$T/ver-pass" "$RR" developer --handoff "$T/handoff3" --cwd "$R" >/dev/null 2>"$T/err"
eq "host failure: its status is returned and classified; the next request is a retry" "$st:$cls:$(grep -c 'routing: retry' "$T/err")" "1:TRANSIENT:1"
FAKE_ANSWER="$T/ver-pass" "$RR" developer --handoff "$T/handoff2" --cwd "$R" --model nonexistent >/dev/null 2>"$T/err"; st=$?
eq "run-role: an invalid --model is refused (2) with the reason" "$st:$(grep -c OVERRIDE_INVALID "$T/err")" "2:1"
hook() { jq -nc --arg r "$1" --arg m "$2" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{subagent_type:$r,prompt:"x",model:$m}}' | "$KIT/hooks/guard-budget.sh" | { o="$(cat)"; [ -z "$o" ] && echo allow || jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "$o"; }; }
eq "hook: a model below the role's floor makes it ask; one that meets it passes" "$(hook verifier haiku):$(hook verifier opus)" "ask:allow"

echo "routing off (the default for old projects) changes nothing"
sed -i.bak 's/^ROUTING=on/ROUTING=off/' .sdkit/sdkit.env
rm -f .sdkit/work/t1/routing.jsonl
FAKE_ANSWER="$T/ver-pass" "$RR" developer --handoff "$T/handoff" --cwd "$R" >/dev/null 2>&1
eq "off: run-role makes no routing record; explain says the decision is ignored" "$(ls .sdkit/work/t1/routing.jsonl 2>/dev/null | wc -l | tr -d ' '):$("$RT" explain --role developer --risk low | grep -c 'ignores this decision')" "0:1"
sed -i.bak 's/^ROUTING=.*/ROUTING=ON/' .sdkit/sdkit.env
eq "a misspelt ROUTING value refuses to run (fails closed)" "$(rc "$RR" developer --handoff "$T/handoff" --cwd "$R" --host claude --dry-run)" 2
cd "$KIT"
finish route
