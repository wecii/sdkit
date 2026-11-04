#!/usr/bin/env bash
# SubagentStop / Stop: append token usage from the transcript to the ledger (scripts/usage.sh) and, with TELEMETRY=1, an agent.end event
# (scripts/telemetry.sh). Off unless USAGE_LOG=1 or TELEMETRY=1. Never blocks: any problem (no transcript, unexpected shape) is a silent exit 0.
# With USAGE_LINE=1, SubagentStop also prints one line to the developer: "[sdkit] <role> done — in: 12.4k (cache read 8.8k, write 0.9k), out: 1.8k, cache hit: 71%"
# (or "token usage not available" when the transcript gives no numbers: never a wrong number). Independent of USAGE_LOG.
# USAGE_LINE=1 also switches the ledger on (usage.sh log), because the step line that sdd.sh prints at each phase move reads it (usage.sh live show).
. "$(dirname "$0")/lib.sh"
[ "${USAGE_LOG:-}" = 1 ] || [ "${TELEMETRY:-}" = 1 ] || [ "${USAGE_LINE:-}" = 1 ] || exit 0
event="$(jget .hook_event_name)"; session="$(jget '.session_id // empty')"
# usage_line <role> [<in> <out> <cache_read> <cache_write>]: the one-line summary as a systemMessage; without numbers it says so
usage_line() {
  [ "${USAGE_LINE:-}" = 1 ] && [ "$event" = SubagentStop ] || return 0
  local msg
  if [ $# -lt 5 ]; then msg="[sdkit] $1 done — token usage not available (the host gave no data)"
  else
    msg="$(awk -v r="$1" -v i="$2" -v o="$3" -v cr="$4" -v cw="$5" 'function k(n) { return n >= 1000 ? sprintf("%.1fk", n / 1000) : n }
      BEGIN { t = i + cr + cw; h = t > 0 ? sprintf("%d%%", cr * 100 / t) : "n/a"
        printf "[sdkit] %s done — in: %s (cache read %s, write %s), out: %s, cache hit: %s", r, k(i + cr + cw), k(cr), k(cw), k(o), h }')"
  fi
  jq -n --arg m "$msg" '{systemMessage:$m}'
}
# A child `claude -p` that scripts/run-role.sh started is accounted by run-role.sh itself (same tokens, id rr-*). Its own Stop hook must not log the session a
# second time: run-role sets SDKIT_CHILD_RUN for that one child process only. Subagents INSIDE the child (SubagentStop) keep their own ids and are still logged.
[ "$event" != SubagentStop ] && [ -n "${SDKIT_CHILD_RUN:-}" ] && exit 0
script="$(kit_cmd "" "scripts/usage.sh")"; [ -x "$script" ] || script="$PROJECT_DIR/$KIT_DIR/scripts/usage.sh"
[ -x "$script" ] || exit 0
# ledger_put <role> <id> <kind> <extract json>: one ledger line per model used (a session that switches model is priced per model); same id, so a
# later snapshot replaces its own earlier one
ledger_put() {
  local r="$1" i="$2" k="$3" x="$4" m mi mo mcr mcw
  while IFS="$(printf '\t')" read -r m mi mo mcr mcw; do
    [ "$m" = - ] && m=""
    "$script" log --role "$r" --host claude --model "$m" --provider "$provider" --session "$session" --in "$mi" --out "$mo" --cache-read "$mcr" --cache-write "$mcw" \
      ${i:+--id "$i"} --kind "$k" --source "$event" >/dev/null 2>&1
  done < <(jq -r '(.by_model | if length == 0 then [{model:"",in:0,out:0,cache_read:0,cache_write:0}] else . end)[] | [(.model | if . == "" then "-" else . end), .in, .out, .cache_read, .cache_write] | @tsv' <<< "$x")
}
if [ "$event" = SubagentStop ]; then
  # the subagent's OWN transcript only. The parent's transcript (`.transcript_path`) is never a fallback: it would book the whole session under this
  # agent. Where the payload has no agent path, Claude Code keeps it at <session transcript without .jsonl>/subagents/agent-<id>.jsonl.
  transcript="$(jget '.agent_transcript_path // empty')"; role="$(jget '.agent_type // .subagent_type')"; role="${role##*:}"
  id="$(jget '.agent_id // empty')"; kind=final
  if [ ! -f "$transcript" ] && [ -n "$id" ]; then
    parent="$(jget '.transcript_path // empty')"; [ -n "$parent" ] && transcript="${parent%.jsonl}/subagents/agent-$id.jsonl"
  fi
else
  transcript="$(jget .transcript_path)"; role=orchestrator; id="session-$session"; kind=snapshot   # every turn end re-reads the whole session: a snapshot
fi
# the payload may carry no agent type; Claude Code keeps it in the .meta.json next to the agent's transcript
if [ -z "$role" ] && [ "$event" = SubagentStop ]; then
  meta="${transcript%.jsonl}.meta.json"; [ -f "$meta" ] && { role="$(jq -r '.agentType // empty' "$meta" 2>/dev/null)"; role="${role##*:}"; }
fi
[ -n "$role" ] || role=subagent
if [ ! -f "$transcript" ]; then
  # an execution happened but its usage cannot be read: leave a mark (unmeasured, never zero) so it shows up as a gap instead of vanishing
  [ "$event" = SubagentStop ] && [ -n "$id" ] && "$script" log --role "$role" --host claude --id "$id" --session "$session" --kind final --tq unavailable --source "$event" >/dev/null 2>&1
  usage_line "$role"; exit 0
fi
# the orchestrator's transcript is the whole session, cumulative over every task it served: count only from the open task's start
since=""; [ "$event" = SubagentStop ] || since="$("$script" window 2>/dev/null)"
ex="$("$script" extract "$transcript" ${since:+--since "$since"} 2>/dev/null)" || { usage_line "$role"; exit 0; }
[ -n "$ex" ] || { usage_line "$role"; exit 0; }
[ "$(jq -r '.messages' <<< "$ex" 2>/dev/null)" -gt 0 ] 2>/dev/null || { usage_line "$role"; exit 0; }
[ -n "$session" ] || session="$(jq -r '.session' <<< "$ex")"
provider="$(jq -r '.provider' <<< "$ex")"
model="$(jq -r '.model' <<< "$ex")"
set -- $(jq -r '"\(.in) \(.out) \(.cache_read) \(.cache_write)"' <<< "$ex")
usage_line "$role" "$1" "$2" "$3" "$4"
if [ "${TELEMETRY:-}" = 1 ]; then
  # tool calls are counted from the transcript (actual); the duration is the span between its first and last timestamp (estimated: the
  # agent may have waited before its first line). A Stop snapshot and a SubagentStop for the same span replace each other in the summary.
  extra="$(jq -rs '{tc: ([.[] | select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .id] | unique | length),
      ts: ([.[] | .timestamp? // empty | select(type=="string") | sub("\\.[0-9]+";"") | try fromdateiso8601 catch empty] | if length > 1 then (max - min) * 1000 else null end)}
    | "\(.tc) \(.ts // "")"' "$transcript" 2>/dev/null)"
  i="$1"; o="$2"; cr="$3"; cw="$4"; set -- $extra
  tele="$(kit_cmd "" scripts/telemetry.sh)"
  [ -x "$tele" ] && "$tele" emit agent.end --role "$role" --host claude --model "${model:-}" --in "$i" --out "$o" --cache-read "$cr" --cache-write "$cw" \
    --tool-calls "${1:-}" --dur-ms "${2:-}" --q tokens=actual --q tool_calls=actual --q duration=estimated ${id:+--span "$id"} --source "$event" >/dev/null 2>&1
fi
ledger_put "$role" "$id" "$kind" "$ex"
# a subagent just ended: refresh the orchestrator's own row from the parent transcript too, so a phase move right after it shows current numbers
# (the step line reads this ledger; without it the orchestrator would be one turn old)
if [ "${USAGE_LINE:-}" = 1 ] && [ "$event" = SubagentStop ]; then
  ptr="$(jget '.transcript_path // empty')"
  if [ -n "$ptr" ] && [ -f "$ptr" ] && px="$("$script" extract "$ptr" --since "$("$script" window 2>/dev/null)" 2>/dev/null)" && [ -n "$px" ]; then
    ledger_put orchestrator "session-$session" snapshot "$px"
  fi
fi
exit 0
