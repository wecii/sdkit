#!/usr/bin/env bash
# Price table tests: scripts/pricing.sh (refresh from the AWS Bedrock list, status), the shipped templates/pricing.json, init and doctor.
# Deterministic: a small AWS-shaped fixture served as a file:// URL, no network. Run: tests/pricing.test.sh
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"; PS="$KIT/scripts/pricing.sh"; US="$KIT/scripts/usage.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
export PATH="$KIT/tests/stubs:$PATH"
# fixture: model "Claude Test 1" with global input/output/cache prices, plus batch and 1h cache entries that must be ignored; a regional-only model
prod() { jq -nc --arg sku "$1" --arg m "$2" --arg ut "$3" '{($sku): {sku:$sku, attributes:{provider:"Anthropic", model:$m, regionCode:"us-east-1", usagetype:$ut}}}'; }
term() { jq -nc --arg sku "$1" --arg p "$2" --arg u "${3:-1M tokens}" '{($sku): {"x": {priceDimensions: {"d": {unit:$u, pricePerUnit:{USD:$p}}}}}}'; }
P="$(for r in "a|Claude Test 1|USE1-MP:USE1_input_tokens_global_standard-Units|2.0" "b|Claude Test 1|USE1-MP:USE1_output_tokens_global_standard-Units|10.0" \
  "c|Claude Test 1|USE1-MP:USE1_cache_read_tokens_global_standard-Units|0.1" "d|Claude Test 1|USE1-MP:USE1_cache_write_tokens_global_standard-Units|2.5" \
  "e|Claude Test 1|USE1-MP:USE1_input_tokens_global_batch-Units|1.0" "f|Claude Test 1|USE1-MP:USE1_cache_write_tokens_1h_global_standard-Units|4.0" \
  "g|Claude Test 1|USE1-MP:USE1_input_tokens_standard-Units|2.2" "h|Claude Old 2|USE1-MP:USE1_InputTokenCount-Units|0.003" "i|Claude Old 2|USE1-MP:USE1_OutputTokenCount-Units|0.015"; do IFS='|' read -r k m u pr <<< "$r"; prod "$k" "$m" "$u"; done | jq -sc add)"
Tm="$(for r in "a|2.0" "b|10.0" "c|0.1" "d|2.5" "e|1.0" "f|4.0" "g|2.2"; do IFS='|' read -r k pr <<< "$r"; term "$k" "$pr"; done | jq -sc add)"
jq -nc --argjson p "$P" --argjson t "$Tm" '{formatVersion:"v1.0", publicationDate:"2026-10-30T00:00:00Z", products:$p, terms:{OnDemand:$t}}' > "$T/aws.json"
mkdir -p "$T/old"; jq -c '.terms.OnDemand += {h:{"x":{priceDimensions:{"d":{unit:"1K tokens",pricePerUnit:{USD:"0.003"}}}}}, i:{"x":{priceDimensions:{"d":{unit:"1K tokens",pricePerUnit:{USD:"0.015"}}}}}}' "$T/aws.json" > "$T/aws2.json"
newrepo() { local r="$T/$1"; mkdir -p "$r/.sdkit"; ( cd "$r" && git init -q -b main . && printf 'BASE_BRANCH=main\nSTACK=generic\nUSAGE_LOG=1\n' > .sdkit/sdkit.env ); echo "$r"; }

echo "refresh"
R="$(newrepo r1)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
"$PS" refresh --from "$T/aws.json" >/dev/null 2>&1
eq "writes <project-dir>/pricing.json marked as kit-written"            "$(jq -r .managed_by .sdkit/pricing.json)" "sdkit pricing"
eq "a model needs an input and an output price (regional-only is out)"   "$(jq -r '[.models[].model]|join(",")' .sdkit/pricing.json)" "claude-test-1"
eq "global standard rates in USD per million tokens"                      "$(jq -r '.models[0]|[.in,.out,.cache_read,.cache_write,.provider]|join(",")' .sdkit/pricing.json)" "2,10,0.1,2.5,bedrock"
eq "batch and 1-hour cache entries are ignored"                           "$(jq -r '.models[0].cache_write' .sdkit/pricing.json)" 2.5
eq "the price list's own date is kept"                                    "$(jq -r .price_list_date .sdkit/pricing.json)" "2026-10-30T00:00:00Z"
"$PS" refresh --from "$T/aws2.json" --regional >/dev/null 2>&1
eq "--regional prices regional inference (per-1K units converted; a model without a regional output price is out)"    "$(jq -r '[.models[]|"\(.model):\(.in)"]|join(",")' .sdkit/pricing.json)" "claude-old-2:3"
cp .sdkit/pricing.json "$T/managed.json"
echo '{"version":2,"currency":"USD","models":[{"model":"mine","in":1,"out":2}]}' > .sdkit/pricing.json
"$PS" refresh --from "$T/aws.json" >/dev/null 2>&1; eq "a table you wrote is left alone (exit 3)"                  "$?" 3
eq "...and unchanged"                                                     "$(jq -r '.models[0].model' .sdkit/pricing.json)" mine
"$PS" refresh --from "$T/aws.json" --force >/dev/null 2>&1; eq "--force replaces it"                              "$(jq -r '.models[0].model' .sdkit/pricing.json)" claude-test-1
SDKIT_PRICE_URL="file://$T/missing.json" "$PS" refresh >/dev/null 2>&1; eq "a failed fetch exits 4"               "$?" 4
eq "...and keeps the table"                                               "$(jq -r '.models[0].model' .sdkit/pricing.json)" claude-test-1
echo '{"hello":1}' > "$T/bad.json"; "$PS" refresh --from "$T/bad.json" >/dev/null 2>&1; eq "a file that is no price list is refused (exit 4)" "$?" 4
SDKIT_PRICE_URL="file://$T/aws.json" "$PS" refresh >/dev/null 2>&1; eq "the fetch path works (file:// URL)"        "$?" 0

echo "status"
R="$(newrepo s1)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
eq "no table: state missing, problems listed (exit 3)"                    "$("$PS" status --json | jq -r .state)" missing
"$PS" status >/dev/null 2>&1; eq "...exit code 3"                          "$?" 3
"$PS" refresh --from "$T/aws.json" >/dev/null 2>&1
eq "a kit-written table: managed"                                          "$("$PS" status --json | jq -r .state)" managed
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: $2)" ;; esac; }
has "an empty REPORT_BASELINE_MODEL is reported"                           "$("$PS" status --json | jq -r '.problems|join(" | ")')" "REPORT_BASELINE_MODEL is not set"
printf 'REPORT_BASELINE_MODEL=nope\n' >> .sdkit/sdkit.env
has "a baseline that is not in the table is reported"                      "$("$PS" status --json | jq -r '.problems|join(" | ")')" "is not in the price table"
sed -i.bak 's/^REPORT_BASELINE_MODEL=.*/REPORT_BASELINE_MODEL=claude-test-1/' .sdkit/sdkit.env
eq "a baseline in the table is fine: no problems, exit 0"                  "$("$PS" status >/dev/null 2>&1; echo $?)" 0
mkdir -p .sdkit/work/x; "$US" log --role developer --model claude-unknown-9 --in 1 --out 1 --id u1 --slug x >/dev/null
has "a model in your ledger without a price is reported"                   "$("$PS" status --json | jq -r '.problems|join(" | ")')" "claude-unknown-9"
jq '.fetched_at="2026-01-01T00:00:00Z"' .sdkit/pricing.json > "$T/o.json" && mv "$T/o.json" .sdkit/pricing.json
has "a kit-written table older than 90 days is reported stale"             "$("$PS" status --json | jq -r '.problems|join(" | ")')" "days old"
jq 'del(.managed_by)' .sdkit/pricing.json > "$T/o.json" && mv "$T/o.json" .sdkit/pricing.json
eq "...a table you took over is never called stale"                        "$("$PS" status --json | jq -r '[.problems[]|select(test("days old"))]|length')" 0
echo '{' > .sdkit/pricing.json; eq "an unreadable table is reported"       "$("$PS" status --json | jq -r .state)" unreadable

echo "the shipped table, init and doctor"
jq -e . "$KIT/templates/pricing.json" >/dev/null 2>&1 && ok "templates/pricing.json is valid JSON" || bad "templates/pricing.json is valid JSON"
eq "it is kit-written, in USD, for Bedrock"                                "$(jq -r '[.managed_by,.currency,([.models[].provider]|unique|join(","))]|join(",")' "$KIT/templates/pricing.json")" "sdkit pricing,USD,bedrock"
eq "it prices the models Claude Code runs on (sonnet-5-5 at 2 / 10)"       "$(jq -r '.models[]|select(.model=="claude-sonnet-5-5")|"\(.in)/\(.out)"' "$KIT/templates/pricing.json")" "2/10"
R="$(newrepo c1)"; cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"; mkdir -p .sdkit/work/c; cp "$KIT/templates/pricing.json" .sdkit/pricing.json
"$US" log --role orchestrator --model claude-sonnet-5-5 --provider bedrock --in 1000000 --out 1000000 --cache-read 1000000 --cache-write 1000000 --id session-z --slug c --kind final >/dev/null
eq "a Bedrock Sonnet 5.5 ledger row is priced from it (2+10+0.1+2.5)"      "$("$US" report c --json | jq -r .totals.cost_usd)" 14.6
D="$T/init1"; mkdir -p "$D"; ( cd "$D" && git init -q -b main . )
"$KIT/bin/init.sh" "$D" >/dev/null 2>&1   # the one init; every scenario below runs on its own copy of it, all at once (init/doctor/upgrade are seconds each)
[ -f "$D/.sdkit/pricing.json" ] && ok "sdkit init installs pricing.json" || bad "sdkit init installs pricing.json"
for n in keep doc upd cust up1 up2 up3; do cp -R "$D" "$T/s-$n"; done
KEEP='{"version":2,"models":[{"model":"keep","in":1,"out":1}]}'
echo "$KEEP" > "$T/s-keep/.sdkit/pricing.json"; echo "$KEEP" > "$T/s-cust/.sdkit/pricing.json"
U="$T/s-up1"; U3="$T/s-up3"
sed -i.bak 's/^TELEMETRY=1$/TELEMETRY=/' "$U/.sdkit/sdkit.local.env"; sed -i.bak 's/^ROUTING=on$/ROUTING=off/' "$U/.sdkit/sdkit.env"; rm -f "$U"/.sdkit/*.bak
echo 1.3.0 > "$U/.sdkit/.scaffold-version"; rm -f "$U/.sdkit/pricing.json"
U2="$T/s-up2"; echo 1.3.2 > "$U2/.sdkit/.scaffold-version"; sed -i.bak 's/^ROUTING=on$/ROUTING=off/; s/^TELEMETRY=1$/TELEMETRY=/' "$U2/.sdkit/sdkit.env" "$U2/.sdkit/sdkit.local.env"; rm -f "$U2"/.sdkit/*.bak
echo 1.2.0 > "$U3/.sdkit/.scaffold-version"; sed -i.bak 's/^ROUTING=on$/ROUTING=shadow/; s/^TELEMETRY=1$/TELEMETRY=0/' "$U3/.sdkit/sdkit.env" "$U3/.sdkit/sdkit.local.env"; rm -f "$U3"/.sdkit/*.bak
( "$KIT/bin/init.sh" "$T/s-keep" >/dev/null 2>&1 ) &
( "$KIT/bin/doctor.sh" "$T/s-doc" > "$T/out-doc" 2>&1 ) &
( SDKIT_PRICE_URL="file://$T/aws.json" "$KIT/bin/doctor.sh" --update-pricing "$T/s-upd" > "$T/out-upd" 2>&1 ) &
( SDKIT_PRICE_URL="file://$T/aws.json" "$KIT/bin/doctor.sh" --update-pricing "$T/s-cust" > "$T/out-cust" 2>&1 ) &
( "$KIT/bin/upgrade.sh" "$U" > "$T/out-up1" 2>&1 ) &
( "$KIT/bin/upgrade.sh" "$U2" >/dev/null 2>&1 ) &
( "$KIT/bin/upgrade.sh" "$U3" >/dev/null 2>&1 ) &
wait
eq "init never overwrites an existing pricing.json"                        "$(jq -r '.models[0].model' "$T/s-keep/.sdkit/pricing.json")" keep
out="$(cat "$T/out-doc")"; has "doctor reports the price table"            "$out" "pricing: managed"
has "...and the unset baseline model"                                      "$out" "REPORT_BASELINE_MODEL"
has "...and that measurement is on"                                        "$out" "measurement on"
eq "doctor --update-pricing rebuilds a kit-written table"                  "$(jq -r '[.models[].model]|join(",")' "$T/s-upd/.sdkit/pricing.json")" "claude-test-1"
eq "...and leaves your own table alone"                                    "$(jq -r '.models[0].model' "$T/s-cust/.sdkit/pricing.json")" keep
has "...saying so"                                                          "$(cat "$T/out-cust")" "it is yours"
eq "a new setup measures: TELEMETRY=1, USAGE_LOG=1, VALUE_REPORT=on"       "$(grep -hE '^(TELEMETRY=1|USAGE_LOG=1|VALUE_REPORT=on)$' "$D/.sdkit/sdkit.local.env" | wc -l | tr -d ' ')" 3
eq "...and ROUTING=on"                                                     "$(grep -c '^ROUTING=on$' "$D/.sdkit/sdkit.env")" 1

echo "upgrade moves old projects to measurement on, once"
out="$(cat "$T/out-up1")"
eq "kit < 1.3.2: TELEMETRY empty becomes 1"                                "$(grep -c '^TELEMETRY=1$' "$U/.sdkit/sdkit.local.env")" 1
eq "...ROUTING=off becomes on"                                             "$(grep -c '^ROUTING=on$' "$U/.sdkit/sdkit.env")" 1
case "$out" in *"ROUTING=on (was off)"*) ok "...and it says so" ;; *) bad "...and it says so" ;; esac
eq "...the missing price table arrives too"                                "$([ -f "$U/.sdkit/pricing.json" ] && echo yes)" yes
eq "a project already at 1.3.2: a later 'off' is yours and stays"          "$(grep -c '^ROUTING=off$' "$U2/.sdkit/sdkit.env")" 1
eq "an old project with other values keeps ROUTING=shadow"                 "$(grep -c '^ROUTING=shadow$' "$U3/.sdkit/sdkit.env")" 1
eq "...and TELEMETRY=0"                                                    "$(grep -c '^TELEMETRY=0$' "$U3/.sdkit/sdkit.local.env")" 1

echo
echo "pricing: $pass passed, $fail failed"
[ "$fail" = 0 ]
