#!/usr/bin/env bash
# SessionStart: tell the agent (and so the developer) which tools the kit needs but cannot find, with the fix.
. "$(dirname "$0")/lib.sh"
missing=""
# a project-local install (node_modules/.bin, e.g. prettier as a devDependency) counts as installed
need() { command -v "$1" >/dev/null 2>&1 || [ -x "$PROJECT_DIR/node_modules/.bin/$1" ] || missing="$missing\n- $1: $2"; }
need jq "brew install jq (the kit's hooks parse JSON with it)"
need git "install git"
tools="$PROJECT_DIR/$KIT_DIR/scripts/tools.sh"
[ -x "$tools" ] || tools="$PLUGIN_ROOT/stacks/$STACK/scripts/tools.sh"
# tools.sh lines: required|<command>|<hint> or optional|<command>|<hint>
[ -x "$tools" ] && while IFS='|' read -r kind cmd hint; do
  [ -n "$cmd" ] && need "$cmd" "$hint"
done < <("$tools" "$PROJECT_DIR")
need openspec "npm install -g @fission-ai/openspec"
[ -z "$missing" ] && exit 0
jq -n --arg m "$(printf 'spec-driven-kit: missing tools, tell the user once:%b' "$missing")" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
