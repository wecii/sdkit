#!/usr/bin/env bash
# The developer's own content in shared files must survive init, re-init and sync byte for byte.
# Run: tests/slow/shared.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="$(cd "$(dirname "$0")/.." && pwd)/stubs:$PATH" OPENSPEC_STUB_LOG="${TMPDIR:-/tmp}/openspec-stub.$$.log"   # init must not need the real openspec
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

cd "$T" && git init -q -b main . && git config user.email t@t && git config user.name t
echo 'module x' > go.mod
mkdir -p .claude .codex .cursor .gemini
printf '# My service\n\nOur own rules: always use tabs.\n' > AGENTS.md
printf '# My service (Claude)\n\nPrefer small PRs.\n' > .claude/CLAUDE.md
cat > .claude/settings.json <<'J'
{"env":{"TEAM":"payments"},"permissions":{"allow":["Bash(make *)"],"deny":["Bash(curl *)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"./team/lint-bash.sh"}]}]}}
J
printf '[agents]\nmax_threads = 9\n\n[mcp_servers.team]\ncommand = "team-mcp"\n' > .codex/config.toml
echo '{"version":1,"hooks":{"stop":[{"command":"./team/notify.sh"}]}}' > .cursor/hooks.json
echo '{"theme":"dark","context":{"fileName":["GEMINI.md"]}}' > .gemini/settings.json
snapshot() { for f in AGENTS.md .claude/CLAUDE.md .claude/settings.json .claude/settings.local.json .codex/config.toml .cursor/hooks.json .gemini/settings.json; do echo "== $f"; cat "$f"; done; }
git add -A && git commit -qm base

echo "init into a repo that already has its own shared files"
"$KIT/bin/init.sh" --host claude,codex,cursor,gemini --stack go . >/dev/null 2>&1
check "AGENTS.md: own text kept"                 grep -q 'Our own rules: always use tabs.' AGENTS.md
check "AGENTS.md: own heading kept first"         test "$(head -1 AGENTS.md)" = '# My service'
check "AGENTS.md: exactly one kit block"          test "$(grep -c 'spec-driven-kit:begin' AGENTS.md)" = 1
check "CLAUDE.md: own text kept"                  grep -q 'Prefer small PRs.' .claude/CLAUDE.md
check "CLAUDE.md: kit block added"                grep -q 'spec-driven-kit:begin' .claude/CLAUDE.md
check "settings.json: own env kept"               test "$(jq -r .env.TEAM .claude/settings.json)" = payments
check "settings.json: own permissions kept"       jq -e '.permissions.allow|index("Bash(make *)")' .claude/settings.json
check "settings.json: own deny kept"              jq -e '.permissions.deny|index("Bash(curl *)")' .claude/settings.json
check "settings.json: kit does not touch it"        test "$(jq -r '.enabledPlugins // "none"' .claude/settings.json)" = none
check "settings.local.json: kit plugin enabled"   jq -e '.enabledPlugins["spec-driven-kit@spec-driven-kit"]' .claude/settings.local.json
check "config.toml: own keys kept"                grep -q 'max_threads = 9' .codex/config.toml
check "config.toml: own table kept"               grep -q 'mcp_servers.team' .codex/config.toml
check "config.toml: [agents] defined once"        test "$(grep -c '^\[agents\]' .codex/config.toml)" = 1
check "config.toml: valid TOML"                   python3 -c 'import tomllib,sys; tomllib.load(open(".codex/config.toml","rb"))'
check "cursor hooks: own hook kept"               grep -q 'team/notify.sh' .cursor/hooks.json
check "cursor hooks: kit hooks added"             grep -q 'adapt.sh cursor' .cursor/hooks.json
check "gemini: own theme kept"                    test "$(jq -r .theme .gemini/settings.json)" = dark
check "gemini: own context file kept"             jq -e '.context.fileName|index("GEMINI.md")' .gemini/settings.json
check "gemini: kit context file added"            jq -e '.context.fileName|index("AGENTS.md")' .gemini/settings.json

echo "re-running init changes nothing"
git add -A && git commit -qm after-init; before="$(snapshot)"
"$KIT/bin/init.sh" --host claude,codex,cursor,gemini --stack go . >/dev/null 2>&1
check "second init leaves shared files identical" test "$before" = "$(snapshot)"
check "sync --check is clean"                     "$KIT/bin/sync.sh" --check .

echo "kit part is refreshed, yours is not"
python3 - <<'P'
import re
s=open("AGENTS.md").read()
s=s.replace("Spec-driven development with spec-driven-kit.","STALE KIT TEXT")      # simulate an older kit block
s=s.replace("Our own rules: always use tabs.","Our own rules: always use tabs. (edited later)")
open("AGENTS.md","w").write(s)
P
check "sync --check sees the stale block"         test "$("$KIT/bin/sync.sh" --check . >/dev/null 2>&1; echo $?)" = 1
"$KIT/bin/sync.sh" . >/dev/null 2>&1
check "sync restored the kit block"               test "$(grep -c 'STALE KIT TEXT' AGENTS.md)" = 0
check "sync kept the developer's later edit"      grep -q 'edited later' AGENTS.md
check "sync --check is clean again"               "$KIT/bin/sync.sh" --check .
check "doctor reports shared files current"       bash -c "'$KIT/bin/doctor.sh' . 2>&1 | grep -q 'shared files carry the current kit'"

echo "OpenCode shell key is a project setting"
mkdir -p "$T/oc" && cd "$T/oc" && git init -q -b main . && echo 'module x' > go.mod
"$KIT/bin/init.sh" --host opencode --stack go . >/dev/null 2>&1
check "default key is shell"                      grep -q '^  shell:$' .sdkit/../.opencode/agents/verifier.md
sed -i.bak 's/^OPENCODE_SHELL_KEY=.*/OPENCODE_SHELL_KEY=bash/' .sdkit/sdkit.env && rm .sdkit/sdkit.env.bak
"$KIT/bin/sync.sh" --force . >/dev/null 2>&1
check "sdkit.env switches the key to bash"      grep -q '^  bash:$' .opencode/agents/verifier.md
check "no drift reported after the switch"        "$KIT/bin/sync.sh" --check .

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
