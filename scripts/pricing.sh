#!/usr/bin/env bash
# SDKit price table: <project-dir>/pricing.json, the table every cost figure (usage.sh, report.sh, route.sh) is computed from.
# The table the kit ships (templates/pricing.json, copied by `sdkit init`) is a snapshot of the public AWS Bedrock price list for the Claude models
# (global cross-region inference, standard tier, USD per million tokens). `refresh` rebuilds it from the live list; `doctor` calls it.
#   pricing.sh refresh [--out FILE] [--from AWS_PRICE_LIST.json] [--region R] [--regional] [--force] [--dry-run]
#        rebuild the table. Only a table this script wrote (marker "managed_by": "sdkit pricing") is replaced: a table you wrote or edited
#        by hand is never touched without --force. --from reads a downloaded list instead of fetching it (offline, tests).
#        --regional prices regional (geo) inference, about 10% above global, instead of global.
#   pricing.sh status [--json]
#        state of the table: missing | unreadable | custom (yours) | managed (kit-written), its age, the models in your ledgers it cannot price,
#        and whether REPORT_BASELINE_MODEL is in it. Exit 0 = fine, 3 = something to fix (doctor shows it as a warning).
# What is NOT modelled (one rate per kind): the 1-hour cache write, batch and flex tiers, and the long-context surcharge of some models.
# Never fails a hook: nothing here runs from a hook.
set -u
command -v jq >/dev/null || { echo "pricing.sh needs jq" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
. "$here/env.sh" 2>/dev/null || { echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }
SDKIT_ENV_QUIET=1 sdkit_env_load "$top"
work="$top/$KIT_DIR/work"
PRICE_URL="${SDKIT_PRICE_URL:-https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonBedrockFoundationModels/current/index.json}"
STALE_DAYS="${PRICING_STALE_DAYS:-90}"
MARK="sdkit pricing"

# aws_to_table <region> <global 1|0>: the AWS offer file on stdin -> a v2 price table (jq). A model needs an input and an output price to be listed.
AWS_JQ='
def per_m: ((.pricePerUnit.USD | tonumber) * (if (.unit // "") | test("1K"; "i") then 1000 else 1 end));
. as $d
| [ .products | to_entries[]
    | select(.value.attributes.provider == "Anthropic" and .value.attributes.regionCode == $region and (.value.attributes.model // "" | startswith("Claude")))
    | .value as $p | ($p.attributes.usagetype | ascii_downcase) as $u
    | select(($u | test("batch|reserved|1h|long_ctx|flex|priority") | not) and (($u | test("global")) == ($global == 1)))
    | ($d.terms.OnDemand[.key] // null) as $t | select($t != null)
    | ($t | to_entries[0].value.priceDimensions | to_entries[0].value) as $pd
    | {model: $p.attributes.model, kind: (if $u | test("cacheread|cache_read") then "cache_read" elif $u | test("cachewrite|cache_write") then "cache_write"
                                          elif $u | test("input") then "in" elif $u | test("output") then "out" else null end), usd: ($pd | per_m)} | select(.kind != null) ]
| group_by(.model)
| map({name: .[0].model, r: (map({key: .kind, value: .usd}) | from_entries)})
| map(select(.r.in != null and .r.out != null))
| map({model: (.name | ascii_downcase | gsub("[ .]"; "-")), provider: "bedrock", in: .r.in, out: .r.out, cache_read: .r.cache_read, cache_write: .r.cache_write,
       source: "AWS Bedrock price list, \($region), \(if $global == 1 then "global" else "regional" end) inference, standard tier"})
| map(with_entries(select(.value != null)))
| sort_by(.model)
'

die() { echo "pricing: $*" >&2; exit "${2:-1}"; }
table_file() { printf '%s' "${TELEMETRY_PRICES:-$top/$KIT_DIR/pricing.json}"; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  refresh)
    out="$(table_file)"; from=""; region=us-east-1; global=1; force=0; dry=0
    while [ $# -gt 0 ]; do case "$1" in
      --out) out="$2"; shift ;; --from) from="$2"; shift ;; --region) region="$2"; shift ;;
      --regional) global=0 ;; --force) force=1 ;; --dry-run) dry=1 ;; *) die "unknown option $1" 2 ;; esac; shift; done
    if [ -f "$out" ] && [ "$force" = 0 ] && [ "$(jq -r '.managed_by // empty' "$out" 2>/dev/null)" != "$MARK" ]; then
      die "$out is not a table this script wrote (no \"managed_by\": \"$MARK\"): it is yours, so it is left alone. Use --force to replace it, or --out to write elsewhere" 3
    fi
    tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.out"' EXIT
    if [ -n "$from" ]; then [ -f "$from" ] || die "no such file: $from"; cp "$from" "$tmp"
    else
      command -v curl >/dev/null || die "curl is needed to fetch the price list (or pass --from FILE)"
      curl -fsS -m 120 -o "$tmp" "$PRICE_URL" || die "could not fetch $PRICE_URL: the table is unchanged. Pass --from FILE with a downloaded list, or keep the one you have" 4
    fi
    jq -e '.products and .terms.OnDemand' "$tmp" >/dev/null 2>&1 || die "not an AWS price list (no products/terms): the table is unchanged" 4
    models="$(jq -c --arg region "$region" --argjson global "$global" "$AWS_JQ" "$tmp")" || die "could not read the price list: the table is unchanged" 4
    [ "$(jq length <<< "$models")" -gt 0 ] || die "the price list has no Claude model for $region: the table is unchanged" 4
    jq -n --argjson m "$models" --arg at "${SDKIT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" --arg listed "$(jq -r '.publicationDate // empty' "$tmp")" --arg mark "$MARK" \
      '{version: 2, currency: "USD", managed_by: $mark, fetched_at: $at, price_list_date: $listed,
        note: "USD per million tokens, API-equivalent estimate, never a bill. cache_write is the 5-minute rate. Rebuilt by `sdkit doctor --update-pricing` (scripts/pricing.sh refresh); delete managed_by to take the table over by hand.",
        models: $m}' > "$tmp.out" || die "could not build the table"
    if [ "$dry" = 1 ]; then cat "$tmp.out"; exit 0; fi
    mkdir -p "$(dirname "$out")" && mv "$tmp.out" "$out" && echo "pricing: wrote $out ($(jq '.models | length' "$out") models, $region, $([ "$global" = 1 ] && echo global || echo regional) inference)" ;;
  status)
    json=0; [ "${1:-}" = --json ] && json=1
    f="$(table_file)"; state=missing; age=null; nmodels=0; unpriced='[]'; bl_ok=null
    if [ -f "$f" ]; then
      if ! jq -e . "$f" >/dev/null 2>&1; then state=unreadable
      else
        if [ "$(jq -r '.managed_by // empty' "$f")" = "$MARK" ]; then state=managed; else state=custom; fi
        nmodels="$(jq -c '[.models[]? | select(type == "object") | .model] | length' "$f" 2>/dev/null || echo 0)"
        at="$(jq -r '.fetched_at // empty' "$f")"
        [ -n "$at" ] && age="$(jq -nr --arg a "$at" 'try ((now - ($a | fromdateiso8601)) / 86400 | floor) catch null')"
        ids="$(cat "$work"/*/usage.jsonl "$work"/_archive/*.usage.jsonl 2>/dev/null | jq -Rr 'fromjson? | select(.tq != "unavailable" and (.model // "") != "") | .model' 2>/dev/null | sort -u)"
        if [ -n "$ids" ]; then
          unpriced="$(printf '%s\n' "$ids" | jq -Rsc --slurpfile t "$f" '[split("\n")[] | select(. != "") | select(. as $m | ([$t[0].models[]? | .model] | index($m) == null and index($m | sub("-[0-9]{8}$"; "")) == null))]')"
        fi
        if [ -n "${REPORT_BASELINE_MODEL:-}" ]; then
          bl_ok="$(jq -c --arg m "$REPORT_BASELINE_MODEL" '[.models[]? | .model] | index($m) != null' "$f")"
        fi
      fi
    fi
    problems="$(jq -nc --arg st "$state" --argjson age "$age" --argjson un "$unpriced" --argjson bl "$bl_ok" --arg blm "${REPORT_BASELINE_MODEL:-}" --argjson stale "$STALE_DAYS" \
      '[ (if $st == "missing" then "no pricing.json: costs are not computed (tokens only)" else empty end),
         (if $st == "unreadable" then "pricing.json is not valid JSON: costs are not computed" else empty end),
         (if $st == "managed" and $age != null and $age > $stale then "the price table is \($age) days old (kit-written): refresh it" else empty end),
         (if ($un | length) > 0 then "models in your ledgers have no price: \($un | join(", "))" else empty end),
         (if $blm == "" then "REPORT_BASELINE_MODEL is not set: routing savings stay N/A" else empty end),
         (if $bl == false then "REPORT_BASELINE_MODEL \($blm) is not in the price table: routing savings stay N/A" else empty end) ]')"
    if [ "$json" = 1 ]; then
      jq -n --arg f "$f" --arg st "$state" --argjson age "$age" --argjson n "$nmodels" --argjson un "$unpriced" --argjson p "$problems" \
        '{file: $f, state: $st, age_days: $age, models: $n, unpriced_models: $un, problems: $p}'
    else
      echo "pricing: $state ($f)$([ "$age" != null ] && echo ", $age day(s) old"), $nmodels model(s)"
      jq -r '.[] | "  - " + .' <<< "$problems"
    fi
    [ "$(jq length <<< "$problems")" -eq 0 ] || exit 3 ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; [ -z "$cmd" ] || exit 2 ;;
esac
