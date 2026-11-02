#!/usr/bin/env bash
# F20: cheap PR checks (T0 + selected T1) fail on a broken script or JSON, and the fixture regression history flags a regression without any model.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"; HI="$KIT/bench/history.sh"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# pr-check.sh runs build-adapters --check and audit.sh policy of the kit it lives in (about 10 s each call) when they exist next to it. This file tests the
# plan, the syntax/JSON checks and the exit codes, not those two steps, so it runs a minimal copy without them (each step is guarded by [ -x ]).
mkdir -p "$T/kit/scripts" && cp "$KIT/scripts/pr-check.sh" "$KIT/scripts/test-select.sh" "$KIT/scripts/env.sh" "$T/kit/scripts/"; PC="$T/kit/scripts/pr-check.sh"
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
R="$T/r"; mkdir -p "$R/tests" "$R/scripts"; cd "$R" && git init -q -b main . && git config user.email t@t && git config user.name t
printf '@all => true\n.* => true\n' > tests/test-map.conf; echo 'echo ok' > scripts/a.sh; echo '{"a":1}' > c.json; git add -A; git commit -qm i; git checkout -qb feat
export CLAUDE_PROJECT_DIR="$R"
echo "echo changed" >> scripts/a.sh
eq "a clean change is green"                 "$("$PC" --base main >/dev/null 2>&1; echo $?)" 0
out="$("$PC" --base main 2>&1)"
eq "the plan names tiers, not a full run"    "$(printf '%s' "$out" | grep -c 'tier T1 (a green T1 is not a full regression)')" 1
echo 'if then' >> scripts/a.sh
eq "a syntax error in a changed script fails" "$("$PC" --base main >/dev/null 2>&1; echo $?)" 1
git checkout -q scripts/a.sh; echo '{bad' > c.json
eq "broken JSON fails"                       "$("$PC" --base main >/dev/null 2>&1; echo $?)" 1
git checkout -q c.json
printf '@all => true\n^zzz$ => true\n' > tests/test-map.conf; echo y >> scripts/a.sh
eq "an unmapped change falls back to the full map (still green here)" "$("$PC" --base main --list | grep -c 'T1:')" 1
eq "--list runs nothing"                     "$("$PC" --base main --list >/dev/null 2>&1; echo $?)" 0
eq "--milestone plans T3 + benchmark check"  "$("$PC" --base main --list --milestone | grep -c '^T3')" 1

echo "regression history"
H="$T/h.jsonl"; line() { printf '{"ts":"t","head":"h","dirty":0,"fixture_sha":"%s","avoidable_reruns":%s,"wrongly_accepted":%s,"shown_bytes":%s,"mean_selected_suites":%s}\n' "$1" "$2" "$3" "$4" "$5"; }
line A 0 0 848 2.2 > "$H"; line A 0 0 850 2.2 >> "$H"
eq "no change: no regression"                "$("$HI" check --file "$H" >/dev/null 2>&1; echo $?)" 0
line A 1 0 850 2.2 >> "$H";  eq "more avoidable reruns: regression"        "$("$HI" check --file "$H" >/dev/null 2>&1; echo $?)" 1
line A 0 1 850 2.2 >> "$H";  eq "a wrongly accepted case: regression"      "$("$HI" check --file "$H" >/dev/null 2>&1; echo $?)" 1
line A 0 0 850 2.2 >> "$H"; line A 0 0 1200 2.2 >> "$H"; eq "views >10% larger: regression" "$("$HI" check --file "$H" >/dev/null 2>&1; echo $?)" 1
line A 0 0 1200 4.0 >> "$H"; eq ">25% more suites per patch: regression"  "$("$HI" check --file "$H" >/dev/null 2>&1; echo $?)" 1
line B 5 0 9999 9.9 >> "$H"; eq "a different fixture set is not comparable (not a failure)" "$("$HI" check --file "$H" >/dev/null 2>&1; echo $?)" 0
eq "a regression names its rollback lever"   "$(line A 0 0 850 2.2 > "$T/g"; line A 2 0 850 2.2 >> "$T/g"; "$HI" check --file "$T/g" 2>&1 | grep -c 'rollback lever')" 1
echo "ci: $pass passed, $failed failed"; [ "$failed" = 0 ]
