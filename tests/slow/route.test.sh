#!/usr/bin/env bash
# F06 tests: deterministic orchestration (scripts/route.sh) and its consumer run-role.sh. No model, no network, no paid call: the only "provider" is a fake CLI.
# Covers: registry and configuration, routing by risk/role/capability, overrides, scheduling (mandatory, optional, reuse, stale, duplicates, concurrency),
# retry and escalation by failure class, budgets (hard vs advisory, unavailable usage, cost), telemetry, compatibility with routing off, and an untouched source tree.
# Run: tests/slow/route.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"; kill $(jobs -p) 2>/dev/null' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (should have failed)"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }

ksum() { (cd "$KIT" && git status --porcelain -- bench >/dev/null 2>&1; find bench -type f ! -name .DS_Store | sort | xargs shasum | shasum | cut -d' ' -f1); }
BENCH0="$(ksum)"
RT="$KIT/scripts/route.sh"; SDD="$KIT/scripts/sdd.sh"; RR="$KIT/scripts/run-role.sh"; US="$KIT/scripts/usage.sh"
export SDKIT_GREEN="${TMPDIR:-/tmp}/sdkit-green.$$"   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }
export VERIFY_BASE=main SDKIT_ROUTE_NO_SLEEP=1

# a repo: newrepo <name> [sdkit.env line]...   (settings go to sdkit.env; budgets to sdkit.local.env via local)
newrepo() {
  local r="$T/$1"; shift; mkdir -p "$r/.sdkit" "$r/src" "$r/openspec/changes/t1"
  ( cd "$r" && git init -q -b main . && git config user.email t@t && git config user.name t
    printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\nRUN_ROLE_HOST=claude\nROUTING=on\nTELEMETRY=1\n' > .sdkit/sdkit.env
    for l in "$@"; do printf '%s\n' "$l" >> .sdkit/sdkit.env; done
    : > .sdkit/sdkit.local.env
    printf 'work/\n.sdd/\n.verify-cache/\nsdkit.local.env\n' > .sdkit/.gitignore
    echo a > src/a.sh; printf '# P\n## Definition of Done\n- D1: a | Verified by: t\n' > openspec/changes/t1/proposal.md
    printf '# D\n## Race scenario\ntwo writers\n' > openspec/changes/t1/design.md
    git add -A && git commit -qm init && git checkout -qb feat )
  echo "$r"
}
use() { cd "$1" || exit 1; export CLAUDE_PROJECT_DIR="$1"; R="$1"; ST="$1/.sdkit/.sdd/state.json"; LED="$1/.sdkit/work/_misc/routing.jsonl"; }
local_env() { printf '%s\n' "$@" >> "$R/.sdkit/sdkit.local.env"; }
green() { "$KIT/scripts/state.sh" t1 init "$1" feat >/dev/null; "$SDD" start t1 --risk "$1" ${2:+--profile "$2"} --proposal openspec/changes/t1/proposal.md >/dev/null && "$SDD" advance proposed >/dev/null \
    && sdd_red >/dev/null && echo "x$RANDOM" >> src/a.sh && sdd_green >/dev/null; }
# j <field> <command...>: one field of a decision
j() { local f="$1"; shift; "$@" 2>/dev/null | jq -r "$f"; }
dec() { "$RT" decide --json "$@"; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

# fake host CLI (claude and opencode): prints FAKE_ANSWER as the result; FAKE_RC the exit status; FAKE_ERR its stderr; FAKE_NOUSAGE drops the usage block; every call is counted
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'X'
#!/usr/bin/env bash
echo x >> "${FAKE_CALLS:-/dev/null}"
[ "${FAKE_RC:-0}" = 0 ] || { echo "${FAKE_ERR:-boom}" >&2; exit "$FAKE_RC"; }
if [ -n "${FAKE_COST:-}" ]; then jq -n --arg r "$(cat "$FAKE_ANSWER")" --argjson c "$FAKE_COST" '{result:$r, usage:{input_tokens:100,output_tokens:50}, total_cost_usd:$c}'; exit 0; fi
if [ -n "${FAKE_NOUSAGE:-}" ]; then jq -n --arg r "$(cat "$FAKE_ANSWER")" '{result:$r}'; else jq -n --arg r "$(cat "$FAKE_ANSWER")" '{result:$r, usage:{input_tokens:100,output_tokens:50}}'; fi
X
cat > "$T/bin/opencode" <<'X'
#!/usr/bin/env bash
echo x >> "${FAKE_CALLS:-/dev/null}"; cat "$FAKE_ANSWER"
X
chmod +x "$T/bin/claude" "$T/bin/opencode"; export PATH="$T/bin:$PATH"
cat > "$T/ver-pass" <<'X'
DOD
- D1 a | PASS | t:1
FINDINGS
- none
VERIFY
- command: v | result: green | ok
VERDICT: PASS
X
cat > "$T/ver-garbage" <<'X'
looks fine to me
X
cat > "$T/aud-pass" <<'X'
NO FINDINGS
- checked authz on src/a.sh
SUMMARY: 0 critical, 0 high, 0 medium, 0 low
VERDICT: PASS
X
cat > "$T/aud-block" <<'X'
- HIGH | src/a.sh:1 | IDOR | GET /x?id=2 | reads another user | check ownership
SUMMARY: 0 critical, 1 high, 0 medium, 0 low
VERDICT: BLOCK
X
cat > "$T/rev-pass" <<'X'
- MINOR | src/a.sh:1 | naming | a nit | rename
SUMMARY: 0 blockers, 0 major, 1 minor
VERDICT: PASS
X
cat > "$T/rev-block" <<'X'
- BLOCKER | src/a.sh:1 | error handling | swallowed | handle it
SUMMARY: 1 blockers, 0 major, 0 minor
VERDICT: BLOCK
X
printf 'do the thing\n' > "$T/handoff"; printf 'do another thing\n' > "$T/handoff2"
export FAKE_CALLS="$T/calls"; calls() { [ -f "$FAKE_CALLS" ] && wc -l < "$FAKE_CALLS" | tr -d ' ' || echo 0; }

echo "configuration and registry"
use "$(newrepo cfg)"
check "default configuration validates"                   "$RT" validate
eq "the registry derives claude tiers from tiers.env"     "$(j '[.[] | select(.adapter=="claude") | .model] | join(",")' "$RT" registry --json)" "haiku,sonnet,opus"
eq "hosts without tier models are one inherit entry"      "$(j '[.[] | select(.id=="gemini:inherit") | .tier] | .[0]' "$RT" registry --json)" "*"
eq "codex tiers are reasoning efforts, not models"        "$(j '[.[] | select(.adapter=="codex") | .effort] | join(",")' "$RT" registry --json)" "low,medium,high"
eq "no cost is invented without a pricing table"          "$(j '[.[] | select(.cost != null)] | length' "$RT" registry --json)" 0
echo '{"sonnet":{"in":3,"out":15}}' > .sdkit/pricing.json
eq "cost comes only from the user's pricing table"        "$(j '[.[] | select(.cost != null) | .id] | join(",")' "$RT" registry --json)" "claude:standard"
rm .sdkit/pricing.json
eq "every adapter lists its capabilities explicitly"      "$(j 'to_entries | map(.value.caps | keys | length) | unique | join(",")' "$RT" capabilities --json)" 8
eq "no capability claims live verification"               "$(j '[.. | strings | select(. == "verified")] | length' "$RT" capabilities --json)" 0
eq "cancellation is unsupported everywhere"              "$(j '[.[] | .caps | select(.cancellation != "none")] | length' "$RT" capabilities --json)" 0
eq "no adapter claims billed or actual cost"              "$(j '[.[] | .caps.cost_reporting] | unique | sort | join(",")' "$RT" capabilities --json)" "estimated,none"
eq "only claude reports a (client-side, estimated) cost"  "$(j 'to_entries | map(select(.value.caps.cost_reporting == "estimated") | .key) | join(",")' "$RT" capabilities --json)" claude
# the claims are checked against what run-role really does (routing off: the command line as the flags give it)
LEG="$(newrepo legacy)"; sed -i.bak 's/^ROUTING=on/ROUTING=off/' "$LEG/.sdkit/sdkit.env"
for h in claude codex opencode cursor gemini; do
  mc="$(jq -r --arg h "$h" '.[$h].caps.model_selection' "$KIT/core/adapters.json")"
  out="$(echo x > "$T/hx"; "$RR" developer --handoff "$T/hx" --host "$h" --model m-probe --cwd "$LEG" --dry-run 2>&1)"
  if [ "$mc" = none ]; then nocheck "$h: no model_selection claim, no model flag" bash -c "grep -q m-probe <<< '$out'"; else check "$h: model_selection claim matches run-role's command line" bash -c "grep -q m-probe <<< '$out'"; fi
done
eq "claude reports tokens (parsed by run-role)"           "$(jq -r '.claude.caps.usage_reporting' "$KIT/core/adapters.json")" declared
eq "codex/opencode/cursor claim no usage reporting"       "$(jq -r '[.codex,.opencode,.cursor] | map(.caps.usage_reporting) | unique | join(",")' "$KIT/core/adapters.json")" none
printf 'ROUTE_POLICY=sideways\n' >> .sdkit/sdkit.env; eq "bad ROUTE_POLICY fails validation" "$(rc "$RT" validate)" 2
sed -i.bak '$d' .sdkit/sdkit.env; printf 'ROUTE_MAX_RETRIES=lots\n' >> .sdkit/sdkit.env; eq "non-numeric limit fails validation" "$(rc "$RT" validate)" 2
sed -i.bak '$d' .sdkit/sdkit.env; printf 'ROUTE_FALLBACK_HOSTS=nosuchhost\n' >> .sdkit/sdkit.env; eq "unknown fallback host fails validation" "$(rc "$RT" validate)" 2
sed -i.bak '$d' .sdkit/sdkit.env
printf '[{"id":"x","adapter":"nope","tier":"standard"}]' > .sdkit/models.json; eq "models.json with an unknown adapter fails validation" "$(rc "$RT" validate)" 2
printf '[{"id":"x","adapter":"claude","tier":"huge"}]' > .sdkit/models.json; eq "models.json with a bad tier fails validation" "$(rc "$RT" validate)" 2
printf '{"id":"x"}' > .sdkit/models.json; eq "models.json that is not an array fails validation" "$(rc "$RT" validate)" 2
printf '[{"id":"cx","adapter":"claude","model":"my-model","tier":"standard"},{"id":"claude:strong","adapter":"claude","model":"opus","tier":"strong","status":"disabled"}]' > .sdkit/models.json
check "a valid models.json validates"                     "$RT" validate
eq "project entries come first and override derived ones" "$(j '.[0].id' "$RT" registry --json)" cx
eq "a disabled override removes the derived entry"        "$(j '[.[] | select(.id=="claude:strong") | .status] | .[0]' "$RT" registry --json)" disabled
rm .sdkit/models.json

echo "routing by risk, role and capability"
use "$(newrepo rt)"
for r in low medium high; do eq "developer at $r risk: the role's own tier, nothing cheaper by default" "$(j '.tier' dec --role developer --risk $r)" standard; done
eq "scout stays light at high risk (a lookup role has no floor)" "$(j '.tier' dec --role scout --risk high)" light
eq "verifier at low risk: its own tier"                   "$(j '.model' dec --role verifier --risk low)" sonnet
eq "verifier at high risk: the deep tier, strong model"   "$(j '[.tier, .model, .reason] | join(",")' dec --role verifier --risk high)" "strong,opus,RISK_FLOOR_APPLIED"
eq "security-auditor at high risk keeps its own tier"     "$(j '.tier' dec --role security-auditor --risk high)" standard
eq "engineer's own strong tier holds at low risk"         "$(j '.tier' dec --role engineer --risk low)" strong
eq "no open task: risk is assumed medium and says so"     "$(j '[.risk, .risk_source] | join(",")' dec --role developer)" ",assumed"
check "the decision carries every minimal field"          bash -c "'$RT' decide --role developer --risk low --json | jq -e 'has(\"decision_id\") and has(\"task\") and has(\"role\") and has(\"action\") and has(\"adapter\") and has(\"model\") and has(\"budget\") and has(\"attempt\") and has(\"reason\") and has(\"policy_version\")'"
eq "policy version is stamped"                            "$(j '.policy_version' dec --role developer --risk low)" route-v1
eq "identical inputs give an identical decision"          "$(dec --role verifier --risk high | shasum)" "$(dec --role verifier --risk high | shasum)"
eq "a size override raises a work role"                   "$(j '.model' dec --role developer --risk low --tier large)" opus
eq "a size override cannot lower an independent role"     "$(j '.tier' dec --role verifier --risk low --tier small)" standard
eq "explain prints the decision without a model call"     "$("$RT" explain --role developer --risk medium | sed -n '1p;3p;4p;5p;7p' | tr '\n' '|')" "Task: _misc|Role: developer (work)|Decision: execute|Adapter: claude|Reason: ROLE_CAPABILITY_MATCH|"
check "explain records nothing"                           test ! -f .sdkit/work/_misc/routing.jsonl
eq "unknown role is refused"                              "$(rc "$RT" decide --role nosuchrole --risk low)" 2
eq "unknown role reason"                                  "$(j '.reason' dec --role nosuchrole --risk low)" UNKNOWN_ROLE
NH="$(newrepo nohost)"; sed -i.bak '/RUN_ROLE_HOST/d' "$NH/.sdkit/sdkit.env"; cd "$NH"; export CLAUDE_PROJECT_DIR="$NH"
eq "NO_ADAPTER when nothing names a host (refused, not guessed)" "$(j '.reason' dec --role developer --risk low)" NO_ADAPTER
eq "NO_ADAPTER exits 2"                                   "$(rc "$RT" decide --role developer --risk low)" 2
cd "$R"; export CLAUDE_PROJECT_DIR="$R"
eq "VERIFIER_HOST routes the independent roles"           "$(VERIFIER_HOST=codex j '.adapter' dec --role verifier --risk low)" codex
printf 'VERIFIER_HOST=codex\n' >> .sdkit/sdkit.env
eq "codex carries a reasoning effort, no model name"      "$(j '[.adapter, .model, .effort] | join(",")' dec --role verifier --risk low)" "codex,,medium"
sed -i.bak '/VERIFIER_HOST/d' .sdkit/sdkit.env
eq "a host with no configured model runs its default and says the tier is unenforced" "$(j '[.adapter, .tier_enforced, (.warnings[0] | split(":")[0])] | join(",")' dec --role developer --risk low --host gemini)" "gemini,false,MODEL_INHERITED"
eq "an unknown host is refused"                           "$(j '.reason' dec --role developer --risk low --host nosuchhost)" ADAPTER_UNSUPPORTED
# a missing compatible model, and adapters that lack a needed capability (a private copy of the kit with an edited adapters file)
printf '[{"id":"claude:strong","adapter":"claude","model":"opus","tier":"strong","status":"disabled"}]' > .sdkit/models.json
eq "no compatible model for the deep verifier: refused"   "$(j '.reason' dec --role verifier --risk high)" NO_COMPATIBLE_MODEL
eq "...and it exits 2, nothing runs"                      "$(rc "$RT" decide --role verifier --risk high)" 2
eq "a lower tier is never substituted for a missing one"  "$(j '.model // ""' dec --role verifier --risk high)" ""
rm .sdkit/models.json
KC="$T/kit"; mkdir -p "$KC"; cp -R "$KIT/scripts" "$KIT/core" "$KC/"
jq '.claude.caps.noninteractive = "none"' "$KIT/core/adapters.json" > "$KC/core/adapters.json"
eq "an adapter that cannot run noninteractively is unusable" "$(j '.reason' "$KC/scripts/route.sh" decide --role developer --risk low --json)" ADAPTER_UNSUPPORTED
jq '.claude.caps.model_selection = "none"' "$KIT/core/adapters.json" > "$KC/core/adapters.json"
eq "an adapter without model selection cannot honour a model" "$(j '.reason' "$KC/scripts/route.sh" decide --role developer --risk low --json)" ADAPTER_UNSUPPORTED
jq '.claude.caps.usage_reporting = "none"' "$KIT/core/adapters.json" > "$KC/core/adapters.json"; local_env TOKEN_BUDGET_TASK=1000
eq "no usage reporting: still routable, budget demoted to advisory" "$(j '[.action, .budget.task_tokens.enforcement] | join(",")' "$KC/scripts/route.sh" decide --role developer --risk low --json)" "execute,advisory"
eq "...with the limitation recorded"                      "$(j '.warnings[0] | split(":")[0]' "$KC/scripts/route.sh" decide --role developer --risk low --json)" USAGE_UNAVAILABLE
: > .sdkit/sdkit.local.env

echo "overrides, preferences, fixed policy, fallback"
eq "--model that is in the registry is applied"           "$(j '[.model, .reason] | join(",")' dec --role developer --risk low --model opus)" "opus,OVERRIDE_APPLIED"
eq "--model not in the registry is refused with a reason" "$(j '[.reason, (.notes[0] | test("not in the registry"))] | join(",")' dec --role developer --risk low --model gpt-nonexistent)" "OVERRIDE_INVALID,true"
eq "--model below the floor of a gate role is refused"    "$(j '.reason' dec --role verifier --risk low --model haiku)" OVERRIDE_BELOW_FLOOR
eq "...also at high risk (deep tier floor)"               "$(j '.reason' dec --role verifier --risk high --model sonnet)" OVERRIDE_BELOW_FLOOR
eq "an override above the floor is fine"                  "$(j '.model' dec --role verifier --risk low --model opus)" opus
eq "an invalid override exits 2"                          "$(rc "$RT" decide --role developer --risk low --model nope)" 2
printf 'ROUTE_PREFER_DEVELOPER=claude:strong\n' >> .sdkit/sdkit.env
eq "a role preference picks the registry entry"           "$(j '[.model, .reason] | join(",")' dec --role developer --risk low)" "opus,PREFERENCE_APPLIED"
sed -i.bak '$d' .sdkit/sdkit.env; printf 'ROUTE_PREFER_DEVELOPER=nope:nope\n' >> .sdkit/sdkit.env
eq "a preference naming nothing fails clearly"            "$(j '.reason' dec --role developer --risk low)" PREFERENCE_INVALID
eq "an invalid preference also fails validation"          "$(rc "$RT" validate)" 2
sed -i.bak '$d' .sdkit/sdkit.env; printf 'ROUTE_PREFER_VERIFIER=claude:light\n' >> .sdkit/sdkit.env
eq "a preference cannot undercut a gate role's tier"      "$(j '.reason' dec --role verifier --risk low)" PREFERENCE_BELOW_FLOOR
sed -i.bak '$d' .sdkit/sdkit.env
printf 'ROUTE_POLICY=fixed\nROUTE_FIXED_MODEL=claude:standard\n' >> .sdkit/sdkit.env
eq "fixed policy: one model for the work roles"           "$(j '[.model, .reason] | join(",")' dec --role developer --risk low)" "sonnet,FIXED_POLICY"
eq "fixed policy: no risk-based change"                   "$(j '.model' dec --role developer --risk high)" sonnet
eq "fixed policy never lowers the high-risk floor"        "$(j '.reason' dec --role verifier --risk high)" FIXED_BELOW_FLOOR
sed -i.bak -E '/ROUTE_POLICY|ROUTE_FIXED/d' .sdkit/sdkit.env
printf 'ROUTE_DOWNGRADE_LOW=1\n' >> .sdkit/sdkit.env
eq "opt-in downgrade: low-risk work runs light"           "$(j '[.model, .reason] | join(",")' dec --role developer --risk low)" "haiku,DOWNGRADE_LOW_RISK"
eq "...never at medium risk"                              "$(j '.model' dec --role developer --risk medium)" sonnet
eq "...never for an independent role"                     "$(j '.model' dec --role verifier --risk low)" sonnet
eq "...and an unknown risk is not treated as low"         "$(j '.model' dec --role developer)" sonnet
sed -i.bak '/DOWNGRADE/d' .sdkit/sdkit.env
printf 'ROUTE_FLOOR_HIGH=strong\n' >> .sdkit/sdkit.env
eq "a configured risk floor raises work roles"            "$(j '[.model, .reason] | join(",")' dec --role developer --risk high)" "opus,RISK_FLOOR_APPLIED"
sed -i.bak '/ROUTE_FLOOR/d' .sdkit/sdkit.env
sed -i.bak 's/^RUN_ROLE_HOST=.*/RUN_ROLE_HOST=bogus/' .sdkit/sdkit.env; printf 'ROUTE_FALLBACK_HOSTS=claude\n' >> .sdkit/sdkit.env
eq "fallback host takes over when the first cannot run"   "$(j '[.adapter, .reason] | join(",")' dec --role developer --risk low)" "claude,ADAPTER_FALLBACK"
eq "an explicit --host never falls back"                  "$(j '.reason' dec --role developer --risk low --host bogus)" ADAPTER_UNSUPPORTED
sed -i.bak 's/^RUN_ROLE_HOST=.*/RUN_ROLE_HOST=claude/; /FALLBACK/d' .sdkit/sdkit.env
eq "--require-cli: a host whose CLI is absent is skipped" "$(PATH="/usr/bin:/bin" j '.reason' "$RT" decide --role developer --risk low --json --require-cli)" ADAPTER_UNSUPPORTED

echo "scheduling: mandatory, optional, reuse, stale, duplicates"
use "$(newrepo hi)"; green high || bad "could not open a high-risk task"
eq "high risk: verifier, reviewer, security-auditor are mandatory" "$(for r in verifier reviewer security-auditor; do j '.mandatory' dec --role $r; done | paste -sd, -)" "true,true,true"
eq "high risk: the developer is not a gate"               "$(j '.mandatory' dec --role developer)" false
eq "the open task's risk is used"                         "$(j '[.risk, .risk_source] | join(",")' dec --role verifier)" "high,task"
eq "no evidence yet: the verifier executes"               "$(j '.action' dec --role verifier --handoff "$T/handoff")" execute
eq "...high-risk verification is the strong model"        "$(j '.model' dec --role verifier --handoff "$T/handoff")" opus
rr() { local role="$1" ans="$2"; shift 2; FAKE_ANSWER="$ans" "$RR" "$role" --handoff "$T/handoff" --cwd "$R" "$@"; }
rr verifier "$T/ver-pass" >/dev/null 2>"$T/err"; eq "run-role executes the decision (verifier at high risk)" "$?" 0
eq "...the fake CLI ran once"                             "$(calls)" 1
eq "...the verdict was recorded as trusted evidence"      "$(jq -r '.evidence.verifier | [.result, .trust] | join(",")' "$ST")" "PASS,spawned"
check "...run-role announced the decision"                grep -q 'routing: execute claude/opus tier=strong' "$T/err"
eq "valid trusted evidence for this diff is reused"       "$(j '[.action, .reason] | join(",")' dec --role verifier --handoff "$T/handoff")" "reuse,EVIDENCE_REUSED"
snap() { { jq -S 'del(.updated)' "$R/.sdkit/work/t1/state.json"; jq -S . "$ST"; wc -l < "$R/.sdkit/work/t1/routing.jsonl" | tr -d ' ' >/dev/null; } | shasum | cut -c1-16; }
S0="$(snap)"; outs0="$(grep -c '"type":"outcome"' "$R/.sdkit/work/t1/routing.jsonl")"
rr verifier "$T/ver-pass" >/dev/null 2>"$T/err"; eq "run-role does not run a reused role (exit 7)" "$?" 7
check "...exit 7 says it is not a failure and not to retry" grep -q 'NOT A FAILURE' "$T/err"
eq "decide exits 7 for reuse, the success-like code"      "$(rc "$RT" decide --role verifier --handoff "$T/handoff")" 7
eq "reuse changed neither task state, evidence nor spawn registrations" "$(snap)" "$S0"
eq "reuse recorded no outcome and so no failure class"    "$(grep -c '"type":"outcome"' "$R/.sdkit/work/t1/routing.jsonl")" "$outs0"
eq "reuse did not touch the code-correction retry"        "$(jq -r '(.retries // {}) | length' "$R/.sdkit/work/t1/state.json")" 0
eq "reuse is not counted as a spawn"                      "$(jq -r '.spawns // 0' "$R/.sdkit/work/t1/state.json")" 1
eq "...no second call was made"                           "$(calls)" 1
rr verifier "$T/ver-pass" --rerun "second look requested by the user" >/dev/null 2>&1; eq "an explicit --rerun reason runs it again" "$?" 0
eq "...and is recorded as such"                           "$(jq -rs '[.[] | select(.type=="decision" and .action=="execute")] | last | .reason' "$R/.sdkit/work/t1/routing.jsonl")" RERUN_REQUESTED
echo "edit$RANDOM" >> src/a.sh
eq "a changed diff makes the evidence stale: execute"     "$(j '[.action, (.notes | join(";") | test("not valid"))] | join(",")' dec --role verifier --handoff "$T/handoff")" "execute,true"
eq "...and the stale evidence never satisfied the gate"   "$("$SDD" evidence --json | jq -r '.[] | select(.role=="verifier") | .state')" stale
eq "no evidence for the security-auditor: execute"        "$(j '.action' dec --role security-auditor --handoff "$T/handoff")" execute
rr security-auditor "$T/aud-block" >/dev/null 2>&1; eq "a security BLOCK run exits 0 (the verdict is evidence)" "$?" 0
eq "...--ignore-budget cannot reopen a standing BLOCK"      "$(j '.reason' dec --role security-auditor --handoff "$T/handoff" --ignore-budget)" SECURITY_BLOCK
eq "a standing security BLOCK is not re-run on the same diff" "$(j '[.action, .reason] | join(",")' dec --role security-auditor --handoff "$T/handoff")" "stop,SECURITY_BLOCK"
eq "...a different handoff does not change that"          "$(j '.reason' dec --role security-auditor --handoff "$T/handoff2")" SECURITY_BLOCK
eq "...a different provider does not change that"         "$(j '.reason' dec --role security-auditor --handoff "$T/handoff" --host codex)" SECURITY_BLOCK
eq "...nor does --rerun"                                  "$(j '.reason' dec --role security-auditor --handoff "$T/handoff" --rerun "please")" SECURITY_BLOCK
n0="$(calls)"; rr security-auditor "$T/aud-pass" >/dev/null 2>"$T/err"; eq "run-role refuses to turn the BLOCK into a PASS (exit 8, not 7)" "$?" 8
check "...and says it is NOT a success"                   grep -q 'NOT RUN' "$T/err"
eq "decide exits 8 for a standing BLOCK"                  "$(rc "$RT" decide --role security-auditor --handoff "$T/handoff")" 8
eq "...and starts nothing"                                "$(calls)" "$n0"
eq "the recorded evidence is still the BLOCK"             "$(jq -r '.evidence["security-auditor"].result' "$ST")" BLOCK
rr reviewer "$T/rev-block" >/dev/null 2>&1
eq "a reviewer BLOCK stands too (verification failure)"   "$(j '.reason' dec --role reviewer --handoff "$T/handoff")" VERIFICATION_FAILED
echo "edit$RANDOM" >> src/a.sh
eq "after the diff changes the BLOCK no longer stands"    "$(j '.action' dec --role security-auditor --handoff "$T/handoff")" execute

echo "scheduling: optional roles, profiles, duplicates, concurrency"
use "$(newrepo med)"; green medium || bad "could not open a medium task"
eq "medium risk: the verifier is mandatory"               "$(j '.mandatory' dec --role verifier)" true
eq "medium risk: reviewer and security-auditor are optional" "$(for r in reviewer security-auditor scout analyst; do j '.mandatory' dec --role $r; done | paste -sd, -)" "false,false,false,false"
use "$(newrepo lowt)"; green low || bad "could not open a low task"
eq "low risk, standard profile: no mandatory verifier"    "$(j '.mandatory' dec --role verifier)" false
use "$(newrepo ha)"; green low high-assurance || bad "could not open a high-assurance task"
eq "high-assurance profile: verifier mandatory even at low risk" "$(j '[.mandatory, .profile] | join(",")' dec --role verifier)" "true,high-assurance"
eq "...the profile never changes the risk floor"          "$(j '.tier' dec --role verifier)" standard
use "$(newrepo dup)"
sleep 60 & LIVE=$!
# several simultaneous requests for the same run: exactly one may start
for i in 1 2 3 4 5 6; do ( dec --role developer --risk low --handoff "$T/handoff" --reserve --pid "$LIVE" > "$T/c$i.json" 2>/dev/null ) & done; wait $(jobs -p | grep -v "^$LIVE$") 2>/dev/null
eq "concurrent identical requests: exactly one executes"  "$(cat "$T"/c?.json | jq -rs '[.[] | select(.action=="execute")] | length')" 1
eq "...the others are refused as duplicates in flight"    "$(cat "$T"/c?.json | jq -rs '[.[] | select(.reason=="DUPLICATE_IN_FLIGHT")] | length')" 5
eq "...and only one run was counted"                      "$(jq -rs '[.[] | select(.type=="decision" and .action=="execute")] | length' "$LED")" 1
eq "a different handoff is a different request"           "$(j '.action' dec --role developer --risk low --handoff "$T/handoff2" --reserve --pid "$LIVE")" execute
id1="$(jq -rs '[.[] | select(.action=="execute")] | .[0].id' "$LED")"
"$RT" outcome --decision "$id1" --rc 0 >/dev/null
eq "a completed identical request is a duplicate"         "$(j '.reason' dec --role developer --risk low --handoff "$T/handoff")" DUPLICATE_COMPLETED
eq "...unless a reason to rerun is given"                 "$(j '[.action, .reason] | join(",")' dec --role developer --risk low --handoff "$T/handoff" --rerun "inputs changed")" "execute,RERUN_REQUESTED"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
# the second request (handoff2) was in flight under a process that is now gone: it is closed as interrupted and retried, not duplicated
eq "a run whose process died is closed as INTERRUPTED and retried" "$(j '[.action, .reason] | join(",")' dec --role developer --risk low --handoff "$T/handoff2" --reserve --pid $$)" "retry,RETRY_INTERRUPTED"
eq "...the interruption is in the ledger"                 "$(jq -rs '[.[] | select(.class=="INTERRUPTED")] | length' "$LED")" 1

echo "retry and escalation by failure class"
use "$(newrepo rty)"
# step <rc> <stderr text> [prc] [role]: close the last reserved decision with that outcome, then ask again
ask() { local o; o="$(dec --role "${1:-developer}" --risk medium --handoff "$T/handoff" --reserve --pid $$ ${2:+--host "$2"})"; jq -r .decision_id <<< "$o" > "$T/lastid"; echo "$o"; }
fail_with() { printf '%s' "$2" > "$T/err.txt"; "$RT" outcome --decision "$(cat "$T/lastid")" --rc "$1" --stderr "$T/err.txt" ${3:+--prc "$3"} >/dev/null; }
resetled() { rm -rf "$R/.sdkit/work"; rm -f "$T/lastid"; }
eq "classify: 503 is transient"                           "$(printf '503 Service Unavailable' > "$T/e"; "$RT" classify --rc 1 --stderr "$T/e")" TRANSIENT
eq "classify: 429 is a rate limit"                        "$(printf 'Error 429 Too Many Requests' > "$T/e"; "$RT" classify --rc 1 --stderr "$T/e")" RATE_LIMIT
eq "classify: deadline exceeded is a timeout"             "$(printf 'context deadline exceeded' > "$T/e"; "$RT" classify --rc 1 --stderr "$T/e")" TIMEOUT
eq "classify: exit 124 is a timeout"                      "$("$RT" classify --rc 124)" TIMEOUT
eq "classify: exit 6 is invalid structured output"       "$("$RT" classify --rc 6)" INVALID_OUTPUT
eq "classify: exit 4 is a contract failure"               "$("$RT" classify --rc 4)" CONTRACT_FAILURE
eq "classify: exit 5 is a reported failure"               "$("$RT" classify --rc 5)" REPORTED_FAILURE
eq "classify: exit 3 is budget exhaustion"                "$("$RT" classify --rc 3)" BUDGET_EXHAUSTED
eq "classify: exit 127 is a missing host"                 "$("$RT" classify --rc 127)" HOST_MISSING
eq "classify: an unexplained error stays unclassified"    "$(printf 'kaboom' > "$T/e"; "$RT" classify --rc 1 --stderr "$T/e")" UNKNOWN
eq "classify: ok with a BLOCK verdict is a verification failure" "$("$RT" classify --rc 0 --prc 1)" VERDICT_BLOCK
ask >/dev/null; fail_with 1 "503 Service Unavailable"
eq "transient: retry, same model, reason says why"        "$(ask | jq -r '[.action, .reason, .model, .attempt, .previous.failure_class] | join(",")')" "retry,RETRY_TRANSIENT,sonnet,2,TRANSIENT"
fail_with 1 "502 bad gateway"; ask >/dev/null; fail_with 1 "network down"
eq "transient: bounded by ROUTE_MAX_RETRIES (2)"          "$(ask | jq -r '[.action, .reason] | join(",")')" "stop,RETRIES_EXHAUSTED"
check "infrastructure retries did not touch the code-correction retry" bash -c "! jq -e '(.retries // {}) | length > 0' '$R/.sdkit/work/state.json' 2>/dev/null"
resetled; ask >/dev/null; fail_with 1 "429 rate limit exceeded"
eq "rate limit: retry with a backoff, observable"         "$(ask | jq -r '[.action, .reason, .wait_s] | join(",")')" "retry,RETRY_RATE_LIMIT,10"
fail_with 1 "429"; eq "rate limit: the backoff grows"     "$(ask | jq -r '.wait_s')" 20
resetled; ask >/dev/null; fail_with 124 ""
eq "timeout: retry once more, reason recorded"            "$(ask | jq -r '[.action, .reason] | join(",")')" "retry,RETRY_TIMEOUT"
resetled; ask >/dev/null; fail_with 6 "no verdict"
eq "malformed output: one retry first"                    "$(ask | jq -r '[.action, .reason, .model] | join(",")')" "retry,RETRY_INVALID_OUTPUT,sonnet"
fail_with 6 ""
eq "...then escalation to the next tier"                  "$(ask | jq -r '[.action, .reason, .model, .tier] | join(",")')" "escalate,ESCALATE_INVALID_OUTPUT,opus,strong"
fail_with 6 ""
eq "...and then it stops: escalation is bounded"          "$(ask | jq -r '[.action, .reason] | join(",")')" "stop,ESCALATION_LIMIT"
resetled; ask >/dev/null; fail_with 4 ""; ask >/dev/null; fail_with 4 ""
eq "contract failure escalates after one retry"           "$(ask | jq -r '.action')" escalate
resetled; printf 'ROUTE_ESCALATE_TO=standard\n' >> .sdkit/sdkit.env; ask >/dev/null; fail_with 6 ""; ask >/dev/null; fail_with 6 ""
eq "escalation stops at ROUTE_ESCALATE_TO"                "$(ask | jq -r '[.action, .reason] | join(",")')" "stop,NO_ESCALATION_TARGET"
sed -i.bak '/ESCALATE_TO/d' .sdkit/sdkit.env
resetled; ask >/dev/null; fail_with 1 "kaboom"
eq "an unexplained failure is not retried blindly"        "$(ask | jq -r '[.action, .reason] | join(",")')" "stop,UNCLASSIFIED_FAILURE"
resetled; ask >/dev/null; fail_with 5 ""
eq "a reported failure is the workflow's decision, not a retry" "$(ask | jq -r '[.action, .reason] | join(",")')" "stop,REPORTED_FAILURE"
resetled; ask security-auditor >/dev/null; fail_with 0 "" 1
eq "security BLOCK outcome: stop"                         "$(ask security-auditor | jq -r '[.action, .reason] | join(",")')" "stop,SECURITY_BLOCK"
eq "...also when another provider is asked"               "$(ask security-auditor codex | jq -r '.reason')" SECURITY_BLOCK
resetled; ask verifier >/dev/null; fail_with 0 "" 1
eq "verification failure outcome: stop, no re-verification of the same request" "$(ask verifier | jq -r '[.action, .reason] | join(",")')" "stop,VERIFICATION_FAILED"
resetled; ask >/dev/null; fail_with 127 ""
eq "a missing host CLI moves to the fallback adapter"     "$(printf 'ROUTE_FALLBACK_HOSTS=opencode\n' >> .sdkit/sdkit.env; ask | jq -r '[.action, .reason, .adapter] | join(",")')" "retry,ADAPTER_FALLBACK,opencode"
sed -i.bak '/FALLBACK/d' .sdkit/sdkit.env
resetled; printf 'ROUTE_MAX_ATTEMPTS=2\n' >> .sdkit/sdkit.env; ask >/dev/null; fail_with 1 "503"; ask >/dev/null; fail_with 1 "503"
eq "ROUTE_MAX_ATTEMPTS caps the whole chain"              "$(ask | jq -r '[.action, .reason] | join(",")')" "stop,RETRIES_EXHAUSTED"
sed -i.bak '/MAX_ATTEMPTS/d' .sdkit/sdkit.env
resetled; ask developer gemini >/dev/null; fail_with 6 ""; ask developer gemini >/dev/null; fail_with 6 ""
eq "a host-default model cannot be escalated"             "$(ask developer gemini | jq -r '[.action, .reason] | join(",")')" "stop,NO_ESCALATION_TARGET"

echo "budgets: hard, advisory, unavailable usage, cost, recovery"
use "$(newrepo bud)"; green medium || bad "could not open a task"
slug=t1; uf="$R/.sdkit/work/t1/usage.jsonl"
"$US" log --role developer --model sonnet --in 6000 --out 2000 --slug t1 --force --tq actual >/dev/null
local_env TOKEN_BUDGET_TASK=10000 MAX_SPAWNS=3
eq "under budget: execute; the figures are exact"         "$(j '[.action, .budget.task_tokens.used, .budget.task_tokens.remaining, .budget.task_tokens.enforcement] | join(",")' dec --role developer)" "execute,8000,2000,hard"
eq "the budget line says what a hard limit does and does not cover" "$(j '.budget.task_tokens.scope | test("not cut off")' dec --role developer)" true
"$US" log --role developer --model sonnet --in 1500 --out 1000 --slug t1 --force --tq actual >/dev/null   # 10500 of 10000
eq "over the token budget: a mandatory role is stopped, not skipped" "$(j '[.action, .reason, .mandatory] | join(",")' dec --role verifier)" "stop,BUDGET_EXHAUSTED,true"
eq "...exit 3"                                            "$(rc "$RT" decide --role verifier)" 3
eq "...the workflow phase is untouched"                   "$(jq -r .phase "$ST")" green
eq "...no PASS evidence was fabricated"                   "$(jq -r '.evidence.verifier // "none"' "$ST")" none
n0="$(calls)"; FAKE_ANSWER="$T/ver-pass" "$RR" verifier --handoff "$T/handoff" --cwd "$R" >/dev/null 2>"$T/err"; eq "run-role: budget exhausted exits 3" "$?" 3
eq "...nothing was started"                               "$(calls)" "$n0"
check "...and the recovery path is printed"               grep -q 'ignore-budget' "$T/err"
eq "a work role is stopped the same way"                  "$(j '.reason' dec --role developer)" BUDGET_EXHAUSTED
eq "--ignore-budget (user agreed) runs it and records that" "$(j '[.action, (.warnings[0] | split(":")[0])] | join(",")' dec --role verifier --ignore-budget)" "execute,BUDGET_OVERRIDDEN"
sed -i.bak 's/^SDD_MODE=.*/SDD_MODE=guided/' .sdkit/sdkit.env
eq "SDD_MODE=guided only warns"                           "$(j '[.action, (.warnings[0] | split(":")[0])] | join(",")' dec --role verifier)" "execute,BUDGET_REACHED"
sed -i.bak 's/^SDD_MODE=.*/SDD_MODE=off/' .sdkit/sdkit.env
eq "SDD_MODE=off evaluates no budget"                     "$(j '[.action, (.warnings // [] | length)] | join(",")' dec --role verifier)" "execute,0"
sed -i.bak 's/^SDD_MODE=.*/SDD_MODE=strict/' .sdkit/sdkit.env
: > .sdkit/sdkit.local.env; local_env TOKEN_BUDGET_TASK=20000 MAX_SPAWNS=3
eq "recovery: raising the budget lets the same role run"  "$(j '[.action, .budget.task_tokens.remaining] | join(",")' dec --role verifier)" "execute,9500"
: > .sdkit/sdkit.local.env; local_env TOKEN_BUDGET_TASK=10000 TOKEN_BUDGET_WARN_PCT=70
rm -f "$uf"; "$US" log --role developer --model sonnet --in 5000 --out 2500 --slug t1 --force --tq actual >/dev/null   # 75%: warn
eq "at the warning level an optional role is skipped, with a reason" "$(j '[.action, .reason] | join(",")' dec --role reviewer)" "stop,OPTIONAL_SKIPPED"
eq "...a lookup role too"                                 "$(j '.reason' dec --role scout)" OPTIONAL_SKIPPED
eq "...but the mandatory verifier still runs"             "$(j '.action' dec --role verifier)" execute
eq "...and so does the work role"                         "$(j '.action' dec --role developer)" execute
eq "--rerun overrides an optional skip"                   "$(j '.action' dec --role reviewer --rerun "user asked for a review")" execute
# unavailable usage is not zero
rm -f "$uf"; "$US" log --role developer --model sonnet --in 0 --out 0 --slug t1 --force --tq unavailable >/dev/null
eq "all runs unreported: used is null, not 0"             "$(j '.budget.task_tokens.used' dec --role developer)" null
eq "...accounting says unavailable and the limit is advisory" "$(j '[.budget.accounting, .budget.task_tokens.enforcement] | join(",")' dec --role developer)" "unavailable,advisory"
eq "...an unmeasured run never exhausts the budget"       "$(j '.action' dec --role developer)" execute
"$US" log --role developer --model sonnet --in 4000 --out 1000 --slug t1 --force --tq actual >/dev/null
eq "mixed: the figure is a lower bound and says so"       "$(j '[.budget.accounting, .budget.task_tokens.used, (.warnings[0] | split(":")[0])] | join(",")' dec --role developer)" "partial,5000,USAGE_PARTIAL"
eq "usage report flags the unmeasured run"                "$("$US" report t1 | grep -c 'reported no token usage')" 1
# per-role budget
: > .sdkit/sdkit.local.env; local_env ROUTE_ROLE_TOKENS=4000
rm -f "$uf"; "$US" log --role verifier --model sonnet --in 3000 --out 1500 --slug t1 --force --tq actual >/dev/null
eq "per-role budget stops that role"                      "$(j '.reason' dec --role verifier)" BUDGET_EXHAUSTED
eq "...but not other roles"                               "$(j '.action' dec --role developer)" execute
eq "...the deep variant counts against the same role"     "$(j '.reason' dec --role verifier-deep)" BUDGET_EXHAUSTED
# spawns are hard and counted at the reservation
: > .sdkit/sdkit.local.env; local_env MAX_SPAWNS=2
rm -f "$uf"
a1="$(j '.action' dec --role developer --handoff "$T/handoff" --reserve --pid $$)"; "$RT" outcome --decision "$(jq -rs 'last | select(.type=="decision") | .id' "$R/.sdkit/work/_misc/routing.jsonl" 2>/dev/null || echo x)" --rc 0 >/dev/null 2>&1
eq "invocations: the first reservation counts one spawn"   "$(jq -r '.spawns' "$R/.sdkit/work/t1/state.json")" 1
dec --role developer --handoff "$T/handoff2" --reserve --pid $$ >/dev/null
eq "invocations: the limit is reached after two"          "$(j '[.action, .budget.invocations.enforcement] | join(",")' dec --role developer --handoff "$T/handoff3" --reserve --pid $$)" "stop,hard"
# timeout enforcement depends on a real command
: > .sdkit/sdkit.local.env; local_env ROUTE_TIMEOUT_S=30
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then want=hard; else want=advisory; fi
eq "timeout is hard only where a timeout command exists"  "$(j '.budget.timeout_enforcement' dec --role developer)" "$want"
eq "the timeout is part of the decision"                  "$(j '.timeout_s' dec --role developer)" 30
# money: advisory and estimated, never actual
: > .sdkit/sdkit.local.env; local_env ROUTE_BUDGET_COST=0.001
eq "no priced usage: the cost limit is unmeasurable, not zero" "$(j '[.budget.cost.estimated_usd, (.warnings[0] | split(":")[0])] | join(",")' dec --role developer)" ",COST_UNMEASURABLE"
echo '{"sonnet":{"in":3,"out":15}}' > .sdkit/pricing.json
"$US" log --role developer --model sonnet --in 100000 --out 10000 --slug t1 --force --tq actual >/dev/null
eq "priced usage gives an estimate"                       "$(j '.budget.cost.estimated_usd' dec --role developer)" 0.45
eq "...actual cost is always null (no adapter reports it)" "$(j '.budget.cost.actual_usd' dec --role developer)" null
eq "...and the limit is advisory: a warning, still executes" "$(j '[.action, .budget.cost.enforcement, (.warnings[0] | split(":")[0])] | join(",")' dec --role developer)" "execute,advisory,COST_ESTIMATE_OVER_BUDGET"
rm -f .sdkit/pricing.json

echo "integration: run-role consumes the decision (fake CLI)"
use "$(newrepo ir USAGE_LOG=1)"; green medium || bad "could not open a task"
rm -f "$FAKE_CALLS"
rr() { local role="$1" ans="$2"; shift 2; FAKE_ANSWER="$ans" "$RR" "$role" --handoff "$T/handoff" --cwd "$R" "$@"; }
rr verifier "$T/ver-pass" >/dev/null 2>"$T/err"; eq "routed run: exit 0" "$?" 0
eq "...the model came from the decision"                  "$(grep -c 'routing: execute claude/sonnet tier=standard reason=ROLE_CAPABILITY_MATCH' "$T/err")" 1
eq "...an outcome is in the ledger (OK, usage actual)"    "$(jq -rs '[.[] | select(.type=="outcome")] | last | [.class, .tokens_quality, .tokens.in] | join(",")' "$R/.sdkit/work/t1/routing.jsonl")" "OK,actual,100"
rr developer "$T/ver-pass" --handoff "$T/handoff" >/dev/null 2>&1
FAKE_NOUSAGE=1 rr developer "$T/ver-pass" --handoff "$T/handoff2" >/dev/null 2>&1
eq "a host that prints no usage: the outcome has null tokens, not 0" "$(jq -rs '[.[] | select(.type=="outcome")] | last | [(.tokens == null), .tokens_quality] | join(",")' "$R/.sdkit/work/t1/routing.jsonl")" "true,unavailable"
eq "...and the usage ledger marks it unmeasured"          "$(tail -1 "$R/.sdkit/work/t1/usage.jsonl" | jq -r .tq)" unavailable
FAKE_RC=1 FAKE_ERR="503 Service Unavailable" rr developer "$T/ver-pass" --handoff "$T/handoff" --rerun "x" >/dev/null 2>&1; eq "host failure: the host's status is returned" "$?" 1
eq "...and is classified in the ledger"                   "$(jq -rs '[.[] | select(.type=="outcome")] | last | .class' "$R/.sdkit/work/t1/routing.jsonl")" TRANSIENT
FAKE_ANSWER="$T/ver-pass" "$RR" developer --handoff "$T/handoff" --cwd "$R" >/dev/null 2>"$T/err"; eq "the next request after the failure is a retry" "$(grep -c 'routing: retry' "$T/err")" 1
printf 'third task\n' > "$T/handoff3"
FAKE_ANSWER="$T/ver-pass" "$RR" developer --handoff "$T/handoff3" --cwd "$R" --model nonexistent >/dev/null 2>"$T/err"; eq "run-role: an invalid --model is refused (exit 2)" "$?" 2
check "...with the reason"                                grep -q 'OVERRIDE_INVALID' "$T/err"
eq "ROUTING=on without route.sh refuses to run"           "$(mkdir -p "$T/lone" && cp "$KIT/scripts/run-role.sh" "$KIT/scripts/env.sh" "$T/lone/" && FAKE_ANSWER="$T/ver-pass" "$T/lone/run-role.sh" developer --handoff "$T/handoff" --cwd "$R" >/dev/null 2>&1; echo $?)" 2
out="$(CLAUDE_PROJECT_DIR="$R" "$RR" developer --handoff "$T/handoff3" --cwd "$R" --dry-run 2>&1)"
check "dry run shows the routed command"                  grep -q -- '--model sonnet' <<< "$out"
check "dry run records no decision"                       bash -c "! jq -e 'select(.source==\"run-role\")' '$R/.sdkit/work/t1/routing.jsonl' 2>/dev/null | grep -q dry"
# contracted handoff failure after the decision closes the decision instead of leaving it in flight
printf 'CONTRACT: 1\nID: \n' > "$T/badc"
FAKE_ANSWER="$T/ver-pass" "$RR" developer --handoff "$T/badc" --cwd "$R" >/dev/null 2>&1; eq "an invalid contract exits 2" "$?" 2
eq "...and leaves no run in flight"                       "$(jq -rs '(map(select(.type=="outcome") | .id)) as $d | [.[] | select(.type=="decision" and .action=="execute" and (.id as $i | $d | index($i) | not))] | length' "$R/.sdkit/work/t1/routing.jsonl")" 0
echo "telemetry and the Claude Code hook"
check "decisions are telemetry events (source routing)"   bash -c "jq -e 'select(.type==\"workflow.decision\" and .source==\"routing\")' '$R/.sdkit/work/t1/events.jsonl' >/dev/null"
check "the event stream still validates"                  "$KIT/scripts/telemetry.sh" validate t1
hook() { jq -nc --arg r "$1" --arg m "${2:-}" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:({subagent_type:$r,prompt:"x"} + (if $m != "" then {model:$m} else {} end))}' | "$KIT/hooks/guard-budget.sh"; }
use "$(newrepo hk)"; green high >/dev/null
hdec() { local o; o="$(hook "$@")"; if [ -z "$o" ]; then echo allow; else jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "$o"; fi; }
check "hook: a first verifier spawn is allowed"           bash -c "! hook_out=\"\$($(declare -f hook); CLAUDE_PROJECT_DIR='$R' hook verifier)\"; [ -z \"\$hook_out\" ]"
eq "hook: a model below the role's floor makes it ask"    "$(hdec verifier haiku)" ask
eq "hook: the model that meets the floor is allowed"      "$(hdec verifier opus)" allow
eq "hook: routing off changes nothing"                    "$(sed -i.bak 's/^ROUTING=on/ROUTING=off/' .sdkit/sdkit.env; hdec verifier haiku)" allow
sed -i.bak 's/^ROUTING=off/ROUTING=on/' .sdkit/sdkit.env

echo "compatibility: routing off (the default) changes nothing"
use "$(newrepo off)"; sed -i.bak 's/^ROUTING=on/ROUTING=off/' .sdkit/sdkit.env; green medium >/dev/null
check "ROUTING is on in the shipped template (measurement)" grep -q '^ROUTING=on' "$KIT/templates/sdkit.env"
off1="$("$RR" verifier --handoff "$T/handoff" --cwd "$R" --host claude --tier large --dry-run 2>&1)"
check "off: legacy tier/model resolution is unchanged"    grep -q -- '--model opus' <<< "$off1"
eq "off: run-role makes no routing record"                "$(FAKE_ANSWER="$T/ver-pass" "$RR" developer --handoff "$T/handoff" --cwd "$R" >/dev/null 2>&1; ls "$R/.sdkit/work/t1/routing.jsonl" 2>/dev/null | wc -l | tr -d ' ')" 0
eq "off: the legacy budget stop still exits 3"            "$(local_env TOKEN_BUDGET_TASK=10 USAGE_LOG=1; "$US" log --role developer --in 50 --out 50 --slug t1 --force --tq actual >/dev/null; FAKE_ANSWER="$T/ver-pass" "$RR" developer --handoff "$T/handoff" --cwd "$R" >/dev/null 2>&1; echo $?)" 3
eq "off: explain says run-role ignores the decision"      "$("$RT" explain --role developer --risk low | grep -c 'ignores this decision')" 1
check "no host: legacy error unchanged"                   bash -c "sed -i.bak '/RUN_ROLE_HOST/d' '$R/.sdkit/sdkit.env'; ! '$RR' developer --handoff '$T/handoff' --cwd '$R' --dry-run 2>&1 | grep -q routing"

eq "a misspelt ROUTING value refuses to run (fails closed)" "$(sed -i.bak 's/^ROUTING=.*/ROUTING=ON/' "$R/.sdkit/sdkit.env"; "$RR" developer --handoff "$T/handoff3" --cwd "$R" --host claude --dry-run >/dev/null 2>&1; echo $?)" 2

echo "F06.1: exit codes, probe, cost provenance, fingerprint reuse, benchmark isolation"
use "$(newrepo xc)"; green medium >/dev/null
eq "optional skipped exits 8 (not run, not success)"      "$(local_env TOKEN_BUDGET_TASK=1000 USAGE_LOG=1; "$US" log --role developer --in 800 --out 0 --slug t1 --force --tq actual >/dev/null; rc "$RT" decide --role reviewer)" 8
eq "budget exhausted still exits 3"                       "$("$US" log --role developer --in 800 --out 0 --slug t1 --force --tq actual >/dev/null; rc "$RT" decide --role verifier)" 3
eq "a refusal by policy still exits 2"                    "$(rc "$RT" decide --role developer --model nope)" 2
: > .sdkit/sdkit.local.env; rm -f .sdkit/work/t1/usage.jsonl
dec --role developer --handoff "$T/handoff" --reserve --pid $$ >/dev/null; "$RT" outcome --decision "$(jq -rs 'last | .id' "$R/.sdkit/work/t1/routing.jsonl")" --rc 0 >/dev/null
eq "a completed duplicate exits 8"                        "$(rc "$RT" decide --role developer --handoff "$T/handoff")" 8
check "the docs tell callers 7 is reuse and 8 is not run"  bash -c "grep -q 'exit 7' '$KIT/skills/spec-driven-dev/references/hosts.md' && grep -q 'exit 8' '$KIT/skills/spec-driven-dev/references/hosts.md'"
eq "the benchmark harness never enables routing (7/8 cannot arise there)" "$(grep -rl ROUTING "$KIT/bench" 2>/dev/null | wc -l | tr -d ' ')" 0
eq "ROUTE_DOWNGRADE_LOW stays off in the shipped template (no comparable F05-B result exists)" "$(sed -n 's/^ROUTE_DOWNGRADE_LOW=//p' "$KIT/templates/sdkit.env")" 0
# one sdd.sh call gives states and fingerprint; the plain form is unchanged
use "$(newrepo fp)"; green high >/dev/null
eq "evidence --json is still an array of roles"            "$("$SDD" evidence --json | jq -r 'type')" array
eq "evidence --json --with-fingerprint adds the fingerprint it judged against" "$("$SDD" evidence --json --with-fingerprint | jq -r '[.fingerprint == "'"$("$SDD" fingerprint)"'", (.roles | length)] | join(",")')" "true,3"
# probe: reads only --help of installed CLIs
PB="$T/pb"; mkdir -p "$PB"; JQD="$(dirname "$(command -v jq)")"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "fake 9.9"; exit 0; }\necho "  -p, --print   print"; echo "  --model <m>"; echo "  --output-format <f>"; echo "  --disallowedTools <t>"; echo "  --permission-mode <m>"\n' > "$PB/claude"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "fake 9.9"; exit 0; }\necho "  -p, --print   print"; echo "  --output-format <f>"; echo "  --disallowedTools <t>"; echo "  --permission-mode <m>"\n' > "$PB/claude2"
chmod +x "$PB/claude" "$PB/claude2"
eq "probe: flags in --help -> help-verified"               "$(PATH="$PB:$JQD:/usr/bin:/bin" "$RT" capabilities --probe claude | grep -o 'model_selection=[^ ]*')" "model_selection=help-verified"
mkdir -p "$T/pb2"; cp "$PB/claude2" "$T/pb2/claude"
eq "probe: a flag missing from --help is named"            "$(PATH="$T/pb2:$JQD:/usr/bin:/bin" "$RT" capabilities --probe claude | grep -o 'model_selection=[^ ]*')" "model_selection=MISSING:--model"
eq "probe: a CLI that is not installed stays declared and says so" "$(PATH="$PB:$JQD:/usr/bin:/bin" "$RT" capabilities --probe gemini | grep -c 'not installed here')" 1
eq "only CLIs that were actually checked here carry help-verified" "$(jq -r '[to_entries[] | select(.key | startswith("_") | not) | select([.value.caps[] | select(. == "help-verified")] | length > 0) | .key] | join(",")' "$KIT/core/adapters.json")" "$(jq -r '._checked | keys | join(",")' "$KIT/core/adapters.json")"
eq "every help-verified capability has probe flags to re-check it" "$(jq -r '[to_entries[] | select(.key | startswith("_") | not) | . as $a | $a.value.caps | to_entries[] | select(.value == "help-verified") | select(($a.value.probe.flags[.key] // []) | length == 0)] | length' "$KIT/core/adapters.json")" 0
# cost: the host's own estimate is kept apart from the price-table estimate and from anything billed
printf 'task 4\n' > "$T/handoff4"; printf 'task 5\n' > "$T/handoff5"
use "$(newrepo cs USAGE_LOG=1)"; green medium >/dev/null; local_env ROUTE_BUDGET_COST=0.05
rr() { local role="$1" ans="$2"; shift 2; FAKE_ANSWER="$ans" "$RR" "$role" --handoff "$T/handoff" --cwd "$R" "$@"; }
FAKE_COST=0.0321 rr developer "$T/ver-pass" >/dev/null 2>&1
eq "a numeric total_cost_usd is stored as a host estimate"  "$(tail -1 .sdkit/work/t1/usage.jsonl | jq -r '[.cost_est_usd, .cost_src] | join(",")')" "0.0321,host-estimate"
eq "...with provenance in the routing ledger"              "$(jq -rs '[.[] | select(.type=="outcome")] | last | [.host_cost_estimate_usd, .cost_provenance] | join("|")' .sdkit/work/t1/routing.jsonl)" "0.0321|host client-side estimate (not billed)"
eq "...reported apart from the price-table estimate and the (absent) billed amount" "$(j '.budget.cost | [.host_reported_estimate_usd, .estimated_usd, .actual_usd, .host_reported_runs] | map(tostring) | join(",")' dec --role developer --handoff "$T/handoff2")" "0.0321,null,null,1"
eq "...the provenance is stated in the decision"           "$(j '.budget.cost.host_reported_provenance | test("not a billed")' dec --role developer --handoff "$T/handoff2")" true
FAKE_COST=0.04 rr developer "$T/ver-pass" --handoff "$T/handoff2" >/dev/null 2>&1
eq "the host estimates add up"                             "$(j '.budget.cost.host_reported_estimate_usd' dec --role developer --handoff "$T/handoff3")" 0.0721
eq "over the money limit: a warning that says whose estimate it is, still executes" "$(j '[.action, (.warnings[] | select(startswith("COST_HOST")) | test("not a bill"))] | map(tostring) | join(",")' dec --role developer --handoff "$T/handoff3")" "execute,true"
FAKE_COST='"abc"' rr developer "$T/ver-pass" --handoff "$T/handoff3" >/dev/null 2>&1
eq "a non-numeric cost is ignored, never written as 0"      "$(tail -1 .sdkit/work/t1/usage.jsonl | jq -r 'has("cost_est_usd")')" false
FAKE_COST=-1 rr developer "$T/ver-pass" --handoff "$T/handoff4" >/dev/null 2>&1
eq "a negative cost is ignored"                            "$(tail -1 .sdkit/work/t1/usage.jsonl | jq -r 'has("cost_est_usd")')" false
rr developer "$T/ver-pass" --handoff "$T/handoff5" >/dev/null 2>&1
eq "no total_cost_usd: no cost field at all (not 0)"        "$(tail -1 .sdkit/work/t1/usage.jsonl | jq -r 'has("cost_est_usd")')" false
check "run-role never resumes a session (so the cost is per run, not cumulative)" bash -c "! '$RR' developer --handoff '$T/handoff' --cwd '$R' --host claude --dry-run 2>&1 | grep -E -q -- '--(resume|continue)'"
use "$KIT"

echo "integrity"
eq "benchmark harness, fixtures and baselines are untouched" "$(ksum)" "$BENCH0"
check "route.sh passes bash -n"                           bash -n "$RT"
check "adapters.json is valid JSON"                       jq -e . "$KIT/core/adapters.json"
if command -v shellcheck >/dev/null 2>&1; then check "route.sh passes shellcheck (errors)" shellcheck -S error "$RT"; fi
echo
echo "route tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
