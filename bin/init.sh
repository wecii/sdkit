#!/usr/bin/env bash
# Install the kit's project side into a repo. Run once, by whoever sets a repo up; developers who clone it do nothing.
# Usage: init.sh [--install-openspec] [--ci bitbucket|github|gitlab] [--host claude[,codex,opencode,cursor,gemini]] [--dir NAME] [--mode plugin|copy] [--stack go|spring-boot|jvm|python|nextjs|react-native|generic] [--no-memory] [--memory-vcs commit|ignore] [--env standalone|analyst|developer] [--force] [--marketplace-url URL] [target-dir]
#   --env analyst|developer  the install persona, kept in sdkit.env as SDKIT_ENV (default standalone = today's behaviour; an existing value is kept).
#                     analyst: a project-specs repo (no stack, no openspec, git-ignored pre-spec dir); developer: a source repo with specs/ as a submodule
#   --host claude     (default) Claude Code
#   The project-side directory (sdkit.env, project.md, rules, memory, scripts ...) is .sdkit/ for every host. It is committed except what
#   is personal or generated (its .gitignore). A repo set up before 1.0 keeps its .claude/.codex/.agentkit with project.env until
#   `sdkit upgrade --migrate`. --dir NAME overrides.
#   Files the kit generates outside .sdkit/ (host settings, hooks, roles, git hooks) are hidden for this clone in .git/info/exclude;
#   only AGENTS.md and CLAUDE.md (kit block) are meant to be committed.
#   Project memory is on by default (--no-memory turns it off); --memory-vcs ignore keeps the entries out of git.
#   --host codex      Codex: AGENTS.md, skills in .agents/skills, roles in .codex/, kit scripts in <project-dir>/scripts, git hooks in .githooks
#   --host opencode|cursor|gemini  like codex: AGENTS.md, skills in .agents/skills, kit scripts and hooks in <project-dir>, git hooks in .githooks,
#                     plus the host's own role files and guard wiring (.opencode/, .cursor/, .gemini/)
#   --host claude,codex,...  any combination; kit scripts are copied so every host uses the same ones
#   plugin (default)  Claude only: project files only; hooks, agents, skills and scripts come from the installed plugin
#   copy              also copies hooks, agents, skills and scripts into .claude/ (no plugin needed)
set -eu
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/shared.sh"

MODE=plugin
HOSTS=claude
KIT_DIR=${KIT_DIR:-}
STACK=""
CI_HOST=""
INSTALL_OPENSPEC=0
MEMORY_ON=1
MEMORY_VCS=""
FORCE=0
MARKETPLACE_URL=""
ENV_REQ=""
TARGET="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOSTS="$2"; shift ;;
    --dir) KIT_DIR="$2"; shift ;;
    --mode) MODE="$2"; shift ;;
    --stack) STACK="$2"; shift ;;
    --marketplace-url) MARKETPLACE_URL="$2"; shift ;;
    --env) ENV_REQ="${2:-}"; shift ;;
    --force) FORCE=1 ;;
    --ci) CI_HOST="$2"; shift ;;
    --install-openspec) INSTALL_OPENSPEC=1 ;;
    --memory) MEMORY_ON=1 ;;
    --no-memory) MEMORY_ON=0 ;;
    --memory-vcs) MEMORY_VCS="$2"; shift ;;
    -*) say "unknown option $1"; exit 2 ;;
    *) TARGET="$(cd "$1" && pwd)" ;;
  esac
  shift
done
export FORCE MARKETPLACE_URL
case "$CI_HOST" in ""|bitbucket|github|gitlab) ;; *) say "--ci takes bitbucket, github or gitlab, got '$CI_HOST'"; exit 2 ;; esac
case "$MEMORY_VCS" in ""|commit|ignore) ;; *) say "--memory-vcs takes commit or ignore, got '$MEMORY_VCS'"; exit 2 ;; esac
case "$ENV_REQ" in ""|standalone|analyst|developer) ;; *) say "--env takes standalone, analyst or developer, got '$ENV_REQ'"; exit 2 ;; esac
case "$MODE" in plugin|copy) ;; *) say "--mode must be plugin or copy"; exit 2 ;; esac
for h in $(printf '%s' "$HOSTS" | tr ',' ' '); do
  case "$h" in claude|codex|opencode|cursor|gemini) ;; *) say "--host takes claude, codex, opencode, cursor and/or gemini, got '$h'"; exit 2 ;; esac
done
want_host() { case ",$HOSTS," in *",$1,"*) return 0 ;; esac; return 1; }
# project-side directory: keep an existing one, else name it after the host(s)
existing="$(resolve_kit_dir "$TARGET")"
if [ -z "$KIT_DIR" ]; then
  if [ -n "$existing" ]; then KIT_DIR="$existing"; else KIT_DIR=.sdkit; fi
fi
case "$KIT_DIR" in .sdkit|.agentkit|.claude|.codex) ;; *) say "--dir must be .sdkit (or a legacy .agentkit, .claude, .codex; the kit finds it by these names)"; exit 2 ;; esac
export KIT_DIR
# the settings file keeps its old name in a repo set up before 1.0
ENV_FILE="$(resolve_kit_env "$TARGET" "$KIT_DIR")"; export KIT_ENV="$ENV_FILE"
# the install persona: --env, else what sdkit.env already says, else standalone. An existing value is never rewritten (edit sdkit.env by hand to change it).
cur_env="$(sed -n 's/^SDKIT_ENV=//p' "$TARGET/$KIT_DIR/$ENV_FILE" 2>/dev/null | tail -1 | tr -d "\"' ")"
case "$cur_env" in ""|standalone|analyst|developer) ;; *) say "SDKIT_ENV='$cur_env' in $KIT_DIR/$ENV_FILE is not standalone, analyst or developer"; exit 2 ;; esac
if [ -n "$cur_env" ] && [ -n "$ENV_REQ" ] && [ "$cur_env" != "$ENV_REQ" ]; then
  say "$KIT_DIR/$ENV_FILE already has SDKIT_ENV=$cur_env; init does not rewrite it. Edit the line by hand to switch to $ENV_REQ."; exit 2
fi
SDKIT_ENV="${cur_env:-${ENV_REQ:-standalone}}"
if [ "$KIT_DIR" = .sdkit ]; then CLAUDE_SETTINGS=.claude/settings.local.json; GITIGNORE_TPL=templates/sdkit.gitignore
else CLAUDE_SETTINGS=.claude/settings.json; GITIGNORE_TPL=templates/claude.gitignore; fi
# every host but Claude has no plugin to fall back on, so kit scripts and skills are copied into the repo
NEED_COPY=0
[ "$MODE" = copy ] && NEED_COPY=1
OTHER_HOSTS=0
for h in $(printf '%s' "$HOSTS" | tr ',' ' '); do [ "$h" = claude ] || OTHER_HOSTS=1; done
[ "$OTHER_HOSTS" = 1 ] && NEED_COPY=1

command -v jq >/dev/null || { say "jq is required"; exit 1; }
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || { say "$TARGET is not a git repository"; exit 1; }

STACKS="go spring-boot react-native jvm nextjs python generic"
if [ -z "$STACK" ] && [ "$SDKIT_ENV" = analyst ]; then STACK=generic; fi   # a project-specs repo has no stack
if [ -z "$STACK" ]; then
  for s in $STACKS; do [ -x "$SCAFFOLD_ROOT/stacks/$s/detect.sh" ] && "$SCAFFOLD_ROOT/stacks/$s/detect.sh" "$TARGET" && { STACK="$s"; break; }; done
fi
if [ -z "$STACK" ]; then
  STACK=generic
  say "no known stack detected: using 'generic'. Set VERIFY_FAST_CMD / VERIFY_TEST_CMD in sdkit.env, or pass --stack (one of: $STACKS)"
fi
[ -d "$SCAFFOLD_ROOT/stacks/$STACK" ] || { say "unsupported stack: $STACK"; exit 1; }

# the plugin is installed from the kit's own git repository, with any credentials stripped from the URL. A checkout of the kit knows it
# (its origin); a package-manager install does not: it sits inside the package manager's repository, so asking git there gives the wrong
# answer (Homebrew's own). Then the URL declared in plugin.json ("repository") is used.
if [ -z "$MARKETPLACE_URL" ]; then
  if [ "$(git -C "$SCAFFOLD_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$SCAFFOLD_ROOT" ]; then
    MARKETPLACE_URL="$(git -C "$SCAFFOLD_ROOT" remote get-url origin 2>/dev/null | sed -E 's#(https?://)[^@/]+@#\1#' || true)"
  fi
  [ -n "$MARKETPLACE_URL" ] || MARKETPLACE_URL="$(jq -r '.repository // empty' "$SCAFFOLD_ROOT/.claude-plugin/plugin.json" 2>/dev/null | sed -E 's#(https?://)[^@/]+@#\1#')"
  export MARKETPLACE_URL
fi

BASE_BRANCH="$(git -C "$TARGET" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [ -z "$BASE_BRANCH" ]; then
  for candidate in develop main master; do
    git -C "$TARGET" rev-parse --verify -q "$candidate" >/dev/null && { BASE_BRANCH="$candidate"; break; }
  done
fi
BASE_BRANCH="${BASE_BRANCH:-main}"
PROJECT_NAME="$(basename "$TARGET")"

say "spec-driven-kit $SCAFFOLD_VERSION -> $TARGET (host=$HOSTS dir=$KIT_DIR mode=$MODE stack=$STACK base=$BASE_BRANCH${ENV_REQ:+ env=$ENV_REQ})"
mkdir -p "$TARGET/$KIT_DIR"
: > "$TARGET/$KIT_DIR/.scaffold-manifest.new"

say "rules and stack defaults (project-owned: edit freely)"
for f in "$SCAFFOLD_ROOT"/core/rules/*.md "$SCAFFOLD_ROOT"/stacks/$STACK/rules/*.md; do
  rel="${f#$SCAFFOLD_ROOT/}"; install_template "$rel" "$KIT_DIR/rules/$(basename "$f")"
done
[ -f "$SCAFFOLD_ROOT/stacks/$STACK/golangci.yml" ] && install_template "stacks/$STACK/golangci.yml" "$KIT_DIR/golangci.yml"
for f in "$SCAFFOLD_ROOT"/stacks/$STACK/verify.d.example/*; do
  [ "$SDKIT_ENV" = analyst ] && break   # no verify in a project-specs repo
  [ -f "$f" ] && install_template "stacks/$STACK/verify.d.example/$(basename "$f")" "$KIT_DIR/verify.d/$(basename "$f")"
done

say "project profile (project-owned: fill in)"
ENV_NEW=0; [ -f "$TARGET/$KIT_DIR/$ENV_FILE" ] || ENV_NEW=1
if [ "$ENV_NEW" = 0 ] && [ -n "$ENV_REQ" ] && ! grep -q '^SDKIT_ENV=' "$TARGET/$KIT_DIR/$ENV_FILE"; then
  # an older file without the key: record the requested persona before add_missing would append the default
  printf '\n# Install persona: standalone | analyst | developer (set by sdkit init --env)\nSDKIT_ENV=%s\n' "$SDKIT_ENV" >> "$TARGET/$KIT_DIR/$ENV_FILE"
fi
install_template templates/sdkit.env "$KIT_DIR/$ENV_FILE"
[ "$ENV_NEW" = 1 ] && [ "$SDKIT_ENV" != standalone ] && { sed -i.bak -e "s#^SDKIT_ENV=.*#SDKIT_ENV=$SDKIT_ENV#" "$TARGET/$KIT_DIR/$ENV_FILE" && rm -f "$TARGET/$KIT_DIR/$ENV_FILE.bak"; }
install_template templates/project.md "$KIT_DIR/project.md"
pitfalls_tpl=templates/known-pitfalls.md; [ -f "$SCAFFOLD_ROOT/stacks/$STACK/known-pitfalls.md" ] && pitfalls_tpl="stacks/$STACK/known-pitfalls.md"
install_template "$pitfalls_tpl" "$KIT_DIR/known-pitfalls.md"
# price table (Bedrock list, USD per million tokens): without it every cost figure is N/A. Kit-written; `sdkit doctor --update-pricing` refreshes it, a table you edit is never touched
install_template templates/pricing.json "$KIT_DIR/pricing.json"
install_template templates/adr/TEMPLATE.md "$KIT_DIR/adr/TEMPLATE.md"
install_template "$GITIGNORE_TPL" "$KIT_DIR/.gitignore"
if want_host claude; then
  # a legacy layout keeps Claude's own ignore file; with .sdkit/ the generated .claude files are excluded per clone instead
  case "$KIT_DIR" in .sdkit|.claude) ;; *) install_template templates/claude.gitignore .claude/.gitignore ;; esac
fi
if [ "$KIT_DIR" = .sdkit ]; then
  # 1.0.0 kept every setting in one file: the personal ones move to sdkit.local.env (git-ignored), the shared file is committed
  split_personal_env "$TARGET/$KIT_DIR" "$ENV_FILE"
  install_template templates/sdkit.local.env "$KIT_DIR/sdkit.local.env"
  gi="$TARGET/$KIT_DIR/.gitignore"
  if [ -f "$gi" ] && ! grep -qxF sdkit.local.env "$gi"; then
    sed -i.bak -e '/^sdkit\.env$/d' -e '/^sdkit\.env\.bak$/d' "$gi" && rm -f "$gi.bak"
    printf '\n# personal settings (sdkit.env is shared and committed)\nsdkit.local.env\nsdkit.local.env.bak\n# a root .gitignore rule such as *.env would hide the shared file; it holds settings only, never secrets\n!sdkit.env\n' >> "$gi"
    say "  update $KIT_DIR/.gitignore: sdkit.local.env is personal now, sdkit.env is shared"
  fi
fi
# settings added to the templates since these files were written arrive with their defaults; existing lines and values are never touched
add_missing() {   # add_missing <env file name> <template> [label]
  local tpl; tpl="$(mktemp)"
  sed -e "s#__BASE_BRANCH__#${BASE_BRANCH}#g" -e "s#__STACK__#${STACK}#g" -e "s#__KIT_DIR__#${KIT_DIR}#g" "$SCAFFOLD_ROOT/$2" > "$tpl"
  local added; added="$(append_missing_env "$TARGET/$KIT_DIR/$1" "$tpl" | paste -sd' ' -)"
  rm -f "$tpl"
  [ -z "$added" ] || say "  added  $KIT_DIR/$1: $added (defaults; yours are untouched)"
}
if [ "$ENV_NEW" = 0 ]; then
  add_missing "$ENV_FILE" templates/sdkit.env
  if [ "$KIT_DIR" = .sdkit ]; then add_missing sdkit.local.env templates/sdkit.local.env
  else add_missing "$ENV_FILE" templates/sdkit.local.env; fi   # a pre-1.0 layout keeps a single file
elif [ "$MEMORY_ON" = 0 ]; then
  sed -i.bak -e 's#^MEMORY=1$#MEMORY=#' "$TARGET/$KIT_DIR/$ENV_FILE" && rm -f "$TARGET/$KIT_DIR/$ENV_FILE.bak"
fi

# Persona-only settings are appended when missing (never rewritten), so a standalone file stays as it is.
env_key() {   # env_key <KEY> <value> <comment>
  grep -q "^$1=" "$TARGET/$KIT_DIR/$ENV_FILE" && return 0
  printf '\n# %s\n%s=%s\n' "$3" "$1" "$2" >> "$TARGET/$KIT_DIR/$ENV_FILE"; say "  added  $KIT_DIR/$ENV_FILE: $1 ($SDKIT_ENV)"
}
case "$SDKIT_ENV" in
  developer)
    env_key SDD_MANAGED on "Managed execution (SDKIT_ENV=developer): tasks come from Jira, approved specs from the read-only submodule below."
    env_key SPECS_DIR specs "Directory of the approved-specs git submodule (read-only for developers)."
    env_key TRACKER jira "Issue tracker for managed execution (see the Jira keys further down)."
    env_key SPEC_REPO "" "Hint: git URL of the project-specs repo to add as the submodule: git submodule add <SPEC_REPO> specs" ;;
  analyst)
    env_key PRESPEC_DIR prespec "Git-ignored directory for pre-specs (raw input). Its content is never committed. Default: prespec"
    env_key SPEC_REVIEW_MAX_ROUNDS 2 "Most review rounds per spec before a human decides. Default: 2" ;;
esac
if [ "$SDKIT_ENV" != standalone ]; then
  # review rubrics per artifact (project-owned: edit freely; existing files are kept)
  for f in "$SCAFFOLD_ROOT"/templates/review.d/*; do
    [ -f "$f" ] && install_template "templates/review.d/$(basename "$f")" "$KIT_DIR/review.d/$(basename "$f")"
  done
fi
if [ "$SDKIT_ENV" = analyst ]; then
  say "pre-spec directory (git-ignored; nothing in it is committed)"
  ps_dir="$(sed -n 's/^PRESPEC_DIR=//p' "$TARGET/$KIT_DIR/$ENV_FILE" | tail -1 | tr -d "\"' ")"; ps_dir="${ps_dir:-prespec}"
  case "$ps_dir" in /*|*..*|*[!A-Za-z0-9._/-]*) say "  FAIL   PRESPEC_DIR '$ps_dir' must be a plain relative path inside the repo"; exit 2 ;; esac
  ps_dir="${ps_dir%/}"
  if [ ! -e "$TARGET/$ps_dir/README.md" ]; then
    mkdir -p "$TARGET/$ps_dir" && cp "$SCAFFOLD_ROOT/templates/prespec/README.md" "$TARGET/$ps_dir/README.md" && say "  wrote  $ps_dir/README.md"
  fi
  # the project's own .gitignore (the directory is outside the project dir); the whole directory is ignored, so no .gitkeep can be committed
  if ! grep -qxF "/$ps_dir/" "$TARGET/.gitignore" 2>/dev/null; then
    printf '\n# pre-specs are working input, never committed (sdkit analyst env)\n/%s/\n' "$ps_dir" >> "$TARGET/.gitignore"; say "  wrote  .gitignore: /$ps_dir/"
  fi
fi

# Project memory: on by default for a new setup (sdkit.env MEMORY=1). The entries are the developer's; init only creates INDEX.md and the ignore line.
pe="$TARGET/$KIT_DIR/$ENV_FILE"
if [ "$(sed -n 's/^MEMORY=//p' "$pe" | tail -1)" = 1 ]; then
  say "project memory (shared through git; entries are yours)"
  [ -z "$MEMORY_VCS" ] || { sed -i.bak -e "s#^MEMORY_VCS=.*#MEMORY_VCS=$MEMORY_VCS#" "$pe" && rm -f "$pe.bak"; }
  mem_dir="$(sed -n 's/^MEMORY_DIR=//p' "$pe" | tail -1)"; mem_dir="${mem_dir:-memory}"
  mem_vcs="$(sed -n 's/^MEMORY_VCS=//p' "$pe" | tail -1)"
  case "$mem_dir" in
    /*) say "  MEMORY_DIR is outside the repo; no .gitignore change" ;;
    *) [ "$mem_vcs" = ignore ] && ! grep -qxF "$mem_dir/" "$TARGET/$KIT_DIR/.gitignore" 2>/dev/null \
         && { printf '\n# project memory kept personal (MEMORY_VCS=ignore)\n%s/\n' "$mem_dir" >> "$TARGET/$KIT_DIR/.gitignore"; say "  wrote  $KIT_DIR/.gitignore: $mem_dir/"; } ;;
  esac
  ( cd "$TARGET" && KIT_DIR="$KIT_DIR" "$SCAFFOLD_ROOT/scripts/memory.sh" init >/dev/null ) && say "  wrote  $KIT_DIR/$mem_dir/INDEX.md" || say "  FAIL   memory.sh init did not run"
fi

# The server-side gate (CI) has no plugin either: it runs the project's own copy of these scripts, in every mode.
if [ "$NEED_COPY" = 0 ]; then
  say "ci gate scripts (managed: sync.sh updates them)"
  install_managed "scripts/env.sh" "$KIT_DIR/scripts/env.sh"
  install_managed "scripts/sdd.sh" "$KIT_DIR/scripts/sdd.sh"
  install_managed "scripts/resolve-base.sh" "$KIT_DIR/scripts/resolve-base.sh"
  chmod +x "$TARGET/$KIT_DIR"/scripts/*.sh
fi
if [ -n "$CI_HOST" ]; then
  say "ci: $CI_HOST (project-owned: merge into an existing pipeline file by hand)"
  case "$CI_HOST" in
    bitbucket) install_template templates/ci/bitbucket-pipelines.yml bitbucket-pipelines.yml ;;
    github) install_template templates/ci/github-actions.yml .github/workflows/spec-driven-gate.yml ;;
    gitlab) install_template templates/ci/gitlab-ci.yml .gitlab-ci.yml ;;
  esac
fi

# install_skills <dest-root>: every skill with its references/, recursively
install_skills() {
  for dir in "$SCAFFOLD_ROOT"/skills/*/; do
    name="$(basename "$dir")"
    ( cd "$dir" && find . -type f | sed 's#^\./##' ) | while IFS= read -r rel; do
      install_managed "skills/$name/$rel" "$1/$name/$rel"
    done
  done
}
install_scripts() {
  for f in "$SCAFFOLD_ROOT"/stacks/$STACK/scripts/*.sh; do install_managed "stacks/$STACK/scripts/$(basename "$f")" "$KIT_DIR/scripts/$(basename "$f")"; done
  [ -f "$SCAFFOLD_ROOT/stacks/$STACK/scripts/steps.sh" ] && grep -q node-lib "$SCAFFOLD_ROOT/stacks/$STACK/scripts/steps.sh" \
    && install_managed "stacks/_node/scripts/node-lib.sh" "$KIT_DIR/scripts/node-lib.sh"
  for s in env sdd resolve-base open-pr guard plan-waves worktree verify-core verify-lib state parse-verdict check-plan-parity check-writes usage memory lookup-cache run-role route workflow contract telemetry dod-check audit redact digest adapter dispatch knowledge recover test-select pr-check pricing review jira spec tasks; do
    install_managed "scripts/$s.sh" "$KIT_DIR/scripts/$s.sh"
  done
  chmod +x "$TARGET/$KIT_DIR"/scripts/*.sh
  # external execution adapters (run-role.sh --host ext:<name>): the kit's own, e.g. litellm
  for f in "$SCAFFOLD_ROOT"/adapters.d/*.sh; do [ -f "$f" ] && install_managed "adapters.d/$(basename "$f")" "$KIT_DIR/adapters.d/$(basename "$f")"; done
  chmod +x "$TARGET/$KIT_DIR"/adapters.d/*.sh 2>/dev/null || true
  # tier -> model map: run-role.sh --tier reads it
  install_managed "core/tiers.env" "$KIT_DIR/tiers.env"
  # execution adapters' capabilities: route.sh (ROUTING=on) reads it
  install_managed "core/adapters.json" "$KIT_DIR/adapters.json"
  # role texts: run-role.sh builds its prompt from them
  for f in "$SCAFFOLD_ROOT"/core/roles/*.md; do
    [ "$(basename "$f")" = README.md ] && continue
    install_managed "core/roles/$(basename "$f")" "$KIT_DIR/roles/$(basename "$f")"
  done
}
# hooks that other hosts call through hooks/adapt.sh
install_hooks() {
  for f in "$SCAFFOLD_ROOT"/hooks/*.sh; do install_managed "hooks/$(basename "$f")" "$KIT_DIR/hooks/$(basename "$f")"; done
  chmod +x "$TARGET/$KIT_DIR"/hooks/*.sh
}

if [ "$MODE" = copy ] && want_host claude; then
  say "kit files copied into .claude/ (managed: sync.sh updates them)"
  install_skills .claude/skills
  for f in "$SCAFFOLD_ROOT"/agents/*.md; do install_managed "agents/$(basename "$f")" ".claude/agents/$(basename "$f")"; done
  for f in "$SCAFFOLD_ROOT"/hooks/*.sh; do install_managed "hooks/$(basename "$f")" ".claude/hooks/$(basename "$f")"; done
  chmod +x "$TARGET"/.claude/hooks/*.sh
fi

if [ "$OTHER_HOSTS" = 1 ]; then
  say "skills, AGENTS.md and git hooks for the non-Claude hosts"
  install_skills .agents/skills
  install_shared block-md AGENTS.md templates/blocks/AGENTS.kit.md
  for f in "$SCAFFOLD_ROOT"/adapters/git/*; do install_managed "adapters/git/$(basename "$f")" ".githooks/$(basename "$f")"; done
  chmod +x "$TARGET"/.githooks/*
  install_hooks
fi
if want_host codex; then
  say "codex: roles"
  for f in "$SCAFFOLD_ROOT"/adapters/codex/agents/*.toml; do install_managed "adapters/codex/agents/$(basename "$f")" ".codex/agents/$(basename "$f")"; done
  install_shared block-hash .codex/config.toml adapters/codex/config.toml.snippet
fi
if want_host opencode; then
  say "opencode: roles and guard plugin"
  for f in "$SCAFFOLD_ROOT"/adapters/opencode/agents/*.md; do install_managed "adapters/opencode/agents/$(basename "$f")" ".opencode/agents/$(basename "$f")"; done
  install_managed adapters/opencode/plugins/spec-driven-kit-guard.js .opencode/plugins/spec-driven-kit-guard.js
fi
if want_host cursor; then
  say "cursor: roles and hooks"
  for f in "$SCAFFOLD_ROOT"/adapters/cursor/agents/*.md; do install_managed "adapters/cursor/agents/$(basename "$f")" ".cursor/agents/$(basename "$f")"; done
  install_shared hooks-flat .cursor/hooks.json adapters/cursor/hooks.json
fi
if want_host gemini; then
  say "gemini: roles, context file and hooks"
  for f in "$SCAFFOLD_ROOT"/adapters/gemini/agents/*.md; do install_managed "adapters/gemini/agents/$(basename "$f")" ".gemini/agents/$(basename "$f")"; done
  install_shared hooks-grouped .gemini/settings.json adapters/gemini/settings.json
fi

if [ "$NEED_COPY" = 1 ]; then
  install_scripts
  # no plugin to fall back on, so the project config points at the copies
  sed -i.bak -e "s#^VERIFY_CMD=.*#VERIFY_CMD=$KIT_DIR/scripts/verify.sh#" -e "s#^DIFF_BASE_CMD=.*#DIFF_BASE_CMD=$KIT_DIR/scripts/resolve-base.sh#" "$TARGET/$KIT_DIR/$ENV_FILE" \
    && rm -f "$TARGET/$KIT_DIR/$ENV_FILE.bak"
fi

if want_host claude; then
  say "settings"
  install_shared claude-settings "$CLAUDE_SETTINGS" "templates/settings.$MODE.json"
  install_shared block-md .claude/CLAUDE.md templates/blocks/CLAUDE.kit.md
fi

# OpenSpec is a permanent part of the workflow (explore, propose, sync, archive are its skills). The kit does not
# vendor it: the CLI comes from npm, and `openspec init` writes its skills for the same hosts as ours.
say "openspec (required by the workflow)"
if [ "$SDKIT_ENV" = analyst ]; then
  say "  skipped (analyst env: no openspec in a project-specs repo)"
elif ! command -v openspec >/dev/null 2>&1 && [ "$INSTALL_OPENSPEC" = 1 ]; then
  if command -v npm >/dev/null 2>&1; then
    say "  installing @fission-ai/openspec (npm install -g)"; npm install -g @fission-ai/openspec >/dev/null 2>&1 || say "  FAIL   npm install -g @fission-ai/openspec did not succeed; install it yourself"
  else say "  FAIL   npm not found: install Node.js first (brew install node), then re-run with --install-openspec"; fi
fi
OPENSPEC_PENDING=0
if [ "$SDKIT_ENV" = analyst ]; then :
elif command -v openspec >/dev/null 2>&1; then
  if [ -d "$TARGET/openspec" ]; then
    say "  kept   openspec/ (exists; run 'openspec update' in the repo if its skills are missing for a host)"
  else
    ( cd "$TARGET" && openspec init --tools "$HOSTS" --no-animation </dev/null 2>&1 | grep -E 'Created|skills and|Config:|error|Error' | sed 's/^/  /' ) \
      || true
    [ -d "$TARGET/openspec" ] && say "  wrote  openspec/ and OpenSpec skills for: $HOSTS" || { say "  FAIL   openspec init did not create openspec/; run it by hand: openspec init --tools $HOSTS"; OPENSPEC_PENDING=1; }
  fi
else
  OPENSPEC_PENDING=1
  say "  MISSING openspec CLI. Install it, then run this again (or: openspec init --tools $HOSTS):"
  say "           npm install -g @fission-ai/openspec        (or re-run with --install-openspec)"
fi

finish_manifest

# Generated files outside .sdkit/ are identical on every machine: hide them from git here (this clone only), keep the project's .gitignore untouched.
# AGENTS.md and CLAUDE.md carry the kit block and are meant to be committed.
gen=()
while IFS="$(printf '\t')" read -r dest _; do case "$dest" in "$KIT_DIR"/*|"") ;; *) gen+=("$dest") ;; esac; done < "$TARGET/$KIT_DIR/.scaffold-manifest"
if [ -f "$TARGET/$KIT_DIR/$SHARED_FILE_NAME" ]; then
  while IFS="$(printf '\t')" read -r kind dest _; do case "$kind" in block-md|"") ;; *) case "$dest" in "$KIT_DIR"/*) ;; *) gen+=("$dest") ;; esac ;; esac; done < "$TARGET/$KIT_DIR/$SHARED_FILE_NAME"
fi
[ "${#gen[@]}" -eq 0 ] || exclude_untracked "$TARGET" "${gen[@]}"

say ""
say "done. next: fill in $KIT_DIR/project.md and review $KIT_DIR/$ENV_FILE, rename the verify.d/*.example files you want, then run:"
say "  $SCAFFOLD_ROOT/bin/doctor.sh $TARGET"
say "Commit $KIT_DIR/ (its .gitignore keeps $ENV_FILE, work/ and generated files out), AGENTS.md and the kit block in .claude/CLAUDE.md. Each developer runs 'sdkit init' once on their machine."
if [ "$OTHER_HOSTS" = 1 ]; then
  say "Other hosts: AGENTS.md is the shared entry file; .agents/ .githooks/ and the host files are generated per machine. Each clone runs once:  git config core.hooksPath .githooks"
  want_host codex && say "Codex: check that your Codex version has multi-agent enabled (see .codex/config.toml); start a task with \$spec-driven-dev."
  want_host opencode && say "OpenCode: roles in .opencode/agents (shell permission key is '$(sed -n 's/^OPENCODE_SHELL_KEY=//p' "$TARGET/$KIT_DIR/$ENV_FILE" | tail -1)'; on older releases set OPENCODE_SHELL_KEY=bash in $KIT_DIR/$ENV_FILE and run sync.sh), guard plugin in .opencode/plugins."
  want_host cursor && say "Cursor: the kit's hooks were merged into .cursor/hooks.json next to yours; hooks and subagents may be IDE-only (see docs/guide.md section 13)."
  want_host gemini && say "Gemini CLI: the kit's hooks and context file were merged into .gemini/settings.json next to your settings; subagents may need the experimental flag."
fi
if [ "$STACK" = react-native ]; then
  # third-party skills are referenced, never vendored: they change upstream every week (docs/guide.md, Stacks)
  has_expo=0
  while IFS= read -r p; do jq -e '(.dependencies.expo // .devDependencies.expo) // empty' "$p" >/dev/null 2>&1 && has_expo=1; done \
    < <(find "$TARGET" -maxdepth 3 -name package.json -not -path '*/node_modules/*' 2>/dev/null)
  say "React Native: optional third-party skills (not part of the kit; install them yourself):"
  [ "$has_expo" = 1 ] && say "  Expo (expo-router, expo-native-ui, expo-data-fetching ...): claude plugin install expo@claude-plugins-official   other hosts: npx skills add expo/skills"
  say "  React Native rules: npx skills add vercel-labs/agent-skills   performance: npx skills add callstackincubator/agent-skills"
  say "  (npx skills add writes .agents/skills/; doctor does not count it as a host install)"
fi
[ "${OPENSPEC_PENDING:-0}" = 1 ] && say "NOTE: the workflow needs OpenSpec; doctor will fail until it is installed and initialised." || true
