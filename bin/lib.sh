# Shared helpers for init.sh / sync.sh / doctor.sh. Source this; do not execute.
SCAFFOLD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD_VERSION="$(jq -r .version "$SCAFFOLD_ROOT/.claude-plugin/plugin.json")"
. "$SCAFFOLD_ROOT/scripts/env.sh"   # settings files are parsed, never sourced; one project-dir resolver

# resolve_kit_dir <target>: the project-side directory that holds sdkit.env (.sdkit) or, in a repo set up before 1.0, project.env
# (.agentkit, .claude or .codex); empty if none yet. resolve_kit_env <target> <dir> prints the env file name in it.
resolve_kit_dir() {
  local KIT_DIR="${KIT_DIR:-}" KIT_ENV=""
  sdkit_resolve_dir "$1"
  [ -f "$1/$KIT_DIR/$KIT_ENV" ] && echo "$KIT_DIR"
  return 0
}
resolve_kit_env() { if [ -f "$1/$2/sdkit.env" ]; then echo sdkit.env; elif [ -f "$1/$2/project.env" ]; then echo project.env; else echo sdkit.env; fi; }

# append_missing_env <dest> <template>: add the settings the template has and dest lacks, with their comments, after the existing content.
# Existing lines (and values) are never touched. Prints the added keys, one per line.
append_missing_env() {
  local dest="$1" tpl="$2" tmp; tmp="$(mktemp)"
  awk -v dest="$dest" '
    BEGIN { while ((getline l < dest) > 0) { if (match(l, /^[A-Z_][A-Z0-9_]*=/)) have[substr(l, 1, RLENGTH - 1)] = 1
                                             else if (match(l, /^: "\$\{[A-Z_]+:=/)) have[substr(l, 6, RLENGTH - 7)] = 1 } }
    /^#/ || /^[[:space:]]*$/ { buf = buf $0 "\n"; next }
    { key = ""
      if (match($0, /^[A-Z_][A-Z0-9_]*=/)) key = substr($0, 1, RLENGTH - 1)
      else if (match($0, /^: "\$\{[A-Z_]+:=/)) key = substr($0, 6, RLENGTH - 7)
      if (key != "" && !(key in have)) { printf "%s%s\n", buf, $0; print key > "/dev/stderr" }
      buf = "" }' "$tpl" > "$tmp" 2> "$tmp.keys"
  if [ -s "$tmp" ]; then
    { [ -z "$(tail -c1 "$dest")" ] || echo; printf '\n# --- added by sdkit %s: settings new since this file was created (your values above are untouched) ---\n' "$SCAFFOLD_VERSION"; cat "$tmp"; } >> "$dest"
    cat "$tmp.keys"
  fi
  rm -f "$tmp" "$tmp.keys"
}

# split_personal_env <dir> <env-name>: a repo on 1.0.0 keeps every setting in one file; the personal ones (the keys of templates/sdkit.local.env:
# limits, memory behaviour, hosts, models) move to sdkit.local.env with their values, the rest stays in the shared file. Does nothing when the
# local file exists already. Only comment lines the kit itself wrote above a moved setting are removed; the user's own lines stay.
split_personal_env() {
  local f="$1/$2" loc="$1/sdkit.local.env" tpl="$SCAFFOLD_ROOT/templates/sdkit.local.env" k v tmp
  [ -f "$f" ] && [ ! -f "$loc" ] || return 0
  cp "$tpl" "$loc"
  for k in $(grep -oE '^[A-Z][A-Z0-9_]*=' "$tpl" | tr -d '='); do
    grep -qE "^$k=" "$f" || continue
    v="$(grep -E "^$k=" "$f" | tail -1 | sed "s/^$k=//")"
    tmp="$(mktemp)"; K="$k" V="$v" awk 'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; next } { print }' "$loc" > "$tmp" && mv "$tmp" "$loc"
  done
  tmp="$(mktemp)"
  awk -v tpl="$tpl" '
    BEGIN { while ((getline l < tpl) > 0) { if (l ~ /^#/) kc[l] = 1; else if (match(l, /^[A-Z][A-Z0-9_]*=/)) pk[substr(l, 1, RLENGTH - 1)] = 1 } }
    /^#/ { buf[++n] = $0; next }
    { key = ""; if (match($0, /^[A-Z][A-Z0-9_]*=/)) key = substr($0, 1, RLENGTH - 1)
      if (key != "" && (key in pk)) { m = 0; for (i = 1; i <= n; i++) if (!(buf[i] in kc)) buf[++m] = buf[i]; n = m; for (i = 1; i <= n; i++) print buf[i]; n = 0; next }
      for (i = 1; i <= n; i++) print buf[i]; n = 0; print }
    END { for (i = 1; i <= n; i++) print buf[i] }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# exclude_untracked <target> <path...>: hide generated files from git for this clone only (.git/info/exclude), never the project's .gitignore.
# A path that git already tracks is left alone (an ignore rule would not apply to it anyway).
exclude_untracked() {
  local target="$1" f p ex; shift
  ex="$(git -C "$target" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  case "$ex" in /*) ;; *) ex="$target/$ex" ;; esac
  mkdir -p "$(dirname "$ex")"; touch "$ex"
  for p in "$@"; do
    git -C "$target" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && continue
    grep -qxF "/$p" "$ex" || { grep -q '^# sdkit: generated files' "$ex" || printf '\n# sdkit: generated files (rebuilt by sdkit init)\n' >> "$ex"; printf '/%s\n' "$p" >> "$ex"; }
  done
}

# detect_hosts <target>: comma list of the hosts a repo was set up for; detect_mode <target>: plugin|copy (Claude)
detect_hosts() {
  local t="$1" h=""
  { [ -f "$t/.claude/settings.json" ] || [ -f "$t/.claude/settings.local.json" ] || [ -f "$t/.claude/CLAUDE.md" ]; } && h=claude
  { [ -f "$t/.codex/config.toml" ] || [ -d "$t/.codex/agents" ]; } && h="${h:+$h,}codex"
  [ -d "$t/.opencode/agents" ] && h="${h:+$h,}opencode"
  [ -d "$t/.cursor/agents" ] && h="${h:+$h,}cursor"
  [ -d "$t/.gemini/agents" ] && h="${h:+$h,}gemini"
  # a repo with AGENTS.md / the kit skill in .agents/skills (not third-party skills) but no host directory yet is a Codex setup (0.3 layout)
  if { [ -z "$h" ] || [ "$h" = claude ]; } && { [ -f "$t/AGENTS.md" ] || [ -d "$t/.agents/skills/spec-driven-dev" ]; }; then h="${h:+$h,}codex"; fi
  echo "${h:-claude}"
}
detect_mode() { if [ -d "$1/.claude/hooks" ]; then echo copy; else echo plugin; fi; }

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
say() { printf '%s\n' "$*"; }

# record_managed <dest-rel> <src-rel>: remember what was installed so sync can tell local edits from upstream changes
record_managed() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$(sha "$TARGET/$1")" >> "$TARGET/$KIT_DIR/.scaffold-manifest.new"
}

# render_managed <src-abs> <dest-rel>: the bytes to install. The source itself, except where a project setting changes the
# kit's output, so the developer sets it in sdkit.env instead of editing a kit file:
#   OPENCODE_SHELL_KEY   the permission key OpenCode roles use for the shell tool (shell; older releases: bash)
render_managed() {
  local key=""
  case "$2" in
    .opencode/agents/*.md)
      key="$(sed -n 's/^OPENCODE_SHELL_KEY=//p' "$TARGET/${KIT_DIR:-.sdkit}/${KIT_ENV:-sdkit.env}" 2>/dev/null | tail -1)"
      if [ -n "$key" ] && [ "$key" != shell ]; then sed "s/^  shell:\$/  $key:/" "$1"; return; fi ;;
  esac
  cat "$1"
}

# install_managed <src-rel> <dest-rel>: copy a scaffold-owned file; keep an existing different file unless FORCE=1
install_managed() {
  local src="$SCAFFOLD_ROOT/$1" dest="$TARGET/$2" rendered
  mkdir -p "$(dirname "$dest")"
  rendered="$(mktemp)"; render_managed "$src" "$2" > "$rendered"
  if [ -f "$dest" ] && ! cmp -s "$rendered" "$dest" && [ "${FORCE:-0}" != 1 ]; then
    say "  kept   $2 (exists and differs; use --force to overwrite)"
  else
    cp -p "$src" "$dest" && cat "$rendered" > "$dest"
    say "  wrote  $2"
  fi
  rm -f "$rendered"
  record_managed "$2" "$1"
}

# install_template <src-rel> <dest-rel>: project-owned file, created once and never synced
install_template() {
  local src="$SCAFFOLD_ROOT/$1" dest="$TARGET/$2"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then say "  kept   $2 (project-owned, exists)"; return; fi
  sed -e "s#__KIT_ENV__#${KIT_ENV:-sdkit.env}#g" -e "s#__BASE_BRANCH__#${BASE_BRANCH}#g" -e "s#__PROJECT_NAME__#${PROJECT_NAME}#g" -e "s#__KIT_DIR__#${KIT_DIR}#g" -e "s#__STACK__#${STACK:-$SDKIT_DEFAULT_STACK}#g" -e "s#__KIT_HOOKS__#${KIT_HOOKS:-./$KIT_DIR/hooks}#g" \
      -e "s#__MARKETPLACE_URL__#${MARKETPLACE_URL:-https://example.invalid/spec-driven-kit.git}#g" "$src" > "$dest"
  say "  wrote  $2 (project-owned: edit it)"
}

finish_manifest() {
  mv "$TARGET/$KIT_DIR/.scaffold-manifest.new" "$TARGET/$KIT_DIR/.scaffold-manifest"
  printf '%s\n' "$SCAFFOLD_VERSION" > "$TARGET/$KIT_DIR/.scaffold-version"
}
