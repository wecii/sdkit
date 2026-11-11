#!/usr/bin/env bash
# Idempotent dispatch of parallel tasks (F15). It does not start anything: it is the ledger and the rules that decide whether a task MAY start now.
#   dispatch.sh claim <task-id> <tasks.md> [--slug S]   take the task: refused when PARALLEL=off (on by default), the task exists, every `after:` task is done,
#                                                       its `writes:` overlap no active claim, and fewer than MAX_PARALLEL claims are active.
#                                                       Claiming a task that is already active or done changes nothing and exits 3 (no duplicate work).
#   dispatch.sh done <task-id> [--slug S]               mark merged. Prints the stale-evidence reminder (a merge changes the diff, so every recorded
#                                                       verifier / reviewer / auditor PASS is stale until it is run again on the merged diff).
#   dispatch.sh release <task-id> [--slug S]            give a claim back without finishing (failed or interrupted); the task can be claimed again
#   dispatch.sh status [--slug S]                       active / done tasks, claims in flight, the limit
# Ledger: <project-dir>/work/<slug>/dispatch.jsonl (personal, gitignored), serialised with sdkit_lock. Cost: parallel runs multiply token use; this script
# measures nothing about cost, and the saving in wall time is NOT claimed (benchmark it before relying on it, tier T4 if with live models).
# Exit: 0 ok, 2 usage, 3 refused (reason printed), 4 parallelism is off.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
. "$here/env.sh" 2>/dev/null; SDKIT_ENV_QUIET=1 sdkit_env_load "$top" 2>/dev/null
command -v jq >/dev/null || { echo "dispatch.sh needs jq" >&2; exit 2; }
cmd="${1:-}"; shift 2>/dev/null || true; id=""; tasks=""; slug=""
while [ $# -gt 0 ]; do case "$1" in --slug) slug="$2"; shift ;; *) if [ -z "$id" ] && [ "$cmd" != status ]; then id="$1"; elif [ -z "$tasks" ]; then tasks="$1"; fi ;; esac; shift; done
[ -n "$slug" ] || slug="$(sdkit_active_slug "$top" 2>/dev/null)"; [ -n "$slug" ] || slug=_misc
dir="$top/$KIT_DIR/work/$slug"; L="$dir/dispatch.jsonl"; max="${MAX_PARALLEL:-3}"; case "$max" in ''|*[!0-9]*|0) max=3 ;; esac
state() { [ -f "$L" ] && jq -sc 'group_by(.task) | map({task: .[0].task, state: (last.event | if . == "claim" then "active" elif . == "done" then "done" else "free" end), writes: (map(select(.event == "claim")) | last.writes // "")})' "$L" || echo '[]'; }
case "$cmd" in
  claim)
    [ "${PARALLEL:-on}" = on ] || { echo "parallel dispatch is off (PARALLEL=off in the settings); run tasks in order" >&2; exit 4; }
    [ -n "$id" ] && [ -f "$tasks" ] || { echo "usage: dispatch.sh claim <task-id> <tasks.md>" >&2; exit 2; }
    line="$(grep -E "^[[:space:]]*- \[[ xX]\] +$id([[:space:]]|\$)" "$tasks" | head -1)"; [ -n "$line" ] || { echo "refused: task $id is not in $tasks" >&2; exit 3; }
    field() { printf '%s\n' "$line" | tr '|' '\n' | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -1 | tr -d ' '; }
    w="$(field writes)"; after="$(field after)"
    mkdir -p "$dir"; sdkit_lock "$L"; trap 'sdkit_unlock "$L"' EXIT
    st="$(state)"
    cur="$(jq -r --arg t "$id" '[.[] | select(.task == $t)][0].state // "free"' <<< "$st")"
    [ "$cur" = active ] && { echo "refused: $id is already dispatched and not finished (no duplicate work)"; exit 3; }
    [ "$cur" = done ] && { echo "refused: $id is already done and merged"; exit 3; }
    for a in $(printf '%s' "$after" | tr ',' ' '); do
      [ "$(jq -r --arg t "$a" '[.[] | select(.task == $t)][0].state // "free"' <<< "$st")" = done ] || { echo "refused: $id waits for $a (after:), which is not done"; exit 3; }; done
    nact="$(jq '[.[] | select(.state == "active")] | length' <<< "$st")"
    [ "$nact" -lt "$max" ] || { echo "refused: $nact task(s) already active, MAX_PARALLEL=$max"; exit 3; }
    # write sets: equal or one contains the other = conflict (the same rule as plan-waves.sh); a task with no writes is read-only and never conflicts
    for p in $(printf '%s' "$w" | tr ',' ' '); do
      while IFS=$'\t' read -r ot ow; do
        for q in $(printf '%s' "$ow" | tr ',' ' '); do
          pp="${p%/}"; qq="${q%/}"
          case "$pp/" in "$qq"/*) echo "refused: $id writes $p, which overlaps $q of active task $ot"; exit 3 ;; esac
          case "$qq/" in "$pp"/*) echo "refused: $id writes $p, which overlaps $q of active task $ot"; exit 3 ;; esac
        done
      done < <(jq -r '.[] | select(.state == "active") | [.task, .writes] | @tsv' <<< "$st")
    done
    printf '%s\n' "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg t "$id" --arg w "$w" --arg h "$(git -C "$top" rev-parse --short HEAD 2>/dev/null)" '{ts:$ts,event:"claim",task:$t,writes:$w,head:$h}')" >> "$L"
    echo "claimed $id (active $((nact + 1))/$max)" ;;
  done|release)
    [ -n "$id" ] || { echo "usage: dispatch.sh $cmd <task-id>" >&2; exit 2; }
    mkdir -p "$dir"; sdkit_lock "$L"; trap 'sdkit_unlock "$L"' EXIT
    cur="$(state | jq -r --arg t "$id" '[.[] | select(.task == $t)][0].state // "free"')"
    [ "$cur" = active ] || { echo "refused: $id is not active ($cur)"; exit 3; }
    ev=done; [ "$cmd" = release ] && ev=release
    printf '%s\n' "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg t "$id" --arg e "$ev" --arg h "$(git -C "$top" rev-parse --short HEAD 2>/dev/null)" '{ts:$ts,event:$e,task:$t,head:$h}')" >> "$L"
    if [ "$cmd" = done ]; then echo "done $id. The merged diff changed: every recorded verifier / reviewer / security-auditor PASS is stale until it is run again on the merged diff (sdd.sh evidence)."; else echo "released $id"; fi ;;
  status)
    st="$(state)"; echo "$st" | jq -r --argjson m "$max" '"parallel limit \($m), active \([.[] | select(.state == "active")] | length), done \([.[] | select(.state == "done")] | length)"'
    echo "$st" | jq -r '.[] | "  \(.task) \(.state)\(if .state == "active" then " writes=" + .writes else "" end)"' ;;
  *) echo "usage: dispatch.sh claim|done|release|status ..." >&2; exit 2 ;;
esac
