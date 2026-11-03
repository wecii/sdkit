#!/usr/bin/env bash
# F10 test selection: changed path -> focused commands, conservative fallback, failure through pipes, evidence-keyed cache. Fixture commands only.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; TS="$ROOT/scripts/test-select.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
M="$T/maps"; mkdir -p "$M"; mkdir -p "$T/repo"; cd "$T/repo" && git init -q . && git config user.email t@t && git config user.name t && mkdir -p src docs tests
echo a > src/a.txt; echo b > src/b.txt; echo d > docs/d.md; echo core > src/core.sh; git add -A && git commit -qm init
cat > "$M/map.conf" <<'X'
@all => echo ALL1 ;; echo ALL2
@always => echo ALWAYS
^src/core\.sh$ => ALL
^src/a\.txt$ => echo TEST_A
^src/b\.txt$ => echo TEST_B ;; echo TEST_A
^docs/ => NONE
^tests/([a-z]+)\.sh$ => echo ran-\1
X
L() { "$TS" list --map "$M/map.conf" "$@" 2>&1; }

echo "mapping"
eq "one file -> its test (+always)"        "$(L --files src/a.txt | grep -v '^#' | tr '\n' ,)" "echo TEST_A,echo ALWAYS,"
eq "two files unite and dedupe"            "$(L --files 'src/a.txt src/b.txt' | grep -v '^#' | tr '\n' ,)" "echo TEST_A,echo TEST_B,echo ALWAYS,"
eq "shared module -> all"                  "$(L --files src/core.sh | head -1)" "# tier=T3 reason: src/core.sh matches shared rule"
eq "unmapped path -> all (never guess)"    "$(L --files 'src/a.txt src/new.txt' | head -1 | cut -c1-9)" "# tier=T3"
eq "docs only -> only the @always command"  "$(L --files docs/d.md | grep -v '^#' | tr '\n' ,)" "echo ALWAYS,"
eq "\\1 group substituted"                 "$(L --files tests/foo.sh | grep -c 'echo ran-foo')" 1
eq "forced T3 runs all"                    "$(L --files src/a.txt --tier T3 | head -1 | cut -c1-9)" "# tier=T3"
eq "no map -> usage error (run everything)" "$("$TS" list --map "$M/nope.conf" --files x >/dev/null 2>&1; echo $?)" 2
eq "git-derived changed files"             "$(echo x >> src/a.txt; L | grep -c 'TEST_A')" 1; git checkout -q src/a.txt
eq "nothing changed"                       "$(L)" "tests: nothing changed, nothing to run"

echo "run: failure propagation, cache"
cat > "$M/fmap.conf" <<X
@all => true
^src/a\.txt$ => false | cat
^src/b\.txt$ => echo ok >> $M/ran.log
X
eq "a failure hidden behind a pipe still fails"   "$("$TS" run --map "$M/fmap.conf" --files src/a.txt >/dev/null 2>&1; echo $?)" 1
out="$("$TS" run --map "$M/fmap.conf" --files src/a.txt 2>&1)"
eq "failure names the log"                         "$(printf '%s' "$out" | grep -c 'full output:')" 1
eq "a failure is never cached"                     "$(printf '%s' "$out" | grep -c '(cached')" 0
echo x >> src/b.txt
"$TS" run --map "$M/fmap.conf" --files src/b.txt >/dev/null 2>&1; "$TS" run --map "$M/fmap.conf" --files src/b.txt > "$M/o2" 2>&1
eq "identical tree: second run is cached, test not rerun" "$(wc -l < "$M/ran.log" | tr -d ' ')" 1
eq "…and says so"                                  "$(grep -c '(cached' "$M/o2")" 1
echo y >> src/b.txt; "$TS" run --map "$M/fmap.conf" --files src/b.txt >/dev/null 2>&1
eq "tree changed: cache invalidated, test reruns"  "$(wc -l < "$M/ran.log" | tr -d ' ')" 2
"$TS" run --map "$M/fmap.conf" --files src/b.txt --no-cache >/dev/null 2>&1
eq "--no-cache reruns"                             "$(wc -l < "$M/ran.log" | tr -d ' ')" 3
eq "summary line has counters"                     "$("$TS" run --map "$M/fmap.conf" --files src/b.txt --no-cache 2>&1 | grep -c '^tests: tier=T1 commands=1 ran=1 cached=0 failed=0')" 1

echo "deleted / missing test scripts, cache context"
printf '#!/bin/sh\necho ran >> "%s/ran2.log"\n' "$M" > tests/gone.test.sh; git add -A; git commit -qm gone
cat > "$M/dmap.conf" <<'X'
@all => bash tests/gone.test.sh
^tests/([a-z-]+)\.test\.sh$ => bash tests/\1.test.sh
^src/ => bash tests/gone.test.sh
X
git rm -q tests/gone.test.sh
out="$("$TS" run --map "$M/dmap.conf" --files tests/gone.test.sh 2>&1)"; drc=$?
eq "a test deleted in this change is skipped, not a false failure" "$drc" 0
eq "…and the skip is said"                          "$(printf '%s' "$out" | grep -c 'deleted in this change')" 1
"$TS" run --map "$M/dmap.conf" --files src/a.txt >"$M/o3" 2>&1; mrc=$?
eq "a test missing without being deleted FAILS (broken map), never hidden" "$mrc" 1
eq "…naming the script"                             "$(grep -c 'does not exist and was not deleted' "$M/o3")" 1
git reset -q --hard
echo "echo CTX" > /dev/null
"$TS" run --map "$M/fmap.conf" --files src/b.txt >/dev/null 2>&1; n1=$(wc -l < "$M/ran.log" | tr -d ' ')
SDD_MODE=guided "$TS" run --map "$M/fmap.conf" --files src/b.txt >/dev/null 2>&1; n2=$(wc -l < "$M/ran.log" | tr -d ' ')
eq "a behaviour-switching environment variable invalidates the cache" "$((n2 - n1))" 1

echo "selection: $pass passed, $failed failed"
[ "$failed" = 0 ]
