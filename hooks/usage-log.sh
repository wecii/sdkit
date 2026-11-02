#!/usr/bin/env bash
# SubagentStop / Stop: append token usage from the transcript to the ledger (scripts/usage.sh) and, with TELEMETRY=1, an agent.end event
# (scripts/telemetry.sh). Off unless USAGE_LOG=1 or TELEMETRY=1. Never blocks: any problem (no transcript, unexpected shape) is a silent exit 0.
. "$(dirname "$0")/lib.sh"
[ "${USAGE_LOG:-}" = 1 ] || [ "${TELEMETRY:-}" = 1 ] || exit 0
event="$(jget .hook_event_name)"; session="$(jget '.session_id // empty')"
# A child `claude -p` that scripts/run-role.sh started is accounted by run-role.sh itself (same tokens, id rr-*). Its own Stop hook must not log the session a
# second time: run-role sets SDKIT_CHILD_RUN for that one child process only. Subagents INSIDE the child (SubagentStop) keep their own ids and are still logged.
[ "$event" != SubagentStop ] && [ -n "${SDKIT_CHILD_RUN:-}" ] && exit 0
script="$(kit_cmd "" "scripts/usage.sh")"; [ -x "$script" ] || script="$PROJECT_DIR/$KIT_DIR/scripts/usage.sh"
[ -x "$script" ] || exit 0
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
  exit 0
fi
# the orchestrator's transcript is the whole session, cumulative over every task it served: count only from the open task's start
since=""; [ "$event" = SubagentStop ] || since="$("$script" window 2>/dev/null)"
ex="$("$script" extract "$transcript" ${since:+--since "$since"} 2>/dev/null)" || exit 0
[ -n "$ex" ] || exit 0
[ "$(jq -r '.messages' <<< "$ex" 2>/dev/null)" -gt 0 ] 2>/dev/null || exit 0
[ -n "$session" ] || session="$(jq -r '.session' <<< "$ex")"
provider="$(jq -r '.provider' <<< "$ex")"
model="$(jq -r '.model' <<< "$ex")"
set -- $(jq -r '"\(.in) \(.out) \(.cache_read) \(.cache_write)"' <<< "$ex")
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
# one ledger line per model used (a session that switches model is priced per model); same id, so a later snapshot replaces its own earlier one
while IFS="$(printf '\t')" read -r m mi mo mcr mcw; do
  [ "$m" = - ] && m=""
  "$script" log --role "$role" --host claude --model "$m" --provider "$provider" --session "$session" --in "$mi" --out "$mo" --cache-read "$mcr" --cache-write "$mcw" \
    ${id:+--id "$id"} --kind "$kind" --source "$event" >/dev/null 2>&1
done < <(jq -r '(.by_model | if length == 0 then [{model:"",in:0,out:0,cache_read:0,cache_write:0}] else . end)[] | [(.model | if . == "" then "-" else . end), .in, .out, .cache_read, .cache_write] | @tsv' <<< "$ex")
exit 0
