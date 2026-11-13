#!/usr/bin/env bash
# generate-tasks core (F07): AC trace, cycles, approval gate, stable externalIds, rendered task accepted by jira.sh. No model, no network.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"; TS="$KIT/scripts/tasks.sh"; JS="$KIT/scripts/jira.sh"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
R="$T/r"; mkdir -p "$R/specs/s1"; cd "$R" && git init -q . && git config user.email t@t && git config user.name t
printf '# s1\nAC-1 does a\nAC-2 does b\n' > specs/s1/spec.md; echo '{"id":"s1","version":"1.0","status":"approved"}' > specs/s1/spec.meta.json
git add -A; git commit -qm spec; SHA="$(git rev-parse HEAD)"
# spec.sh stub (owned by another agent): approves only the SHA listed in $T/approved
cat > "$T/spec.sh" <<'X'
#!/usr/bin/env bash
[ "$1" = approved-sha ] && [ "$(cat "$(dirname "$0")/approved" 2>/dev/null)" = "$4" ]
X
chmod +x "$T/spec.sh"; echo "$SHA" > "$T/approved"; export SPEC_SH="$T/spec.sh" TASKS_REPO="$R"
mk() { jq -n --arg sha "$1" --argjson t "$2" '{specId:"s1",specVersion:"1.0",specSha:$sha,parent:"PROJ-1",tasks:$t}'; }
TA='[{"ref":"A","title":"a","risk":"low","acceptanceCriteria":["AC-1"],"dependsOn":[],"scope":["src/a/"]},{"ref":"B","title":"b","risk":"high","acceptanceCriteria":["AC-2"],"dependsOn":["A"],"scope":["src/b/"]}]'
mk "$SHA" "$TA" > "$T/t.json"; printf 'AC-1\nAC-2\n' > "$T/ac"; echo AC-3 >> "$T/ac"
eq "an unmapped AC is rejected"              "$(rc "$TS" trace "$T/t.json" "$T/ac")" 1
printf 'AC-1,AC-2\n' > "$T/ac"; eq "full coverage passes" "$(rc "$TS" trace "$T/t.json" "$T/ac")" 0
mk "$SHA" "$(jq -c '(.[0].dependsOn)=["B"]' <<< "$TA")" > "$T/cyc.json"
eq "a cycle is detected (exit 1, cycle printed)" "$(rc "$TS" cycles "$T/cyc.json"):$("$TS" cycles "$T/cyc.json" 2>&1 | grep -c -- '->')" "1:1"
OTHER="$(printf 'b%.0s' $(seq 40))"; mk "$OTHER" "$TA" > "$T/bad.json"
eq "an unapproved SHA is refused"            "$(rc "$TS" ids "$T/bad.json")" 3
mk "$SHA" "$(jq -c 'reverse | map(.title += " (renamed)")' <<< "$TA")" > "$T/t2.json"
eq "externalIds are stable across reruns, order and title" "$(diff <("$TS" ids "$T/t.json" | jq -c '[.tasks[]|{ref,externalId}]|sort') <("$TS" ids "$T/t2.json" | jq -c '[.tasks[]|{ref,externalId}]|sort') >/dev/null; echo $?)" 0
eq "a rendered task passes jira.sh validate-task" "$("$TS" render "$T/t.json" B | "$JS" validate-task - | jq -r '.specId + .risk')" s1high
# per change: the key includes the change slug; a revision lists only the ACs its changes added or modified
mk "$SHA" "$(jq -c '.[0].change = "c1"' <<< "$TA")" > "$T/t3.json"
eq "the change slug changes the key (a modified AC gets a new task)" "$([ "$("$TS" ids "$T/t.json" | jq -r '.tasks[0].key')" != "$("$TS" ids "$T/t3.json" | jq -r '.tasks[0].key')" ] && echo diff)" diff
mkdir -p specs/s1/changes/c1; printf '# s1\n#### Scenario: AC-1 - a\n#### Scenario: AC-2 - b\n#### Scenario: AC-3 (withdrawn) - c\n#### Scenario: AC-4 - d\n' > specs/s1/spec.md
echo '{"slug":"c1","status":"applied","applied":{"version":"1.1"},"touches":["AC-2","AC-3","AC-4"]}' > specs/s1/changes/c1/change.json
echo '{"slug":"old","status":"applied","applied":{"version":"1.0"},"touches":["AC-1"]}' > specs/s1/changes/old.json; mkdir -p specs/s1/changes/old; mv specs/s1/changes/old.json specs/s1/changes/old/change.json
echo '{"id":"s1","version":"1.1","status":"approved"}' > specs/s1/spec.meta.json; git add -A; git commit -qm rev; SHA2="$(git rev-parse HEAD)"; echo "$SHA2" > "$T/approved"
jq -n --arg sha "$SHA2" --argjson t "$TA" '{specId:"s1",specVersion:"1.1",specSha:$sha,parent:"PROJ-1",tasks:$t}' > "$T/rev.json"
eq "changes lists only the changes applied in this revision" "$("$TS" changes "$T/rev.json")" c1
eq "acs --revision: added/modified and still active (not the withdrawn, not the older change)" "$("$TS" acs "$T/rev.json" --revision | tr '\n' ' ')" "AC-2 AC-4 "
echo "tasks: $pass passed, $failed failed"; [ "$failed" = 0 ]
