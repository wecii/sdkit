#!/usr/bin/env bash
# Budget safety (F14): strict numbers, one price resolver, reservation lifecycle (TTL, run-role exits, signals), project-wide concurrency, child-session accounting, usage reconciliation, DoD acceptance. Fake CLIs only.
# Run: tests/reservation.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
RT="$KIT/scripts/route.sh"; US="$KIT/scripts/usage.sh"; RR="$KIT/scripts/run-role.sh"
export SDKIT_ROUTE_NO_SLEEP=1
newrepo() {
  local r="$T/$1"; mkdir -p "$r/.sdkit"; ( cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
    printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\nRUN_ROLE_HOST=claude\nROUTING=on\n' > .sdkit/sdkit.env; : > .sdkit/sdkit.local.env
    printf 'work/\n.sdd/\nsdkit.local.env\n' > .sdkit/.gitignore
    echo '[{"id":"cx","adapter":"claude","model":"m-test","tier":"standard"},{"id":"cs","adapter":"claude","model":"m-test","tier":"strong"},{"id":"cl","adapter":"claude","model":"m-test","tier":"light"}]' > .sdkit/models.json
    echo '{"m-test":{"in":3,"out":15}}' > .sdkit/pricing.json
    echo a > f; git add -A; git commit -qm i ); echo "$r"; }
use() { cd "$1" || exit 1; export CLAUDE_PROJECT_DIR="$1"; R="$1"; }
cfg() { printf '%s\n' "$@" >> "$R/.sdkit/sdkit.local.env"; }
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"; export PATH="$T/bin:$PATH"

echo "strict numbers"
use "$(newrepo n)"
cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=1.2.3 ROUTE_RESERVE_USD=0.1
eq "a malformed limit is refused by decide (2), not an empty decision" "$(rc "$RT" decide --role developer --json)" 2
: > .sdkit/sdkit.local.env; cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=5
eq "hard with nothing to derive a reservation from: fails closed (2)" "$(rc "$RT" decide --role developer --json)" 2
cfg ROUTE_ROLE_TOKENS=1000000
out="$("$RT" decide --role developer --json 2>/dev/null)"; r1=$?
eq "a token cap plus a price derives a stated reservation (1M x 15)" "$(jq -r '[.budget.cost_hard.reservation_usd, (.budget.cost_hard.reservation_basis | test("derived"))] | join(",")' <<< "$out")" "15.000000,true"
eq "...which exceeds the 5 USD limit, so the run is stopped (3)" "$r1" 3

echo "one price resolver (dated model ids)"
use "$(newrepo p)"
echo '{"version":2,"models":[{"model":"claude-x-1","in":3,"out":15}]}' > .sdkit/pricing.json
cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=2 ROUTE_RESERVE_USD=0.01
"$US" log --role developer --model claude-x-1-20260115 --provider "" --in 1000000 --out 0 --id d1 --kind final --force >/dev/null 2>&1
eq "usage.sh prices the dated id (3 USD)"                 "$("$US" report --json 2>/dev/null | jq -r '.totals.cost_usd')" 3
out="$("$RT" decide --role developer --json 2>/dev/null)"; r1=$?
eq "route.sh prices the same id: same estimate, stops (3)" "$(jq -r .budget.cost_hard.task.estimated_usd <<< "$out"):$r1" "3:3"
echo "reservation lifecycle"
use "$(newrepo l)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=1 ROUTE_RESERVE_USD=0.6 ROUTE_RESERVE_TTL_S=60
"$RT" decide --role developer --json --reserve --pid 999999 >/dev/null 2>&1
RF=.sdkit/work/_misc/reservations.jsonl
# age a reservation by rewriting its time instead of waiting for the TTL
old() { jq -c --arg k "$1" 'if .type == "reserve" and ((.pid | tostring) == $k) then .ts = "2000-01-01T00:00:00Z" else . end' $RF > $RF.x && mv $RF.x $RF; }
old 999999
eq "past the TTL with its process gone it is stale"       "$("$RT" reservations --json | jq -r '.[0].state')" stale
eq "...a stale reservation no longer blocks"              "$(rc "$RT" decide --role scout --json --reserve --pid $$)" 0
old $$
eq "an old reservation whose process is alive stays active" "$("$RT" reservations --json | jq -r --argjson p $$ '[.[] | select(.pid == $p) | .state] | first')" active

echo "run-role closes the decision on every way out"
use "$(newrepo r)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=10 ROUTE_RESERVE_USD=0.5
printf 'Do a thing.\n' > h.md
held() { jq -s '([.[] | select(.type == "reserve") | .id]) - ([.[] | select(.type == "release") | .id]) | length' .sdkit/work/_misc/reservations.jsonl 2>/dev/null || echo 0; }
printf '#!/bin/sh\necho "{\\"result\\":\\"ok\\",\\"usage\\":{\\"input_tokens\\":10,\\"output_tokens\\":5}}"\n' > "$T/bin/claude"
# the fake host announces itself, so we wait for that instead of sleeping
printf '#!/bin/sh\ntouch "%s/started"\nexec sleep 30\n' "$T" > "$T/bin/claude"
"$RR" developer --handoff h.md --rerun t >/dev/null 2>&1 & rp=$!
i=0; while [ ! -f "$T/started" ] && [ "$i" -lt 100 ]; do i=$((i + 1)); perl -e 'select(undef,undef,undef,0.1)'; done
eq "while running, the reservation is held"               "$(held)" 1
kill -TERM "$rp"; wait "$rp" 2>/dev/null; st=$?
eq "SIGTERM: exit 143, released"                          "$st:$(held)" "143:0"
eq "...outcome class INTERRUPTED recorded"                "$(jq -r 'select(.type == "outcome") | .class' .sdkit/work/_misc/routing.jsonl | tail -1)" INTERRUPTED
pkill -f "sleep 30" 2>/dev/null

echo "project-wide concurrency across tasks"
SH="$T/shared"; mkdir -p "$SH/work"
for i in 1 2 3; do
  r="$(newrepo "c$i")"; rm -rf "$r/.sdkit/work"; ln -s "$SH/work" "$r/.sdkit/work"; mkdir -p "$SH/work/t$i" "$r/.sdkit/.sdd"
  echo '{"spawns":0}' > "$SH/work/t$i/state.json"; echo "{\"task\":\"t$i\"}" > "$r/.sdkit/.sdd/state.json"
  printf 'ROUTE_COST_ENFORCE=hard\nROUTE_PROJECT_BUDGET_COST=0.8\nROUTE_RESERVE_USD=0.4\n' >> "$r/.sdkit/sdkit.local.env"
done
for i in 1 2 3; do ( CLAUDE_PROJECT_DIR="$T/c$i" "$RT" decide --role developer --json --reserve --pid $$ >/dev/null 2>&1; echo $? > "$T/c$i.rc" ) & done; wait
eq "3 simultaneous tasks, 0.80 USD project limit, 0.40 each: 2 admitted, 1 stopped (3)" "$(cat "$T"/c?.rc | sort | paste -sd, -)" "0,0,3"
eq "...the ledgers hold 0.80 USD in total, never more than the limit" "$(cat "$SH"/work/*/reservations.jsonl 2>/dev/null | jq -s 'map(select(.type == "reserve") | .usd) | add')" 0.8

echo "child claude session counted once"
use "$(newrepo k)"; cfg USAGE_LOG=1; mkdir -p .sdkit/work/k1; echo '{"spawns":0}' > .sdkit/work/k1/state.json
tr1="$T/child.jsonl"; jq -nc '{type:"assistant", uuid:"u1", sessionId:"childsess", timestamp:"2026-03-01T10:00:00.000Z", message:{id:"msg_1", model:"m-test", usage:{input_tokens:100, output_tokens:50, cache_read_input_tokens:0, cache_creation_input_tokens:0}}}' > "$tr1"
stopev() { jq -nc --arg t "$tr1" '{hook_event_name:"Stop", session_id:"childsess", transcript_path:$t}' | "$KIT/hooks/usage-log.sh"; }
SDKIT_CHILD_RUN=rr-1-2 stopev
eq "the Stop of a run-role child session logs nothing a second time" "$(cat .sdkit/work/k1/usage.jsonl 2>/dev/null | wc -l | tr -d ' ')" 0
jq -nc --arg t "$tr1" --arg a "$tr1" '{hook_event_name:"SubagentStop", session_id:"childsess", transcript_path:$t, agent_transcript_path:$a, agent_type:"analyst", agent_id:"ag9"}' | SDKIT_CHILD_RUN=rr-1-2 "$KIT/hooks/usage-log.sh"
printf '#!/bin/sh\necho "$SDKIT_CHILD_RUN" > "%s/marker"\necho "{\\"result\\":\\"ok\\"}"\n' "$T" > "$T/bin/claude"
printf 'x\n' > h2.md; "$RR" scout --handoff h2.md --host claude >/dev/null 2>&1
eq "run-role sets SDKIT_CHILD_RUN for its child only"     "$(cut -c1-3 "$T/marker"):${SDKIT_CHILD_RUN:-unset}" "rr-:unset"

echo "usage reconciliation"
use "$(newrepo u)"; mkdir -p .sdkit/work/u1; echo '{"spawns":0}' > .sdkit/work/u1/state.json
echo '{"version":2,"models":[{"model":"m-a","in":3,"out":15}]}' > .sdkit/pricing.json
: > .sdkit/work/u1/usage.jsonl
"$US" log --role developer --host claude --model m-a --force --id f1 --kind snapshot --in 1000 --out 500 >/dev/null 2>&1
"$US" log --role developer --host claude --model m-a --force --id f1 --kind final --in 900 --out 600 >/dev/null 2>&1
"$US" log --role developer --host claude --model m-a --force --id f1 --kind snapshot --in 5000 --out 5000 >/dev/null 2>&1
eq "a final keeps the larger of each counter, one line; a late snapshot never displaces it" "$(jq -r 'select(.id == "f1") | "\(.kind) \(.in) \(.out)"' .sdkit/work/u1/usage.jsonl)" "final 1000 600"

echo "DoD acceptance"
use "$(newrepo a)"; DC="$KIT/scripts/dod-check.sh"; PV="$KIT/scripts/parse-verdict.sh"
mkdir -p ch; printf '## Definition of Done\n- D1: works | Verified by: unit test\n- D2: looks right | Verified by: manual check\n' > ch/proposal.md
ans() { printf 'DOD\n- D1 works | PASS | a_test.go:1\n- D2 looks right | PASS | %s\nFINDINGS\n- none\nVERIFY\n- command: v | result: green | ok\nVERDICT: PASS\n' "$1"; }
eq "an 'accepted' PASS without a record is refused (2)"   "$(ans 'accepted: Ayse' | "$PV" - --proposal ch/proposal.md >/dev/null 2>&1; echo $?)" 2
eq "the user's acceptance is recorded"                    "$(rc "$DC" accept ch/proposal.md D2 --by Ayse --reason 'checked in staging')" 0
eq "...with who, why, the item and its hash"              "$(jq -r '[.by, .reason, .id, (.item_sha256 | length)] | join("|")' ch/acceptances.jsonl)" "Ayse|checked in staging|D2|64"
eq "...and the 'accepted' PASS now counts"                "$(ans 'accepted: Ayse' | "$PV" - --proposal ch/proposal.md 2>&1 | grep -c 'accepted=1')" 1
sed -i.bak 's/looks right | Verified by/looks right and fast | Verified by/' ch/proposal.md
eq "editing the item voids the acceptance"                "$(rc "$DC" accepted ch/proposal.md D2)" 1

finish reservation
