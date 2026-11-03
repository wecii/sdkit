#!/usr/bin/env bash
# The developer's own content in shared files (AGENTS.md, CLAUDE.md, settings, codex/cursor/gemini config) survives init, re-init and sync; the kit part is refreshed.
# Run: tests/shared.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
export PATH="$KIT/tests/stubs:$PATH" OPENSPEC_STUB_LOG="$T/openspec.log"

R="$T/r"; mkdir -p "$R/.claude" "$R/.codex" "$R/.cursor" "$R/.gemini"; cd "$R"
echo 'module x' > go.mod
printf '# My service\n\nOur own rules: always use tabs.\n' > AGENTS.md
printf '# My service (Claude)\n\nPrefer small PRs.\n' > .claude/CLAUDE.md
echo '{"env":{"TEAM":"payments"},"permissions":{"allow":["Bash(make *)"]}}' > .claude/settings.json
printf '[agents]\nmax_threads = 9\n\n[mcp_servers.team]\ncommand = "team-mcp"\n' > .codex/config.toml
echo '{"version":1,"hooks":{"stop":[{"command":"./team/notify.sh"}]}}' > .cursor/hooks.json
echo '{"theme":"dark","context":{"fileName":["GEMINI.md"]}}' > .gemini/settings.json
snapshot() { for f in AGENTS.md .claude/CLAUDE.md .claude/settings.json .codex/config.toml .cursor/hooks.json .gemini/settings.json; do echo "== $f"; cat "$f"; done; }
git_repo "$R"

"$KIT/bin/init.sh" --host claude,codex,cursor,gemini --stack go . >/dev/null 2>&1
check "AGENTS.md: own text and heading kept, one kit block" bash -c "grep -q 'always use tabs' AGENTS.md && [ \"\$(head -1 AGENTS.md)\" = '# My service' ] && [ \"\$(grep -c 'spec-driven-kit:begin' AGENTS.md)\" = 1 ]"
check "CLAUDE.md: own text kept, kit block added"          bash -c "grep -q 'Prefer small PRs' .claude/CLAUDE.md && grep -q 'spec-driven-kit:begin' .claude/CLAUDE.md"
check "settings.json: own env and permissions kept"        bash -c "[ \"\$(jq -r .env.TEAM .claude/settings.json)\" = payments ] && jq -e '.permissions.allow|index(\"Bash(make *)\")' .claude/settings.json"
check "settings.local.json: kit plugin enabled there"      jq -e '.enabledPlugins["spec-driven-kit@spec-driven-kit"]' .claude/settings.local.json
check "config.toml: own keys and table kept, [agents] once, valid" bash -c "grep -q 'max_threads = 9' .codex/config.toml && grep -q 'mcp_servers.team' .codex/config.toml && [ \"\$(grep -c '^\[agents\]' .codex/config.toml)\" = 1 ] && python3 -c 'import tomllib; tomllib.load(open(\".codex/config.toml\",\"rb\"))'"
check "cursor hooks: own hook kept, kit hooks added"       bash -c "grep -q 'team/notify.sh' .cursor/hooks.json && grep -q 'adapt.sh cursor' .cursor/hooks.json"
check "gemini: own theme and context kept, kit context added" bash -c "[ \"\$(jq -r .theme .gemini/settings.json)\" = dark ] && jq -e '.context.fileName|index(\"GEMINI.md\")' .gemini/settings.json && jq -e '.context.fileName|index(\"AGENTS.md\")' .gemini/settings.json"

git add -A && git commit -qm after-init; before="$(snapshot)"
"$KIT/bin/init.sh" --host claude,codex,cursor,gemini --stack go . >/dev/null 2>&1
eq "second init leaves shared files identical" "$([ "$before" = "$(snapshot)" ] && echo same)" same
check "sync --check is clean"                              "$KIT/bin/sync.sh" --check .

sed -i.bak -e 's/Spec-driven development with spec-driven-kit\./STALE KIT TEXT/' -e 's/always use tabs\./always use tabs. (edited later)/' AGENTS.md && rm AGENTS.md.bak
eq "sync --check sees the stale block" "$(rc "$KIT/bin/sync.sh" --check .)" 1
"$KIT/bin/sync.sh" . >/dev/null 2>&1
check "sync restored the kit block and kept the later edit" bash -c "! grep -q 'STALE KIT TEXT' AGENTS.md && grep -q 'edited later' AGENTS.md"
check "sync --check is clean again"                        "$KIT/bin/sync.sh" --check .
finish shared
