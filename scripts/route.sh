#!/usr/bin/env bash
# Orchestration decisions (F06): which adapter and model run a role, within which budget, whether to reuse, retry, escalate or stop.
# Core owns policy, adapters (core/adapters.json, scripts/run-role.sh) provide capabilities, providers execute. No model call is ever made here:
# every decision is a pure function of the open task (risk, profile, evidence), the settings, the registry, the routing ledger and the usage ledger,
# and carries a machine-readable reason code. Off by default (ROUTING=on in sdkit.env turns run-role.sh into a consumer of these decisions).
#   route.sh decide  --role R [--host H] [--tier T] [--model M] [--handoff FILE] [--risk L] [--rerun WHY] [--ignore-budget] [--require-cli] [--reserve] [--pid N] [--json]
#   route.sh explain --role R ...      the same, as five readable lines; never records anything
#   route.sh outcome --decision ID --rc N [--prc N] [--stderr FILE] [--dur-ms N] [--in N --out N] [--tokens actual|unavailable]
#                                     record how a decided run ended; prints the failure class and what the next request for this role will do
#   route.sh classify [--rc N] [--prc N] [--stderr FILE] [--role R]   the failure class of an exit status (OK TRANSIENT RATE_LIMIT TIMEOUT INVALID_OUTPUT CONTRACT_FAILURE ...)
#   route.sh registry [--json]         the model registry: derived from core/tiers.env + <project-dir>/models.json (project entries first)
#   route.sh capabilities [host] [--json|--probe]   the execution contract per adapter (core/adapters.json); --probe re-checks the flags against the installed CLIs' --help (no model call)
#   route.sh validate                  check the ROUTE_* settings, models.json and the preferences; exit 2 and list the problems
#   route.sh log [slug]                the routing ledger of a task, one line per decision/outcome
# decide exit: 0 run it (action execute|retry|escalate) | 7 reuse: valid evidence already exists (success-like: nothing to run or retry)
#              | 8 stop, nothing run and nothing valid exists (optional skipped, duplicate, a standing BLOCK, retries/escalation exhausted): never success
#              | 3 budget exhausted | 2 refused by policy or configuration (nothing is run; the reason says which setting)
# Policy version: route-v1. A decision never lowers a risk floor, skips a mandatory gate, or turns a BLOCK into a PASS.
set -u
cmd="${1:-}"; [ $# -gt 0 ] && shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v jq >/dev/null || { echo "route.sh needs jq" >&2; exit 2; }
top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
. "$here/env.sh" || { echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 2; }
SDKIT_ENV_QUIET=1 sdkit_env_load "$top"
POLICY="route-v1"
work="$top/$KIT_DIR/work"; sdd_state="$top/$KIT_DIR/.sdd/state.json"; slug=""

rank() { case "$1" in light) echo 1 ;; standard) echo 2 ;; strong) echo 3 ;; *) echo 0 ;; esac; }
tier_of_rank() { case "$1" in 1) echo light ;; 2) echo standard ;; 3) echo strong ;; esac; }
upper() { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }
isint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }
find_file() {  # find_file <core-relative name> <project-dir name>: the kit's copy, else the project's installed copy
  local f; for f in "$here/../core/$1" "$top/$KIT_DIR/$2"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
tierenv() { local f; f="$(find_file tiers.env tiers.env)" && sed -n "s/^$1=//p" "$f" | tail -1; }
ADAPTERS="$(find_file adapters.json adapters.json 2>/dev/null || true)"
now_s() { date +%s; }
# flattened once per process: this runs in command substitutions, where a lazy cache would be lost, and it used to be rebuilt (jq + date) on every use
PRICES_FLAT="$(sdkit_prices_flat "${TELEMETRY_PRICES:-$top/$KIT_DIR/pricing.json}")"
prices_json() { printf '%s' "$PRICES_FLAT"; }   # the user's price table (usd per million tokens), flattened to what is in force today; the kit ships none
# Money is priced by the SAME resolver as usage.sh (env.sh SDKIT_PRICE_JQ: exact id, else the id without a -YYYYMMDD suffix; provider; effective window on the record date), never by a private lookup.
PT="$(sdkit_price_table "${TELEMETRY_PRICES:-$top/$KIT_DIR/pricing.json}")"
PJQ="$SDKIT_PRICE_JQ"'def nrm: . + {model: (.model // ""), provider: (.provider // ""), in: (.in // 0), out: (.out // 0), cache_read: (.cache_read // 0), cache_write: (.cache_write // 0)};'
# strict numbers: 1.2.3, "." and "1e5" are not numbers; a monetary value is never guessed
isnum() { [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
ispos() { isnum "${1:-}" && awk -v v="$1" 'BEGIN{exit !(v > 0)}'; }

cost_scope() {  # cost_scope <usage ledger files...> (env CS_ROLE = only that role): {runs, unmeasured_or_unpriced, usd} from the user's price table, lower bound when any run is unpriced. Fails (non-zero, no output) when it cannot compute.
  local f all='[]'; for f in "$@"; do [ -f "$f" ] && { all="$(jq -sc --argjson a "$all" '$a + .' "$f")" || return 1; }; done
  jq -c --argjson pt "$PT" --arg r "${CS_ROLE:-}" "$PJQ"'
    map(select(type == "object") | nrm | select($r == "" or ((.role // "" | sub("-deep$"; "")) == $r))) as $m
    | ($m | map(select((.tq // "actual") != "unavailable" and cost_of(.) != null))) as $pr
    | {runs: ($m | length), unmeasured_or_unpriced: (($m | length) - ($pr | length)), usd: ($pr | map(cost_of(.)) | add // 0)}' <<< "$all"
}
R_RTTL="${ROUTE_RESERVE_TTL_S:-3600}"
reservations_open() {  # one line per reservation that has no release yet, over every task: slug <TAB> id <TAB> usd <TAB> age_s <TAB> pid <TAB> active|stale. Non-zero when a ledger cannot be read (callers under hard enforcement stop).
  local f s chunk out=""
  for f in "$work"/*/reservations.jsonl; do [ -f "$f" ] || continue; s="$(basename "$(dirname "$f")")"
    chunk="$(jq -sr --arg s "$s" '(map(select(.type == "release") | .id)) as $done | .[] | select(.type == "reserve" and (.id as $i | $done | index($i) | not))
      | [$s, .id, (.usd | tostring), ((now - ((.ts // "1970-01-01T00:00:00Z") | fromdateiso8601)) | floor | tostring), ((.pid // "") | tostring)] | @tsv' "$f" 2>/dev/null)" || return 1
    [ -z "$chunk" ] || out="$out$chunk"$'\n'
  done
  local sl id usd age pid st
  while IFS=$'\t' read -r sl id usd age pid; do [ -n "$id" ] || continue
    isnum "$usd" || return 1
    st=active; if [ "$age" -gt "$R_RTTL" ] && ! { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }; then st=stale; fi   # old AND its process is gone; a live process keeps its reservation however long it runs
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sl" "$id" "$usd" "$age" "$pid" "$st"
  done <<< "$out"
}
open_reserved() {  # USD currently reserved by runs that have not reported an outcome yet and are not stale, over every task (F14); non-zero when unreadable
  local l; l="$(reservations_open)" || return 1
  awk -F'\t' '$6 == "active" {t += $3} END {printf "%.6f\n", t + 0}' <<< "$l"
}
release_reservation() {  # release_reservation <slug> <id> <class> [note]: idempotent (a second call, or a late outcome, appends nothing); under the project lock
  local f="$work/$1/reservations.jsonl" u
  [ -f "$f" ] || return 0
  sdkit_lock "$work/.project-budget"
  if ! jq -e --arg id "$2" 'select(.type == "release" and .id == $id)' "$f" >/dev/null 2>&1; then
    u="$(jq -r --arg id "$2" 'select(.type == "reserve" and .id == $id) | .usd' "$f" | head -1)"
    isnum "$u" || u=0
    printf '%s\n' "$(jq -nc --arg id "$2" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson u "$u" --arg c "$3" --arg n "${4:-actual spend is in usage.jsonl; release returns the reservation}" '{type:"release",id:$id,ts:$ts,reserved_usd:$u,class:$c,note:$n}')" >> "$f"
  fi
  sdkit_unlock "$work/.project-budget"
}

# ---------------------------------------------------------------- settings (all optional; the defaults are conservative)
ROUTING="${ROUTING:-off}"; R_POLICY="${ROUTE_POLICY:-tiered}"; R_FIXED="${ROUTE_FIXED_MODEL:-}"
R_RETRIES="${ROUTE_MAX_RETRIES:-2}"; R_ESCS="${ROUTE_MAX_ESCALATIONS:-1}"; R_ESCTO="${ROUTE_ESCALATE_TO:-strong}"; R_ATTEMPTS="${ROUTE_MAX_ATTEMPTS:-4}"
R_BACKOFF="${ROUTE_BACKOFF_S:-10}"; R_TTL="${ROUTE_INFLIGHT_TTL_S:-1800}"; R_FALLBACK="${ROUTE_FALLBACK_HOSTS:-}"
R_FLOOR_LOW="${ROUTE_FLOOR_LOW:-light}"; R_FLOOR_MED="${ROUTE_FLOOR_MEDIUM:-light}"; R_FLOOR_HIGH="${ROUTE_FLOOR_HIGH:-standard}"; R_DOWN="${ROUTE_DOWNGRADE_LOW:-0}"

cfg_errors() {  # one line per problem in the settings; nothing when sound
  case "$ROUTING" in on|off) ;; *) echo "ROUTING must be on or off (is '$ROUTING')" ;; esac
  case "$R_POLICY" in tiered) ;; fixed) [ -n "$R_FIXED" ] || echo "ROUTE_POLICY=fixed needs ROUTE_FIXED_MODEL=<registry id>" ;; *) echo "ROUTE_POLICY must be tiered or fixed (is '$R_POLICY')" ;; esac
  local v; for v in ROUTE_MAX_RETRIES ROUTE_MAX_ESCALATIONS ROUTE_MAX_ATTEMPTS ROUTE_BACKOFF_S ROUTE_INFLIGHT_TTL_S; do
    eval "isint \"\${$v:-0}\"" || echo "$v must be a non-negative integer"; done
  for v in ROUTE_TIMEOUT_S ROUTE_ROLE_TOKENS; do eval "[ -z \"\${$v:-}\" ] || isint \"\${$v:-}\"" || echo "$v must be a non-negative integer"; done
  [ -z "${ROUTE_BUDGET_COST:-}" ] || isnum "$ROUTE_BUDGET_COST" || echo "ROUTE_BUDGET_COST must be a number (USD), like 5 or 0.25"
  case "${ROUTE_COST_ENFORCE:-off}" in off|hard) ;; *) echo "ROUTE_COST_ENFORCE must be off or hard" ;; esac
  for v in ROUTE_ROLE_BUDGET_COST ROUTE_PROJECT_BUDGET_COST ROUTE_RESERVE_USD; do
    eval "[ -z \"\${$v:-}\" ] || isnum \"\${$v:-}\"" || echo "$v must be a number (USD), like 5 or 0.25"; done
  [ -z "${ROUTE_RESERVE_USD:-}" ] || ! isnum "$ROUTE_RESERVE_USD" || [ "${ROUTE_COST_ENFORCE:-off}" != hard ] || ispos "$ROUTE_RESERVE_USD" || echo "ROUTE_RESERVE_USD must be greater than 0 under ROUTE_COST_ENFORCE=hard (a zero reservation reserves nothing)"
  isint "${ROUTE_RESERVE_TTL_S:-3600}" || echo "ROUTE_RESERVE_TTL_S must be a non-negative integer (seconds)"
  [ "${ROUTE_COST_ENFORCE:-off}" != hard ] || [ -n "${ROUTE_BUDGET_COST:-}${ROUTE_ROLE_BUDGET_COST:-}${ROUTE_PROJECT_BUDGET_COST:-}" ] || echo "ROUTE_COST_ENFORCE=hard needs ROUTE_BUDGET_COST, ROUTE_ROLE_BUDGET_COST or ROUTE_PROJECT_BUDGET_COST"
  case "$R_DOWN" in 0|1) ;; *) echo "ROUTE_DOWNGRADE_LOW must be 0 or 1" ;; esac
  for v in "$R_ESCTO" "$R_FLOOR_LOW" "$R_FLOOR_MED" "$R_FLOOR_HIGH"; do [ "$(rank "$v")" != 0 ] || echo "'$v' is not a tier (light|standard|strong)"; done
  local h; for h in $R_FALLBACK; do [ -z "$ADAPTERS" ] || jq -e --arg h "$h" 'has($h)' "$ADAPTERS" >/dev/null 2>&1 || echo "ROUTE_FALLBACK_HOSTS: unknown host '$h'"; done
  [ -n "$ADAPTERS" ] && jq -e . "$ADAPTERS" >/dev/null 2>&1 || echo "adapters.json is missing or not valid JSON"
}

# ---------------------------------------------------------------- registry
registry_build() {  # JSON array: <project-dir>/models.json entries first, then the entries derived from tiers.env (never invented model names). One jq call.
  local proj="$top/$KIT_DIR/models.json" tf envj p="[]"
  tf="$(find_file tiers.env tiers.env 2>/dev/null || true)"
  envj="$( { [ -n "$tf" ] && sed -n 's/^\([A-Z0-9_]*\)=\(.*\)$/\1=\2/p' "$tf"
             for t in LIGHT STANDARD STRONG; do eval "v=\${RUN_ROLE_MODEL_$t:-}"; [ -n "$v" ] && printf 'RUN_ROLE_MODEL_%s=%s\n' "$t" "$v"; done; } | jq -R -s -c 'split("\n") | map(select(test("^[A-Z0-9_]+=")) | capture("^(?<key>[A-Z0-9_]+)=(?<value>.*)$")) | from_entries' 2>/dev/null)"
  [ -n "$envj" ] || envj='{}'
  if [ -f "$proj" ]; then
    jq -e 'type == "array"' "$proj" >/dev/null 2>&1 || { echo "models.json must be a JSON array" >&2; return 1; }
    p="$(jq -c 'map({status:"available", roles:"*", tools:true} + . + {source:"models.json"})' "$proj")"
  fi
  jq -n -c --slurpfile a "$ADAPTERS" --argjson env "$envj" --argjson p "$p" --argjson pr "$(prices_json)" '
    def up: ascii_upcase;
    def effort($h; $t): if $h != "codex" then null else ($env["CODEX_EFFORT_" + ($t | up)] // ({"light":"low","standard":"medium","strong":"high"}[$t])) end;
    def derived:
      [ ($a[0] | keys_unsorted[] | select(startswith("_") | not)) as $h
        | ([ ("light","standard","strong") as $t
             | (($env["RUN_ROLE_MODEL_" + ($t | up)] // "") | if . == "" then ($env[($h | up) + "_MODEL_" + ($t | up)] // "") else . end) as $m
             | effort($h; $t) as $e
             | select($m != "" or $e != null)
             | {id: "\($h):\($t)", adapter: $h, model: (if $m == "" then null else $m end), effort: $e, tier: $t, roles: "*", tools: true, status: "available", source: "tiers.env"} ]) as $tiers
        | if ($tiers | length) > 0 then $tiers[]
          else {id: "\($h):inherit", adapter: $h, model: null, effort: null, tier: "*", roles: "*", tools: true, status: "available", source: "inherit"} end ];
    ($p | map(.id)) as $ids
    | ($p + (derived | map(select(.id as $i | $ids | index($i) | not))))
    | map(. + {provider: (.provider // $a[0][.adapter].provider // null), context: (.context // null), cost: (.cost // $pr[.model // ""] // null),
               usage_accounting: ($a[0][.adapter].caps.usage_reporting // "none")})'
}
registry_errors() {  # problems in the registry (project entries are the only user input); $1 = an already built registry
  local reg="${1:-}"; [ -n "$reg" ] || reg="$(registry_build 2>&1)" || { echo "$reg"; return; }
  jq -r --slurpfile a "$ADAPTERS" '
    (map(select(.source == "models.json"))) as $p
    | ($p | map(.id) | group_by(.) | map(select(length > 1) | "models.json: duplicate id \(.[0])")[]),
      ($p[] | select((.id // "") == "" or ((.id | type) != "string")) | "models.json: an entry has no id"),
      ($p[] | select(.adapter as $x | $a[0] | has($x // "") | not) | "models.json: \(.id): unknown adapter \(.adapter)"),
      ($p[] | select([.tier] | inside(["light","standard","strong","*"]) | not) | "models.json: \(.id): tier must be light, standard, strong or *"),
      ($p[] | select(((.roles // "*") | type) as $t | ((.roles // "*") != "*" and $t != "array")) | "models.json: \(.id): roles must be \"*\" or an array"),
      ($p[] | select(has("status") and ([.status] | inside(["available","disabled"]) | not)) | "models.json: \(.id): status must be available or disabled")' <<< "$reg"
}

# ---------------------------------------------------------------- small helpers shared by the commands
role_src() { local b="${1%-deep}" c; for c in "$here/../core/roles/$b.md" "$top/$KIT_DIR/roles/$b.md"; do [ -f "$c" ] && { echo "$c"; return 0; }; done; return 1; }
fm() { awk -v k="$2" 'BEGIN{f=0} /^---$/{f++; next} f==1 && index($0,k":")==1 {sub("^"k":[ ]*",""); print; exit}' "$1"; }
slug_now() { local s; s="$(sdkit_active_slug "$top")"; echo "${s:-_misc}"; }
ledger_of() { echo "$work/$1/routing.jsonl"; }
tele() { [ "${TELEMETRY:-}" = 1 ] && [ -x "$here/telemetry.sh" ] && { "$here/telemetry.sh" emit "$@" ${slug:+--task "$slug"} >/dev/null 2>&1 || true; }; return 0; }

classify_text() {  # (exit 7/8 of run-role/decide are routing outcomes, not host failures)  # classify_text <rc> <prc> <stderr file> -> class
  local rc="$1" prc="$2" f="$3" t=""
  [ -f "$f" ] && t="$(tail -40 "$f" 2>/dev/null | tr 'A-Z' 'a-z')"
  case "$rc" in
    0) case "$prc" in 1) echo VERDICT_BLOCK ;; *) echo OK ;; esac; return ;;
    3) echo BUDGET_EXHAUSTED; return ;; 4) echo CONTRACT_FAILURE; return ;; 5) echo REPORTED_FAILURE; return ;;
    6) echo INVALID_OUTPUT; return ;; 130|143) echo INTERRUPTED; return ;; 127) echo HOST_MISSING; return ;; 124) echo TIMEOUT; return ;; 7) echo NOT_RUN; return ;;
  esac
  case "$t" in
    *"rate limit"*|*"rate_limit"*|*"429"*|*"too many requests"*|*"quota"*|*"overloaded"*) echo RATE_LIMIT ;;
    *"timed out"*|*"timeout"*|*"etimedout"*|*"deadline exceeded"*) echo TIMEOUT ;;
    *"econnreset"*|*"connection reset"*|*"temporarily unavailable"*|*"service unavailable"*|*"502"*|*"503"*|*"504"*|*"network"*|*"econnrefused"*) echo TRANSIENT ;;
    *) echo UNKNOWN ;;
  esac
}

# ---------------------------------------------------------------- commands without a decision
case "$cmd" in
  registry)
    reg="$(registry_build)" || exit 2
    if [ "${1:-}" = --json ]; then echo "$reg" | jq .; else
      echo "$reg" | jq -r '.[] | [.id, .adapter, (.model // "(host default)"), (.effort // "-"), .tier, (if .roles == "*" then "*" else (.roles | join(",")) end), .status, "usage=" + .usage_accounting, (if .cost then "cost=set" else "cost=unknown" end), .source] | @tsv' | column -t -s "$(printf '\t')"
    fi
    exit 0 ;;
  capabilities)
    [ -n "$ADAPTERS" ] || { echo "adapters.json is missing" >&2; exit 2; }
    h=""; js=0; probe=0; for a in "$@"; do case "$a" in --json) js=1 ;; --probe) probe=1 ;; *) h="$a" ;; esac; done
    sel='.'; [ -n "$h" ] && sel="{\"$h\": .[\"$h\"]}"
    strip='with_entries(select(.key | startswith("_") | not))'
    if [ "$probe" = 1 ]; then
      # Reads only `<cli> --help` (and --version) of the CLIs installed here: never a model call. A capability is help-verified when every flag it needs is in that
      # help text; a flag that is missing is reported by name; a CLI that is not installed leaves its capabilities as declared. The behaviour is not exercised.
      for hh in $(jq -r "$strip | keys_unsorted[]" "$ADAPTERS"); do
        [ -z "$h" ] || [ "$h" = "$hh" ] || continue
        cli="$(jq -r --arg h "$hh" '.[$h].cli' "$ADAPTERS")"
        if ! command -v "$cli" >/dev/null 2>&1; then echo "$hh: $cli not installed here: every capability stays as declared in adapters.json (unverified)"; continue; fi
        ver="$("$cli" --version 2>&1 | head -1)"
        helparg="$(jq -r --arg h "$hh" '.[$h].probe.help | join(" ")' "$ADAPTERS")"
        # shellcheck disable=SC2086
        htxt="$(${tmo:-} "$cli" $helparg --help 2>&1)"
        res=""
        while IFS=$'\t' read -r cap flags; do
          st=help-verified
          for f in $flags; do
            printf '%s\n' "$htxt" | grep -E -q -- "(^|[[:space:],\[])$f([[:space:],=<\[]|$)" || { st="MISSING:$f"; break; }
          done
          res="$res $cap=$st"
        done < <(jq -r --arg h "$hh" '.[$h].caps as $c | .[$h].probe.flags | to_entries[] | select($c[.key] != "none") | [.key, (.value | join(" "))] | @tsv' "$ADAPTERS")
        echo "$hh ($ver):$res"
      done
      exit 0
    fi
    [ "$js" = 1 ] && { jq "$strip | $sel" "$ADAPTERS"; exit 0; }
    jq -r "$strip | $sel | to_entries[] | select(.value != null) | \"\(.key)\t\" + (.value.caps | to_entries | map(\"\(.key)=\(.value)\") | join(\" \"))" "$ADAPTERS" | column -t -s "$(printf '\t')"
    echo "(help-verified = flags present in the local --help, behaviour not exercised; declared = documented headless mode, never checked here; estimated = host's own client-side estimate, not billing; kit = provided by the kit; none = unsupported; see --probe)"
    exit 0 ;;
  validate)
    errs="$( { cfg_errors; registry_errors
      reg="$(registry_build 2>/dev/null)"
      [ -z "$R_FIXED" ] || jq -e --arg i "$R_FIXED" 'map(select(.id == $i and .status == "available")) | length > 0' <<< "$reg" >/dev/null 2>&1 || { [ -z "$R_FIXED" ] || echo "ROUTE_FIXED_MODEL '$R_FIXED' is not an available registry id"; }
      for r in verifier reviewer security-auditor developer test-writer engineer devsecops scout analyst; do
        p="$(eval "printf '%s' \"\${ROUTE_PREFER_$(upper $r):-}\"")"
        [ -z "$p" ] || jq -e --arg i "$p" 'map(select(.id == $i and .status == "available")) | length > 0' <<< "$reg" >/dev/null 2>&1 || echo "ROUTE_PREFER_$(upper $r): '$p' is not an available registry id"
      done; } | sed '/^$/d')"
    if [ -n "$errs" ]; then printf '%s\n' "$errs" >&2; exit 2; fi
    echo "routing configuration ok (ROUTING=$ROUTING, policy $POLICY/$R_POLICY)"; exit 0 ;;
  log)
    s="${1:-$(slug_now)}"; f="$(ledger_of "$s")"; [ -f "$f" ] || { echo "no routing decisions recorded for $s"; exit 0; }
    jq -r 'if .type == "decision" then "\(.ts) \(.id) \(.role) \(.action) \(.adapter // "-")/\(.model // "default") tier=\(.tier // "-") attempt=\(.attempt) \(.reason)"
           else "\(.ts) \(.id) outcome \(.class) rc=\(.rc)" end' "$f"
    exit 0 ;;
  classify)
    rc=""; prc=""; err=""; while [ $# -gt 0 ]; do case "$1" in --rc) rc="$2"; shift ;; --prc) prc="$2"; shift ;; --stderr) err="$2"; shift ;; --role) shift ;; esac; shift; done
    isint "$rc" || { echo "classify needs --rc N" >&2; exit 2; }
    classify_text "$rc" "$prc" "$err"; exit 0 ;;
  reservations)  # reservations [list|expire] [--json]: the open reservations of every task; expire releases the stale ones (old AND owner process gone)
    act=list; js=0; for a in "$@"; do case "$a" in list|expire) act="$a" ;; --json) js=1 ;; *) echo "usage: route.sh reservations [list|expire] [--json]" >&2; exit 2 ;; esac; done
    l="$(reservations_open)" || { echo "reservations: a reservations.jsonl cannot be read (restore it; nothing is guessed)" >&2; exit 2; }
    if [ "$act" = expire ]; then
      n=0; while IFS=$'\t' read -r sl id usd age pid st; do [ "$st" = stale ] || continue
        release_reservation "$sl" "$id" EXPIRED "expired after ${age}s (older than ROUTE_RESERVE_TTL_S=$R_RTTL and its process ${pid:+$pid }is gone); released by route.sh reservations expire"; n=$((n + 1)); done <<< "$l"
      echo "reservations: expired $n stale reservation(s)"; exit 0
    fi
    if [ "$js" = 1 ]; then jq -Rn '[inputs | split("\t") | select(length >= 6) | {slug: .[0], id: .[1], usd: (.[2] | tonumber), age_s: (.[3] | tonumber), pid: (if .[4] == "" then null else (.[4] | tonumber) end), state: .[5]}]' <<< "$l"
    else [ -z "$l" ] && echo "no open reservations" || awk -F'\t' '{printf "%s\t%s\t$%s\tage %ss\t%s\n", $1, $2, $3, $4, $6}' <<< "$l"; fi
    exit 0 ;;
  decide|explain|outcome) ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- outcome: close a decided run
slug="$(slug_now)"; ledger="$(ledger_of "$slug")"
if [ "$cmd" = outcome ]; then
  did=""; rc=""; prc=""; err=""; dur=""; tin=""; tout=""; tq=unavailable; cest=""
  while [ $# -gt 0 ]; do case "$1" in --decision) did="$2"; shift ;; --rc) rc="$2"; shift ;; --prc) prc="$2"; shift ;; --stderr) err="$2"; shift ;;
    --dur-ms) dur="$2"; shift ;; --cost-est) cest="$2"; shift ;; --in) tin="$2"; shift ;; --out) tout="$2"; shift ;; --tokens) tq="$2"; shift ;; *) echo "unknown option $1" >&2; exit 2 ;; esac; shift; done
  [ -n "$did" ] && isint "$rc" || { echo "outcome needs --decision ID and --rc N" >&2; exit 2; }
  [ -f "$ledger" ] || { echo "no routing ledger for $slug" >&2; exit 2; }
  dec="$(jq -c --arg id "$did" 'select(.type == "decision" and .id == $id)' "$ledger" | tail -1)"
  [ -n "$dec" ] || { echo "unknown decision $did" >&2; exit 2; }
  cls="$(classify_text "$rc" "$prc" "$err")"
  if [ "$cls" = VERDICT_BLOCK ]; then [ "$(jq -r .role <<< "$dec")" = security-auditor ] && cls=SECURITY_BLOCK || cls=VERIFICATION_FAILURE; fi
  tj=null; [ "$tq" = actual ] && isint "$tin" && isint "$tout" && tj="$(jq -nc --argjson i "$tin" --argjson o "$tout" '{in:$i,out:$o}')"
  line="$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg id "$did" --arg cls "$cls" --argjson rc "$rc" --argjson d "$dec" --arg dur "$dur" --argjson tok "$tj" --arg tq "$tq" --arg cest "$cest" \
    '{v:1, type:"outcome", ts:$ts, id:$id, key:$d.key, role:$d.role, class:$cls, rc:$rc, dur_ms:(if $dur == "" then null else ($dur | tonumber) end), tokens:$tok, tokens_quality:(if $tok == null then "unavailable" else "actual" end)}
     + (if ($cest | test("^[0-9]+([.][0-9]+)?$")) then {host_cost_estimate_usd:($cest | tonumber), cost_provenance:"host client-side estimate (not billed)"} else {} end)')"
  sdkit_lock "$ledger"; printf '%s\n' "$line" >> "$ledger"; sdkit_unlock "$ledger"
  # reconcile: the reservation goes back to the pool whatever happened (idempotent); the actual spend is whatever the usage ledger now says (estimated, or unknown)
  release_reservation "$slug" "$did" "$cls"
  tele workflow.decision --source routing --outcome "outcome:$cls" --role "$(jq -r .role <<< "$dec")" --note "$did rc=$rc"
  echo "$cls"; exit 0
fi

# ---------------------------------------------------------------- decide / explain
role=""; host=""; want=""; model=""; handoff=""; risk_arg=""; rerun=""; nobudget=0; reqcli=0; reserve=0; pid=""; js=0; src=cli
while [ $# -gt 0 ]; do case "$1" in
  --role) role="$2"; shift ;; --host) host="$2"; shift ;; --tier) want="$2"; shift ;; --model) model="$2"; shift ;; --handoff) handoff="$2"; shift ;;
  --risk) risk_arg="$2"; shift ;; --rerun) rerun="$2"; shift ;; --ignore-budget) nobudget=1 ;; --require-cli) reqcli=1 ;; --reserve) reserve=1 ;;
  --pid) pid="$2"; shift ;; --json) js=1 ;; --source) src="$2"; shift ;; *) echo "unknown option $1" >&2; exit 2 ;; esac; shift; done
[ "$cmd" = explain ] && reserve=0
[ -n "$role" ] || { echo "--role is required" >&2; exit 2; }
[ -z "$pid" ] || isint "$pid" || { echo "--pid must be a number" >&2; exit 2; }

# decision state, filled in below; emit prints it
D_ACTION=execute; D_REASON=ROLE_CAPABILITY_MATCH; D_ADAPTER=""; D_MODEL=""; D_EFFORT=""; D_TIER=""; D_ENFORCED=true; D_ATTEMPT=1; D_MAND=false
D_CLASS=work; D_WAIT=0; D_PREV=null; D_NOTES=(); D_WARN=(); D_BUDGET='{}'; D_ID="rd-$slug-preview"; D_CLI=null; D_TIMEOUT=""
risk="" ; profile="standard"; D_RISKSRC=task

emit() {  # print the decision and leave with the exit status its action implies
  local rcx=0 notes warns
  case "$D_ACTION" in execute|retry|escalate) rcx=0 ;; reuse) rcx=7 ;; stop)
    case "$D_REASON" in BUDGET_EXHAUSTED) rcx=3 ;;
      CONFIG_INVALID|UNKNOWN_ROLE|NO_ADAPTER|ADAPTER_UNSUPPORTED|NO_COMPATIBLE_MODEL|OVERRIDE_INVALID|OVERRIDE_BELOW_FLOOR|PREFERENCE_INVALID|PREFERENCE_BELOW_FLOOR|FIXED_INVALID|FIXED_BELOW_FLOOR|NO_ESCALATION_TARGET) rcx=2 ;;
      *) rcx=8 ;; esac ;;
  esac
  notes="$(printf '%s\n' ${D_NOTES[@]+"${D_NOTES[@]}"})"; warns="$(printf '%s\n' ${D_WARN[@]+"${D_WARN[@]}"})"   # newline lists; split inside the one jq below
  local j
  j="$(jq -nc --arg id "$D_ID" --arg task "$slug" --arg role "$role" --arg action "$D_ACTION" --arg adapter "$D_ADAPTER" --arg model "$D_MODEL" --arg effort "$D_EFFORT" --arg tier "$D_TIER" \
    --argjson enforced "$D_ENFORCED" --argjson attempt "$D_ATTEMPT" --arg reason "$D_REASON" --arg pol "$POLICY" --arg mand "$D_MAND" --arg cls "$D_CLASS" --arg risk "$risk" \
    --arg profile "$profile" --argjson wait "$D_WAIT" --argjson prev "$D_PREV" --arg notes "$notes" --arg warns "$warns" --argjson budget "$D_BUDGET" --arg routing "$ROUTING" --arg timeout "$D_TIMEOUT" --arg rsrc "$D_RISKSRC" \
    '($notes | split("\n") | map(select(. != ""))) as $notes | ($warns | split("\n") | map(select(. != ""))) as $warns
    | {decision_id:$id, task:$task, role:$role, role_class:$cls, mandatory:($mand == "true"), risk:(if $risk == "" then null else $risk end), risk_source:$rsrc, profile:$profile,
      action:$action, adapter:(if $adapter == "" then null else $adapter end), model:(if $model == "" then null else $model end), effort:(if $effort == "" then null else $effort end),
      tier:(if $tier == "" then null else $tier end), tier_enforced:$enforced, timeout_s:(if $timeout == "" then null else ($timeout | tonumber) end),
      budget:$budget, attempt:$attempt, wait_s:$wait, reason:$reason, policy_version:$pol, routing:$routing}
     + (if $prev != null then {previous:$prev} else {} end) + (if ($notes | length) > 0 then {notes:$notes} else {} end) + (if ($warns | length) > 0 then {warnings:$warns} else {} end)')"
  if [ "$reserve" = 1 ]; then
    mkdir -p "$work/$slug" 2>/dev/null
    printf '%s\n' "$(jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg key "$KEY" --arg pid "$pid" --arg src "$src" '. + {id:.decision_id, v:1, type:"decision", ts:$ts, key:$key, source:$src, pid:(if $pid == "" then null else ($pid | tonumber) end)} | del(.decision_id)' <<< "$j")" >> "$ledger"
    tele workflow.decision --source routing --outcome "$D_ACTION" --role "$role" --host "$D_ADAPTER" --model "$D_MODEL" --tier "$D_TIER" --attempt "$D_ATTEMPT" --note "$D_REASON $D_ID"
  fi
  if [ "$cmd" = explain ]; then
    jq -r '"Task: \(.task)\nRisk: \(.risk // "unknown") (profile \(.profile))\nRole: \(.role) (\(.role_class)\(if .mandatory then ", mandatory" else "" end))\n"
      + "Decision: \(.action)\nAdapter: \(.adapter // "-")\nModel: \(.model // "host default") (tier \(.tier // "-")\(if .tier_enforced then "" else ", NOT enforced: the host default model is used" end)\(if .effort then ", effort \(.effort)" else "" end))\nReason: \(.reason)\n"
      + "Budget: " + ([.budget | to_entries[] | select(.value | type == "object" and has("enforcement")) | "\(.key)=\(.value.enforcement)"] + (if .budget.timeout_s then ["timeout=\(.budget.timeout_enforcement)"] else [] end) | if length == 0 then "none configured" else join(" ") end)
      + "\nPolicy: \(.policy_version)  Routing: \(.routing)\(if .routing == "off" then " (run-role.sh ignores this decision until ROUTING=on)" else "" end)"
      + (if .warnings then "\nWarnings: " + (.warnings | join("; ")) else "" end) + (if .notes then "\nNotes: " + (.notes | join("; ")) else "" end)' <<< "$j"
  else printf '%s\n' "$j"; fi
  exit "$rcx"
}
stop() { D_ACTION=stop; D_REASON="$1"; [ -n "${2:-}" ] && D_NOTES+=("$2"); emit; }

KEY=""
if [ "$reserve" = 1 ]; then   # one decision at a time per task: the in-flight check and the record below must not interleave with another request
  D_ID="rd-$slug-$(date +%s)-$$-$RANDOM"; mkdir -p "$work/$slug" 2>/dev/null
  # lock order is fixed: the PROJECT lock (project-wide money decisions) first, then the task's ledger lock; nothing takes them the other way round
  if [ "${ROUTE_COST_ENFORCE:-off}" = hard ]; then sdkit_lock "$work/.project-budget"; plocked=1; fi
  sdkit_lock "$ledger"; trap 'sdkit_unlock "$ledger"; [ "${plocked:-0}" = 1 ] && sdkit_unlock "$work/.project-budget"' EXIT
fi
cerr="$(cfg_errors | head -3 | paste -sd';' -)"; [ -z "$cerr" ] || stop CONFIG_INVALID "$cerr"
REG="$(registry_build 2>&1)" || stop CONFIG_INVALID "$REG"   # built once per decision
rerr="$(registry_errors "$REG" | head -3 | paste -sd';' -)"; [ -z "$rerr" ] || stop CONFIG_INVALID "$rerr"

# --- role
base="${role%-deep}"; rsrc="$(role_src "$role")" || stop UNKNOWN_ROLE "no role text for '$base'"
rtier="$(fm "$rsrc" tier)"; [ -n "$rtier" ] || rtier=standard; access="$(fm "$rsrc" access)"
[ "$role" != "$base" ] && { d="$(fm "$rsrc" deep)"; [ -n "$d" ] && rtier="$d"; }
case "$base" in verifier|reviewer|security-auditor) D_CLASS=gate ;; scout|analyst) D_CLASS=lookup ;; *) D_CLASS=work ;; esac

# --- task facts: risk, profile and mandatory-ness come from the workflow policy (workflow.sh), never restated here
if [ -f "$sdd_state" ] && [ -x "$here/workflow.sh" ]; then
  pj="$(CLAUDE_PROJECT_DIR="$top" "$here/workflow.sh" policy --json 2>/dev/null)"
  risk="$(jq -r '.risk // empty' <<< "$pj" 2>/dev/null)"; profile="$(jq -r '.profile // "standard"' <<< "$pj" 2>/dev/null)"
  ver="$(jq -r '.verifier // empty' <<< "$pj" 2>/dev/null)"; evroles="$(jq -r '(.evidence_roles // []) | join(" ")' <<< "$pj" 2>/dev/null)"
  case " $evroles " in *" $base "*) D_MAND=true ;; esac
  [ "$base" = verifier ] && [ "$ver" = independent-verifier ] && D_MAND=true
fi
[ -n "$risk_arg" ] && { risk="$risk_arg"; D_RISKSRC=flag; }
case "$risk" in low|medium|high) ;; "") D_RISKSRC=assumed; D_NOTES+=("no open task: risk assumed medium, no downgrade") ;; *) stop CONFIG_INVALID "risk must be low|medium|high" ;; esac
eff_risk="${risk:-medium}"

# --- key of this request: what makes two requests "the same" (role + handoff + the diff, for roles whose evidence is bound to it)
hsum="-"; [ -n "$handoff" ] && [ -f "$handoff" ] && hsum="$(shasum -a 256 "$handoff" | cut -c1-16)"
fp=""
evj=""   # one sdd.sh call gives both the diff fingerprint and every role's evidence state (the diff is hashed once, not twice)
if [ "$D_CLASS" = gate ] && [ -f "$sdd_state" ]; then
  evj="$(CLAUDE_PROJECT_DIR="$top" "$here/sdd.sh" evidence --json --with-fingerprint 2>/dev/null)"
  fp="$(jq -r '.fingerprint // empty' <<< "$evj" 2>/dev/null | cut -c1-16)"
fi
KEY="$base|$hsum|${fp:--}"

# --- evidence: reuse what sdd.sh calls valid (it is the one judge of validity: trusted run, this task, this diff, no shared run), never re-judge a BLOCK
#     that stands for this diff, otherwise (missing / stale / untrusted / conflict) run the role
if [ "$D_CLASS" = gate ] && [ -f "$sdd_state" ] && [ -n "$fp" ]; then
  evs="$(jq -r --arg r "$base" '.roles[] | select(.role == $r) | [.state, .verdict, .run] | @tsv' <<< "$evj")"
  ev_state="${evs%%$'\t'*}"; ev_run="${evs##*$'\t'}"
  ev_bfp="$(jq -r --arg r "$base" '.evidence[$r] | select(.result == "BLOCK") | .fingerprint // empty' "$sdd_state" 2>/dev/null | cut -c1-16)"
  if [ -n "$ev_bfp" ] && [ "$ev_bfp" = "$fp" ]; then
    [ "$base" = security-auditor ] && stop SECURITY_BLOCK "the $base BLOCKed this diff; a BLOCK is not re-run on the same diff (another model or provider cannot overturn it): change the diff first"
    stop VERIFICATION_FAILED "the $base BLOCKed this diff; fix it (state.sh retry) so the diff changes, then run the $base again"
  fi
  case "$ev_state" in
    valid) if [ -z "$rerun" ]; then D_ACTION=reuse; D_REASON=EVIDENCE_REUSED; D_NOTES+=("valid trusted $base PASS for this diff (run ${ev_run:--})"); emit; fi ;;
    missing|"") ;;
    *) D_NOTES+=("recorded $base evidence is not valid for this diff ($ev_state): running it again") ;;
  esac
fi

# --- chain: previous attempts of this exact request (same role, same handoff, same diff)
a_n=0; a_retry=0; a_esc=0; l_class=""; l_tier=""; l_adapter=""; l_model=""; l_effort=""; l_enforced=true; l_id=""; failed_adapters=""; same_class=0
if [ -f "$ledger" ]; then
  chain="$(jq -sc --arg k "$KEY" '[.[] | select(.key == $k)]' "$ledger" 2>/dev/null || echo '[]')"
  # a decision that never got an outcome is in flight while its process lives (or, with no pid, until the TTL), else it was interrupted
  while IFS=$'\t' read -r oid opid ots; do
    [ -n "$oid" ] || continue
    alive=0
    if [ -n "$opid" ] && [ "$opid" != null ]; then kill -0 "$opid" 2>/dev/null && alive=1
    else [ $(( $(now_s) - $(date -u -j -f %Y-%m-%dT%H:%M:%SZ "$ots" +%s 2>/dev/null || date -u -d "$ots" +%s 2>/dev/null || echo 0) )) -lt "$R_TTL" ] && alive=1; fi
    if [ "$alive" = 1 ]; then stop DUPLICATE_IN_FLIGHT "decision $oid for the same request is still running (pid ${opid:--})"; fi
    # interrupted: close it so it counts as a failed attempt
    if [ "$reserve" = 1 ]; then
      printf '%s\n' "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg id "$oid" --arg k "$KEY" --arg r "$base" '{v:1,type:"outcome",ts:$ts,id:$id,key:$k,role:$r,class:"INTERRUPTED",rc:null,dur_ms:null,tokens:null,tokens_quality:"unavailable"}')" >> "$ledger"
      chain="$(jq -sc --arg k "$KEY" '[.[] | select(.key == $k)]' "$ledger")"
    else chain="$(jq -c --arg id "$oid" --arg k "$KEY" '. + [{type:"outcome",id:$id,key:$k,class:"INTERRUPTED"}]' <<< "$chain")"; fi
  done < <(jq -r '(map(select(.type == "outcome") | .id)) as $done | .[] | select(.type == "decision" and (.action | IN("execute","retry","escalate")) and (.id as $i | $done | index($i) | not)) | [.id, (.pid // "null"), .ts] | @tsv' <<< "$chain")
  a_n="$(jq '[.[] | select(.type == "decision" and (.action | IN("execute","retry","escalate")))] | length' <<< "$chain")"
  a_retry="$(jq '[.[] | select(.type == "decision" and .action == "retry")] | length' <<< "$chain")"
  a_esc="$(jq '[.[] | select(.type == "decision" and .action == "escalate")] | length' <<< "$chain")"
  last="$(jq -c '[.[] | select(.type == "decision" and (.action | IN("execute","retry","escalate")))] | last // null' <<< "$chain")"
  if [ "$last" != null ]; then
    l_id="$(jq -r .id <<< "$last")"; l_tier="$(jq -r '.tier // ""' <<< "$last")"; l_adapter="$(jq -r '.adapter // ""' <<< "$last")"; l_model="$(jq -r '.model // ""' <<< "$last")"
    l_effort="$(jq -r '.effort // ""' <<< "$last")"; l_enforced="$(jq -r '.tier_enforced' <<< "$last")"
    l_class="$(jq -r --arg id "$l_id" '[.[] | select(.type == "outcome" and .id == $id)] | last | .class // ""' <<< "$chain")"
    same_class="$(jq -r --arg c "$l_class" '[.[] | select(.type == "outcome" and .class == $c)] | length' <<< "$chain")"
    failed_adapters="$(jq -r '[.[] | select(.type == "outcome" and .class == "HOST_MISSING") | .id] as $ids | [.[] | select(.type == "decision" and (.id as $i | $ids | index($i))) | .adapter] | unique | join(" ")' <<< "$chain")"
  fi
fi
D_ATTEMPT=$((a_n + 1))
mode=fresh; retry_note=""
if [ -n "$l_class" ] && [ -z "$rerun" ]; then
  D_PREV="$(jq -nc --arg id "$l_id" --arg c "$l_class" '{decision_id:$id, failure_class:$c}')"
  [ "$a_n" -ge "$R_ATTEMPTS" ] && stop RETRIES_EXHAUSTED "attempt limit ROUTE_MAX_ATTEMPTS=$R_ATTEMPTS reached (last failure $l_class)"
  case "$l_class" in
    OK) [ "$D_CLASS" = gate ] && { mode=fresh; D_NOTES+=("a previous run exited ok but left no valid evidence"); } || stop DUPLICATE_COMPLETED "this exact request already completed; pass --rerun <reason> to run it again" ;;
    TRANSIENT|RATE_LIMIT|TIMEOUT|INTERRUPTED)
      [ "$a_retry" -ge "$R_RETRIES" ] && stop RETRIES_EXHAUSTED "infrastructure retry limit ROUTE_MAX_RETRIES=$R_RETRIES reached after $l_class"
      mode=retry; D_REASON="RETRY_$l_class"; [ "$l_class" = RATE_LIMIT ] && D_WAIT=$(( R_BACKOFF * (a_retry + 1) )) ;;
    INVALID_OUTPUT|CONTRACT_FAILURE)
      if [ "$same_class" -le 1 ] && [ "$a_retry" -lt "$R_RETRIES" ]; then mode=retry; D_REASON="RETRY_$l_class"
      elif [ "$a_esc" -lt "$R_ESCS" ]; then mode=escalate; D_REASON="ESCALATE_$l_class"
      else stop ESCALATION_LIMIT "$l_class repeated and ROUTE_MAX_ESCALATIONS=$R_ESCS is used"; fi ;;
    HOST_MISSING) mode=fallback ;;
    SECURITY_BLOCK) stop SECURITY_BLOCK "a BLOCK is final for this request; changing provider does not change it" ;;
    VERIFICATION_FAILURE) stop VERIFICATION_FAILED "the role reported BLOCK; fix the change (state.sh retry), then ask again with a new request" ;;
    REPORTED_FAILURE) stop REPORTED_FAILURE "the role reported partial|blocked|failed: that is a code-correction decision for the workflow, not an infrastructure retry" ;;
    BUDGET_EXHAUSTED|NOT_RUN) mode=fresh ;;
    *) stop UNCLASSIFIED_FAILURE "failure class $l_class has no automatic retry; read the host's error and decide" ;;
  esac
elif [ -n "$l_class" ] && [ -n "$rerun" ]; then D_REASON=RERUN_REQUESTED; D_NOTES+=("rerun: $(printf '%s' "$rerun" | tr '\n' ' ' | cut -c1-80)")
fi
[ "$mode" = retry ] && D_ACTION=retry; [ "$mode" = escalate ] && D_ACTION=escalate; [ "$mode" = fallback ] && D_ACTION=retry

# --- tier: role's own tier, size override (run-role --tier), then the risk floors. Independent roles never go below their own tier.
needed="$rtier"; why_tier=""
if [ -n "$want" ]; then
  case "$want" in small) want=light ;; medium) want=standard ;; large) want=strong ;; esac
  [ "$(rank "$want")" != 0 ] || stop CONFIG_INVALID "--tier must be light|standard|strong (or small|medium|large)"
  if [ "$D_CLASS" = gate ]; then [ "$(rank "$want")" -gt "$(rank "$needed")" ] && needed="$want"; else needed="$want"; fi
elif [ "$R_DOWN" = 1 ] && [ "$D_CLASS" = work ] && [ "$risk" = low ] && [ "$rtier" = standard ]; then needed=light; why_tier=DOWNGRADE_LOW_RISK
fi
if [ "$D_CLASS" != lookup ]; then
  case "$eff_risk" in low) fl="$R_FLOOR_LOW" ;; medium) fl="$R_FLOOR_MED" ;; high) fl="$R_FLOOR_HIGH" ;; esac
  [ "$base" = verifier ] && [ "$risk" = high ] && [ "$(rank "$(fm "$rsrc" deep)")" -gt "$(rank "$fl")" ] && fl="$(fm "$rsrc" deep)"   # high-risk verification is the deep tier
  if [ "$(rank "$fl")" -gt "$(rank "$needed")" ]; then needed="$fl"; why_tier=RISK_FLOOR_APPLIED; fi
  # a downgrade must never undercut a gate role's own tier (the downgrade branch above only applies to work roles)
fi
if [ "$mode" = escalate ]; then
  [ "$l_enforced" = true ] || stop NO_ESCALATION_TARGET "the previous attempt ran on the host default model, whose tier cannot be raised"
  nr=$(( $(rank "${l_tier:-$needed}") + 1 ))
  [ "$nr" -le "$(rank "$R_ESCTO")" ] || stop NO_ESCALATION_TARGET "already at the escalation ceiling ROUTE_ESCALATE_TO=$R_ESCTO"
  needed="$(tier_of_rank "$nr")"; why_tier=ESCALATION
fi

# --- adapter candidates
primary="$host"
[ -n "$primary" ] || { [ "$D_CLASS" = gate ] && primary="${VERIFIER_HOST:-}"; }
[ -n "$primary" ] || primary="${RUN_ROLE_HOST:-}"
reg="$REG"
pref="$(eval "printf '%s' \"\${ROUTE_PREFER_$(upper "$base"):-}\"")"
prefe=""; fixede=""
if [ -n "$pref" ] && [ -z "$model" ]; then
  prefe="$(jq -c --arg i "$pref" '[.[] | select(.id == $i and .status == "available")][0] // empty' <<< "$reg")"
  [ -n "$prefe" ] || stop PREFERENCE_INVALID "ROUTE_PREFER_$(upper "$base")='$pref' is not an available registry id"
fi
if [ "$R_POLICY" = fixed ]; then
  fixede="$(jq -c --arg i "$R_FIXED" '[.[] | select(.id == $i and .status == "available")][0] // empty' <<< "$reg")"
  [ -n "$fixede" ] || stop FIXED_INVALID "ROUTE_FIXED_MODEL='$R_FIXED' is not an available registry id"
fi
cands=""
if [ -n "$host" ]; then cands="$host"
elif [ "$mode" != fresh ] && [ -n "$l_adapter" ] && [ "$mode" != fallback ]; then cands="$l_adapter"
elif [ -n "$fixede" ]; then cands="$(jq -r .adapter <<< "$fixede")"
elif [ -n "$prefe" ]; then cands="$(jq -r .adapter <<< "$prefe")"
else cands="$primary${R_FALLBACK:+ $R_FALLBACK}"; fi
cands="$(printf '%s\n' $cands | awk 'NF && !seen[$0]++' | paste -sd' ' -)"
[ -n "$cands" ] || stop NO_ADAPTER "no host: pass --host or set RUN_ROLE_HOST (VERIFIER_HOST for independent roles) in $KIT_DIR/$KIT_ENV"
if [ -n "$fixede" ] && [ -n "$host" ] && [ "$host" != "$(jq -r .adapter <<< "$fixede")" ]; then stop OVERRIDE_INVALID "--host $host conflicts with ROUTE_FIXED_MODEL ($R_FIXED runs on $(jq -r .adapter <<< "$fixede"))"; fi

pick=""; first=""; lastwhy=NO_COMPATIBLE_MODEL; lastnote=""; n_try=0
for a in $cands; do
  n_try=$((n_try + 1)); [ -n "$first" ] || first="$a"
  case " $failed_adapters " in *" $a "*) continue ;; esac
  IFS=$'\x1f' read -r a_known caps_ok a_cli < <(jq -r --arg a "$a" 'if has($a) then ["yes", (.[$a].caps | (.noninteractive != "none" and .tool_use != "none") | tostring), .[$a].cli] else ["no", "", ""] end | join("\u001f")' "$ADAPTERS")
  [ "$a_known" = yes ] || { lastwhy=ADAPTER_UNSUPPORTED; lastnote="unknown adapter '$a'"; continue; }
  [ "$caps_ok" = true ] || { lastwhy=ADAPTER_UNSUPPORTED; lastnote="adapter $a cannot run noninteractively with tools"; continue; }
  if [ "$reqcli" = 1 ]; then c="$a_cli"; command -v "$c" >/dev/null 2>&1 || { lastwhy=ADAPTER_UNSUPPORTED; lastnote="CLI '$c' (adapter $a) is not installed"; failed_adapters="$failed_adapters $a"; continue; }; fi
  # eligible: this adapter, available, handles the role, and (unless it is the host default) at least the needed tier
  elig="$(jq -c --arg a "$a" --arg r "$base" --argjson need "$(rank "$needed")" '
    def rk: {"light":1,"standard":2,"strong":3}[.] // 0;
    [.[] | select(.adapter == $a and .status == "available" and (.roles == "*" or ((.roles // []) | index($r)) != null) and (.tier == "*" or (.tier | rk) >= $need))]
    | sort_by(if .tier == "*" then 99 else (.tier | rk) end)' <<< "$reg")"
  if [ -n "$model" ]; then   # explicit model: must be a registry entry of this adapter, and not below the floor
    ent="$(jq -c --arg m "$model" '[.[] | select(.model == $m or .id == $m)][0] // empty' <<< "$(jq -c --arg a "$a" '[.[] | select(.adapter == $a)]' <<< "$reg")")"
    [ -n "$ent" ] || { lastwhy=OVERRIDE_INVALID; lastnote="model '$model' is not in the registry for adapter $a (route.sh registry; add it to $KIT_DIR/models.json)"; continue; }
    [ "$(jq -r .status <<< "$ent")" = available ] || { lastwhy=OVERRIDE_INVALID; lastnote="model '$model' is disabled"; continue; }
    jq -e --arg id "$(jq -r .id <<< "$ent")" 'map(.id == $id) | any' <<< "$elig" >/dev/null || { lastwhy=OVERRIDE_BELOW_FLOOR; lastnote="model '$model' ($(jq -r .tier <<< "$ent")) is below the required tier $needed or not allowed for $base"; continue; }
    pick="$ent"; D_REASON=OVERRIDE_APPLIED; break
  elif [ -n "$fixede" ]; then
    jq -e --arg id "$(jq -r .id <<< "$fixede")" 'map(.id == $id) | any' <<< "$elig" >/dev/null || { lastwhy=FIXED_BELOW_FLOOR; lastnote="ROUTE_FIXED_MODEL $R_FIXED is below the required tier $needed or not allowed for $base: a fixed policy never lowers a floor"; continue; }
    pick="$fixede"; D_REASON=FIXED_POLICY; break
  elif [ -n "$prefe" ]; then
    jq -e --arg id "$(jq -r .id <<< "$prefe")" 'map(.id == $id) | any' <<< "$elig" >/dev/null || { lastwhy=PREFERENCE_BELOW_FLOOR; lastnote="ROUTE_PREFER_$(upper "$base")=$pref is below the required tier $needed or not allowed for $base"; continue; }
    pick="$prefe"; D_REASON=PREFERENCE_APPLIED; break
  elif [ "$mode" != fresh ] && [ "$mode" != escalate ] && [ "$mode" != fallback ] && [ -n "$l_adapter$l_model" ]; then
    pick="$(jq -c --arg a "$l_adapter" --arg m "$l_model" --arg e "$l_effort" '[.[] | select(.adapter == $a and ((.model // "") == $m) and ((.effort // "") == $e))][0] // empty' <<< "$reg")"
    [ -n "$pick" ] && break
  fi
  pick="$(jq -c '.[0] // empty' <<< "$elig")"
  [ -n "$pick" ] && break
  lastwhy=NO_COMPATIBLE_MODEL; lastnote="no available $a model for role $base at tier $needed or above (route.sh registry)"
done
if [ -z "$pick" ]; then
  [ "$mode" = escalate ] && stop NO_ESCALATION_TARGET "$lastnote"
  stop "$lastwhy" "$lastnote"
fi
# one jq for everything read from the pick and its adapter (each jq is a process: ~25 ms on this machine)
IFS=$'\x1f' read -r D_ADAPTER D_MODEL D_EFFORT pick_tier D_CLI model_sel adapt_usage < <(jq -r --slurpfile a "$ADAPTERS" '[.adapter, (.model // ""), (.effort // ""), .tier, $a[0][.adapter].cli, $a[0][.adapter].caps.model_selection, $a[0][.adapter].caps.usage_reporting] | join("\u001f")' <<< "$pick")
D_TIER="$needed"; [ "$pick_tier" = "*" ] && { D_ENFORCED=false; D_WARN+=("MODEL_INHERITED: adapter $D_ADAPTER has no configured model for tier $needed, so the host's default model runs; its capability tier is not verified"); }
# a model needs model selection support (every shipped adapter declares it; a project may state otherwise)
if [ -n "$D_MODEL" ] && [ "$model_sel" = none ]; then stop ADAPTER_UNSUPPORTED "adapter $D_ADAPTER cannot select a model, so $D_MODEL cannot be honoured"; fi
[ "$D_REASON" = ROLE_CAPABILITY_MATCH ] && [ -n "$why_tier" ] && D_REASON="$why_tier"
[ "$mode" = escalate ] && D_REASON="ESCALATE_${l_class}"
[ "$mode" = fallback ] && { D_REASON=ADAPTER_FALLBACK; D_NOTES+=("adapter(s) failed with HOST_MISSING: ${failed_adapters# }"); }
if [ "$mode" = fresh ] && [ "$D_ADAPTER" != "$first" ] && [ -z "$host" ]; then D_REASON=ADAPTER_FALLBACK; D_NOTES+=("$first could not run this role: $lastnote"); fi

# --- budget. Hard = checked at the spawn boundary, so no further run starts; the run itself is only as bounded as the host allows.
mode_sdd="${SDD_MODE:-strict}"
used_n=0; used_un=0; used_tok=0; roleused=0; est=null; est_complete=true; hc=null; hcn=0
uf="$work/$slug/usage.jsonl"
if [ -f "$uf" ]; then
  ub="$(jq -sc --arg r "$base" --argjson pt "$PT" "$PJQ"'
    def tq: (.tq // "actual");
    map(select(type == "object") | nrm) |
    {n: length, un: (map(select(tq == "unavailable")) | length),
     tok: (map(select(tq != "unavailable") | (.in + .out + .cache_write)) | add // 0),
     role: (map(select((.role // "" | sub("-deep$"; "")) == $r and tq != "unavailable") | (.in + .out + .cache_write)) | add // 0),
     hc: (map(.cost_est_usd // empty) | if length == 0 then null else add end), hcn: (map(select(.cost_est_usd != null)) | length),
     priced: (map(select(tq != "unavailable" and cost_of(.) != null))), unpriced: (map(select(tq == "unavailable" or cost_of(.) == null)) | length)}
    | . + {est: (if (.priced | length) == 0 then null else (.priced | map(cost_of(.)) | add) end)}' "$uf" 2>/dev/null)"
  if [ -n "$ub" ]; then used_n="$(jq .n <<< "$ub")"; used_un="$(jq .un <<< "$ub")"; used_tok="$(jq .tok <<< "$ub")"; roleused="$(jq .role <<< "$ub")"; est="$(jq .est <<< "$ub")"; hc="$(jq .hc <<< "$ub")"; hcn="$(jq .hcn <<< "$ub")"; [ "$(jq .unpriced <<< "$ub")" = 0 ] || est_complete=false; fi
fi
acct=complete; [ "$used_un" -gt 0 ] && acct=partial; [ "$used_n" -gt 0 ] && [ "$used_un" = "$used_n" ] && acct=unavailable
tok_enf=hard; { [ "$acct" != complete ] || [ "$adapt_usage" = none ]; } && tok_enf=advisory
[ "$adapt_usage" = none ] && [ -n "${TOKEN_BUDGET_TASK:-}${ROUTE_ROLE_TOKENS:-}" ] && D_WARN+=("USAGE_UNAVAILABLE: adapter $D_ADAPTER reports no token usage, so token budgets are advisory (runs on it are not counted)")
[ "$acct" = partial ] && D_WARN+=("USAGE_PARTIAL: $used_un of $used_n earlier run(s) reported no token usage; the used figure is a lower bound")
over=""; warnpct=0; bj='{}'
spawns_used=0; [ -f "$work/$slug/state.json" ] && spawns_used="$(jq -r '.spawns // 0' "$work/$slug/state.json" 2>/dev/null)"
if isint "${MAX_SPAWNS:-}" && [ "${MAX_SPAWNS:-0}" != 0 ]; then
  bj="$(jq -c --argjson l "$MAX_SPAWNS" --argjson u "$spawns_used" '. + {invocations:{limit:$l, used:$u, remaining:([$l - $u, 0] | max), enforcement:"hard"}}' <<< "$bj")"
  [ $((spawns_used + 1)) -gt "$MAX_SPAWNS" ] && over="${over:+$over; }invocation limit MAX_SPAWNS=$MAX_SPAWNS reached ($spawns_used used)"
fi
if isint "${TOKEN_BUDGET_TASK:-}" && [ "${TOKEN_BUDGET_TASK:-0}" != 0 ]; then
  used_j="$used_tok"; [ "$acct" = unavailable ] && used_j=null
  rem="$(( TOKEN_BUDGET_TASK > used_tok ? TOKEN_BUDGET_TASK - used_tok : 0 ))"; [ "$acct" = unavailable ] && rem=null
  bj="$(jq -c --argjson l "$TOKEN_BUDGET_TASK" --argjson u "$used_j" --argjson r "$rem" --arg e "$tok_enf" '. + {task_tokens:{limit:$l, used:$u, remaining:$r, enforcement:$e, scope:"no new run starts at or over the limit; a running process is not cut off"}}' <<< "$bj")"
  if [ "$acct" != unavailable ] && [ "$used_tok" -ge "$TOKEN_BUDGET_TASK" ]; then over="${over:+$over; }task token budget TOKEN_BUDGET_TASK=$TOKEN_BUDGET_TASK reached ($used_tok used)"; fi
  wp="${TOKEN_BUDGET_WARN_PCT:-70}"; isint "$wp" || wp=70; [ "$acct" != unavailable ] && [ $((used_tok * 100 / TOKEN_BUDGET_TASK)) -ge "$wp" ] && warnpct=1
fi
if isint "${ROUTE_ROLE_TOKENS:-}" && [ "${ROUTE_ROLE_TOKENS:-0}" != 0 ]; then
  rem="$(( ROUTE_ROLE_TOKENS > roleused ? ROUTE_ROLE_TOKENS - roleused : 0 ))"
  bj="$(jq -c --argjson l "$ROUTE_ROLE_TOKENS" --argjson u "$roleused" --argjson r "$rem" --arg e "$tok_enf" '. + {role_tokens:{limit:$l, used:$u, remaining:$r, enforcement:$e}}' <<< "$bj")"
  [ "$roleused" -ge "$ROUTE_ROLE_TOKENS" ] && over="${over:+$over; }role token budget ROUTE_ROLE_TOKENS=$ROUTE_ROLE_TOKENS reached for $base ($roleused used)"
fi
bj="$(jq -c --argjson l "$R_ATTEMPTS" --argjson u "$a_n" '. + {attempts:{limit:$l, used:$u, enforcement:"hard"}}' <<< "$bj")"
tcmd=""; command -v timeout >/dev/null 2>&1 && tcmd=timeout; [ -z "$tcmd" ] && command -v gtimeout >/dev/null 2>&1 && tcmd=gtimeout
if isint "${ROUTE_TIMEOUT_S:-}" && [ "${ROUTE_TIMEOUT_S:-0}" != 0 ]; then
  D_TIMEOUT="$ROUTE_TIMEOUT_S"; te=hard; [ -n "$tcmd" ] || { te=advisory; D_WARN+=("TIMEOUT_ADVISORY: no timeout/gtimeout command, so ROUTE_TIMEOUT_S is only recorded, not enforced"); }
  bj="$(jq -c --argjson t "$ROUTE_TIMEOUT_S" --arg e "$te" '. + {timeout_s:$t, timeout_enforcement:$e}' <<< "$bj")"
fi
if [ -n "${ROUTE_BUDGET_COST:-}" ]; then
  # money: estimated from the token ledger and the user's pricing table only; no adapter reports an actual cost, so this limit is advisory
  bj="$(jq -c --argjson l "$ROUTE_BUDGET_COST" --argjson e "$est" --argjson c "$est_complete" --argjson hc "$hc" --argjson hn "$hcn" '. + {cost:{limit_usd:$l, estimated_usd:$e, actual_usd:null, estimate_complete:$c, host_reported_estimate_usd:$hc, host_reported_runs:$hn, host_reported_provenance:"the host'"'"'s own client-side estimate, not a billed amount", enforcement:"advisory"}}' <<< "$bj")"
  if [ "$hc" != null ] && awk -v e="$hc" -v l="$ROUTE_BUDGET_COST" 'BEGIN{exit !(e >= l)}'; then D_WARN+=("COST_HOST_ESTIMATE_OVER_BUDGET: the host reports an estimated \$$hc of \$$ROUTE_BUDGET_COST (its own client-side estimate, not a bill; advisory, not a stop)"); fi
  if [ "$est" = null ] && [ "$hc" = null ]; then D_WARN+=("COST_UNMEASURABLE: no priced usage yet (needs token usage and $KIT_DIR/pricing.json); ROUTE_BUDGET_COST is not evaluated")
  elif [ "$est" != null ] && awk -v e="$est" -v l="$ROUTE_BUDGET_COST" 'BEGIN{exit !(e >= l)}'; then D_WARN+=("COST_ESTIMATE_OVER_BUDGET: estimated \$$est of \$$ROUTE_BUDGET_COST (advisory; not a stop)"); fi
fi
# F14 hard cost policy (opt-in): ROUTE_COST_ENFORCE=hard turns the money limits into a stop at the spawn boundary, with reservations. Money stays an
# ESTIMATE from the user's price table. A scope with an unpriced or unmeasured run, or a model with no price, is UNKNOWN, and unknown never passes a hard limit.
if [ "${ROUTE_COST_ENFORCE:-off}" = hard ]; then
  # Fail closed: any value or calculation that cannot be trusted is a CONFIG_INVALID stop (not overridable by --ignore-budget), never an empty or zero figure.
  hfail() { D_NOTES+=("ROUTE_COST_ENFORCE=hard fails closed: $1"); stop CONFIG_INVALID; }
  PRICE_PROBE="$(jq -n --argjson pt "$PT" --arg m "$D_MODEL" --arg d "$(date -u +%Y-%m-%d)" "$PJQ"'rate({model: $m, provider: "", ts: $d}) // null')" || hfail "the price table could not be evaluated"
  price_known=no; [ "$D_MODEL" != "" ] && [ "$PRICE_PROBE" != null ] && price_known=yes
  # the reservation this run holds: ROUTE_RESERVE_USD if given (validated > 0), else a conservative figure derived from the token cap and the model's dearest rate
  resv="${ROUTE_RESERVE_USD:-}"; resv_basis="ROUTE_RESERVE_USD"
  if [ -z "$resv" ]; then
    cap="${ROUTE_ROLE_TOKENS:-}"; [ -n "$cap" ] && [ "$cap" != 0 ] || cap="${TOKEN_BUDGET_TASK:-}"
    if isint "$cap" && [ "${cap:-0}" != 0 ] && [ "$price_known" = yes ]; then
      mr="$(jq -nr --argjson e "$PRICE_PROBE" '[$e.in, $e.out, $e.cache_read, $e.cache_write | select(type == "number")] | max // empty' 2>/dev/null)" && isnum "$mr" && resv="$(awk -v m="$mr" -v c="$cap" 'BEGIN{printf "%.6f", m * c / 1000000}')" || resv=""
      resv_basis="derived: token cap $cap x the dearest rate of $D_MODEL (every token priced at it)"
    fi
  fi
  ispos "$resv" || hfail "no usable reservation: set ROUTE_RESERVE_USD to a number > 0 (USD held per running role), or set ROUTE_ROLE_TOKENS/TOKEN_BUDGET_TASK and a price for the model so one can be derived"
  openr="$(open_reserved)" && isnum "$openr" || hfail "open reservations could not be read"
  hardj='{}'
  for sc in task role project; do
    case "$sc" in
      task)    lim="${ROUTE_BUDGET_COST:-}"; sj="$(CS_ROLE= cost_scope "$work/$slug/usage.jsonl")" || sj="" ;;
      role)    lim="${ROUTE_ROLE_BUDGET_COST:-}"; sj="$(CS_ROLE="$base" cost_scope "$work/$slug/usage.jsonl")" || sj="" ;;
      project) lim="${ROUTE_PROJECT_BUDGET_COST:-}"; sj="$(CS_ROLE= cost_scope "$work"/*/usage.jsonl "$work"/_archive/*.usage.jsonl)" || sj="" ;;
    esac
    [ -n "$lim" ] || continue
    su="$(jq -r .usd <<< "$sj" 2>/dev/null)"; sunk="$(jq -r .unmeasured_or_unpriced <<< "$sj" 2>/dev/null)"
    isnum "$su" && isint "$sunk" || hfail "the $sc spend could not be computed from the usage ledger"
    hardj="$(jq -c --arg s "$sc" --argjson l "$lim" --argjson u "$su" --argjson k "$sunk" --argjson o "$openr" --argjson r "$resv" '. + {($s): {limit_usd:$l, estimated_usd:$u, unknown_runs:$k, open_reservations_usd:$o, this_reservation_usd:$r, remaining_usd:([$l - $u - $o - $r, 0] | max)}}' <<< "$hardj")" || hfail "the $sc budget could not be computed"
    if [ "$sunk" -gt 0 ]; then over="${over:+$over; }$sc cost limit unknown: $sunk earlier run(s) have no usage or no price, so spend cannot be shown to be under \$$lim (hard policy: unknown does not pass)"
    elif awk -v u="$su" -v o="$openr" -v r="$resv" -v l="$lim" 'BEGIN{exit !(u + o + r > l)}'; then over="${over:+$over; }$sc cost limit \$$lim reached (estimated \$$su + reserved \$$openr + this run \$$resv)"; fi
  done
  if [ "$price_known" = no ] && [ -n "${ROUTE_BUDGET_COST:-}${ROUTE_ROLE_BUDGET_COST:-}${ROUTE_PROJECT_BUDGET_COST:-}" ]; then
    over="${over:+$over; }no price for model '${D_MODEL:-(host default)}' in $KIT_DIR/pricing.json: its cost is unknown, and unknown does not pass a hard cost limit"; fi
  bj="$(jq -c --argjson h "$hardj" --arg rb "$resv_basis" --argjson rv "$resv" '. + {cost_hard:($h + {enforcement:"hard", reservation_usd:$rv, reservation_basis:$rb, basis:"estimate from the user price table, not a bill"})}' <<< "$bj")" || hfail "the budget record could not be built"
fi
D_BUDGET="$(jq -c --arg a "$acct" '. + {accounting:$a}' <<< "$bj")"

if [ -n "$over" ] && [ "$mode_sdd" != off ]; then
  if [ "$nobudget" = 1 ] && [ "$mode_sdd" = strict ]; then D_WARN+=("BUDGET_OVERRIDDEN: $over (--ignore-budget after the user agreed)")
  elif [ "$mode_sdd" = guided ]; then D_WARN+=("BUDGET_REACHED: $over (SDD_MODE=guided: warning only)")
  else
    D_NOTES+=("$over"); D_NOTES+=("state is preserved; raise the limit in $KIT_DIR/sdkit.local.env or ask the user and re-run with --ignore-budget; a mandatory role is never skipped")
    stop BUDGET_EXHAUSTED
  fi
fi
# optional roles are not run once the budget is at its warning level (mandatory and work roles still are); the decision says so
if [ "$D_CLASS" = lookup ] || { [ "$D_CLASS" = gate ] && [ "$D_MAND" = false ]; }; then
  if [ "$warnpct" = 1 ] && [ "$mode_sdd" = strict ] && [ -z "$rerun" ]; then stop OPTIONAL_SKIPPED "optional role $base not run: the task token budget is at its warning level"; fi
fi

# --- reserve: take the spawn count and record the decision, under the lock so two requests cannot both start the same run
if [ "$reserve" = 1 ]; then
  [ -f "$work/$slug/state.json" ] && "$here/state.sh" "$slug" spawn >/dev/null 2>&1
  if [ "${ROUTE_COST_ENFORCE:-off}" = hard ]; then   # held until the outcome reports (route.sh outcome releases and reconciles it); the project lock is still held, so inspect-and-reserve is one step
    printf '%s\n' "$(jq -nc --arg id "$D_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson u "$resv" --arg r "$base" --arg pid "$pid" '{type:"reserve",id:$id,ts:$ts,role:$r,usd:$u,pid:(if $pid == "" then null else ($pid | tonumber) end)}')" >> "$work/$slug/reservations.jsonl"
  fi
fi
emit
