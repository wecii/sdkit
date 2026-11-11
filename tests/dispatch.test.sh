#!/usr/bin/env bash
# F15 opt-in parallel dispatch rules: dependencies, write-set overlap, concurrency limit, idempotent claims, concurrent claimers. No model.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"; DP="$KIT/scripts/dispatch.sh"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
R="$T/r"; mkdir -p "$R/.sdkit"; cd "$R" && git init -q . && git config user.email t@t && git config user.name t
printf 'STACK=generic\nMAX_PARALLEL=2\n' > .sdkit/sdkit.env; : > .sdkit/sdkit.local.env; echo x > f; git add -A; git commit -qm i; export CLAUDE_PROJECT_DIR="$R"
cat > "$T/tasks.md" <<'X'
- [ ] T1 core | role: developer | writes: src/core/ | after:
- [ ] T2 api | role: developer | writes: src/api/ | after:
- [ ] T3 docs | role: developer | writes: docs/ | after:
- [ ] T4 core tests | role: test-writer | writes: src/core/tests/ | after:
- [ ] T5 glue | role: developer | writes: src/glue/ | after: T1,T2
- [ ] T6 lookup | role: scout | after:
X
echo 'PARALLEL=off' >> .sdkit/sdkit.local.env
eq "PARALLEL=off refuses (exit 4)"                      "$(rc "$DP" claim T1 "$T/tasks.md")" 4
sed -i.bak '/^PARALLEL=/d' .sdkit/sdkit.local.env; rm -f .sdkit/sdkit.local.env.bak
eq "a claim succeeds"                                "$(rc "$DP" claim T1 "$T/tasks.md")" 0
eq "claiming it again is refused, nothing changes"   "$(rc "$DP" claim T1 "$T/tasks.md")" 3
eq "…and wrote no second claim line"                 "$(wc -l < .sdkit/work/_misc/dispatch.jsonl | tr -d ' ')" 1
eq "an overlapping write set is refused"             "$("$DP" claim T4 "$T/tasks.md" | grep -c overlaps)" 1
eq "a disjoint task is allowed"                      "$(rc "$DP" claim T2 "$T/tasks.md")" 0
eq "the concurrency limit (2) holds"                 "$("$DP" claim T3 "$T/tasks.md" | grep -c 'MAX_PARALLEL=2')" 1
eq "an unknown task is refused"                      "$(rc "$DP" claim T99 "$T/tasks.md")" 3
eq "a dependency that is not done blocks"            "$("$DP" claim T5 "$T/tasks.md" | grep -c 'waits for')" 1
out="$("$DP" done T1)"; eq "done warns that evidence is stale"  "$(printf '%s' "$out" | grep -c 'stale')" 1
eq "done twice is refused"                           "$(rc "$DP" done T1)" 3
"$DP" done T2 >/dev/null; eq "with deps done, T5 may start" "$(rc "$DP" claim T5 "$T/tasks.md")" 0
eq "a read-only task never conflicts"                "$(rc "$DP" claim T6 "$T/tasks.md")" 0
"$DP" release T6 >/dev/null; eq "a released task can be claimed again" "$(rc "$DP" claim T6 "$T/tasks.md")" 0
eq "status reports the limit"                        "$("$DP" status | head -1)" "parallel limit 2, active 2, done 2"
# two claimers at once for the same task: exactly one wins
rm -rf .sdkit/work; ( "$DP" claim T1 "$T/tasks.md" >/dev/null 2>&1 & "$DP" claim T1 "$T/tasks.md" >/dev/null 2>&1 & wait )
eq "two concurrent claims of one task: one claim line" "$(grep -c '"claim"' .sdkit/work/_misc/dispatch.jsonl)" 1
echo "dispatch: $pass passed, $failed failed"; [ "$failed" = 0 ]
