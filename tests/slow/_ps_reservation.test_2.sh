#!/usr/bin/env bash
# Budget safety (F14 stabilization): strict numbers, hard reservations, one price resolver, reservation lifecycle (run-role exits, signals, expiry,
# recovery), project-wide concurrency, child-session accounting, usage reconciliation, DoD acceptance. Fake CLIs and fixtures only: no model, no network.
set -u
[ -n "${PSEC_ONLY:-}" ] || exec "$(dirname "$0")/../lib/psections.sh" "$0" "$@"   # the sections are independent: run them at the same time
KIT="$(cd "$(dirname "$0")/../.." && pwd)"; RT="$KIT/scripts/route.sh"; US="$KIT/scripts/usage.sh"; RR="$KIT/scripts/run-role.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
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
rc() { "$@" >/dev/null 2>&1; echo $?; }
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"; export PATH="$T/bin:$PATH"

echo "reservation lifecycle"
use "$(newrepo l)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=1 ROUTE_RESERVE_USD=0.6 ROUTE_RESERVE_TTL_S=60
out="$("$RT" decide --role developer --json --reserve --pid 999999 2>/dev/null)"; id="$(jq -r .decision_id <<< "$out")"
RF=.sdkit/work/_misc/reservations.jsonl
# age a reservation by rewriting its time instead of waiting for the TTL (a sleep made the test slow and, once decide took over a second, wrong)
old() { jq -c --arg k "$1" 'if .type == "reserve" and ((.pid | tostring) == $k) then .ts = "2000-01-01T00:00:00Z" else . end' $RF > $RF.x && mv $RF.x $RF; }
eq "the run reserves"                                         "$(jq -s '[.[] | select(.type == "reserve")] | length' $RF)" 1
eq "a fresh reservation of a dead pid still counts (not yet old)" "$(rc "$RT" decide --role scout --json --reserve --pid $$)" 3
old 999999
eq "past the TTL with its process gone it is stale"           "$("$RT" reservations --json | jq -r '.[0].state')" stale
eq "…a stale reservation no longer blocks"                    "$(rc "$RT" decide --role scout --json --reserve --pid $$)" 0
old $$
eq "an OLD reservation whose process is alive stays active (premature expiry protected)" "$("$RT" reservations --json | jq -r --argjson p $$ '[.[] | select(.pid == $p) | .state] | first')" active
eq "recover scan lists only the stale one"                    "$("$KIT/scripts/recover.sh" scan --json 2>/dev/null | jq -r '[.[] | select(.kind == "reservation")] | length')" 1
"$KIT/scripts/recover.sh" apply >/dev/null 2>&1
eq "recover apply released it as EXPIRED"                     "$(jq -s '[.[] | select(.type == "release" and .class == "EXPIRED")] | length' $RF)" 1
"$KIT/scripts/recover.sh" apply >/dev/null 2>&1
eq "a second apply changes nothing (idempotent)"              "$(jq -s '[.[] | select(.type == "release" and .class == "EXPIRED")] | length' $RF)" 1
"$RT" outcome --decision "$id" --rc 0 >/dev/null 2>&1; "$RT" outcome --decision "$id" --rc 0 >/dev/null 2>&1 || true
eq "a late outcome of the expired run adds no second release" "$(jq -s --arg i "$id" '[.[] | select(.type == "release" and .id == $i)] | length' $RF)" 1
eq "…and the pool is not double-credited (only the live one is held)" "$("$RT" reservations --json | jq -r 'map(select(.state == "active") | .usd) | add')" 0.6

echo "run-role closes the decision on every way out"
use "$(newrepo r)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=10 ROUTE_RESERVE_USD=0.5
printf 'Do a thing.\n' > h.md
held() { jq -s '([.[] | select(.type == "reserve") | .id]) - ([.[] | select(.type == "release") | .id]) | length' .sdkit/work/_misc/reservations.jsonl 2>/dev/null || echo 0; }
printf '#!/bin/sh\necho "{\\"result\\":\\"ok\\",\\"usage\\":{\\"input_tokens\\":10,\\"output_tokens\\":5}}"\n' > "$T/bin/claude"
"$RR" developer --handoff h.md --rerun t >/dev/null 2>&1; eq "success: exit 0"          "$?" 0
eq "…reservation released"                                    "$(held)" 0
printf '#!/bin/sh\necho boom >&2\nexit 9\n' > "$T/bin/claude"
"$RR" developer --handoff h.md --rerun t >/dev/null 2>&1; eq "failure: the host status is preserved (9)" "$?" 9
eq "…reservation released"                                    "$(held)" 0
printf '#!/bin/sh\nsleep 30\n' > "$T/bin/claude"
"$RR" developer --handoff h.md --rerun t >/dev/null 2>&1 & rp=$!; sleep 3
eq "while running, the reservation is held"                   "$(held)" 1
kill -TERM "$rp"; wait "$rp" 2>/dev/null; st=$?
eq "SIGTERM: exit 143"                                        "$st" 143
eq "…reservation released"                                    "$(held)" 0
eq "…outcome class INTERRUPTED recorded"                      "$(jq -r 'select(.type == "outcome") | .class' .sdkit/work/_misc/routing.jsonl | tail -1)" INTERRUPTED
python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' "$RR" developer --handoff h.md --rerun t >/dev/null 2>&1 & rp=$!; sleep 3; kill -INT "$rp"; wait "$rp" 2>/dev/null; st=$?
eq "SIGINT: exit 130, released"                               "$st:$(held)" "130:0"
# a workflow requirement that refuses the run after the reservation (high-assurance profile, uncontracted handoff)
mkdir -p .sdkit/.sdd; echo '{"task":"wf","phase":"implement","profile":"high-assurance"}' > .sdkit/.sdd/state.json; mkdir -p .sdkit/work/wf; echo '{"spawns":0}' > .sdkit/work/wf/state.json
"$RR" developer --handoff h.md --rerun t >/dev/null 2>&1; wst=$?
ws="$(jq -s '([.[] | select(.type == "reserve") | .id]) - ([.[] | select(.type == "release") | .id]) | length' .sdkit/work/wf/reservations.jsonl 2>/dev/null || echo 0)"
eq "a workflow refusal (exit 2) leaves no reservation open"   "$wst:$ws" "2:0"

echo "project-wide concurrency across tasks"
SH="$T/shared"; mkdir -p "$SH/work"; : > "$SH/dummy"
echo '{"m-test":{"in":3,"out":15}}' > "$SH/pricing.json"
for i in 1 2 3 4 5 6 7 8; do
  r="$(newrepo "c$i")"; rm -rf "$r/.sdkit/work"; ln -s "$SH/work" "$r/.sdkit/work"; mkdir -p "$SH/work/t$i" "$r/.sdkit/.sdd"
  echo "{\"spawns\":0}" > "$SH/work/t$i/state.json"; echo "{\"task\":\"t$i\"}" > "$r/.sdkit/.sdd/state.json"
  printf 'ROUTE_COST_ENFORCE=hard\nROUTE_PROJECT_BUDGET_COST=1.0\nROUTE_RESERVE_USD=0.4\n' >> "$r/.sdkit/sdkit.local.env"
done
for i in 1 2 3 4 5 6 7 8; do ( CLAUDE_PROJECT_DIR="$T/c$i" "$RT" decide --role developer --json --reserve --pid $$ >"$T/c$i.out" 2>&1; echo $? > "$T/c$i.rc" ) & done; wait
okc=0; for i in 1 2 3 4 5 6 7 8; do [ "$(cat "$T/c$i.rc")" = 0 ] && okc=$((okc + 1)); done
eq "8 simultaneous tasks, 1.00 USD project limit, 0.40 each: exactly 2 are admitted" "$okc" 2
eq "…the ledgers hold 0.80 USD in total, never more than the limit" "$(cat "$SH"/work/*/reservations.jsonl 2>/dev/null | jq -s 'map(select(.type == "reserve") | .usd) | add')" 0.8
eq "…the others were stopped as BUDGET_EXHAUSTED (3)"          "$(for i in 1 2 3 4 5 6 7 8; do cat "$T/c$i.rc"; done | grep -c '^3$')" 6

echo "usage reconciliation"
use "$(newrepo u)"; mkdir -p .sdkit/work/u1; echo '{"spawns":0}' > .sdkit/work/u1/state.json
echo '{"version":2,"models":[{"model":"m-a","in":3,"out":15}]}' > .sdkit/pricing.json
"$US" log --role developer --host claude --model "" --force --id e1 --kind final --tq unavailable --status interrupted >/dev/null 2>&1
"$US" log --role developer --host claude --model m-a --force --id e1 --kind final --in 1000 --out 100 >/dev/null 2>&1
eq "a measured line replaces the empty-model unmeasured placeholder (ledger)" "$(jq -s 'map(select(.id == "e1")) | length' .sdkit/work/u1/usage.jsonl)" 1
printf '%s\n' '{"v":2,"ts":"2026-03-01T10:00:00Z","role":"developer","model":"","id":"e2","kind":"final","tq":"unavailable","in":0,"out":0,"cache_read":0,"cache_write":0}' '{"v":2,"ts":"2026-03-01T10:00:01Z","role":"developer","model":"m-a","id":"e2","kind":"final","in":50,"out":5,"cache_read":0,"cache_write":0}' > .sdkit/work/u1/usage.jsonl
eq "…and the report drops a placeholder already in an older ledger" "$("$US" report --json | jq -r '[.totals.runs, .totals.unmeasured] | join(",")')" "1,0"
: > .sdkit/work/u1/usage.jsonl
"$US" log --role developer --host claude --model m-a --force --id f1 --kind snapshot --in 1000 --out 500 >/dev/null 2>&1
"$US" log --role developer --host claude --model m-a --force --id f1 --kind final --in 900 --out 600 >/dev/null 2>&1
eq "a final with smaller counters is promoted keeping the larger of each (in 1000, out 600)" "$(jq -r 'select(.id == "f1") | "\(.kind) \(.in) \(.out)"' .sdkit/work/u1/usage.jsonl)" "final 1000 600"
eq "…one line, so the report and the budget read the same"      "$(jq -s 'map(select(.id == "f1")) | length' .sdkit/work/u1/usage.jsonl)" 1
"$US" log --role developer --host claude --model m-a --force --id f1 --kind snapshot --in 5000 --out 5000 >/dev/null 2>&1
eq "a late snapshot never displaces the final"                  "$(jq -r 'select(.id == "f1") | "\(.kind) \(.in)"' .sdkit/work/u1/usage.jsonl)" "final 1000"
printf '%s\n' '{"v":2,"ts":"2026-03-01T10:00:00Z","role":"developer","model":"m-a","id":"g1","kind":"snapshot","in":1000,"out":500,"cache_read":0,"cache_write":0}' '{"v":2,"ts":"2026-03-01T10:00:01Z","role":"developer","model":"m-a","id":"g1","kind":"final","in":900,"out":600,"cache_read":0,"cache_write":0}' > .sdkit/work/u1/usage.jsonl
eq "the report reconciles a snapshot+final pair the same way"   "$("$US" report --json | jq -r '[.totals.in, .totals.out] | join(",")')" "1000,600"

echo "DoD acceptance (explicit, auditable)"
use "$(newrepo a)"; DC="$KIT/scripts/dod-check.sh"; PV="$KIT/scripts/parse-verdict.sh"
mkdir -p ch; printf '## Definition of Done\n- D1: works | Verified by: unit test\n- D2: looks right | Verified by: manual check\n' > ch/proposal.md
ans() { printf 'DOD\n- D1 works | PASS | a_test.go:1\n- D2 looks right | PASS | %s\nFINDINGS\n- none\nVERIFY\n- command: v | result: green | ok\nVERDICT: PASS\n' "$1"; }
eq "a manual item with no acceptance is not accepted"           "$(rc "$DC" accepted ch/proposal.md D2)" 1
eq "an 'accepted' PASS without a record is refused (2)"         "$(ans 'accepted: Ayse' | "$PV" - --proposal ch/proposal.md >/dev/null 2>&1; echo $?)" 2
eq "accept needs --by and --reason"                             "$(rc "$DC" accept ch/proposal.md D2 --by x)" 2
eq "an automated item cannot be accepted"                       "$(rc "$DC" accept ch/proposal.md D1 --by x --reason y)" 1
eq "the user's acceptance is recorded"                          "$(rc "$DC" accept ch/proposal.md D2 --by Ayse --reason 'checked in staging')" 0
eq "…the record names who, why, the item and its hash"          "$(jq -r '[.by, .reason, .id, (.item_sha256 | length)] | join("|")' ch/acceptances.jsonl)" "Ayse|checked in staging|D2|64"
eq "…and the 'accepted' PASS now counts"                        "$(ans 'accepted: Ayse' | "$PV" - --proposal ch/proposal.md 2>&1 | grep -c 'accepted=1')" 1
eq "…but 'manual' alone is still not evidence"                  "$(ans manual | "$PV" - --proposal ch/proposal.md >/dev/null 2>&1; echo $?)" 2
eq "…and without --proposal an acceptance cannot be checked"    "$(ans 'accepted: Ayse' | "$PV" - >/dev/null 2>&1; echo $?)" 2
sed -i.bak 's/looks right | Verified by: manual check/looks right and fast | Verified by: manual check/' ch/proposal.md
eq "editing the item voids the acceptance"                      "$(rc "$DC" accepted ch/proposal.md D2)" 1

echo "reservation: $pass passed, $failed failed"; [ "$failed" = 0 ]

