#!/usr/bin/env bash
# The 1.0 layout: shared .sdkit/ with personal files ignored, generated host files excluded per clone, missing settings appended,
# legacy (pre-1.0) repos still working, and sdkit upgrade --migrate.
# Run: tests/sdkit-dir.test.sh
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="$(cd "$(dirname "$0")" && pwd)/stubs:$PATH" OPENSPEC_STUB_LOG="${TMPDIR:-/tmp}/openspec-stub.$$.log"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
newrepo() { rm -rf "$1"; mkdir -p "$1"; ( cd "$1" && git init -q -b main . && git config user.email t@t && git config user.name t && echo 'module x' > go.mod && echo own > README.md && git add -A && git commit -qm base ); }

echo "append_missing_env"
. "$KIT/bin/lib.sh"; SCAFFOLD_VERSION=9.9.9
printf '# top\n# about A\nA=9\n# about C\nC=3\n: "${P:=x}"\nD=\n' > "$T/tpl"; printf 'A=1\nP=mine\n' > "$T/env"
added="$(append_missing_env "$T/env" "$T/tpl" | paste -sd' ' -)"
check "adds only missing keys"                  test "$added" = "C D"
check "existing values untouched"               grep -qx 'A=1' "$T/env"
check "existing P (assignment form) not added"  test "$(grep -c 'P' "$T/env")" = 1
check "added key keeps its comment"             grep -q '^# about C$' "$T/env"
check "second run adds nothing"                 test -z "$(append_missing_env "$T/env" "$T/tpl")"

echo "new layout"
R="$T/new"; newrepo "$R"; mkdir -p "$R/.claude"; echo '{"permissions":{"allow":["Bash(make *)"]}}' > "$R/.claude/settings.json"; echo '# own' > "$R/.claude/CLAUDE.md"
( cd "$R" && git add -A && git commit -qm own )
check "init uses .sdkit"                         bash -c "cd '$R' && '$KIT/bin/init.sh' --host claude . >/dev/null && test -f .sdkit/sdkit.env && test ! -e .claude/project.env"
check "usage ledger is on in sdkit.local.env"   bash -c "cd '$R' && grep -q '^USAGE_LOG=1' .sdkit/sdkit.local.env && grep -q '^MEMORY_PROMOTE=ask' .sdkit/sdkit.local.env"
nocheck "personal settings are not in the shared file" bash -c "cd '$R' && grep -qE '^(USAGE_LOG|TOKEN_BUDGET_TASK|MAX_SPAWNS|MAX_PARALLEL)=' .sdkit/sdkit.env"
check "memory INDEX created"                    test -f "$R/.sdkit/memory/INDEX.md"
check "sdkit.local.env is ignored"              bash -c "cd '$R' && git check-ignore -q .sdkit/sdkit.local.env"
check "work/ is ignored"                        bash -c "cd '$R' && git check-ignore -q .sdkit/work/t/state.json"
nocheck "project.md is NOT ignored"             bash -c "cd '$R' && git check-ignore -q .sdkit/project.md"
check "plugin settings go to settings.local.json" jq -e '.enabledPlugins["spec-driven-kit@spec-driven-kit"]' "$R/.claude/settings.local.json"
check "CLAUDE.md keeps own text and gets the block" bash -c "cd '$R' && grep -q '^# own' .claude/CLAUDE.md && grep -q 'spec-driven-kit:begin' .claude/CLAUDE.md"
check "doctor passes the layout checks"         bash -c "'$KIT/bin/doctor.sh' '$R' 2>&1 | grep -q 'sdkit.env is shared through git'"
echo '# precious' >> "$R/.sdkit/sdkit.local.env"; sed -i.bak '/^MAX_SPAWNS=/d' "$R/.sdkit/sdkit.local.env" && rm "$R/.sdkit/sdkit.local.env.bak"
check "re-init appends the missing setting"     bash -c "cd '$R' && '$KIT/bin/init.sh' --host claude . 2>&1 | grep -q 'added  .sdkit/sdkit.local.env: MAX_SPAWNS' && grep -q '^MAX_SPAWNS=' .sdkit/sdkit.local.env"

echo "shared policy and personal overrides"
printf 'BASE_BRANCH_MODE=release\nPROTECTED_PATHS=services/user\nMAX_PARALLEL=7\n' >> "$R/.sdkit/sdkit.env"
check "a hook sees the shared policy"           bash -c "cd '$R' && echo '{}' | CLAUDE_PROJECT_DIR='$R' bash -c '. \"$KIT/hooks/lib.sh\"; test \"\$BASE_BRANCH_MODE\" = release && test \"\$PROTECTED_PATHS\" = services/user'"

echo "a 1.0.0 repo with one settings file"
O="$T/oldsdkit"; newrepo "$O"; mkdir -p "$O/.sdkit"
cat > "$O/.sdkit/sdkit.env" <<'E'
BASE_BRANCH=develop
STACK=go
# Most subagents running at once; scripts/plan-waves.sh splits any wave larger than this. A positive integer. Default: 3
MAX_PARALLEL=5
# my own note
SERVICES_DIR=svc
USAGE_LOG=
TOKEN_BUDGET_TASK=90000
BASE_BRANCH_MODE=release
E
printf 'sdkit.env\nwork/\n' > "$O/.sdkit/.gitignore"
check "init splits the personal settings out"   bash -c "cd '$O' && '$KIT/bin/init.sh' --host claude . >/dev/null 2>&1 && grep -q '^TOKEN_BUDGET_TASK=90000' .sdkit/sdkit.local.env && grep -q '^MAX_PARALLEL=5' .sdkit/sdkit.local.env && grep -q '^USAGE_LOG=\$' .sdkit/sdkit.local.env"
nocheck "...and removes them from the shared file" bash -c "cd '$O' && grep -qE '^(TOKEN_BUDGET_TASK|MAX_PARALLEL|USAGE_LOG)=' .sdkit/sdkit.env"
check "the team's settings stay in sdkit.env"   bash -c "cd '$O' && grep -q '^BASE_BRANCH_MODE=release' .sdkit/sdkit.env && grep -q '^SERVICES_DIR=svc' .sdkit/sdkit.env && grep -qx '# my own note' .sdkit/sdkit.env"
check ".gitignore now ignores the local file only" bash -c "cd '$O' && git check-ignore -q .sdkit/sdkit.local.env && ! git check-ignore -q .sdkit/sdkit.env"

echo "marketplace url"
MC="$T/mkt2"; newrepo "$MC"
check "--marketplace-url wins"                  bash -c "cd '$MC' && '$KIT/bin/init.sh' --host claude --marketplace-url https://example.org/k.git . >/dev/null 2>&1 && grep -q example.org/k.git .claude/settings.local.json"

echo "legacy layout keeps working"
L="$T/legacy"; newrepo "$L"; mkdir -p "$L/.claude/rules" "$L/.claude/adr" "$L/.claude/knowledge" "$L/.claude/memory" "$L/.claude/skills/own" "$L/.claude/work/t1" "$L/.claude/scripts"
printf 'BASE_BRANCH=main\nSTACK=go\nTOKEN_BUDGET_TASK=123\n' > "$L/.claude/project.env"; echo "# rubric \`high\`" > "$L/.claude/project.md"; echo r > "$L/.claude/rules/mine.md"
echo a > "$L/.claude/adr/0001.md"; echo "# Knowledge index" > "$L/.claude/knowledge/INDEX.md"; echo native > "$L/.claude/memory/MEMORY.md"; echo s > "$L/.claude/skills/own/SKILL.md"
echo '{}' > "$L/.claude/work/t1/state.json"; echo '#!/bin/sh' > "$L/.claude/scripts/sdd.sh"; echo k > "$L/.claude/known-pitfalls.md"
printf '.claude/scripts/sdd.sh\tscripts/sdd.sh\tx\n' > "$L/.claude/.scaffold-manifest"; echo 0.5.0 > "$L/.claude/.scaffold-version"
cat > "$L/.claude/settings.json" <<'J'
{"env":{"TEAM":"pay"},"permissions":{"allow":["Bash(make *)"]},"enabledPlugins":{"spec-driven-kit@spec-driven-kit":true,"other@x":true},"extraKnownMarketplaces":{"spec-driven-kit":{"source":{"source":"git","url":"u"}}},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"./team/lint.sh"},{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard-git.sh"}]}]}}
J
( cd "$L" && git add -A && git commit -qm legacy )
check "the resolver finds the legacy dir"        bash -c "cd '$L' && . '$KIT/bin/lib.sh' && test \"\$(resolve_kit_dir .)\" = .claude && test \"\$(resolve_kit_env . .claude)\" = project.env"
check "doctor flags the legacy layout"           bash -c "'$KIT/bin/doctor.sh' '$L' 2>&1 | grep -q 'legacy layout'"

echo "migrate"
check "dry run lists the moves"                 bash -c "'$KIT/bin/migrate.sh' '$L' | grep -q 'move   .claude/project.env -> .sdkit/sdkit.env'"
check "apply migrates"                          bash -c "'$KIT/bin/upgrade.sh' --migrate --apply '$L' >/dev/null 2>&1"
check "its personal settings went to sdkit.local.env" bash -c "cd '$L' && grep -q '^TOKEN_BUDGET_TASK=123' .sdkit/sdkit.local.env && ! grep -q '^TOKEN_BUDGET_TASK' .sdkit/sdkit.env"
check "kit-owned files moved"                   bash -c "cd '$L' && test -f .sdkit/project.md && test -f .sdkit/rules/mine.md && test -f .sdkit/adr/0001.md && test -f .sdkit/known-pitfalls.md && test -f .sdkit/work/t1/state.json"
check "sdkit.env stays in git (renamed)"        bash -c "cd '$L' && git status --short | grep -q '^R.*project.env -> .sdkit/sdkit.env'"
check "kit keys left the shared settings"       bash -c "cd '$L' && jq -e '(.enabledPlugins|has(\"spec-driven-kit@spec-driven-kit\")|not) and (.enabledPlugins.\"other@x\") and .env.TEAM == \"pay\" and (.extraKnownMarketplaces|not)' .claude/settings.json"
check "the project's own hook survived"         bash -c "cd '$L' && jq -e '[.hooks.PreToolUse[].hooks[].command] == [\"./team/lint.sh\"]' .claude/settings.json"
check "doctor is happy on the new layout"       bash -c "'$KIT/bin/doctor.sh' '$L' 2>&1 | grep -q 'sdkit.env is shared through git'"

echo "sdkit-dir tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
