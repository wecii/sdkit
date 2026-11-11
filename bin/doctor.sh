#!/usr/bin/env bash
# Check that a repo's kit setup is complete. Prints what to fix. Exit 0 = no failures (warnings allowed).
# Usage: doctor.sh [--update-pricing] [target-dir]
#   --update-pricing  rebuild <project-dir>/pricing.json from the public AWS Bedrock price list (only a table the kit wrote; yours is left alone)
set -u
. "$(dirname "$0")/lib.sh"
UPDATE_PRICING=0; [ "${1:-}" = --update-pricing ] && { UPDATE_PRICING=1; shift; }
TARGET="$(cd "${1:-$PWD}" && pwd)"
FAILS=0; WARNS=0
ok()   { say "  ok    $*"; }
bad()  { say "  FAIL  $*"; FAILS=$((FAILS + 1)); }
warn() { say "  warn  $*"; WARNS=$((WARNS + 1)); }

say "doctor: $TARGET"
command -v jq >/dev/null && ok "jq installed" || bad "jq missing (the hooks parse JSON with it): brew install jq"
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 && ok "git repository" || bad "not a git repository"

KIT_DIR="$(resolve_kit_dir "$TARGET")"; KIT_DIR="${KIT_DIR:-.claude}"
ok "project directory: $KIT_DIR"
ENV_NAME="$(resolve_kit_env "$TARGET" "$KIT_DIR")"; env_file="$TARGET/$KIT_DIR/$ENV_NAME"
if [ -f "$env_file" ]; then
  # the settings files are parsed, not run: a line the parser cannot read is ignored by every script, so report it (never its content)
  ignored="$( { sdkit_env_load_file "$env_file"; sdkit_env_load_file "$TARGET/$KIT_DIR/sdkit.local.env"; } 2>&1 >/dev/null )"
  if [ -z "$ignored" ]; then ok "$ENV_NAME parses"
  else bad "settings lines the kit ignores (shell code in a settings file is not run any more; see docs/upgrading.md, \"Settings files are parsed\"):"; printf '%s\n' "$ignored" | sed 's/^/          /'; fi
  SDKIT_ENV_QUIET=1 sdkit_env_load_file "$env_file"; SDKIT_ENV_QUIET=1 sdkit_env_load_file "$TARGET/$KIT_DIR/sdkit.local.env"
  ENVP="$(sed -n 's/^SDKIT_ENV=//p' "$env_file" | tail -1 | tr -d "\"' ")"; ENVP="${ENVP:-standalone}"   # install persona: analyst skips the stack and verify checks
  case "$ENVP" in standalone|analyst|developer) [ "$ENVP" = standalone ] || ok "install env: $ENVP" ;; *) bad "SDKIT_ENV '$ENVP' is not standalone, analyst or developer"; ENVP=standalone ;; esac
  [ "$ENVP" = analyst ] || [ -n "${STACK:-}" ] || warn "STACK is not set in $ENV_NAME: the kit assumes '$SDKIT_DEFAULT_STACK'. Set STACK=<go|spring-boot|jvm|python|nextjs|react-native|generic>"
  git -C "$TARGET" rev-parse --verify -q "${BASE_BRANCH:-}" >/dev/null || git -C "$TARGET" rev-parse --verify -q "origin/${BASE_BRANCH:-}" >/dev/null \
    && ok "BASE_BRANCH '${BASE_BRANCH:-}' exists" || bad "BASE_BRANCH '${BASE_BRANCH:-}' is not a branch in this repo"
  if [ "$ENVP" = analyst ]; then :
  elif [ -n "${VERIFY_CMD:-}" ]; then
    [ -x "$TARGET/$VERIFY_CMD" ] && ok "VERIFY_CMD executable" || bad "VERIFY_CMD '$VERIFY_CMD' missing or not executable"
  else
    ok "VERIFY_CMD empty: the plugin's verify engine is used"
  fi
  if [ -n "${RISK_FLOOR_GLOBS:-}" ]; then
    why="$(CLAUDE_PROJECT_DIR="$TARGET" KIT_DIR="$KIT_DIR" "$SCAFFOLD_ROOT/scripts/sdd.sh" floor --validate 2>&1)" \
      && ok "RISK_FLOOR_GLOBS is well-formed" || bad "RISK_FLOOR_GLOBS is invalid: $why (level:glob,level:glob with level low|medium|high; the workflow refuses to start and CI fails until it is fixed)"
  fi
  case "${MAX_PARALLEL:-3}" in
    ''|*[!0-9]*|0) bad "MAX_PARALLEL '${MAX_PARALLEL:-}' is not a positive integer (plan-waves.sh falls back to 3)" ;;
    *) ok "MAX_PARALLEL=${MAX_PARALLEL:-3} (most subagents at once)" ;;
  esac
  if [ "${MEMORY:-}" = 1 ]; then
    mscript="$TARGET/$KIT_DIR/scripts/memory.sh"; [ -x "$mscript" ] || mscript="$(dirname "$0")/../scripts/memory.sh"
    ok "$( cd "$TARGET" && KIT_DIR="$KIT_DIR" "$mscript" status )"
    stale="$( cd "$TARGET" && KIT_DIR="$KIT_DIR" "$mscript" stale 2>/dev/null )"
    [ -z "$stale" ] || warn "memory entries to re-check (scripts/memory.sh stale): $(printf '%s' "$stale" | cut -d: -f1 | tr '\n' ' ')"
  else
    ok "project memory off (sdkit init --memory, or MEMORY=1 in project.env)"
  fi
  # settings the kit added to its templates since these files were written
  miss=""
  for k in $(grep -oE '^[A-Z][A-Z0-9_]*=' "$SCAFFOLD_ROOT/templates/sdkit.env" | tr -d '=' | sort -u); do
    grep -qE "^($k=|: \"\\$\\{$k:=)" "$env_file" || miss="$miss $k"
  done
  local_file="$TARGET/$KIT_DIR/sdkit.local.env"; [ "$KIT_DIR" = .sdkit ] || local_file="$env_file"
  for k in $(grep -oE '^[A-Z][A-Z0-9_]*=' "$SCAFFOLD_ROOT/templates/sdkit.local.env" | tr -d '=' | sort -u); do
    grep -qE "^$k=" "$local_file" 2>/dev/null || miss="$miss $k"
  done
  [ -z "$miss" ] && ok "settings files have every setting of this kit version" || warn "settings lacking:$miss (defaults apply; sdkit upgrade adds them)"
  if [ "$KIT_DIR" = .sdkit ]; then
    git -C "$TARGET" check-ignore -q -- "$KIT_DIR/$ENV_NAME" 2>/dev/null \
      && warn "$KIT_DIR/$ENV_NAME is git-ignored but it holds the team's settings: add '!$ENV_NAME' to $KIT_DIR/.gitignore (sdkit upgrade does)" || ok "$ENV_NAME is shared through git"
    [ -f "$local_file" ] || warn "no $KIT_DIR/sdkit.local.env: personal settings (limits, memory behaviour, hosts); sdkit upgrade creates it"
    git -C "$TARGET" ls-files --error-unmatch -- "$KIT_DIR/sdkit.local.env" >/dev/null 2>&1 \
      && warn "$KIT_DIR/sdkit.local.env is committed but it is personal: git rm --cached $KIT_DIR/sdkit.local.env" || ok "sdkit.local.env stays out of git"
  else
    warn "legacy layout ($KIT_DIR with $ENV_NAME): it keeps working; sdkit upgrade --migrate moves it to .sdkit/"
  fi
  if [ "$ENVP" = developer ]; then
    sd="${SPECS_DIR:-specs}"
    if [ -e "$TARGET/$sd/.git" ] && git -C "$TARGET/$sd" rev-parse --git-dir >/dev/null 2>&1; then ok "$sd/ submodule present"
    else warn "$sd/ submodule missing: git submodule add ${SPEC_REPO:-<SPEC_REPO>} $sd (then git submodule update --init)"; fi
    [ "${SDD_MANAGED:-}" = on ] && ok "SDD_MANAGED=on" || warn "SDD_MANAGED is not on (developer env runs managed)"
    [ "${TRACKER:-}" = jira ] && ok "TRACKER=jira" || warn "TRACKER is not jira (set TRACKER=jira in $ENV_NAME; developer env takes tasks from Jira)"
  fi
  if [ "$ENVP" = analyst ]; then
    pd="${PRESPEC_DIR:-prespec}"; pd="${pd%/}"
    if git -C "$TARGET" check-ignore -q -- "$pd/x" 2>/dev/null; then ok "$pd/ is git-ignored (pre-specs are never committed)"
    else bad "$pd/ is not git-ignored: add /$pd/ to .gitignore (sdkit init --env analyst does)"; fi
    [ -z "$(git -C "$TARGET" ls-files -- "$pd" 2>/dev/null)" ] || bad "files under $pd/ are tracked: git rm -r --cached $pd"
  fi
  [ -z "${BASE_BRANCH_MODE:-}" ] || ok "release-branch flow on (BASE_BRANCH_MODE=$BASE_BRANCH_MODE)"
else
  bad "no sdkit.env in .sdkit/ (or project.env in a legacy .agentkit/, .claude/, .codex/): run sdkit init"
fi

# measurement: the Value Report is only as good as what is recorded
if [ -f "$env_file" ]; then
  miss=""
  [ "${USAGE_LOG:-}" = 1 ] || miss="$miss USAGE_LOG=1"; [ "${TELEMETRY:-}" = 1 ] || miss="$miss TELEMETRY=1"
  [ "${VALUE_REPORT:-}" = on ] || miss="$miss VALUE_REPORT=on"; [ "${ROUTING:-}" = on ] || miss="$miss ROUTING=on"
  [ -z "$miss" ] && ok "measurement on (USAGE_LOG, TELEMETRY, VALUE_REPORT, ROUTING)" \
    || warn "measurement off, so the Value Report has gaps (tokens, phases, routing):$miss (USAGE_LOG, TELEMETRY, VALUE_REPORT in sdkit.local.env; ROUTING in sdkit.env)"
  # role tiers (AGENT_<ROLE>_TIER): a typo is silent otherwise, the role simply keeps its own tier
  for _k in $(compgen -v | grep -E '^AGENT_[A-Z0-9_]+_TIER$'); do
    _r="$(printf '%s' "${_k#AGENT_}" | sed 's/_TIER$//' | tr 'A-Z_' 'a-z-')"; _v="${!_k:-}"; _f=""
    for _c in "$SCAFFOLD_ROOT/core/roles/$_r.md" "$TARGET/$KIT_DIR/roles/$_r.md"; do [ -f "$_c" ] && { _f="$_c"; break; }; done
    if [ -z "$_f" ]; then warn "$_k: there is no role '$_r' (roles: $(ls "$SCAFFOLD_ROOT"/core/roles/*.md | xargs -n1 basename | sed 's/\.md$//' | grep -v '^README$' | tr '\n' ' '))"; continue; fi
    [ -n "$_v" ] || continue
    case "$_v" in light|standard|strong) ;; *) warn "$_k=$_v is not a tier (light | standard | strong): the role keeps its own tier"; continue ;; esac
    _own="$(sdkit_fm "$_f" tier)"
    case "$_r" in verifier|reviewer|security-auditor) [ "$(sdkit_tier_rank "$_v")" -ge "$(sdkit_tier_rank "$_own")" ] || warn "$_k=$_v is below the role's own tier ($_own): independent roles are never moved down, the value is ignored" ;; esac
  done
  # price table and routing baseline
  pscript="$TARGET/$KIT_DIR/scripts/pricing.sh"; [ -x "$pscript" ] || pscript="$SCAFFOLD_ROOT/scripts/pricing.sh"
  if [ "$UPDATE_PRICING" = 1 ]; then
    if [ -x "$pscript" ]; then pout="$(CLAUDE_PROJECT_DIR="$TARGET" "$pscript" refresh 2>&1)" && ok "$pout" || warn "pricing not updated: $pout"
    else warn "pricing.sh not found: run sdkit upgrade"; fi
  fi
  if [ -x "$pscript" ]; then
    pout="$(CLAUDE_PROJECT_DIR="$TARGET" "$pscript" status 2>&1)" && ok "$(printf '%s' "$pout" | head -1)" \
      || { warn "$(printf '%s' "$pout" | head -1)"; printf '%s\n' "$pout" | tail -n +2 | sed 's/^  - /        /'
           say "        fix: set REPORT_BASELINE_MODEL=<model id from pricing.json> in sdkit.env; refresh the table with: sdkit doctor --update-pricing"; }
  fi
fi

project_md="$TARGET/$KIT_DIR/project.md"
if [ -f "$project_md" ]; then
  # a bare TODO only: the template's own explanatory line quotes it as `TODO`
  grep -qE '(^|[^`])TODO($|[^`])' "$project_md" && bad "project.md still has TODO placeholders" || ok "project.md filled in"
  grep -q '`high`' "$project_md" && ok "risk rubric present" || bad "project.md has no risk rubric"
else
  bad "$KIT_DIR/project.md missing"
fi
for f in known-pitfalls.md .gitignore; do
  [ -f "$TARGET/$KIT_DIR/$f" ] && ok "$KIT_DIR/$f present" || bad "$KIT_DIR/$f missing"
done
{ [ -f "$TARGET/.claude/settings.json" ] || [ -f "$TARGET/.claude/settings.local.json" ]; } && { [ -f "$TARGET/.claude/CLAUDE.md" ] && ok ".claude/CLAUDE.md present" || bad ".claude/CLAUDE.md missing"; }
if [ "${ENVP:-standalone}" != analyst ]; then
  [ -n "$(ls "$TARGET/$KIT_DIR"/verify.d/[0-9]*.sh 2>/dev/null | head -1)" ] && ok "verify.d has active policies" \
    || warn "no active verify.d policy (rename .example files to enable the ones you want)"
fi

settings="$TARGET/.claude/settings.json"; [ -f "$TARGET/.claude/settings.local.json" ] && settings="$TARGET/.claude/settings.local.json"
if [ -f "$settings" ]; then
  jq empty "$settings" 2>/dev/null && ok "$(basename "$settings") valid" || bad "$(basename "$settings") is not valid JSON"
  [ "$(jq '.permissions.deny | length' "$settings" 2>/dev/null)" -gt 0 ] 2>/dev/null && ok "permissions.deny set" || warn "no permissions.deny list"
  if [ -d "$TARGET/.claude/hooks" ]; then
    for hook in "$TARGET"/.claude/hooks/*.sh; do [ -x "$hook" ] || bad "hook not executable: $hook"; done
    [ "$(jq '[.. | .command? // empty | select(contains("hooks/"))] | length' "$settings")" -gt 0 ] \
      && ok "copy mode: hooks wired in settings.json" || bad "hooks copied but settings.json does not reference them"
  else
    jq -e '.enabledPlugins["spec-driven-kit@spec-driven-kit"] == true' "$settings" >/dev/null 2>&1 \
      && ok "plugin mode: spec-driven-kit enabled in $(basename "$settings")" || bad "$(basename "$settings") does not enable spec-driven-kit"
    url="$(jq -r '.extraKnownMarketplaces["spec-driven-kit"].source.url // empty' "$settings")"
    case "$url" in ""|*invalid*) bad "marketplace url missing in $(basename "$settings") (extraKnownMarketplaces)" ;; *) ok "marketplace: $url" ;; esac
  fi
elif [ -f "$TARGET/AGENTS.md" ]; then
  ok "no .claude settings: setup for non-Claude hosts only (AGENTS.md present)"
else
  bad ".claude/settings.local.json (or settings.json) missing: run sdkit init"
fi

has_codex=0; has_opencode=0; has_cursor=0; has_gemini=0
{ [ -f "$TARGET/.codex/config.toml" ] || [ -d "$TARGET/.codex/agents" ]; } && has_codex=1
[ -d "$TARGET/.opencode" ] && has_opencode=1
[ -d "$TARGET/.cursor" ] && has_cursor=1
[ -d "$TARGET/.gemini" ] && has_gemini=1
# a non-Claude host install: the kit block in AGENTS.md or the kit's own skill. Any other .agents/skills/ content
# (third-party skills from `npx skills add`) is not a host install and must not trigger the host checks.
has_agents_host=0
{ grep -qs 'spec-driven-kit:begin' "$TARGET/AGENTS.md" || [ -d "$TARGET/.agents/skills/spec-driven-dev" ]; } && has_agents_host=1
if [ "$has_agents_host" = 1 ]; then
  [ -f "$TARGET/AGENTS.md" ] && ok "AGENTS.md present" || bad "AGENTS.md missing"
  [ -f "$TARGET/.agents/skills/spec-driven-dev/SKILL.md" ] && ok "skills installed in .agents/skills" || bad ".agents/skills/spec-driven-dev missing (run init.sh --host <host>)"
  for s in verify verify-core env guard plan-waves worktree resolve-base state parse-verdict check-plan-parity check-writes usage memory lookup-cache run-role route workflow contract telemetry dod-check audit redact digest adapter dispatch knowledge recover test-select pr-check pricing review jira spec tasks; do
    [ -x "$TARGET/$KIT_DIR/scripts/$s.sh" ] || bad "$KIT_DIR/scripts/$s.sh missing or not executable (run upgrade.sh)"
  done
  [ -x "$TARGET/$KIT_DIR/adapters.d/jira.sh" ] || bad "$KIT_DIR/adapters.d/jira.sh missing or not executable (run upgrade.sh)"
  [ -x "$TARGET/$KIT_DIR/hooks/adapt.sh" ] && ok "hooks copied for the non-Claude hosts" || bad "$KIT_DIR/hooks missing (run upgrade.sh)"
  [ "$(git -C "$TARGET" config core.hooksPath 2>/dev/null)" = ".githooks" ] && ok "git hooks active (core.hooksPath=.githooks)" \
    || warn "git hooks not active in this clone: git config core.hooksPath .githooks"
  if [ "$has_codex" = 1 ]; then
    [ -f "$TARGET/.codex/config.toml" ] && ok "codex: .codex/config.toml present" || bad "codex: .codex/config.toml missing"
    [ -n "$(ls "$TARGET"/.codex/agents/*.toml 2>/dev/null | head -1)" ] && ok "codex: role files present" || bad "codex: .codex/agents/*.toml missing"
  fi
  if [ "$has_opencode" = 1 ]; then
    [ -n "$(ls "$TARGET"/.opencode/agents/*.md 2>/dev/null | head -1)" ] && ok "opencode: role files present" || bad "opencode: .opencode/agents/*.md missing"
    [ -f "$TARGET/.opencode/plugins/spec-driven-kit-guard.js" ] && ok "opencode: guard plugin present" || bad "opencode: .opencode/plugins/spec-driven-kit-guard.js missing"
  fi
  if [ "$has_cursor" = 1 ]; then
    [ -n "$(ls "$TARGET"/.cursor/agents/*.md 2>/dev/null | head -1)" ] && ok "cursor: role files present" || bad "cursor: .cursor/agents/*.md missing"
    [ -f "$TARGET/.cursor/hooks.json" ] && { jq empty "$TARGET/.cursor/hooks.json" 2>/dev/null && ok "cursor: hooks.json valid" || bad "cursor: .cursor/hooks.json is not valid JSON"; } || bad "cursor: .cursor/hooks.json missing"
  fi
  if [ "$has_gemini" = 1 ]; then
    [ -n "$(ls "$TARGET"/.gemini/agents/*.md 2>/dev/null | head -1)" ] && ok "gemini: role files present" || bad "gemini: .gemini/agents/*.md missing"
    [ -f "$TARGET/.gemini/settings.json" ] && { jq empty "$TARGET/.gemini/settings.json" 2>/dev/null && ok "gemini: settings.json valid" || bad "gemini: .gemini/settings.json is not valid JSON"; } || bad "gemini: .gemini/settings.json missing"
  fi
fi
# kit version and drift of the managed copies
proj_ver="$(cat "$TARGET/$KIT_DIR/.scaffold-version" 2>/dev/null || true)"
if [ -z "$proj_ver" ]; then warn "no $KIT_DIR/.scaffold-version (set up before versions were recorded): run upgrade.sh"
elif [ "$proj_ver" = "$SCAFFOLD_VERSION" ]; then ok "project is on kit $SCAFFOLD_VERSION"
else warn "project was set up with kit $proj_ver, this kit is $SCAFFOLD_VERSION: run upgrade.sh"; fi
if [ -f "$TARGET/$KIT_DIR/.scaffold-manifest" ]; then
  drift="$("$SCAFFOLD_ROOT/bin/sync.sh" --check "$TARGET" 2>&1 | grep -cE '^  (missing|drift)' || true)"
  [ "${drift:-0}" = 0 ] && ok "managed copies match the kit" || warn "$drift managed file(s) differ from the kit: sync.sh --check $TARGET (then sync.sh)"
fi

# the kit's part of the shared files (AGENTS.md, CLAUDE.md, settings.json, hooks.json, config.toml)
if [ -f "$TARGET/$KIT_DIR/.scaffold-shared" ]; then
  . "$SCAFFOLD_ROOT/bin/shared.sh"
  shared_out="$(KIT_DIR="$KIT_DIR" TARGET="$TARGET" refresh_shared check 2>&1)" \
    && ok "shared files carry the current kit block/entries" \
    || warn "kit part of a shared file is out of date: $(printf '%s' "$shared_out" | grep -c drift) file(s). Run sync.sh (it rewrites only the kit's block/entries)"
else
  warn "no $KIT_DIR/.scaffold-shared: shared files (AGENTS.md, settings.json ...) predate block management; run upgrade.sh"
fi

# git hooks need the scripts: from the project's copy, or from the kit registered on this machine
if [ -d "$TARGET/.githooks" ] && [ ! -x "$TARGET/$KIT_DIR/scripts/guard.sh" ]; then
  reg="${SPEC_KIT_HOME:-$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/spec-driven-kit/home" 2>/dev/null || true)}"
  [ -x "$reg/scripts/guard.sh" ] || { command -v sdkit >/dev/null 2>&1 && reg="$(sdkit where)"; }
  [ -n "$reg" ] && [ -x "$reg/scripts/guard.sh" ] && ok "git hooks use the kit at $reg" \
    || bad "git hooks have no kit to call: run $SCAFFOLD_ROOT/bin/install.sh (or init.sh --host <non-claude> to vendor the scripts)"
fi

# server-side gate: local hooks can be skipped, CI cannot
if grep -qsE 'sdd\.sh"? ci-check' "$TARGET/bitbucket-pipelines.yml" "$TARGET"/.github/workflows/*.yml "$TARGET/.gitlab-ci.yml" 2>/dev/null; then
  ok "CI runs the spec-driven gate (sdd.sh ci-check)"
  [ -x "$TARGET/$KIT_DIR/scripts/sdd.sh" ] || bad "CI calls $KIT_DIR/scripts/sdd.sh but it is missing (run upgrade.sh)"
else
  warn "no server-side gate in CI: local hooks can be skipped with --no-verify (init.sh --ci bitbucket|github|gitlab)"
fi

# run-role.sh needs the host's CLI; the rest of the kit does not
cli_note() { command -v "$1" >/dev/null && ok "$1 CLI installed" || warn "$1 CLI not found (only needed for scripts/run-role.sh --host $2)"; }
{ [ -f "$TARGET/.claude/settings.json" ] || [ -f "$TARGET/.claude/settings.local.json" ]; } && cli_note claude claude
[ "$has_codex" = 1 ] && cli_note codex codex
[ "$has_opencode" = 1 ] && cli_note opencode opencode
[ "$has_cursor" = 1 ] && cli_note cursor-agent cursor
[ "$has_gemini" = 1 ] && cli_note gemini gemini

# tools the stack needs: required|<command>|<hint> or optional|<command>|<hint>
STACK="${STACK:-$SDKIT_DEFAULT_STACK}"
tools="$TARGET/$KIT_DIR/scripts/tools.sh"; [ -x "$tools" ] || tools="$SCAFFOLD_ROOT/stacks/$STACK/scripts/tools.sh"
if [ -x "$tools" ] && [ "${ENVP:-standalone}" != analyst ]; then
  while IFS='|' read -r kind cmd hint; do
    [ -n "$cmd" ] || continue
    if command -v "$cmd" >/dev/null || [ -x "$TARGET/node_modules/.bin/$cmd" ]; then ok "$cmd installed"
    elif [ "$kind" = required ]; then bad "$cmd missing: $hint"
    else warn "$cmd missing: $hint"; fi
  done < <("$tools" "$TARGET")
fi
# react-native: third-party skills that upstream renamed or removed still sit in the repo (installed with npx skills add)
if [ "$STACK" = react-native ]; then
  for s in building-native-ui expo-tailwind-setup; do
    for d in .agents/skills .claude/skills; do
      [ -e "$TARGET/$d/$s" ] && warn "$d/$s is an outdated Expo skill (removed upstream): remove it and install the current set (claude plugin install expo@claude-plugins-official, or npx skills add expo/skills)" && break
    done
  done
fi
# OpenSpec is a permanent part of the workflow: the CLI, the openspec/ directory and its skills for the repo's hosts
if command -v openspec >/dev/null 2>&1; then
  ok "openspec CLI installed ($(openspec --version 2>/dev/null | head -1); the kit was tested with 1.13.x)"
else
  bad "openspec CLI missing: npm install -g @fission-ai/openspec (or: sdkit init --install-openspec)"
fi
if [ "${ENVP:-standalone}" != analyst ]; then
  [ -f "$TARGET/openspec/config.yaml" ] && ok "openspec/ initialised" || bad "openspec/ missing: run 'openspec init --tools <your hosts>' in the repo (sdkit init does it)"
fi
if [ -d "$TARGET/openspec" ]; then
  if [ -f "$TARGET/.claude/settings.json" ] || [ -f "$TARGET/.claude/settings.local.json" ] || [ -d "$TARGET/.claude/skills" ]; then
    [ -d "$TARGET/.claude/skills/openspec-propose" ] && ok "openspec skills present for Claude Code" || warn "openspec skills missing in .claude/skills: run 'openspec update' (or init with --tools claude)"
  fi
  if [ "$has_agents_host" = 1 ]; then
    [ -d "$TARGET/.agents/skills/openspec-propose" ] && ok "openspec skills present in .agents/skills" || warn "openspec skills missing in .agents/skills: run 'openspec update'"
  fi
fi

say ""; say "doctor: $FAILS failure(s), $WARNS warning(s)"
[ "$FAILS" -eq 0 ]
