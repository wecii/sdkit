#!/usr/bin/env bash
# Interrupted-work detection and safe, idempotent cleanup (F18). It closes bookkeeping that a crash left open; it never dispatches, retries,
# re-runs a role, edits evidence or turns a BLOCK into anything else. After `apply`, the normal bounded rules decide what runs next
# (state.sh retry: once per task id; route.sh: attempt / retry / escalation limits and backoff).
#   recover.sh scan [slug] [--json]    list what is interrupted or stale and the single safe action for each (read-only)
#   recover.sh apply [slug]            do the safe actions: close stale contract handoffs, drop stale spawn registrations, release stale dispatch claims, expire stale budget reservations
# "Stale" = older than RECOVER_STALE_S (default 1800 s; sdkit.env). Reported, never auto-fixed: an unreadable state.json (restore it, do not guess),
# routing decisions in flight (route.sh closes them as INTERRUPTED itself on the next request), evidence that no longer matches the diff (run the role again).
# Every applied action is appended to <project-dir>/work/<slug>/recovery.jsonl. A second `apply` finds nothing and changes nothing.
# Exit: 0 nothing to do / done, 1 scan found items (scan only), 2 usage.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
. "$here/env.sh" 2>/dev/null; SDKIT_ENV_QUIET=1 sdkit_env_load "$top" 2>/dev/null
command -v jq >/dev/null || { echo "recover.sh needs jq" >&2; exit 2; }
mode="${1:-}"; shift 2>/dev/null || true; slug=""; json=0
for a in "$@"; do case "$a" in --json) json=1 ;; -*) echo "unknown option $a" >&2; exit 2 ;; *) slug="$a" ;; esac; done
case "$mode" in scan|apply) ;; *) echo "usage: recover.sh scan|apply [slug] [--json]" >&2; exit 2 ;; esac
[ -n "$slug" ] || slug="$(sdkit_active_slug "$top" 2>/dev/null)"
notask=0; [ -n "$slug" ] || { notask=1; slug=_none; }   # without an open task only the project-wide part (budget reservations) can apply
ttl="${RECOVER_STALE_S:-1800}"; case "$ttl" in ''|*[!0-9]*) ttl=1800 ;; esac
work="$top/$KIT_DIR/work/$slug"; now="$(date +%s)"; items='[]'
mt() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "$now"; }   # GNU first: on GNU stat -f means filesystem status and succeeds with text
iso_s() { date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo "$now"; }
add() {  # kind id action detail
  items="$(jq -c --arg k "$1" --arg i "$2" --arg a "$3" --arg d "$4" --arg ap "${5:-yes}" '. + [{kind:$k, id:$i, action:$a, detail:$d, applicable:($ap == "yes")}]' <<< "$items")"; }
# 1. contract handoffs issued and never answered
for f in "$work"/contracts/*.json; do [ -f "$f" ] || continue
  [ "$(jq -r .state "$f" 2>/dev/null)" = issued ] || continue; age=$((now - $(mt "$f")))
  [ "$age" -ge "$ttl" ] && add contract "$slug/$(basename "$f" .json)" "contract.sh close $slug/$(basename "$f" .json) --reason interrupted" "issued ${age}s ago, no result"; done
# 2. subagent registrations that never closed
st="$top/$KIT_DIR/.sdd/state.json"
if [ -f "$st" ]; then
  if ! jq -e . "$st" >/dev/null 2>&1; then add state "$st" "restore state.json from your own copy; nothing is guessed" "unreadable JSON" no
  else
    while IFS=$'\t' read -r run role at; do [ -n "$at" ] || continue; age=$((now - $(iso_s "$at")))
      [ "$age" -ge "$ttl" ] && add spawn "${run:-$role}" "sdd.sh _spawn-close ${run:+--run $run}${run:---role $role --source hook} --reason interrupted" "$role registered ${age}s ago, no answer recorded"
    done < <(jq -r '(.spawns // [])[] | [(.run // ""), .role, .at] | @tsv' "$st")
    ev="$(CLAUDE_PROJECT_DIR="$top" "$here/sdd.sh" evidence --json 2>/dev/null)"
    for r in $(jq -r '.[]? | select(.state != "valid" and .state != "missing") | .role' <<< "$ev" 2>/dev/null); do
      add evidence "$r" "run the $r again on the current diff (its recorded result no longer matches)" "state: $(jq -r --arg r "$r" '.[] | select(.role == $r) | .state' <<< "$ev")" no; done
  fi
fi
# 3. dispatch claims never finished
D="$work/dispatch.jsonl"
if [ -f "$D" ]; then
  while IFS=$'\t' read -r t ts; do age=$((now - $(iso_s "$ts")))
    [ "$age" -ge "$ttl" ] && add dispatch "$t" "dispatch.sh release $t --slug $slug" "claimed ${age}s ago, not done"
  done < <(jq -sr 'group_by(.task) | .[] | select(last.event == "claim") | [last.task, last.ts] | @tsv' "$D")
fi
# 4. routing decisions in flight whose process is gone (route.sh closes them itself; reported for the record)
R="$work/routing.jsonl"
if [ -f "$R" ]; then
  while IFS=$'\t' read -r id pid; do [ -n "$id" ] || continue
    [ -n "$pid" ] && [ "$pid" != null ] && kill -0 "$pid" 2>/dev/null && continue
    add routing "$id" "none: the next route.sh decide closes it as INTERRUPTED and counts it as one attempt" "no outcome and no live process" no
  done < <(jq -sr '(map(select(.type == "outcome") | .id)) as $d | .[] | select(.type == "decision" and (.action | IN("execute","retry","escalate")) and (.id as $i | $d | index($i) | not)) | [.id, (.pid // "null")] | @tsv' "$R")
fi
# 5. budget reservations whose run is gone (F14): old AND the owning process is not alive. A live process keeps its reservation however long it runs.
if [ -x "$here/route.sh" ]; then
  rj="$(CLAUDE_PROJECT_DIR="$top" "$here/route.sh" reservations list --json 2>/dev/null)" && while IFS=$'\t' read -r rs rid rage; do [ -n "$rid" ] || continue
    add reservation "$rs/$rid" "route.sh reservations expire" "reserved USD held ${rage}s with no outcome and no live process"
  done < <(jq -r '.[]? | select(.state == "stale") | [.slug, .id, .age_s] | @tsv' <<< "$rj" 2>/dev/null)
fi
n="$(jq length <<< "$items")"
[ "$notask" = 1 ] && [ "$n" = 0 ] && { echo "recover: no open task"; exit 0; }
if [ "$mode" = scan ]; then
  if [ "$json" = 1 ]; then jq . <<< "$items"; else
    [ "$n" = 0 ] && echo "recover: nothing interrupted or stale for $slug" || jq -r '.[] | "\(.kind)\t\(.id)\t\(if .applicable then "apply" else "manual" end)\t\(.detail)\n    -> \(.action)"' <<< "$items"
  fi
  [ "$n" = 0 ]; exit
fi
# apply: only the applicable ones, each through the owning script
done_n=0; mkdir -p "$work"
while IFS= read -r it; do
  [ -n "$it" ] || continue; k="$(jq -r .kind <<< "$it")"; id="$(jq -r .id <<< "$it")"; rc=0
  case "$k" in
    contract) CLAUDE_PROJECT_DIR="$top" "$here/contract.sh" close "$id" --reason interrupted --source recover >/dev/null 2>&1 || rc=$? ;;
    spawn) if [ "$(jq -r '.id | test("^[^ ]+$")' <<< "$it")" = true ] && jq -e --arg i "$id" '(.spawns // [])[] | select(.run == $i)' "$st" >/dev/null 2>&1; then CLAUDE_PROJECT_DIR="$top" "$here/sdd.sh" _spawn-close --run "$id" --reason interrupted >/dev/null 2>&1 || rc=$?
           else CLAUDE_PROJECT_DIR="$top" "$here/sdd.sh" _spawn-close --role "$id" --source hook --reason interrupted >/dev/null 2>&1 || rc=$?; fi ;;
    reservation) CLAUDE_PROJECT_DIR="$top" "$here/route.sh" reservations expire >/dev/null 2>&1 || rc=$? ;;
    dispatch) CLAUDE_PROJECT_DIR="$top" "$here/dispatch.sh" release "$id" --slug "$slug" >/dev/null 2>&1 || rc=$? ;;
  esac
  printf '%s\n' "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg k "$k" --arg i "$id" --argjson rc "$rc" '{ts:$ts,kind:$k,id:$i,rc:$rc,note:"bookkeeping closed; nothing was re-run"}')" >> "$work/recovery.jsonl"
  done_n=$((done_n + 1))
done < <(jq -c '.[] | select(.applicable)' <<< "$items")
echo "recover: closed $done_n stale item(s); $(jq '[.[] | select(.applicable | not)] | length' <<< "$items") need a manual step (recover.sh scan)"
