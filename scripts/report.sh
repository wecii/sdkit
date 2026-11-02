#!/usr/bin/env bash
# SDKit Value Report: what a task or a session accomplished, which roles and models did it, what it used and cost, and what SDKit demonstrably saved.
# A READER of what the kit already records: usage.sh (token ledger, canonical price resolver, reconciliation), telemetry.sh (events), the routing ledger,
# the context, selection and cache records. It keeps no second ledger, does no price arithmetic of its own beyond sums and a ratio, and calls no model.
# Off unless VALUE_REPORT=on in sdkit.env (the automatic parts); the commands below always work. Design, formulas, limits: docs/design-report.md.
#   report.sh task [slug|latest] [--run ID] [--detailed|--json|--markdown]     the stored report of a finished task, else a live view of an open one
#   report.sh session [id|latest|current] [--detailed|--json|--markdown]       a session: stored summary, else built now (never stored while it may still run)
#   report.sh latest [--detailed|--json|--markdown]                            the newest stored report (task or session)
#   report.sh history [--json]                                                 every stored report, one line each (compare tasks over time)
#   report.sh finalize --status completed|failed|blocked|partial|aborted [--slug S] [--force] [--quiet]
#                                      write the task's report ONCE (a second call finds it and does nothing; --force rewrites) and print it compactly on stderr
#   report.sh session-end [--session ID] [--reason R] [--quiet]               a true end-of-session signal (SessionEnd hook): mark the session ended and store its summary
#   report.sh recover [--quiet]                                                sessions with records but no end signal (killed, crashed) get a summary marked "interrupted"
#   report.sh regenerate task|session ID                                       rebuild a stored report from the records still on disk (the status is kept)
# Output goes to stdout for the read commands; finalize, session-end and recover write to stderr so they never mix with a tool's own output.
# Reporting never fails its caller: finalize, session-end and recover always exit 0.
# Stored (small, local, no prompts, no transcripts): <project-dir>/work/_reports/{task/<slug>@<run>.json, session/<id>.json, index.jsonl, sessions.jsonl}.
set -u
command -v jq >/dev/null || { echo "report.sh needs jq" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; kit="$(cd "$here/.." && pwd)"
top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
. "$here/env.sh" 2>/dev/null || { echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }
SDKIT_ENV_QUIET=1 sdkit_env_load "$top"
work="$top/$KIT_DIR/work"; rdir="$work/_reports"
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in finalize|session-end|recover) trap 'exit 0' ERR 2>/dev/null ;; esac

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
safe_slug() { case "$1" in ''|*[!A-Za-z0-9_.@-]*) return 1 ;; esac; return 0; }

# ---------------------------------------------------------------- the builder (jq)
# One shared prelude: role table, totals, cost, routing counterfactual, avoided executions, savings. Task and session reports both use it.
COMMON='
def clean: if type == "string" then gsub("\\p{Cc}"; "") | .[0:120] else . end;
# a sentence for people (warnings): control characters out, cut only at a word boundary and marked, never mid-word
def cleanmsg: if type == "string" then gsub("\\p{Cc}"; "") | if length > 400 then (.[0:400] | sub(" [^ ]*$"; "")) + "…" else . end else . end;
def n: (. // 0);
def fresh: (.in // 0) + (.out // 0) + (.cache_write // 0);
def tot: (.in // 0) + (.out // 0) + (.cache_read // 0) + (.cache_write // 0);
def r4: if . == null then null else ((. * 10000) | round) / 10000 end;
def r1: if . == null then null else ((. * 10) | round) / 10 end;
def rowsof($U): if ($U.rows // null) == null then [] else ($U.rows | map(.role |= clean | .model |= clean | .provider |= clean | .host |= clean | .session |= clean)) end;
def nruns: (map(select(.id != "") | .id) | unique | length) + (map(select(.id == "")) | length);
def kindof: if .[0].role == "orchestrator" then "orchestrator" elif any(.[]; (.id // "") | startswith("rr-")) then "host-agent" else "subagent" end;
def roletable($rows): $rows | group_by([.role, .model, .provider]) | map(. as $g | ($g | map(select(.tq != "unavailable"))) as $m | ($g | map(select(.cost_status == "priced"))) as $p
  | {role: $g[0].role, kind: ($g | kindof), model: ($g[0].model | if . == "" then null else . end), provider: ($g[0].provider | if . == "" then null else . end),
     runs: ($g | nruns), unmeasured_runs: ($g | map(select(.tq == "unavailable")) | length),
     in: (if ($m | length) == 0 then null else ($m | map(.in) | add) end), out: (if ($m | length) == 0 then null else ($m | map(.out) | add) end),
     cache_read: (if ($m | length) == 0 then null else ($m | map(.cache_read) | add) end), cache_write: (if ($m | length) == 0 then null else ($m | map(.cache_write) | add) end),
     tokens: (if ($m | length) == 0 then null else ($m | map(tot) | add) end),
     cost_usd: (if ($p | length) == 0 then null else ($p | map(.cost_usd) | add | r4) end), cost_complete: (($p | length) == ($g | length)),
     cost_reason: ($g | map(select(.cost_status != "priced") | .cost_reason) | unique | join(","))})
  | sort_by([(if .kind == "orchestrator" then 0 else 1 end), .role, (.model // "")]);
# routing counterfactual: the same measured tokens of every NON-orchestrator run, priced on the configured baseline model by the canonical resolver.
# A run already on the baseline model contributes 0; a run on a dearer model contributes a NEGATIVE amount (shown, never hidden).
def routing($rows; $bm):
  if $bm == "" then {state: "na", reason: "no REPORT_BASELINE_MODEL configured"}
  else ($rows | map(select(.role != "orchestrator" and .tq != "unavailable"))) as $c
    | ($c | map(select(.cost_status == "priced" and (.as_status // "") == "priced"))) as $ok
    | if ($c | length) == 0 then {state: "na", reason: "no measured agent run"}
      elif ($ok | length) == 0 then {state: "na", reason: "baseline model \($bm) or the selected models are not priced (\($c | map(.as_reason // .cost_reason) | map(select(. != "")) | unique | join(",")))"}
      else {state: "ok", baseline_model: $bm, runs: ($c | length), priced_runs: ($ok | length),
            on_baseline: ($ok | map(select(.model == $bm)) | length),
            cheaper: ($ok | map(select(.as_cost_usd > .cost_usd)) | length), dearer: ($ok | map(select(.as_cost_usd < .cost_usd)) | length),
            actual_usd: ($ok | map(.cost_usd) | add), baseline_usd: ($ok | map(.as_cost_usd) | add), delta_usd: ($ok | map(.as_cost_usd - .cost_usd) | add),
            models: ($ok | map(.model) | unique)} end end;
def avoidcls: if .action == "reuse" then "evidence_reuse"
  elif (.reason == "DUPLICATE_COMPLETED" or .reason == "DUPLICATE_IN_FLIGHT") then "skipped_redundant"
  elif .reason == "OPTIONAL_SKIPPED" then "skipped_budget" else null end;
# avoided executions: counted from routing decisions (measured). Quantified only where a comparable recorded execution of the same role exists:
# first this task, then earlier stored reports. No comparable record = counted, not priced.
def avoided($rt; $rows; $hist):
  ($rt | map(select(.type == "decision")) | unique_by(.id) | map(. + {cls: avoidcls}) | map(select(.cls != null))) as $a
  | ($rows | map(select(.role != "orchestrator" and .tq != "unavailable"))) as $meas
  | def base: sub("-deep$"; "");
    ($a | map(. as $d | ($meas | map(select(.role == $d.role or .role == ($d.role | base))) | unique_by(.id)) as $m
        | ($hist | map(.roles[]? | select(.role == $d.role or .role == ($d.role | base))) | map(select(.runs > 0 and .tokens != null))) as $h
        | if ($m | length) > 0 then
            {id: .id, role: .role, cls: .cls, source: "this task: \($m | length) recorded run(s) of the role", confidence: "medium",
             in: ($m | map(.in) | add / ($m | length)), out: ($m | map(.out) | add / ($m | length)), cache_read: ($m | map(.cache_read) | add / ($m | length)), cache_write: ($m | map(.cache_write) | add / ($m | length)),
             cost_usd: (($m | map(select(.cost_status == "priced") | .cost_usd)) as $c | if ($c | length) == ($m | length) then ($c | add / length) else null end)}
          elif ($h | length) > 0 then
            {id: .id, role: .role, cls: .cls, source: "earlier reports: \($h | map(.runs) | add) run(s) of the role", confidence: "low",
             in: ($h | map(.in) | add / (map(.runs) | add)), out: ($h | map(.out) | add / (map(.runs) | add)), cache_read: ($h | map(.cache_read) | add / (map(.runs) | add)), cache_write: ($h | map(.cache_write) | add / (map(.runs) | add)),
             cost_usd: (if ($h | all(.cost_usd != null and .cost_complete == true)) then (($h | map(.cost_usd) | add) / ($h | map(.runs) | add)) else null end)}
          else {id: .id, role: .role, cls: .cls, source: null, confidence: null, in: null, out: null, cache_read: null, cache_write: null, cost_usd: null} end)) as $items
  | {count: ($a | length), by_class: ($a | group_by(.cls) | map({key: .[0].cls, value: length}) | from_entries),
     quantified: ($items | map(select(.in != null)) | length), items: $items};
# savings: token and dollar figures stay apart. Baseline = what the same scope would have used/cost without the measured SDKit effect. N/A when nothing supports one.
def savings($rows; $rt; $av):
  ($rows | map(select(.tq != "unavailable"))) as $m
  | ($m | map(fresh) | add // 0) as $actual_fresh
  | ($av.items | map(select(.in != null))) as $q
  | ($q | map(.in + .out + .cache_write) | add // 0) as $av_fresh
  | ($rt) as $r
  | {tokens: (if ($q | length) == 0 then {state: "na", text: "N/A — insufficient baseline data", why: (if $av.count == 0 then "no avoided execution observed (routing changes the price, not the token count)" else "\($av.count) avoided execution(s) counted, none has a comparable recorded run" end)}
        else {state: "estimated", kind: "estimated", baseline_tokens: ($actual_fresh + $av_fresh | round), actual_tokens: ($actual_fresh | round), saved_tokens: ($av_fresh | round),
              rate_pct: (if ($actual_fresh + $av_fresh) > 0 then ($av_fresh / ($actual_fresh + $av_fresh) * 100 | r1) else null end),
              baseline_source: ($q | map(.source) | unique | join("; ")), method: "avoided executions x mean tokens of the comparable recorded runs; baseline = actual + avoided",
              accounting: "fresh tokens = in + out + cache_write; cache reads are not counted as saved or as spent here",
              coverage: "\($q | length) of \($av.count) avoided execution(s) quantified", confidence: ($q | map(.confidence) | if any(. == "low") then "low" else "medium" end)} end),
     cost: ((if $r.state == "ok" then $r.delta_usd else null end) as $rd
            | ($q | map(select(.cost_usd != null)) | map(.cost_usd) | add) as $ad
            | if $rd == null and $ad == null then {state: "na", text: "N/A — insufficient baseline data", why: (if $r.state == "na" then $r.reason else "routing not applicable" end)}
              else (($rows | map(select(.cost_status == "priced") | .cost_usd) | add // 0) as $act
                    | ($act + ($rd // 0) + ($ad // 0)) as $base
                    | {state: "estimated", kind: "estimated", baseline_usd: ($base | r4), actual_usd: ($act | r4), saved_usd: (($base - $act) | r4),
                       rate_pct: (if $base > 0 then (($base - $act) / $base * 100 | r1) else null end),
                       components: ([(if $rd != null then {name: "routing", usd: ($rd | r4), source: "same tokens priced on baseline model \($r.baseline_model)", confidence: "low"} else empty end),
                                     (if $ad != null then {name: "avoided executions", usd: ($ad | r4), source: ($q | map(select(.cost_usd != null) | .source) | unique | join("; ")), confidence: ($q | map(.confidence) | if any(. == "low") then "low" else "medium" end)} else empty end)]),
                       method: "baseline cost = actual priced cost + routing counterfactual + avoided executions; savings = baseline - actual",
                       coverage: "\($rows | map(select(.cost_status == "priced")) | length) of \($rows | length) run(s) priced" + (if $r.state == "ok" then "; routing on \($r.priced_runs) run(s)" else "" end),
                       confidence: ([$r.state == "ok" and $rd != null, $ad != null] | if .[0] and .[1] then "low" elif .[0] then "low" else "medium" end),
                       regression: ((($base - $act)) < 0)}) end)};
def durfmt: if . == null then "N/A" else (. | floor) as $s | if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m\($s % 60)s" else "\($s / 3600 | floor)h\(($s % 3600) / 60 | floor)m" end end;
'

BUILD_TASK='
def optimizations($T; $rt; $cx; $sl; $av; $rtg; $sv):
  [ (if $rtg.state == "ok" then {name: "Intelligent routing", class: "estimated",
        evidence: "\($rtg.priced_runs) priced agent run(s) on \($rtg.models | join(", ")); \($rtg.on_baseline) on the baseline model, \($rtg.cheaper) cheaper, \($rtg.dearer) dearer",
        benefit: ("\(if $rtg.delta_usd >= 0 then "$" + ($rtg.delta_usd | r4 | tostring) + " avoided" else "REGRESSION $" + (-$rtg.delta_usd | r4 | tostring) + " extra" end) vs baseline \($rtg.baseline_model) (same-token counterfactual)")} else empty end),
    ($av.by_class.evidence_reuse // 0 | select(. > 0) | {name: "Evidence reuse", class: "measured count", evidence: "\(.) valid evidence reuse(s) recorded by routing", benefit: "\(.) execution(s) avoided" + (if $av.quantified > 0 then "; priced only where a comparable run exists (see savings)" else "; tokens not quantified (no comparable run)" end)}),
    ((($av.by_class.skipped_redundant // 0) + ($av.by_class.skipped_budget // 0)) | select(. > 0) | {name: "Skipped redundant agents", class: "measured count", evidence: "\($av.by_class.skipped_redundant // 0) duplicate and \($av.by_class.skipped_budget // 0) budget-skipped request(s)", benefit: "\(.) execution(s) not started" + (if $av.quantified > 0 then "; priced only where a comparable run exists" else "; tokens not quantified" end)}),
    (($sl | map(.cached) | add // 0) as $c | ($sl | map(.skipped_suites) | add // 0) as $s | select($c > 0 or $s > 0) | {name: "Test selection", class: "measured", evidence: "ran \($sl | map(.ran) | add // 0), reused \($c) cached green, left out \($s) suite(s)", benefit: "\($sl | map(.cached_s) | add // 0)s of cached runs replayed (time measured when first run); skipped suites untimed; no token claim"}),
    (($cx | map((.full_bytes // 0) - (.shown_bytes // 0)) | add // 0) as $b | select($b > 0) | {name: "Context optimization", class: "heuristic", evidence: "\($cx | length) bounded view(s); \($b) bytes kept off the orchestrator context", benefit: "about \($b / 4 | floor) tokens at ~4 bytes/token (heuristic, not in the savings rate)"}),
    (($rt | map(select(.type == "decision" and ((.budget // {}) | length) > 0)) | unique_by(.id)) as $bd | ($rt | map(select(.type == "decision" and .reason == "BUDGET_EXHAUSTED")) | unique_by(.id) | length) as $st | select(($bd | length) > 0) | {name: "Budget enforcement", class: "qualitative", evidence: "\($bd | length) routing decision(s) with budget accounting; \($st) stopped for budget", benefit: "spending checked before each run; no dollar claim"}),
    (select($T != null and ((($T.phases // []) | length) > 1 or ($T.failures.gate_rejections // 0) > 0)) | {name: "Workflow enforcement", class: "qualitative", evidence: "\(($T.phases // []) | length) phase(s), \($T.failures.gate_rejections // 0) gate rejection(s)", benefit: (if ($T.failures.gate_rejections // 0) > 0 then "\($T.failures.gate_rejections) invalid move(s) stopped before they landed" else "transitions validated; nothing had to be stopped" end)}) ];

# purpose of a role: first sentence of its definition (core/roles), passed in; why: the routing decision reasons seen for it
def purposeof($P; $r): ($P[$r] // $P[($r | sub("-deep$"; ""))] // null);
$T as $T | $RT as $rt | $CX as $cx | $SL as $sl | $HIST as $hist
| rowsof($U) as $rows
| roletable($rows) as $roles
| ($rows | map(select(.tq != "unavailable"))) as $meas
| routing($rows; $M.baseline_model) as $rtg
| avoided($rt; $rows; $hist) as $av
| savings($rows; $rtg; $av) as $sv
| ($rt | map(select(.type == "decision")) | unique_by(.id)) as $dec
| ($T.tests // []) as $tests
| (($tests | map(select(.outcome == "pass") | .runs) | add // 0)) as $tp
| (($tests | map(select(.outcome == "fail" and .phase != "red") | .runs) | add // 0)) as $tf
| (($tests | map(select(.outcome == "fail" and .phase == "red") | .runs) | add // 0)) as $tr
| ($T.verification.final // null) as $vf
| ($T.contracts.by_status // {}) as $cs
| (if $M.status == "completed" and ((($cs.partial // 0) + ($cs.blocked // 0) + ($cs.failed // 0)) > 0) then "partial" else $M.status end) as $status
| ($rows | map(.host) | map(select(. != "")) | unique) as $hosts
| ($meas | map(select(.model != "")) | group_by(.model) | map({m: .[0].model, t: (map(tot) | add)}) | sort_by(-.t) | .[0].m // null) as $pm
| ($meas | map(.ts) | map(select(. != null)) | sort) as $lts
| ($T.wall_s // $M.wall_s // (if ($lts | length) > 1 then ((($lts | last) | fromdateiso8601) - (($lts | first) | fromdateiso8601)) else null end)) as $dur
| ($M.sessions) as $sess
| {schema: "value-report/1", kind: "task", key: $M.key, generated_at: $M.now, regenerated: ($M.regenerated // false),
   task: {name: ($M.slug | clean), id: ($M.slug | clean), run: $M.run, status: $status, status_requested: $M.status, terminal: $M.terminal, status_source: $M.status_source,
          duration: {s: $dur, source: (if $T.wall_s != null then "telemetry events" elif $M.wall_s != null then "task state" elif $dur != null then "usage record timestamps (lower bound)" else "unavailable" end)},
          workflow: ($T.risk as $r | {profile: ($T.workflow.profile // $M.profile // null), risk: ($T.risk // $M.risk // null)}),
          hosts: $hosts, primary_model: $pm, sessions: $sess,
          files_changed: $M.files_changed,
          tests: (if ($tests | length) == 0 then {state: "not recorded"} else {state: (if $tf > 0 then "failed" else "passed" end), passed: $tp, failed: $tf, red_expected: $tr} end),
          quality_gates: (if $M.terminal | not then {state: "Pending", note: "task still open: the gate runs when it is verified"}
                          elif $T == null then {state: "Not run", note: "telemetry off: no gate result recorded"}
                          elif $vf == null then {state: "Not run", note: "no verification result recorded"}
                          elif ($vf | tostring | ascii_downcase) == "pass" then {state: "Passed", final: $vf, rejections: ($T.failures.gate_rejections // 0)}
                          else {state: "Failed", final: $vf, rejections: ($T.failures.gate_rejections // 0)} end)},
   roles: ($roles | map(. as $x | . + {purpose: purposeof($M.purposes; .role),
                                       why: ($dec | map(select(.role == $x.role or (.role | sub("-deep$"; "")) == $x.role) | .reason) | unique),
                                       result_text: (if .role == "verifier" or .role == "verifier-deep" then ($vf // "no verdict recorded") elif .kind == "orchestrator" then "coordinated" else "recorded" end)})),
   executions: {total: ($rows | nruns), by_kind: ($roles | group_by(.kind) | map({key: .[0].kind, value: (map(.runs) | add)}) | from_entries), unmeasured: ($rows | map(select(.tq == "unavailable")) | length)},
   tokens: (if ($rows | length) == 0 then {state: "unavailable", note: "no usage ledger rows (USAGE_LOG off, or nothing recorded)"}
            else {state: (if ($rows | map(select(.tq == "unavailable")) | length) > 0 then "partial" else "recorded" end),
                  in: ($meas | map(.in) | add // 0), out: ($meas | map(.out) | add // 0), cache_read: ($meas | map(.cache_read) | add // 0), cache_write: ($meas | map(.cache_write) | add // 0),
                  total: ($meas | map(tot) | add // 0), fresh: ($meas | map(fresh) | add // 0),
                  measured_runs: ($meas | nruns), unmeasured_runs: ($rows | map(select(.tq == "unavailable")) | nruns),
                  cache_hit_rate: ($U.cache.hit_rate // null), note: "cache reads are input served from cache, never counted as newly generated tokens"} end),
   cost: (if ($rows | length) == 0 then {state: "unavailable"}
          else {state: ($U.pricing.source as $s | if ($rows | map(select(.cost_status == "priced")) | length) == 0 then "unavailable" elif ($rows | any(.cost_status != "priced")) then "partial" else "estimated" end),
                api_equivalent_usd: ($U.totals.cost_usd | r4), priced_runs: ($U.totals.priced // 0), unpriced_runs: ($U.totals.unpriced // 0),
                pricing_source: ($U.pricing.source // "none"), billed: "unavailable: no source reports it; a subscription is not billed per token, the figure is what the same tokens cost at API rates",
                host_estimate_usd: ($U.host_estimate.usd | r4),
                cache_saving_usd: ($U.cache.saving_usd | r4), cache_saving_note: "provider prompt caching vs uncached input, API-equivalent; not an SDKit optimization",
                reasons: ($U.warnings // [] | map(select(test("not priced|no pricing|unreadable"))))} end),
   savings: ($sv + {routing: $rtg, avoided: ($av | del(.items) + {items: ($av.items | map({role, cls, source, confidence, quantified: (.in != null)}))})}),
   optimizations: optimizations($T; $rt; $cx; $sl; $av; $rtg; $sv),
   validation: {tests: ($tests | map("\(.phase) \(.outcome) x\(.runs)")), verification: ($T.verification.results // [] | map(.outcome)), final: $vf,
                retries: ($T.retries // null), failures: ($T.failures.by_category // null)},
   warnings: ([($U.warnings // [])[], (if $T == null then "telemetry off or empty: phases, durations, tests and gate results are unavailable" else empty end),
               (if $M.base_missing then "REPORT_BASELINE_MODEL is not set: routing savings are N/A" else empty end)] | map(cleanmsg)),
   summary: ("\($M.slug | clean) " + (if $M.terminal then "ended" else "is" end) + " \($status | ascii_upcase)" + (if $dur != null then " after \($dur | durfmt)" else "" end)
             + ": \($rows | nruns) role execution(s) across \($roles | map(.role) | unique | length) role(s)"
             + (if $vf != null then "; final verification \($vf)" else "" end)
             + (if $status == "partial" then "; some role results were partial, blocked or failed" else "" end) + ".")}
'

BUILD_SESSION='
$TASKS as $tasks
| rowsof($U) as $rows | roletable($rows) as $roles | ($rows | map(select(.tq != "unavailable"))) as $meas
| routing($rows; $M.baseline_model) as $rtg
| ($tasks | map(select(.sessions | length <= 1))) as $inside | ($tasks | map(select(.sessions | length > 1))) as $span
| ($inside | map(.avoided_by_class // {}) | map(to_entries) | add // [] | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries) as $avc
| ($inside | map(.saved_tokens // 0) | add) as $at | ($inside | map(.saved_usd_avoided // 0) | add) as $ac
| {schema: "value-report/1", kind: "session", key: $M.key, generated_at: $M.now, regenerated: ($M.regenerated // false),
   session: {id: ($M.session | clean), state: $M.state, end_reason: ($M.reason | clean), ended_at: $M.ended_at, first_record: ($rows | map(.ts) | map(select(. != null)) | min), last_record: ($rows | map(.ts) | map(select(. != null)) | max),
             note: (if $M.state == "ended" then "true end-of-session signal received" elif $M.state == "interrupted" then "no end signal: the session was killed or abandoned; usage is what was recorded up to then" else "still running, or no end signal yet" end)},
   tasks: {total: ($tasks | length), completed: ($tasks | map(select(.status == "completed")) | length), partial: ($tasks | map(select(.status == "partial")) | length),
           failed: ($tasks | map(select(.status == "failed" or .status == "aborted")) | length), blocked: ($tasks | map(select(.status == "blocked")) | length),
           list: ($tasks | map({task, status, tokens_fresh, cost_usd}))},
   executions: {total: ($rows | nruns), by_role: ($roles | group_by(.role) | map({role: .[0].role, runs: (map(.runs) | add), kinds: (map(.kind) | unique)})), unmeasured: ($rows | map(select(.tq == "unavailable")) | length)},
   roles: $roles,
   tokens: (if ($rows | length) == 0 then {state: "unavailable"}
            else {state: (if ($rows | any(.tq == "unavailable")) then "partial" else "recorded" end), in: ($meas | map(.in) | add // 0), out: ($meas | map(.out) | add // 0), cache_read: ($meas | map(.cache_read) | add // 0), cache_write: ($meas | map(.cache_write) | add // 0), total: ($meas | map(tot) | add // 0), fresh: ($meas | map(fresh) | add // 0), cache_hit_rate: ($U.cache.hit_rate // null)} end),
   cost: (if ($rows | length) == 0 then {state: "unavailable"} else {state: (if ($rows | map(select(.cost_status == "priced")) | length) == 0 then "unavailable" elif ($rows | any(.cost_status != "priced")) then "partial" else "estimated" end), api_equivalent_usd: ($U.totals.cost_usd | r4), priced_runs: ($U.totals.priced // 0), unpriced_runs: ($U.totals.unpriced // 0), pricing_source: ($U.pricing.source // "none"), billed: "unavailable", cache_saving_usd: ($U.cache.saving_usd | r4)} end),
   savings: {routing: $rtg,
             routing_usd: (if $rtg.state == "ok" then ($rtg.delta_usd | r4) else null end),
             avoided_executions: {counted_in_session_tasks: $avc, tokens_saved_estimate: (if $at > 0 then $at else null end), usd_saved_estimate: (if $ac > 0 then $ac else null end),
                                  excluded: "\($span | length) task(s) span several sessions: their avoided executions stay in the task reports and are not added here"},
             tokens: (if $at > 0 then {state: "estimated", saved_tokens: $at, note: "sum of the quantified avoided executions of tasks fully inside this session; rate is in each task report"} else {state: "na", text: "N/A — insufficient baseline data"} end),
             cost: (if $rtg.state == "ok" or $ac > 0 then {state: "estimated", saved_usd: ((($rtg.delta_usd // 0) + $ac) | r4), components: {routing: (if $rtg.state == "ok" then ($rtg.delta_usd | r4) else null end), avoided_executions: (if $ac > 0 then ($ac | r4) else null end)}} else {state: "na", text: "N/A — insufficient baseline data", why: ($rtg.reason // "none")} end)},
   evidence_reuse: ($avc.evidence_reuse // 0), skipped: (($avc.skipped_redundant // 0) + ($avc.skipped_budget // 0)),
   validation: {tests_passed: ($tasks | map(.tests_passed // 0) | add), tests_failed: ($tasks | map(.tests_failed // 0) | add), gates: ($tasks | map(.gates) | group_by(.) | map({key: .[0], value: length}) | from_entries)},
   optimizations_observed: ($tasks | map(.optimizations // []) | add // [] | unique),
   warnings: ([($U.warnings // [])[], (if $M.state != "ended" then "this session has no end signal: figures cover what was recorded" else empty end)] | map(cleanmsg)),
   summary: ("session \($M.session | clean) (\($M.state)): \($tasks | length) task(s), \($rows | nruns) role execution(s)" + (if $M.state != "ended" then " [not a confirmed session end]" else "" end) + ".")}
'

# ---------------------------------------------------------------- renderers (jq, from the report JSON only)
FMT='
def commas: if . == null then "N/A" else (round | tostring) as $s | ($s | ltrimstr("-")) as $a | (if ($a | length) <= 3 then $a else ($a | explode | reverse | [range(0; length; 3) as $i | .[$i:$i+3] | reverse | implode] | reverse | join(",")) end) as $b | (if $s | startswith("-") then "-" else "" end) + $b end;
def usd($x): if $x == null then "N/A" else (if $x < 0 then "-$" else "$" end) + ((($x | fabs) * 10000 | round) as $m | "\($m / 10000 | floor).\(("0000" + ($m % 10000 | tostring))[-4:])") end;
def cell: tostring | gsub("\\|"; "/") | gsub("\n"; " ");
def tbl($h; $rows): ("| " + ($h | join(" | ")) + " |"), ("|" + ($h | map("---") | join("|")) + "|"), ($rows[] | "| " + (map(cell) | join(" | ")) + " |");
def dur: if . == null then "N/A" else (floor) as $s | if $s < 60 then "\($s)s" elif $s < 3600 then "\($s / 60 | floor)m\($s % 60)s" else "\($s / 3600 | floor)h\(($s % 3600) / 60 | floor)m" end end;
def pctc: if . == null then "N/A" else "\(.)%" end;
def costtxt($c): if $c.state == "unavailable" then "N/A (no pricing)" else usd($c.api_equivalent_usd) + (if $c.state == "partial" then " (PARTIAL: \($c.unpriced_runs) run(s) unpriced, lower bound)" else "" end) end;
def tokens_row($t): if $t.state == "unavailable" then "N/A (nothing recorded)" else "\($t.total | commas)" + (if $t.state == "partial" then " (lower bound: some runs unmeasured)" else "" end) end;
def savtxt($s): ($s.tokens as $t | $s.cost as $c |
   "tokens: " + (if $t.state == "na" then $t.text else "\($t.saved_tokens | commas) saved (\($t.rate_pct | pctc), estimated, \($t.confidence) confidence)" end)
   + " | cost: " + (if $c.state == "na" then $c.text else "\(usd($c.saved_usd)) (\($c.rate_pct | pctc), estimated" + (if $c.regression then ", REGRESSION: SDKit cost more than the baseline" else "" end) + ")" end));
def statline: "\(.task.status | ascii_upcase)";
def taskrows: [
  ["Task", .task.name], ["Task ID", "\(.task.id)@\(.task.run // "-")"], ["Status", statline + (if .task.terminal then "" else " (not terminal: live view)" end)],
  ["Duration", "\(.task.duration.s | dur) (\(.task.duration.source))"], ["Workflow", "\(.task.workflow.profile // "N/A") (risk \(.task.workflow.risk // "N/A"))"],
  ["Host", (.task.hosts | if length == 0 then "N/A" else join(", ") end)], ["Primary Model", .task.primary_model // "N/A"],
  ["Files Changed", (if .task.files_changed == null then "N/A" else "\(.task.files_changed.n) (\(.task.files_changed.method))" end)],
  ["Tests", (if .task.tests.state == "not recorded" then "not recorded" else "\(.task.tests.passed) passed / \(.task.tests.failed) failed" + (if (.task.tests.red_expected // 0) > 0 then " (+\(.task.tests.red_expected) expected red-phase failure(s))" else "" end) end)],
  ["Quality Gates", .task.quality_gates.state + (if .task.quality_gates.note then " (\(.task.quality_gates.note))" else "" end)] ];
def rolerows: .roles | map([(.role + " (" + .kind + ")"), ((.model // "unknown") + (if .provider then " @" + .provider else "" end)), (.purpose // "-"), .runs, (if .tokens == null then "N/A" else (.tokens | commas) end), (if .cost_usd == null then "N/A" else usd(.cost_usd) + (if .cost_complete then "" else "*" end) end), .result_text]);
def tokrows: .tokens as $t | .cost as $c | .savings as $s | [
  ["Input Tokens", ($t.in | commas)], ["Output Tokens", ($t.out | commas)], ["Cache Read Tokens", ($t.cache_read | commas)], ["Cache Write Tokens", ($t.cache_write | commas)],
  ["Total Recorded Tokens", tokens_row($t)],
  ["Estimated API-Equivalent Cost", costtxt($c)],
  ["Estimated Baseline Cost", (if $s.cost.state == "na" then "N/A — insufficient baseline data" else usd($s.cost.baseline_usd) end)],
  ["Estimated Savings", (if $s.cost.state == "na" then "N/A" else usd($s.cost.saved_usd) end)],
  ["Estimated Savings Rate (cost)", (if $s.cost.state == "na" then "N/A — insufficient baseline data" else ($s.cost.rate_pct | pctc) end)],
  ["Estimated Savings Rate (tokens)", (if $s.tokens.state == "na" then "N/A — insufficient baseline data" else "\($s.tokens.rate_pct | pctc) (\($s.tokens.saved_tokens | commas) of \($s.tokens.baseline_tokens | commas) fresh tokens)" end)] ];
def md_task: "## SDKit Value Report — task \(.task.name)", "", "**\(.summary)**", "", "### A. Task Overview", "", tbl(["Metric", "Value"]; taskrows), "",
  "### B. Agent & Role Breakdown", "", (if (.roles | length) == 0 then "No role execution was recorded (USAGE_LOG off, or nothing ran)." else tbl(["Role / Agent", "Model", "Purpose", "Executions", "Tokens", "Cost", "Result"]; rolerows) end),
  "", "_kind: orchestrator = the main session; subagent = a delegated agent; host-agent = a separate host process started by run-role.sh. Executions are distinct execution ids. `*` = some runs unpriced._", "",
  "### C. Token & Cost Breakdown", "", tbl(["Metric", "Amount"]; tokrows), "",
  "_Cost is API-equivalent (tokens x your price table), not a bill. Billed: \(.cost.billed)._", "",
  "### D. SDKit Optimization Impact", "",
  (if (.optimizations | length) == 0 then "No SDKit optimization was observed in the records of this task." else tbl(["Optimization", "Evidence", "Benefit", "Type"]; .optimizations | map([.name, .evidence, .benefit, .class])) end), "",
  "**Savings** — " + savtxt(.savings), "";
def md_task_detail: md_task, "### Savings method", "",
  tbl(["Figure", "Baseline source", "Method", "Coverage", "Confidence", "Type"];
    [ (.savings.tokens | if .state == "na" then ["Token savings", "-", .why, "-", "-", "N/A"] else ["Token savings", .baseline_source, .method + ". " + .accounting, .coverage, .confidence, .kind] end),
      (.savings.cost | if .state == "na" then ["Cost savings", "-", .why, "-", "-", "N/A"] else ["Cost savings", (.components | map(.source) | join("; ")), .method, .coverage, .confidence, .kind] end) ]), "",
  "### Why each role ran", "", (if (.roles | length) == 0 then "-" else tbl(["Role", "Routing reasons", "Runs", "Unmeasured runs"]; .roles | map([.role, (.why | if length == 0 then "invoked directly (no routing record)" else join(", ") end), .runs, .unmeasured_runs])) end), "",
  "### Validation", "", "- tests: \(.validation.tests | if length == 0 then "none recorded" else join(", ") end)", "- verification: \(.validation.verification | if length == 0 then "none recorded" else join(" -> ") end)", "- retries: \(.validation.retries // "N/A"); failures: \(.validation.failures // {} | to_entries | map("\(.key)=\(.value)") | join(" ") | if . == "" then "none" else . end)", "",
  "### Caveats", "", (.warnings | if length == 0 then "- none" else map("- " + .) | .[] end),
  "- cache saving (provider prompt caching, not SDKit): \(usd(.cost.cache_saving_usd))";
def txt_task: "SDKit Value Report — \(.summary)",
  "  \(.task.duration.s | dur) · workflow \(.task.workflow.profile // "N/A") · host \(.task.hosts | if length == 0 then "N/A" else join(",") end) · files \(.task.files_changed.n // "N/A") · tests \(if .task.tests.state == "not recorded" then "n/r" else "\(.task.tests.passed)p/\(.task.tests.failed)f" end) · gates \(.task.quality_gates.state)",
  (if (.roles | length) > 0 then "  roles:" , (.roles[] | "    \(.role) [\(.kind)] \(.model // "?") x\(.runs)  \(if .tokens == null then "N/A" else (.tokens | commas) end) tok  \(if .cost_usd == null then "N/A" else usd(.cost_usd) end)") else "  roles: none recorded" end),
  "  usage: \(tokens_row(.tokens)) tokens (in \(.tokens.in | commas) out \(.tokens.out | commas) cache_read \(.tokens.cache_read | commas) cache_write \(.tokens.cache_write | commas)) · est. API-equivalent cost \(costtxt(.cost))",
  "  savings: " + savtxt(.savings),
  "  optimizations: " + (if (.optimizations | length) == 0 then "none observed" else (.optimizations | map("\(.name) [\(.class)]") | join(", ")) end),
  "  validation: tests \(.validation.tests | if length == 0 then "none recorded" else join(", ") end) · verification \(.validation.final // "not recorded")",
  "  details: sdkit report task \(.task.id) --detailed   (--json / --markdown to export)";
def sess_rows: [["Session", .session.id], ["State", .session.state + " — " + .session.note], ["Tasks", "\(.tasks.total) (completed \(.tasks.completed), partial \(.tasks.partial), failed/aborted \(.tasks.failed), blocked \(.tasks.blocked))"],
  ["Role executions", "\(.executions.total) (unmeasured \(.executions.unmeasured))"], ["Total tokens", tokens_row(.tokens)], ["Est. API-equivalent cost", costtxt(.cost)],
  ["Evidence reuse", "\(.evidence_reuse) execution(s) avoided"], ["Skipped executions", "\(.skipped)"],
  ["Validation", "tests \(.validation.tests_passed) passed / \(.validation.tests_failed) failed; gates \(.validation.gates | to_entries | map("\(.key)=\(.value)") | join(" ") | if . == "" then "n/a" else . end)"],
  ["Savings", savtxt(.savings)]];
def md_session: "## SDKit Session Summary — \(.session.id)", "", "**\(.summary)**", "", tbl(["Metric", "Value"]; sess_rows), "",
  "### Agent & role participation", "", (if (.roles | length) == 0 then "No role execution recorded." else tbl(["Role / Agent", "Model", "Executions", "Tokens", "Cost"]; .roles | map([(.role + " (" + .kind + ")"), ((.model // "unknown") + (if .provider then " @" + .provider else "" end)), .runs, (if .tokens == null then "N/A" else (.tokens | commas) end), (if .cost_usd == null then "N/A" else usd(.cost_usd) end)])) end), "",
  "### Tasks", "", (if (.tasks.list | length) == 0 then "No stored task report belongs to this session." else tbl(["Task", "Status", "Fresh tokens", "Cost"]; .tasks.list | map([.task, .status, (.tokens_fresh | commas), usd(.cost_usd)])) end), "",
  "### Savings", "", "- routing: \(if .savings.routing.state == "ok" then usd(.savings.routing.delta_usd) + " vs baseline \(.savings.routing.baseline_model) (same-token counterfactual, estimated)" else "N/A — \(.savings.routing.reason)" end)",
  "- avoided executions: \(.savings.avoided_executions.counted_in_session_tasks | to_entries | map("\(.key)=\(.value)") | join(" ") | if . == "" then "none" else . end); \(.savings.avoided_executions.excluded)", "",
  "### Caveats", "", (.warnings | if length == 0 then "- none" else map("- " + .) | .[] end);
def txt_session: "SDKit Session Summary — \(.summary)",
  "  tasks \(.tasks.total): completed \(.tasks.completed), partial \(.tasks.partial), failed/aborted \(.tasks.failed), blocked \(.tasks.blocked)",
  "  executions \(.executions.total) across \(.roles | map(.role) | unique | length) role(s) · tokens \(tokens_row(.tokens)) · est. API-equivalent cost \(costtxt(.cost))",
  "  evidence reuse \(.evidence_reuse) · skipped \(.skipped) · tests \(.validation.tests_passed)p/\(.validation.tests_failed)f",
  "  savings: " + savtxt(.savings),
  "  details: sdkit report session \(.session.id) --detailed";
def render($mode; $detail):
  if $mode == "json" then . elif .kind == "session" then (if $mode == "markdown" or $detail then md_session else txt_session end) else (if $mode == "markdown" then md_task elif $detail then md_task_detail else txt_task end) end;
'

# ---------------------------------------------------------------- data collection
src() {  # src <slug> <name>: the live file of a task, else its archived copy, else nothing
  local f="$work/$1/$2.jsonl"; [ -f "$f" ] && { echo "$f"; return; }
  f="$work/_archive/$1.$2.jsonl"; [ -f "$f" ] && echo "$f"; return 0
}
slurp() { local f="$1"; if [ -n "$f" ] && [ -f "$f" ]; then jq -sc '[.[] | select(type == "object")]' "$f" 2>/dev/null || echo '[]'; else echo '[]'; fi; }
baseline_model() { printf '%s' "${REPORT_BASELINE_MODEL:-}" | tr -cd 'A-Za-z0-9._:/@-'; }
purposes() {  # {role: first sentence of its definition}; roles of the kit only, nothing invented for others. One awk, one jq.
  local d="$kit/core/roles"; [ -d "$d" ] || { echo '{}'; return; }
  awk 'FNR == 1 { n = FILENAME; sub(".*/", "", n); sub("\\.md$", "", n); done = 0 }
       !done && /^description:/ { sub(/^description:[ \t]*/, ""); sub(/\. .*/, ""); sub(/\.$/, ""); if (length($0) > 110) { $0 = substr($0, 1, 110); sub(/ [^ ]*$/, "", $0); $0 = $0 "…" } if (n != "README") print n "\t" $0; done = 1 }' "$d"/*.md 2>/dev/null \
    | jq -Rn '[inputs | split("\t") | select(length == 2) | {key: .[0], value: .[1]}] | from_entries' 2>/dev/null || echo '{}'
}
history_json() {  # role statistics of earlier stored task reports (comparable-run baselines), other than <key>
  local f list=""; [ -d "$rdir/task" ] || { echo '[]'; return; }
  for f in $(ls -t "$rdir"/task/*.json 2>/dev/null | head -20); do list="$list $f"; done
  # shellcheck disable=SC2086
  [ -n "$list" ] && jq -sc --arg k "$1" '[.[] | select(.key != $k and .kind == "task") | {key, roles: [.roles[] | select(.kind != "orchestrator" and .tokens != null) | {role, runs, in, out, cache_read, cache_write, tokens, cost_usd, cost_complete}]}]' $list 2>/dev/null || echo '[]'
}
files_changed() {
  local b f n
  b="$("$here/resolve-base.sh" 2>/dev/null | head -1)"; [ -n "$b" ] || { echo null; return; }
  n="$( { git -C "$top" diff --name-only "$b" 2>/dev/null; git -C "$top" ls-files -o --exclude-standard 2>/dev/null | grep -v "^$KIT_DIR/"; } | sort -u | grep -c . )" || n=0
  [ "$n" -gt 0 ] && jq -nc --argjson n "$n" --arg b "$b" '{n: $n, method: "git diff vs \($b) plus untracked"}' || echo null
}
usage_json() {  # usage_json <slug|""> <session|""> -> the canonical usage report (rows included), through usage.sh
  local a=(report); [ -n "$1" ] && a+=("$1"); a+=(--project --json); [ -n "$2" ] && a+=(--session "$2")
  local bm; bm="$(baseline_model)"; [ -n "$bm" ] && a+=(--as-model "$bm")
  USAGE_LOG="${USAGE_LOG:-}" "$here/usage.sh" "${a[@]}" 2>/dev/null | jq -c . 2>/dev/null || echo '{"empty":true}'
}

# build_task <slug> <status> <terminal true|false> <status_source> [regenerated]
build_task() {
  local slug="$1" status="$2" term="$3" ssrc="$4" regen="${5:-false}" run="" ev tj='null' state="$top/$KIT_DIR/.sdd/state.json" prof="" risk="" t0="" wall=null sess key bm
  [ -f "$work/$slug/run.id" ] && run="$(tr -cd 'A-Za-z0-9_.-' < "$work/$slug/run.id" | head -c 60)"
  ev="$(src "$slug" events)"
  if [ -n "$ev" ] && [ -s "$ev" ]; then
    tj="$("$here/telemetry.sh" summary --file "$ev" ${run:+--run "$run"} --json 2>/dev/null | jq -c 'select(.error | not)' 2>/dev/null)"; [ -n "$tj" ] || tj='null'
    [ -z "$run" ] && run="$(jq -r '.run // empty' <<< "$tj")"
  fi
  if [ -f "$state" ] && [ "$(jq -r '.task // empty' "$state" 2>/dev/null)" = "$slug" ]; then
    prof="$(jq -r '.profile // empty' "$state")"; risk="$(jq -r '.risk // empty' "$state")"; t0="$(jq -r '.startedAt // empty' "$state")"
    [ -n "$t0" ] && wall="$(jq -nr --arg a "$t0" --arg b "$(now)" '(($b | fromdateiso8601) - ($a | fromdateiso8601))' 2>/dev/null || echo null)"
  fi
  [ -n "$run" ] || run="${t0:-0}"; run="$(printf '%s' "$run" | tr -cd 'A-Za-z0-9_.-')"; [ -n "$run" ] || run=0
  key="$slug@$run"; bm="$(baseline_model)"
  local U RT CX SL H P FC
  "$here/usage.sh" reconcile --slug "$slug" >/dev/null 2>&1 || true   # subagent runs whose transcript was not yet written at SubagentStop
  U="$(usage_json "$slug" "")"; RT="$(slurp "$(src "$slug" routing)")"; CX="$(slurp "$(src "$slug" context)")"; SL="$(slurp "$(src "$slug" selection)")"
  H="$(history_json "$key")"; P="$(purposes)"; FC="$(files_changed)"
  sess="$(jq -c '[(.rows // [])[] | .session | select(. != "")] | unique' <<< "$U")"
  jq -nc --argjson U "$U" --argjson T "$tj" --argjson RT "$RT" --argjson CX "$CX" --argjson SL "$SL" --argjson HIST "$H" \
    --argjson M "$(jq -nc --arg slug "$slug" --arg run "$run" --arg key "$key" --arg st "$status" --argjson term "$term" --arg ss "$ssrc" --arg now "$(now)" --arg bm "$bm" \
      --arg prof "$prof" --arg risk "$risk" --argjson wall "${wall:-null}" --argjson sess "$sess" --argjson fc "$FC" --argjson pur "$P" --argjson regen "$regen" \
      '{slug:$slug, run:$run, key:$key, status:$st, terminal:$term, status_source:$ss, now:$now, baseline_model:$bm, base_missing:($bm == ""), profile:(if $prof == "" then null else $prof end), risk:(if $risk == "" then null else $risk end), wall_s:$wall, sessions:$sess, files_changed:$fc, purposes:$pur, regenerated:$regen}')" \
    "def _x: .; $COMMON $BUILD_TASK" 2>"${REPORT_DEBUG:-/dev/null}"
}

index_line() {  # <report json> <file>: one compact index record
  jq -c --arg f "$2" 'if .kind == "task" then {key, kind, id: .task.id, task: .task.id, status: .task.status, ts: .generated_at, file: $f, sessions: .task.sessions,
        tokens_fresh: (.tokens.fresh // null), cost_usd: (.cost.api_equivalent_usd // null), saved_usd: (.savings.cost.saved_usd // null), saved_tokens: (.savings.tokens.saved_tokens // null),
        avoided_by_class: (.savings.avoided.by_class // {}), saved_usd_avoided: ((.savings.cost.components // []) | map(select(.name == "avoided executions") | .usd) | add // 0),
        tests_passed: (.task.tests.passed // 0), tests_failed: (.task.tests.failed // 0), gates: .task.quality_gates.state, optimizations: (.optimizations | map(.name))}
      else {key, kind, id: .session.id, status: .session.state, ts: .generated_at, file: $f, tasks: .tasks.total} end' <<< "$1"
}
store() {  # store <kind> <name> <json>: atomic write, then one index line (an unchanged key is replaced, so the index stays one line per report)
  local kind="$1" name="$2" json="$3" f="$rdir/$1/$2.json" key
  mkdir -p "$rdir/$kind" 2>/dev/null || return 1
  printf '%s\n' "$json" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f" || return 1
  key="$(jq -r .key <<< "$json")"; sdkit_lock "$rdir/index.jsonl"
  { [ -f "$rdir/index.jsonl" ] && jq -c --arg k "$key" 'select(.key != $k)' "$rdir/index.jsonl" 2>/dev/null; index_line "$json" "$kind/$name.json"; } > "$rdir/index.jsonl.tmp.$$" \
    && mv "$rdir/index.jsonl.tmp.$$" "$rdir/index.jsonl"
  sdkit_unlock "$rdir/index.jsonl"
}
show() {  # show <json> <mode> <detail>
  jq -r --arg mode "$2" --argjson detail "$3" "$FMT"'render($mode; $detail)' <<< "$1" 2>/dev/null
}
show_json() { jq . <<< "$1"; }
# export_report <id> <json>: with REPORT_EXPORT=on, the end signal also leaves the report in <project-dir>/reports/<id>.{json,md} (committed with the project:
# a readable copy of the stored report, no prompts or transcripts). <id> is the task id, or the session id for a session that served no task.
export_report() {
  [ "${REPORT_EXPORT:-}" = on ] || return 0
  local d="$top/$KIT_DIR/reports" id="$1" j="$2"
  safe_slug "$id" && mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\n' "$j" | jq . > "$d/$id.json.tmp.$$" 2>/dev/null && mv "$d/$id.json.tmp.$$" "$d/$id.json" || { rm -f "$d/$id.json.tmp.$$"; return 0; }
  show "$j" markdown true > "$d/$id.md.tmp.$$" 2>/dev/null && mv "$d/$id.md.tmp.$$" "$d/$id.md" || rm -f "$d/$id.md.tmp.$$"
  return 0
}

# ---------------------------------------------------------------- commands
mode=text; detail=false; slug=""; run=""; sid=""; status=""; force=0; quiet=0; reason=""; sub=""
parse() { while [ $# -gt 0 ]; do case "$1" in
    --detailed) detail=true ;; --json) mode=json ;; --markdown) mode=markdown ;; --force) force=1 ;; --quiet) quiet=1 ;;
    --status) status="$2"; shift ;; --slug) slug="$2"; shift ;; --run) run="$2"; shift ;; --session) sid="$2"; shift ;; --reason) reason="$2"; shift ;;
    -*) echo "report: unknown option $1" >&2; exit 2 ;; *) sub="$1" ;; esac; shift; done; }
emit() { if [ "$mode" = json ]; then show_json "$1"; else show "$1" "$mode" "$detail"; fi; }

latest_entry() {  # latest_entry [kind]: newest index record
  [ -f "$rdir/index.jsonl" ] || return 0
  jq -sc --arg k "${1:-}" 'map(select($k == "" or .kind == $k)) | sort_by(.ts) | last // empty' "$rdir/index.jsonl" 2>/dev/null
}
stored() { [ -f "$rdir/$1/$2.json" ] && cat "$rdir/$1/$2.json"; }

case "$cmd" in
  task)
    parse "$@"; s="${sub:-latest}"
    if [ "$s" = latest ]; then
      e="$(latest_entry task)"
      if [ -n "$e" ]; then j="$(stored task "$(jq -r '.key' <<< "$e")")"; else
        s="$(sdkit_active_slug "$top")"; [ -n "$s" ] || { echo "report: no task report and no open task (set VALUE_REPORT=on, or finish a task)" >&2; exit 1; }
      fi
    fi
    if [ -z "${j:-}" ]; then
      safe_slug "$s" || { echo "report: bad task id" >&2; exit 2; }
      # a stored report wins (the run argument or the newest run of this task); an open task gets a live, NOT stored, view
      if [ -n "$run" ]; then j="$(stored task "$s@$run")"; else
        f="$(ls -t "$rdir"/task/"$s"@*.json 2>/dev/null | head -1)"; [ -z "$f" ] && [ -f "$rdir/task/$s.json" ] && f="$rdir/task/$s.json"; [ -n "$f" ] && j="$(cat "$f")"; fi
      if [ -z "${j:-}" ]; then
        [ -n "$(src "$s" usage)$(src "$s" events)" ] || [ -f "$work/$s/state.json" ] || { echo "report: no records for task '$s'" >&2; exit 1; }
        j="$(build_task "$s" in-progress false "live view of a task that has not ended")"
      fi
    fi
    [ -n "${j:-}" ] || { echo "report: could not build the report" >&2; exit 1; }
    emit "$j" ;;
  session)
    parse "$@"; s="${sub:-latest}"
    case "$s" in latest|current)
      s="$(cat "$work"/*/usage.jsonl "$work"/_archive/*.usage.jsonl 2>/dev/null | jq -rs 'map(select(type == "object" and (.session // "") != "")) | sort_by(.ts) | last.session // empty')"
      [ -n "$s" ] || { echo "report: no ledger row carries a session id yet" >&2; exit 1; } ;; esac
    safe_slug "$s" || { echo "report: bad session id" >&2; exit 2; }
    j="$(stored session "$s")"
    if [ -z "$j" ]; then
      st=running; ended_at=null; rs=""; if [ -f "$rdir/sessions.jsonl" ]; then m="$(jq -c --arg s "$s" 'select(.session == $s)' "$rdir/sessions.jsonl" | tail -1)"; [ -n "$m" ] && { st="$(jq -r .state <<< "$m")"; ended_at="$(jq -c '.ts' <<< "$m")"; rs="$(jq -r '.reason // ""' <<< "$m")"; }; fi
      U="$(usage_json "" "$s")"; [ "$(jq -r '.empty // false' <<< "$U")" = true ] && { echo "report: no records for session '$s'" >&2; exit 1; }
      TK="$( [ -f "$rdir/index.jsonl" ] && jq -sc --arg s "$s" 'map(select(.kind == "task" and ((.sessions // []) | index($s)) != null))' "$rdir/index.jsonl" || echo '[]')"
      j="$(jq -nc --argjson U "$U" --argjson TASKS "$TK" --argjson M "$(jq -nc --arg s "$s" --arg st "$st" --arg r "$rs" --argjson e "$ended_at" --arg now "$(now)" --arg bm "$(baseline_model)" '{session:$s, key:("session:" + $s), state:$st, reason:$r, ended_at:$e, now:$now, baseline_model:$bm}')" "def _x: .; $COMMON $BUILD_SESSION")"
    fi
    emit "$j" ;;
  latest)
    parse "$@"; e="$(latest_entry "")"; [ -n "$e" ] || { echo "report: nothing stored yet (reports are written when a task ends: VALUE_REPORT=on)" >&2; exit 1; }
    j="$(stored "$(jq -r .kind <<< "$e")" "$(jq -r '.file | sub("^[a-z]+/"; "") | sub("\\.json$"; "")' <<< "$e")")"; [ -n "$j" ] && emit "$j" ;;
  history)
    parse "$@"; [ -f "$rdir/index.jsonl" ] || { echo "no stored reports"; exit 0; }
    if [ "$mode" = json ]; then jq -sc 'sort_by(.ts)' "$rdir/index.jsonl" | jq .; else
      jq -rs 'sort_by(.ts) | .[] | [.ts, .kind, .id, .status, (if .kind == "task" then "tokens \(.tokens_fresh // "N/A")" else "tasks \(.tasks)" end), (if .kind == "task" then "cost \(.cost_usd // "N/A")" else "" end), (if .kind == "task" then "saved \(.saved_usd // "N/A")" else "" end)] | @tsv' "$rdir/index.jsonl" | column -t -s "$(printf '\t')"
    fi ;;
  finalize)
    parse "$@"; [ "${VALUE_REPORT:-}" = on ] || [ "$force" = 1 ] || exit 0
    case "$status" in completed|failed|blocked|partial|aborted) ;; *) echo "report: --status must be completed|failed|blocked|partial|aborted" >&2; exit 0 ;; esac
    [ -n "$slug" ] || slug="$(sdkit_active_slug "$top")"; [ -n "$slug" ] && safe_slug "$slug" || exit 0
    j="$(build_task "$slug" "$status" true "terminal state reported by the workflow ($status)")" || exit 0; [ -n "$j" ] || exit 0
    k="$(jq -r .key <<< "$j")"
    if [ -f "$rdir/task/$k.json" ] && [ "$force" = 0 ]; then export_report "$slug" "$(cat "$rdir/task/$k.json")"; [ "$quiet" = 1 ] || echo "SDKit Value Report for $k already exists: sdkit report task $slug" >&2; exit 0; fi
    store task "$k" "$j" || exit 0
    export_report "$slug" "$j"
    [ "$quiet" = 1 ] || { show "$j" text false >&2; } ;;
  session-end)
    parse "$@"; [ "${VALUE_REPORT:-}" = on ] || [ "$force" = 1 ] || exit 0
    [ -n "$sid" ] && safe_slug "$sid" || exit 0
    mkdir -p "$rdir" 2>/dev/null || exit 0
    sdkit_lock "$rdir/sessions.jsonl"
    jq -nc --arg s "$sid" --arg r "$reason" --arg ts "$(now)" '{session:$s, state:"ended", reason:$r, ts:$ts}' >> "$rdir/sessions.jsonl"; sdkit_unlock "$rdir/sessions.jsonl"
    U="$(usage_json "" "$sid")"; [ "$(jq -r '.empty // false' <<< "$U")" = true ] && exit 0
    TK="$( [ -f "$rdir/index.jsonl" ] && jq -sc --arg s "$sid" 'map(select(.kind == "task" and ((.sessions // []) | index($s)) != null))' "$rdir/index.jsonl" || echo '[]')"
    j="$(jq -nc --argjson U "$U" --argjson TASKS "$TK" --argjson M "$(jq -nc --arg s "$sid" --arg r "$reason" --arg now "$(now)" --arg bm "$(baseline_model)" '{session:$s, key:("session:" + $s), state:"ended", reason:$r, ended_at:$now, now:$now, baseline_model:$bm}')" "def _x: .; $COMMON $BUILD_SESSION")" || exit 0
    [ -n "$j" ] && store session "$sid" "$j" && { [ "$TK" != "[]" ] || export_report "$sid" "$j"; [ "$quiet" = 1 ] || show "$j" text false >&2; } ;;
  recover)
    parse "$@"; [ "${VALUE_REPORT:-}" = on ] || [ "$force" = 1 ] || exit 0
    # sessions that left records but never got an end signal and have no stored summary; the newest one may still be running, so it is left alone
    cur="${sid:-}"
    all="$(cat "$work"/*/usage.jsonl "$work"/_archive/*.usage.jsonl 2>/dev/null | jq -rs 'map(select(type == "object" and (.session // "") != "")) | group_by(.session) | map({s: .[0].session, last: (map(.ts) | max)}) | sort_by(.last) | .[].s' 2>/dev/null)"
    [ -n "$all" ] || exit 0
    newest="$(printf '%s\n' "$all" | tail -1)"; n=0
    for s in $all; do
      safe_slug "$s" || continue
      [ "$s" = "$cur" ] && continue; [ "$s" = "$newest" ] && [ -z "$cur" ] && continue
      [ -f "$rdir/session/$s.json" ] && continue
      U="$(usage_json "" "$s")"; [ "$(jq -r '.empty // false' <<< "$U")" = true ] && continue
      TK="$( [ -f "$rdir/index.jsonl" ] && jq -sc --arg s "$s" 'map(select(.kind == "task" and ((.sessions // []) | index($s)) != null))' "$rdir/index.jsonl" || echo '[]')"
      j="$(jq -nc --argjson U "$U" --argjson TASKS "$TK" --argjson M "$(jq -nc --arg s "$s" --arg now "$(now)" --arg bm "$(baseline_model)" '{session:$s, key:("session:" + $s), state:"interrupted", reason:"no end signal", ended_at:null, now:$now, baseline_model:$bm}')" "def _x: .; $COMMON $BUILD_SESSION")" || continue
      [ -n "$j" ] && store session "$s" "$j" && { [ "$TK" != "[]" ] || export_report "$s" "$j"; n=$((n + 1)); }
    done
    [ "$n" -gt 0 ] && [ "$quiet" = 0 ] && echo "SDKit: $n earlier session(s) ended without a signal; their summaries were recovered (interrupted): sdkit report history" >&2
    exit 0 ;;
  regenerate)
    kind="${1:-}"; id="${2:-}"
    case "$kind" in
      task)
        [ -n "$id" ] && safe_slug "$id" || { echo "usage: report.sh regenerate task|session ID" >&2; exit 2; }
        f="$rdir/task/$id.json"; [ -f "$f" ] || f="$(ls -t "$rdir"/task/"$id"@*.json 2>/dev/null | head -1)"; [ -f "$f" ] || { echo "report: no stored report for '$id'" >&2; exit 1; }
        st="$(jq -r '.task.status_requested // .task.status' "$f")"; s="$(jq -r '.task.id' "$f")"
        j="$(build_task "$s" "$st" true "regenerated from the records on disk" true)"; [ -n "$j" ] || exit 1
        [ "$(jq -r '.key' <<< "$j")" = "$(jq -r '.key' "$f")" ] || { echo "report: the run id no longer matches the stored report; nothing was changed" >&2; exit 1; }
        if [ "$(jq -r '.tokens.state' <<< "$j")" = unavailable ] && [ "$(jq -r '.tokens.state' "$f")" != unavailable ]; then
          echo "report: the usage records of '$s' are gone (not archived); the stored report is kept as it is" >&2; exit 0; fi
        store task "$(jq -r .key <<< "$j")" "$j" && echo "regenerated $(jq -r .key <<< "$j")" ;;
      session)
        [ -n "$id" ] && safe_slug "$id" || { echo "usage: report.sh regenerate task|session ID" >&2; exit 2; }
        old="$(stored session "$id")"; st=interrupted; [ -n "$old" ] && st="$(jq -r '.session.state' <<< "$old")"
        U="$(usage_json "" "$id")"; [ "$(jq -r '.empty // false' <<< "$U")" = true ] && { echo "report: no records left for session '$id'; the stored report is kept" >&2; exit 0; }
        TK="$( [ -f "$rdir/index.jsonl" ] && jq -sc --arg s "$id" 'map(select(.kind == "task" and ((.sessions // []) | index($s)) != null))' "$rdir/index.jsonl" || echo '[]')"
        j="$(jq -nc --argjson U "$U" --argjson TASKS "$TK" --argjson M "$(jq -nc --arg s "$id" --arg st "$st" --arg now "$(now)" --arg bm "$(baseline_model)" '{session:$s, key:("session:" + $s), state:$st, reason:"regenerated", ended_at:null, now:$now, baseline_model:$bm, regenerated:true}')" "def _x: .; $COMMON $BUILD_SESSION")"
        store session "$id" "$j" && echo "regenerated session $id" ;;
      *) echo "usage: report.sh regenerate task|session ID" >&2; exit 2 ;;
    esac ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
