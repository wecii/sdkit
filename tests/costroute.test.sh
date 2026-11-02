#!/usr/bin/env bash
# F14 hard cost policy of route.sh (opt-in ROUTE_COST_ENFORCE=hard): limits, unknown cost, reservations, reconciliation, mandatory roles. No model, no network.
set -u
[ -n "${PSEC_ONLY:-}" ] || exec "$(dirname "$0")/lib/psections.sh" "$0" "$@"   # the sections are independent: run them at the same time
KIT="$(cd "$(dirname "$0")/.." && pwd)"; RT="$KIT/scripts/route.sh"; US="$KIT/scripts/usage.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
export SDKIT_ROUTE_NO_SLEEP=1
newrepo() {
  local r="$T/$1"; mkdir -p "$r/.sdkit"; ( cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
    printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\nRUN_ROLE_HOST=claude\nROUTING=on\n' > .sdkit/sdkit.env; : > .sdkit/sdkit.local.env
    printf 'work/\n.sdd/\nsdkit.local.env\n' > .sdkit/.gitignore
    echo '[{"id":"cx","adapter":"claude","model":"m-test","tier":"standard"},{"id":"cs","adapter":"claude","model":"m-test","tier":"strong"},{"id":"cl","adapter":"claude","model":"m-test","tier":"light"}]' > .sdkit/models.json
    echo '{"m-test":{"in":3,"out":15}}' > .sdkit/pricing.json
    echo a > f; git add -A; git commit -qm i ) ; echo "$r"; }
use() { cd "$1" || exit 1; export CLAUDE_PROJECT_DIR="$1"; R="$1"; }
cfg() { printf '%s\n' "$@" >> "$R/.sdkit/sdkit.local.env"; }
spend() { "$US" log --role developer --model m-test --provider "" --in "$1" --out 0 --id "$2" --kind final --force ${3:+--tq "$3"} >/dev/null 2>&1; }  # $1 input tokens ($3 per M => $)
dec() { "$RT" decide --role "${ROLE:-developer}" --json --require-cli "$@" 2>&1; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"; export PATH="$T/bin:$PATH"

echo "off by default: money stays advisory"
use "$(newrepo a)"; cfg ROUTE_BUDGET_COST=0.001; spend 1000000 u1
eq "an over-limit estimate does not stop without ROUTE_COST_ENFORCE=hard" "$(rc "$RT" decide --role developer --json)" 0

echo "hard limits"
use "$(newrepo b)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_RESERVE_USD=0.01 ROUTE_BUDGET_COST=10
eq "under the limit and a known price: runs"                  "$(rc "$RT" decide --role developer --json)" 0
eq "…the decision shows the remaining USD"                    "$("$RT" decide --role developer --json 2>/dev/null | jq -r '.budget.cost_hard.task.remaining_usd')" 9.99
spend 1000000 u1   # 1M input tokens at $3 per M = $3
eq "estimated spend under the limit: runs"                    "$(rc "$RT" decide --role developer --json)" 0
cfg ROUTE_BUDGET_COST=2
eq "estimated spend over the limit: BUDGET_EXHAUSTED (3)"     "$(rc "$RT" decide --role developer --json)" 3
eq "…with the reason code"                                    "$("$RT" decide --role developer --json 2>/dev/null | jq -r .reason)" BUDGET_EXHAUSTED
eq "…--ignore-budget (user agreed) records an override"       "$("$RT" decide --role developer --json --ignore-budget 2>/dev/null | jq -r '.warnings | map(select(startswith("BUDGET_OVERRIDDEN"))) | length')" 1
eq "a mandatory role is stopped too, never skipped or passed" "$(ROLE=verifier rc "$RT" decide --role verifier --json)" 3

echo "unknown never passes"
use "$(newrepo c)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_RESERVE_USD=0.01 ROUTE_BUDGET_COST=100; spend 10 u1 unavailable
eq "an earlier unmeasured run makes the scope unknown: stop"  "$(rc "$RT" decide --role developer --json)" 3
eq "…and says unknown"                                        "$("$RT" decide --role developer --json 2>&1 | jq -r '.notes | join(" ")' | grep -c 'unknown')" 1
use "$(newrepo d)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_RESERVE_USD=0.01 ROUTE_BUDGET_COST=100; echo '{}' > .sdkit/pricing.json
eq "no price for the model: unknown, stop"                    "$(rc "$RT" decide --role developer --json)" 3
rm .sdkit/pricing.json
eq "no price table at all: unknown, stop"                     "$(rc "$RT" decide --role developer --json)" 3

echo "role and project limits"
use "$(newrepo e)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_RESERVE_USD=0.01 ROUTE_ROLE_BUDGET_COST=2; spend 1000000 u1
eq "role limit reached for developer"                         "$(rc "$RT" decide --role developer --json)" 3
eq "…another role is not affected"                            "$(rc "$RT" decide --role scout --json)" 0
use "$(newrepo f)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_RESERVE_USD=0.01 ROUTE_PROJECT_BUDGET_COST=2
mkdir -p .sdkit/work/other; "$US" log --role developer --model m-test --provider "" --in 1000000 --out 0 --id o1 --kind final --force --slug other >/dev/null 2>&1
eq "project limit counts another task's spend"                "$(rc "$RT" decide --role developer --json)" 3

echo "reservations"
use "$(newrepo g)"; cfg ROUTE_COST_ENFORCE=hard ROUTE_BUDGET_COST=1 ROUTE_RESERVE_USD=0.6
out="$("$RT" decide --role developer --json --reserve --pid $$ 2>/dev/null)"; id="$(jq -r .decision_id <<< "$out")"
eq "the first run reserves and starts"                        "$(jq -r .action <<< "$out")" execute
eq "a second run would exceed the limit: stop"                "$(rc "$RT" decide --role scout --json --reserve --pid $$)" 3
"$RT" outcome --decision "$id" --rc 0 >/dev/null 2>&1
eq "the outcome releases the reservation (reconciled)"        "$(jq -s '[.[] | select(.type == "release")] | length' .sdkit/work/_misc/reservations.jsonl)" 1
eq "…so the next run can start"                               "$(rc "$RT" decide --role scout --json --reserve --pid $$)" 0

echo "configuration"
use "$(newrepo h)"; cfg ROUTE_COST_ENFORCE=hard
eq "hard without any limit is a configuration error (2)"      "$(rc "$RT" validate)" 2
cfg ROUTE_BUDGET_COST=5; eq "…valid with a limit"             "$(rc "$RT" validate)" 0
cfg ROUTE_COST_ENFORCE=sometimes; eq "a bad value is rejected" "$(rc "$RT" validate)" 2

echo "costroute: $pass passed, $failed failed"; [ "$failed" = 0 ]
