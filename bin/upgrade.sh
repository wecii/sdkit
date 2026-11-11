#!/usr/bin/env bash
# Bring a project that already uses the kit up to this kit version, without touching what the project owns.
# Usage: upgrade.sh [--migrate [--apply]] [target-dir]
#   --migrate  move a repo set up before 1.0 (.claude/.codex/.agentkit + project.env) into .sdkit/ (dry run unless --apply; see migrate.sh)
# It detects the project's hosts/mode/stack, adds files that are new in this kit version, adds missing lines to the
# project .gitignore, runs sync.sh for copy-mode installs, prints the manual steps for the versions you skipped, and runs doctor.
# It never overwrites project.md, sdkit.env (it only appends settings that are new; one exception, once: step 1b turns the old defaults TELEMETRY= and ROUTING=off on when crossing 1.3.2), rules, known-pitfalls, settings.json or any other file the project edited.
set -eu
. "$(dirname "$0")/lib.sh"
MIGRATE=0; MIGRATE_ARGS=(); TARGET="$PWD"
for arg in "$@"; do case "$arg" in --migrate) MIGRATE=1 ;; --apply) MIGRATE_ARGS+=(--apply) ;; -*) say "unknown option $arg"; exit 2 ;; *) TARGET="$(cd "$arg" && pwd)" ;; esac; done
[ "$MIGRATE" = 0 ] || exec "$(dirname "$0")/migrate.sh" ${MIGRATE_ARGS[@]+"${MIGRATE_ARGS[@]}"} "$TARGET"

KIT_DIR="$(resolve_kit_dir "$TARGET")"
[ -n "$KIT_DIR" ] || { say "no sdkit.env in .sdkit/ (or project.env in a legacy .agentkit/, .claude/, .codex/): this repo is not set up (run init.sh)"; exit 1; }
ENV_FILE="$(resolve_kit_env "$TARGET" "$KIT_DIR")"; export KIT_ENV="$ENV_FILE"
FROM="$(cat "$TARGET/$KIT_DIR/.scaffold-version" 2>/dev/null || echo unknown)"
say "upgrade: $TARGET (project dir $KIT_DIR): kit $FROM -> $SCAFFOLD_VERSION"

HOSTS="$(detect_hosts "$TARGET")"; MODE="$(detect_mode "$TARGET")"
STACK="$(SDKIT_ENV_QUIET=1; sdkit_env_load_file "$TARGET/$KIT_DIR/$ENV_FILE"; echo "${STACK:-$SDKIT_DEFAULT_STACK}")"
SDKIT_ENV_KEEP="$(sed -n 's/^SDKIT_ENV=//p' "$TARGET/$KIT_DIR/$ENV_FILE" | tail -1 | tr -d "\"' ")"   # the install persona survives an upgrade
say "detected: host=$HOSTS mode=$MODE stack=$STACK${SDKIT_ENV_KEEP:+ env=$SDKIT_ENV_KEEP}"

say ""; say "1. new files (existing files are kept)"
"$SCAFFOLD_ROOT/bin/init.sh" --host "$HOSTS" --mode "$MODE" --stack "$STACK" ${SDKIT_ENV_KEEP:+--env "$SDKIT_ENV_KEEP"} --dir "$KIT_DIR" "$TARGET" | grep -E '^  wrote' || say "  nothing new"

# 1.3.2 turned measurement on for new setups (TELEMETRY=1, ROUTING=on). An older project still carries the old defaults (TELEMETRY empty, ROUTING=off), which
# leaves the Value Report with gaps, so they move once, on the upgrade that crosses 1.3.2. Only those exact old defaults change; any other value is yours.
# Afterwards the project is at >= 1.3.2 and a later "off" is never touched again.
older_than_132=0
if [ "$FROM" = unknown ]; then older_than_132=1
elif [ "$FROM" != 1.3.2 ] && [ "$(printf '%s\n%s\n' "$FROM" 1.3.2 | sort -V | head -1)" = "$FROM" ]; then older_than_132=1; fi
if [ "$older_than_132" = 1 ]; then
  say ""; say "1b. measurement defaults (kit $FROM -> 1.3.2: telemetry and routing on)"
  flipped=0
  for f in "$TARGET/$KIT_DIR/sdkit.local.env" "$TARGET/$KIT_DIR/$ENV_FILE"; do
    [ -f "$f" ] || continue
    if grep -qE '^TELEMETRY=(""|'"''"')?$' "$f"; then sed -i.bak -E 's/^TELEMETRY=(""|'"''"')?$/TELEMETRY=1/' "$f" && rm -f "$f.bak"; say "  set    $(basename "$f"): TELEMETRY=1 (was empty)"; flipped=1; fi
    if grep -qE '^ROUTING=("?off"?)$' "$f"; then sed -i.bak -E 's/^ROUTING="?off"?$/ROUTING=on/' "$f" && rm -f "$f.bak"; say "  set    $(basename "$f"): ROUTING=on (was off)"; flipped=1; fi
  done
  [ "$flipped" = 1 ] && say "  to keep either off, set it back now: the kit leaves a project at 1.3.2 or later alone" || say "  already set"
fi

say ""; say "2. .gitignore lines"
gi="$TARGET/$KIT_DIR/.gitignore"
if [ -f "$gi" ]; then
  added=0
  while IFS= read -r line; do
    case "$line" in ''|'#'*|'!'*) continue ;; esac
    grep -qxF "$line" "$gi" || { printf '%s\n' "$line" >> "$gi"; say "  added  $line"; added=1; }
  done < "$SCAFFOLD_ROOT/$([ "$KIT_DIR" = .sdkit ] && echo templates/sdkit.gitignore || echo templates/claude.gitignore)"
  [ "$added" = 1 ] || say "  up to date"
fi

say ""; say "3. managed copies (sync.sh)"
"$SCAFFOLD_ROOT/bin/sync.sh" "$TARGET" | tail -n +2

say ""; say "4. what to do by hand"
notes="$SCAFFOLD_ROOT/docs/upgrading.md"
if [ -f "$notes" ]; then
  say "  see $notes (sections for versions after $FROM)"
fi
case "$MODE" in plugin) say "  plugin mode: also refresh the plugin in Claude Code (/plugin, update spec-driven-kit) so the new skills, roles and hooks load." ;; esac

say ""; "$SCAFFOLD_ROOT/bin/doctor.sh" "$TARGET" || true
printf '%s\n' "$SCAFFOLD_VERSION" > "$TARGET/$KIT_DIR/.scaffold-version"
