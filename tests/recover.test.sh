#!/usr/bin/env bash
# F18 recovery: interrupted bookkeeping is found and closed safely, idempotently; nothing is re-run; a BLOCK stays a BLOCK. No model.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"; RC="$KIT/scripts/recover.sh"; SDD="$KIT/scripts/sdd.sh"; DP="$KIT/scripts/dispatch.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; export VERIFY_BASE=main
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
R="$T/r"; mkdir -p "$R/.sdkit" "$R/src" "$R/openspec/changes/t1"; cd "$R" && git init -q -b main . && git config user.email t@t && git config user.name t
printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=strict\nPARALLEL=on\n' > .sdkit/sdkit.env; : > .sdkit/sdkit.local.env; printf 'work/\n.sdd/\n' > .sdkit/.gitignore
echo a > src/a.sh; printf '# P\n## Definition of Done\n- D1: a | Verified by: unit test\n' > openspec/changes/t1/proposal.md; git add -A; git commit -qm i; git checkout -qb feat
export CLAUDE_PROJECT_DIR="$R"
"$KIT/scripts/state.sh" t1 init medium feat >/dev/null; "$SDD" start t1 --risk medium --proposal openspec/changes/t1/proposal.md >/dev/null; "$SDD" advance proposed >/dev/null
M="$T/green.mark"; "$SDD" advance red --test-cmd "[ -f '$M' ]" >/dev/null; echo x >> src/a.sh; touch "$M"; "$SDD" advance green >/dev/null   # green re-runs the command red was bound to
"$SDD" _evidence verifier BLOCK >/dev/null 2>&1
before="$(jq -c '.evidence' .sdkit/.sdd/state.json)"
# interrupted: a spawn registered long ago, a handoff issued and never answered, a dispatch claim never finished
"$SDD" _spawn verifier --source run-role --run dead-run >/dev/null 2>&1
mkdir -p .sdkit/work/t1/contracts; echo '{"id":"t1/lbl","role":"developer","state":"issued"}' > .sdkit/work/t1/contracts/lbl.json
printf -- '- [ ] T1 a | role: developer | writes: src/ | after:\n' > "$T/tasks.md"; "$DP" claim T1 "$T/tasks.md" --slug t1 >/dev/null 2>&1

echo "fresh work is not stale"
eq "nothing is stale within the window"          "$(RECOVER_STALE_S=3600 "$RC" scan t1 --json | jq '[.[] | select(.kind != "evidence" and .kind != "routing")] | length')" 0
echo "scan (read-only)"
export RECOVER_STALE_S=0
out="$("$RC" scan t1 --json)"
eq "finds the spawn"                              "$(jq '[.[] | select(.kind == "spawn")] | length' <<< "$out")" 1
eq "scan changed nothing"                         "$(jq -c '.evidence' .sdkit/.sdd/state.json)" "$before"
echo "apply"
"$RC" apply t1 >/dev/null 2>&1
eq "the spawn registration is gone"               "$(jq '[.spawns // [] | .[] | select(.run == "dead-run")] | length' .sdkit/.sdd/state.json)" 0
eq "the contract is closed as interrupted"       "$(jq -r .state .sdkit/work/t1/contracts/lbl.json)" interrupted
eq "the dispatch claim is released"               "$("$DP" status --slug t1 | grep -c 'T1 active')" 0
eq "the verifier BLOCK is untouched"              "$(jq -c '.evidence' .sdkit/.sdd/state.json)" "$before"
eq "each action is logged"                        "$(wc -l < .sdkit/work/t1/recovery.jsonl | tr -d ' ')" 3
echo "idempotent"
"$RC" apply t1 >/dev/null 2>&1
eq "a second apply closes nothing more"          "$(wc -l < .sdkit/work/t1/recovery.jsonl | tr -d ' ')" 3
echo "unreadable state is reported, never guessed"
cp .sdkit/.sdd/state.json "$T/keep"; echo '{broken' > .sdkit/.sdd/state.json
eq "reported as manual"                           "$("$RC" scan t1 --json | jq '[.[] | select(.kind == "state" and (.applicable | not))] | length')" 1
"$RC" apply t1 >/dev/null 2>&1; eq "apply leaves it alone" "$(cat .sdkit/.sdd/state.json)" "{broken"
echo "recover: $pass passed, $failed failed"; [ "$failed" = 0 ]
