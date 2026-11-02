#!/usr/bin/env bash
# Role tiers (AGENT_<ROLE>_TIER in sdkit.env) and the task-size gate (ROUTING=on: `sdd.sh advance proposed` wants size: on every delegated task).
# The template lists every role with its own tier; the helper, route.sh, run-role.sh, the Agent hook, the session start and doctor all follow the setting.
# Deterministic: no host CLI, no network. Run: tests/roletier.test.sh
set -u
[ -n "${PSEC_ONLY:-}" ] || exec "$(dirname "$0")/lib/psections.sh" "$0" "$@"   # chained where marked, otherwise independent sections run at the same time
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (found '$3')" ;; *) ok "$1" ;; esac; }
export PATH="$KIT/tests/stubs:$PATH"
. "$KIT/scripts/env.sh"

echo "the template lists every role with its own tier"
for f in "$KIT"/core/roles/*.md; do
  rl="$(basename "$f" .md)"; case "$rl" in README|orchestrator) continue ;; esac
  k="AGENT_$(printf '%s' "$rl" | tr 'a-z-' 'A-Z_')_TIER"
  eq "$k = the tier core/roles gives $rl" "$(sed -n "s/^$k=//p" "$KIT/templates/sdkit.env")" "$(sdkit_fm "$f" tier)"
done

echo "the helper"
AGENT_ENGINEER_TIER=standard; AGENT_SCOUT_TIER=strong; AGENT_VERIFIER_TIER=light; AGENT_REVIEWER_TIER=strong; AGENT_DEVELOPER_TIER=nonsense; AGENT_ANALYST_TIER=
eq "a developer role moves down"                           "$(sdkit_role_tier engineer strong)" standard
eq "...and up"                                              "$(sdkit_role_tier scout light)" strong
eq "an independent role is never moved below its own tier"  "$(sdkit_role_tier verifier standard)" standard
eq "...but it may go up"                                    "$(sdkit_role_tier reviewer standard)" strong
eq "a value that is not a tier is ignored"                  "$(sdkit_role_tier developer standard)" standard
eq "empty means the role's own tier"                        "$(sdkit_role_tier analyst standard)" standard
eq "an unset role keeps its tier"                           "$(sdkit_role_tier test-writer standard)" standard
eq "verifier-deep keeps its deep tier"                      "$(sdkit_role_tier verifier-deep strong)" strong
eq "the model alias of a tier (Claude Code)"                "$(sdkit_tier_model standard)" sonnet
unset AGENT_ENGINEER_TIER AGENT_SCOUT_TIER AGENT_VERIFIER_TIER AGENT_REVIEWER_TIER AGENT_DEVELOPER_TIER AGENT_ANALYST_TIER

echo "a project"
R="$T/p"; mkdir -p "$R/.sdkit" "$R/openspec/changes/t1" "$R/src"
( cd "$R" && git init -q -b main . && git config user.email t@t && git config user.name t
  printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\nROUTING=on\nRUN_ROLE_HOST=claude\nAGENT_ENGINEER_TIER=standard\nAGENT_SCOUT_TIER=strong\n' > .sdkit/sdkit.env
  printf 'work/\n.sdd/\nsdkit.local.env\n' > .sdkit/.gitignore; printf 'TELEMETRY=1\n' > .sdkit/sdkit.local.env; echo a > src/a.sh; echo 'Do a thing.' > h.md
  printf '# P\n## Definition of Done\n- D1: a | Verified by: unit test\n' > openspec/changes/t1/proposal.md
  git add -A && git commit -qm init && git checkout -qb feat )
cd "$R" || exit 1; export CLAUDE_PROJECT_DIR="$R"
dec() { "$KIT/scripts/route.sh" decide --role "$1" --host claude --json 2>/dev/null | jq -r '.tier'; }
eq "route.sh decides engineer at the configured tier"      "$(dec engineer)" standard
eq "...scout at the configured tier"                        "$(dec scout)" strong
eq "...a role nobody changed at its own tier"               "$(dec developer)" standard
out="$("$KIT/scripts/run-role.sh" engineer --handoff h.md --host claude --dry-run 2>&1)"
has "run-role.sh runs engineer at the configured tier"      "$out" "tier=standard"

echo "the Agent hook (Claude Code)"   # with-previous
hook() { jq -nc --arg r "$1" --arg m "${2:-}" '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:({subagent_type:$r,prompt:"x"} + (if $m == "" then {} else {model:$m} end))}' | "$KIT/hooks/guard-budget.sh" 2>/dev/null | jq -rs 'if length == 0 then "none" else (.[0].hookSpecificOutput.permissionDecision // "none") end'; }
eq "engineer without a model parameter is refused"          "$(hook spec-driven-kit:engineer)" deny
eq "...with the wrong model too"                            "$(hook spec-driven-kit:engineer opus)" deny
eq "...and allowed with the model of its tier"              "$(hook spec-driven-kit:engineer sonnet)" none
eq "a role the project did not move is left alone"          "$(hook spec-driven-kit:developer)" none
reason="$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{subagent_type:"engineer",prompt:"x"}}' | "$KIT/hooks/guard-budget.sh" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason')"
has "the refusal names the setting and the model"           "$reason" 'AGENT_ENGINEER_TIER=standard'
has "...and the model to pass"                              "$reason" 'model "sonnet"'
sed -i.bak 's/^SDD_MODE=strict/SDD_MODE=off/' .sdkit/sdkit.env; rm -f .sdkit/sdkit.env.bak
eq "SDD_MODE=off turns the hook off"                        "$(hook engineer)" none
sed -i.bak 's/^SDD_MODE=off/SDD_MODE=strict/' .sdkit/sdkit.env; rm -f .sdkit/sdkit.env.bak

echo "the session start tells the orchestrator"   # with-previous
ctx="$(echo '{}' | "$KIT/hooks/session-context.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext')"
has "engineer is listed with its model"                     "$ctx" 'engineer=standard(model sonnet)'
has "...scout too"                                          "$ctx" 'scout=strong(model opus)'
hasnt "...a role nobody moved is not"                       "$ctx" 'developer='

echo "the size gate"   # with-previous
printf -- '- [ ] T1 first | role: developer | writes: src/ | after:\n- [ ] T2 second | role: test-writer | size: small | writes: tests/ | after: T1\n- [ ] T3 note without a role\n' > openspec/changes/t1/tasks.md
"$KIT/scripts/sdd.sh" start t1 --risk low --proposal openspec/changes/t1/proposal.md >/dev/null 2>&1
msg="$("$KIT/scripts/sdd.sh" advance proposed 2>&1)"; rc=$?
eq "ROUTING=on: a role task without size: is refused"       "$rc" 1
has "...naming the task"                                    "$msg" 'T1 '
hasnt "...not the ones that have a size or no role"         "$msg" 'T2 have'
has "...and saying what to do"                              "$msg" 'model-routing.md'
eq "the phase did not move"                                 "$("$KIT/scripts/sdd.sh" phase)" intake
has "the refusal is recorded with its reason"               "$(jq -r 'select(.type == "phase.reject") | .reason' .sdkit/work/t1/events.jsonl 2>/dev/null | tail -1)" no-task-size
sed -i.bak 's/| role: developer |/| role: developer | size: medium |/' openspec/changes/t1/tasks.md; rm -f openspec/changes/t1/tasks.md.bak
"$KIT/scripts/sdd.sh" advance proposed >/dev/null 2>&1; eq "with every size: given it moves on"   "$?" 0
"$KIT/scripts/sdd.sh" abort >/dev/null 2>&1
printf -- '- [ ] T1 first | role: developer | writes: src/\n' > openspec/changes/t1/tasks.md
"$KIT/scripts/sdd.sh" start t1 --risk low --proposal openspec/changes/t1/proposal.md >/dev/null 2>&1
printf 'ROUTE_REQUIRE_SIZE=0\n' >> .sdkit/sdkit.env
"$KIT/scripts/sdd.sh" advance proposed >/dev/null 2>&1; eq "ROUTE_REQUIRE_SIZE=0 opts out"        "$?" 0
"$KIT/scripts/sdd.sh" abort >/dev/null 2>&1
sed -i.bak 's/^ROUTE_REQUIRE_SIZE=0/ROUTE_REQUIRE_SIZE=1/; s/^ROUTING=on/ROUTING=off/' .sdkit/sdkit.env; rm -f .sdkit/sdkit.env.bak
"$KIT/scripts/sdd.sh" start t1 --risk low --proposal openspec/changes/t1/proposal.md >/dev/null 2>&1
"$KIT/scripts/sdd.sh" advance proposed >/dev/null 2>&1; eq "ROUTING=off: no size is needed"       "$?" 0

echo "doctor"
D="$T/d"; mkdir -p "$D"; ( cd "$D" && git init -q -b main . ); "$KIT/bin/init.sh" "$D" >/dev/null 2>&1
printf 'AGENT_ENGINEER_TIER=standart\nAGENT_VERIFIER_TIER=light\nAGENT_PLUMBER_TIER=light\nAGENT_ANALYST_TIER=light\n' >> "$D/.sdkit/sdkit.env"
out="$("$KIT/bin/doctor.sh" "$D" 2>&1)"
has "a misspelled tier is reported"                         "$out" 'AGENT_ENGINEER_TIER=standart is not a tier'
has "an independent role below its tier is reported"        "$out" 'AGENT_VERIFIER_TIER=light is below'
has "an unknown role is reported"                           "$out" "there is no role 'plumber'"
hasnt "a good value is not"                                 "$out" 'AGENT_ANALYST_TIER=light is'

echo
echo "role tiers: $pass passed, $fail failed"
[ "$fail" = 0 ]
