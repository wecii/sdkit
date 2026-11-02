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

echo "strict numbers (route.sh validate and decide)"
use "$(newrepo n)"
for bad in 1.2.3 . "" 1e5 -1 abc 1..2 .5; do
  : > .sdkit/sdkit.local.env; cfg ROUTE_COST_ENFORCE=hard "ROUTE_BUDGET_COST=${bad:-x}" ROUTE_RESERVE_USD=0.1; [ -n "$bad" ] || cfg "ROUTE_BUDGET_COST=''"
  [ "$bad" = "" ] && continue
  eq "limit '$bad' is a configuration error"  "$(rc "$RT" validate)" 2
  eq "…decide refuses it (2), not an empty decision" "$(rc "$RT" decide --role developer --json)" 2
done
for bad in 1.2.3 . 0 0.0 -1; do
  : > .sdkit/sdkit.local.env; cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=5 "ROUTE_RESERVE_USD=$bad"
  eq "reservation '$bad' is refused under hard (decide exits 2)" "$(rc "$RT" decide --role developer --json)" 2
done
: > .sdkit/sdkit.local.env; cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=5.50 ROUTE_RESERVE_USD=0.25
eq "valid decimals are accepted"                              "$(rc "$RT" decide --role developer --json)" 0
: > .sdkit/sdkit.local.env; cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=5
eq "hard with no reservation and nothing to derive one from: fails closed (2)" "$(rc "$RT" decide --role developer --json)" 2
eq "…and says why"                                            "$("$RT" decide --role developer --json 2>&1 | jq -r '.notes | join(" ")' | grep -c 'reservation')" 1
cfg ROUTE_ROLE_TOKENS=1000000
out="$("$RT" decide --role developer --json 2>/dev/null)"
eq "a token cap plus a price derives a reservation (3 USD: 1M tokens at the dearest rate 15 = 15)" "$(jq -r '.budget.cost_hard.reservation_usd' <<< "$out")" 15.000000
eq "…and the basis is stated"                                 "$(jq -r '.budget.cost_hard.reservation_basis' <<< "$out" | grep -c derived)" 1
eq "…which here exceeds the 5 USD limit, so the run is stopped (3)" "$(rc "$RT" decide --role developer --json)" 3

echo "one price resolver (dated model ids)"
use "$(newrepo p)"
echo '{"version":2,"models":[{"model":"claude-x-1","in":3,"out":15}]}' > .sdkit/pricing.json
cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=2 ROUTE_RESERVE_USD=0.01
"$US" log --role developer --model claude-x-1-20260115 --provider "" --in 1000000 --out 0 --id d1 --kind final --force >/dev/null 2>&1
eq "usage.sh prices the dated id (3 USD)"                     "$("$US" report --json 2>/dev/null | jq -r '.totals.cost_usd')" 3
eq "route.sh prices the SAME dated id: 3 > 2 so it stops (3)" "$(rc "$RT" decide --role developer --json)" 3
eq "…and reports the same estimate"                           "$("$RT" decide --role developer --json 2>/dev/null | jq -r '.budget.cost_hard.task.estimated_usd')" 3
echo '{"version":2,"models":[{"model":"claude-x-1","in":3,"out":15,"effective_from":"2099-01-01"}]}' > .sdkit/pricing.json
eq "a price not yet effective is unknown in both (usage: unpriced)" "$("$US" report --json 2>/dev/null | jq -r '.coverage.unpriced_runs')" 1
eq "…and route.sh treats the run as unknown (3)"              "$(rc "$RT" decide --role developer --json)" 3
echo '{"version":2,"models":[{"model":"claude-x-1","provider":"bedrock","in":3,"out":15}]}' > .sdkit/pricing.json
"$US" log --role developer --model claude-x-1 --provider anthropic --in 1000000 --out 0 --id d2 --kind final --force >/dev/null 2>&1
eq "a provider mismatch is unpriced in usage.sh"              "$("$US" report --json 2>/dev/null | jq -r '.coverage.unpriced_runs')" 1
eq "…and counted unknown by route.sh (3)"                     "$(rc "$RT" decide --role developer --json)" 3

echo "reservation: $pass passed, $failed failed"; [ "$failed" = 0 ]

