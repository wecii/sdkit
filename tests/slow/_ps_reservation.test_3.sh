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

echo "child claude session counted once"
use "$(newrepo k)"; cfg USAGE_LOG=1; mkdir -p .sdkit/work/k1; echo '{"spawns":0}' > .sdkit/work/k1/state.json
tr1="$T/child.jsonl"; jq -nc '{type:"assistant", uuid:"u1", sessionId:"childsess", timestamp:"2026-03-01T10:00:00.000Z", message:{id:"msg_1", model:"m-test", usage:{input_tokens:100, output_tokens:50, cache_read_input_tokens:0, cache_creation_input_tokens:0}}}' > "$tr1"
stopev() { jq -nc --arg t "$tr1" '{hook_event_name:"Stop", session_id:"childsess", transcript_path:$t}' | "$KIT/hooks/usage-log.sh"; }
stopev; eq "an ordinary session Stop is logged (orchestrator snapshot)" "$(cat .sdkit/work/k1/usage.jsonl 2>/dev/null | jq -s 'map(select(.role == "orchestrator")) | length')" 1
rm -f .sdkit/work/k1/usage.jsonl
SDKIT_CHILD_RUN=rr-1-2 stopev; eq "the Stop of a run-role child session logs nothing a second time" "$(cat .sdkit/work/k1/usage.jsonl 2>/dev/null | wc -l | tr -d ' ')" 0
sub="$T/sub.jsonl"; cp "$tr1" "$sub"
jq -nc --arg t "$tr1" --arg a "$sub" '{hook_event_name:"SubagentStop", session_id:"childsess", transcript_path:$t, agent_transcript_path:$a, agent_type:"analyst", agent_id:"ag9"}' | SDKIT_CHILD_RUN=rr-1-2 "$KIT/hooks/usage-log.sh"
eq "…but a subagent inside it keeps its own record"            "$(jq -s 'map(select(.id == "ag9")) | length' .sdkit/work/k1/usage.jsonl)" 1
# run-role hands the marker to the child process only
printf '#!/bin/sh\necho "$SDKIT_CHILD_RUN" > "%s/marker"\necho "{\\"result\\":\\"ok\\"}"\n' "$T" > "$T/bin/claude"
printf 'x\n' > h2.md; "$RR" scout --handoff h2.md --host claude >/dev/null 2>&1
eq "run-role sets SDKIT_CHILD_RUN for its claude child"        "$(cut -c1-3 "$T/marker")" "rr-"
eq "…and not in this shell"                                    "${SDKIT_CHILD_RUN:-unset}" unset

echo "reservation: $pass passed, $failed failed"; [ "$failed" = 0 ]

