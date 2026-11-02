#!/usr/bin/env bash
# SessionStart: give the agent branch, ticket and open-change context.
. "$(dirname "$0")/lib.sh"
cd "$PROJECT_DIR" || exit 0
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
ticket="$(printf '%s' "$branch" | grep -oE '[A-Z]+-[0-9]+' | head -1)"
# listing every open change floods the context, so only the one matching the branch ticket is named
changes=""
[ -n "$ticket" ] && changes="$(ls openspec/changes 2>/dev/null | grep -i -- "$ticket" | tr '\n' ' ')"
message="Branch: ${branch:-unknown}. Integration branch: ${BASE_BRANCH:-develop}."
base_cmd="$(kit_cmd "${DIFF_BASE_CMD:-}" "scripts/resolve-base.sh")"
if [ "${BASE_BRANCH_MODE:-}" = release ] && [ -x "$base_cmd" ]; then
  release_ref="$("$base_cmd")"
  case "$release_ref" in
    *"/${RELEASE_BRANCH_PREFIX:-release/}"*)
      state="$("$base_cmd" --frozen)"
      message="$message Active release: $release_ref ($state). Cut new work from it, merge to ${BASE_BRANCH:-develop} for test, never bring ${BASE_BRANCH:-develop} into a feature branch."
      [ "$state" = frozen ] && message="$message The release is FROZEN: no new work may be added to it." ;;
    *) message="$message No release branch found locally (run: git fetch --tags origin); falling back to $release_ref." ;;
  esac
fi
[ -n "$ticket" ] && message="$message Ticket from branch: $ticket."
[ -n "$changes" ] && message="$message Matching openspec change: $changes"
sdd_status="$("$PLUGIN_ROOT/scripts/sdd.sh" status 2>/dev/null)"
message="$message Workflow: ${sdd_status:-no active task} (SDD_MODE=$("$PLUGIN_ROOT/scripts/sdd.sh" mode 2>/dev/null)); code edits, push and PR are gated by phase; start with the spec-driven-dev skill."
message="$message Verify with the spec-driven-kit verify script${VERIFY_CMD:+ ($VERIFY_CMD)}."
if [ "${MEMORY:-}" = 1 ]; then
  mem_script="$PLUGIN_ROOT/scripts/memory.sh"; [ -x "$mem_script" ] || mem_script="$PROJECT_DIR/$KIT_DIR/scripts/memory.sh"
  mem_index="$([ -x "$mem_script" ] && "$mem_script" autoload 2>/dev/null)"
  [ -n "$mem_index" ] && message="$message Project memory index (open an entry only when its line is relevant; add with memory.sh): $mem_index"
fi
# roles the project moved to another tier than their agent file's (AGENT_<ROLE>_TIER in sdkit.env): the orchestrator must pass that tier's model on the Agent call
if type sdkit_role_tier >/dev/null 2>&1; then
  _moved=""
  for _rf in "$PLUGIN_ROOT"/core/roles/*.md "$PROJECT_DIR/$KIT_DIR"/roles/*.md; do
    [ -f "$_rf" ] || continue; _r="$(basename "$_rf" .md)"; case "$_r" in README|orchestrator) continue ;; esac
    _own="$(sdkit_fm "$_rf" tier)"; _own="${_own:-standard}"; _eff="$(sdkit_role_tier "$_r" "$_own")"
    [ "$_eff" = "$_own" ] || _moved="$_moved $_r=$_eff(model $(sdkit_tier_model "$_eff" "$PROJECT_DIR"))"
  done
  [ -z "$_moved" ] || message="$message Role tiers set in sdkit.env:$_moved. Spawn those roles with the Agent tool's model parameter set to that model; the Agent hook refuses another one."
fi
jq -n --arg m "$message" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
