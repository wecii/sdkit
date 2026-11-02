#!/usr/bin/env bash
# PreToolUse on the Agent tool: register an independent role's spawn (F04), count the spawn and check the task's token budget.
# The budget part is off unless MAX_SPAWNS or TOKEN_BUDGET_TASK is set.
# SDD_MODE: strict asks before the spawn that goes over, guided only warns, off disables. Never blocks because of its own problem.
. "$(dirname "$0")/lib.sh"
# F04: an independent role (verifier, reviewer, security-auditor) is being started: register the spawn with the diff it will see, so the verdict that
# record-verdict.sh takes when the agent stops can prove it came from a real run on this diff (sdd.sh _spawn). Silent, never blocks, no model call.
_role="$(jget .tool_input.subagent_type)"
case "${_role##*:}" in verifier|verifier-deep|reviewer|security-auditor)
  [ -f "$PROJECT_DIR/$KIT_DIR/.sdd/state.json" ] && "$PLUGIN_ROOT/scripts/sdd.sh" _spawn "$_role" --source hook >/dev/null 2>&1 ;; esac
# AGENT_<ROLE>_TIER (sdkit.env): a kit role that the project moved to another tier than its agent file's must be spawned with the model of that tier.
# The orchestrator is told at session start; this is what makes it stick when it forgets. SDD_MODE: strict refuses, guided only warns, off does nothing.
_b="${_role##*:}"
if [ -n "$_b" ] && [ "${_b%-deep}" = "$_b" ] && type sdkit_role_tier >/dev/null 2>&1; then
  _rf=""; for _c in "$PROJECT_DIR/$KIT_DIR/roles/$_b.md" "$PLUGIN_ROOT/core/roles/$_b.md"; do [ -f "$_c" ] && { _rf="$_c"; break; }; done
  if [ -n "$_rf" ]; then
    _own="$(sdkit_fm "$_rf" tier)"; _own="${_own:-standard}"; _eff="$(sdkit_role_tier "$_b" "$_own")"
    if [ "$_eff" != "$_own" ]; then
      _want="$(sdkit_tier_model "$_eff" "$PROJECT_DIR")"; _got="$(jget .tool_input.model)"
      case "$_got" in *haiku*) _gt=light ;; *sonnet*) _gt=standard ;; *opus*) _gt=strong ;; *) _gt="" ;; esac
      if [ -n "$_want" ] && [ "$_gt" != "$_eff" ]; then
        _m="AGENT_$(printf '%s' "$_b" | tr 'a-z-' 'A-Z_')_TIER=$_eff in sdkit.env: spawn $_b with model \"$_want\" ($_eff tier)${_got:+, not \"$_got\"}."
        case "$("$PLUGIN_ROOT/scripts/sdd.sh" mode 2>/dev/null)" in off) ;; guided) jq -n --arg m "$_m" '{systemMessage:$m}' ;; *) decide deny "$_m" ;; esac
      fi
    fi
  fi
fi
# F06 (ROUTING=on only): ask the routing policy about a kit role before it starts: valid evidence to reuse, a BLOCK that stands, a duplicate, a model below the
# risk floor. A preview (no record, no model call); anything it cannot answer lets the spawn through, the other gates are unchanged.
if [ "${ROUTING:-off}" = on ] && [ -x "$PLUGIN_ROOT/scripts/route.sh" ] && [ -f "$PROJECT_DIR/$KIT_DIR/roles/${_role##*:}.md" -o -f "$PLUGIN_ROOT/core/roles/${_role##*:}.md" ]; then
  _rd="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/scripts/route.sh" decide --role "${_role##*:}" --host claude --json 2>/dev/null)"
  _ra="$(printf '%s' "$_rd" | jq -r '.action // empty' 2>/dev/null)"; _rr="$(printf '%s' "$_rd" | jq -r '.reason // empty' 2>/dev/null)"
  _mode="$("$PLUGIN_ROOT/scripts/sdd.sh" mode 2>/dev/null)"
  case "$_ra:$_rr" in
    reuse:*|stop:EVIDENCE_*|stop:SECURITY_BLOCK|stop:VERIFICATION_FAILED|stop:DUPLICATE_*)
      [ "$_mode" = off ] || { _m="Routing policy ($_rr): $(printf '%s' "$_rd" | jq -r '(.notes // []) | join("; ")'). Spawn only if the user wants it anyway."
        if [ "$_mode" = guided ]; then jq -n --arg m "$_m" '{systemMessage:$m}'; else decide ask "$_m"; fi; } ;;
  esac
  _rm="$(jget .tool_input.model)"; _rt="$(printf '%s' "$_rd" | jq -r '.tier // empty' 2>/dev/null)"
  if [ -n "$_rm" ] && [ -n "$_rt" ] && [ "$_mode" != off ]; then
    _mt="$("$PLUGIN_ROOT/scripts/route.sh" registry --json 2>/dev/null | jq -r --arg m "$_rm" '[.[] | select(.adapter == "claude" and .model == $m)][0].tier // empty' 2>/dev/null)"
    _rk() { case "$1" in light) echo 1 ;; standard) echo 2 ;; strong) echo 3 ;; *) echo 0 ;; esac; }
    if [ -n "$_mt" ] && [ "$(_rk "$_mt")" -lt "$(_rk "$_rt")" ]; then
      _m="Routing policy: model '$_rm' ($_mt) is below the $_rt tier this role needs at this risk. Use the $_rt model, or ask the user."
      if [ "$_mode" = guided ]; then jq -n --arg m "$_m" '{systemMessage:$m}'; else decide ask "$_m"; fi
    fi
  fi
fi
[ -n "${MAX_SPAWNS:-}${TOKEN_BUDGET_TASK:-}" ] || exit 0
mode="$("$PLUGIN_ROOT/scripts/sdd.sh" mode 2>/dev/null)"; [ "$mode" = off ] && exit 0
slug="$(sdkit_active_slug "$PROJECT_DIR")"; [ -n "$slug" ] || exit 0   # the open SDD task, else the newest work/*/state.json
problems=""; warnings=""
msg="$("$PLUGIN_ROOT/scripts/state.sh" "$slug" spawn 2>&1)" || problems="$msg"
usage_msg="$("$PLUGIN_ROOT/scripts/usage.sh" budget "$slug" 2>&1)"
case $? in
  4) problems="${problems:+$problems; }$usage_msg" ;;
  3) warnings="$usage_msg" ;;
esac
if [ -n "$problems" ]; then
  reason="Budget reached for task $slug: $problems. Confirm with the user before spawning another agent."
  if [ "$mode" = guided ]; then jq -n --arg m "$reason" '{systemMessage:$m}'; exit 0; fi
  decide ask "$reason"
fi
[ -n "$warnings" ] && jq -n --arg m "$warnings" '{systemMessage:$m}'
exit 0
