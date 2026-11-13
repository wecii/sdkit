#!/usr/bin/env bash
# generate-tasks deterministic core (F07): trace, cycles, stable ids, render, report. No model, no network. Contract: docs/design-role-aware.md.
# tasks.json: {"specId","specVersion","specSha","parent","tasks":[{"ref","title","summary"?,"slug"?,"change"?,"risk","acceptanceCriteria":[],"dependsOn":[ref],"scope":[]}]}
#   tasks.sh acs <tasks.json> [--revision]       AC ids found in the spec at specSha (AC-<feature>-<n> tokens), one per line. --revision: only the active ACs the changes of this
#                                                revision (applied at the spec's version at specSha) added or modified: the ACs that need NEW tasks
#   tasks.sh changes <tasks.json>                slugs of the changes applied in the revision at specSha, one per line (empty for a spec without changes)
#   tasks.sh trace <tasks.json> <ac-list|->      ac-list: file (ids by line or comma) or -; exit 1 on an unmapped AC, an unknown AC or an orphan task
#   tasks.sh cycles <tasks.json>                 exit 1 and print the cycle (ref -> ref) on a dependency cycle or unknown dependsOn; no approval needed
#   tasks.sh ids <tasks.json>                    tasks.json with key + externalId (<specId>:<taskKey>); key = hash of ACs+scope(+slug), never of order or title
#   tasks.sh order <tasks.json>                  refs in creation order (dependencies first)
#   tasks.sh render <tasks.json> <ref> [--keys MAP.json] [--json]
#                                                Jira description with the fenced sdkit-task block (or the upsert JSON); validated by jira.sh validate-task.
#                                                MAP.json: {"<externalId>":"PROJ-12"}; an unmapped dependency stays its externalId (plan-time check only)
#   tasks.sh report <tasks.json> <results.jsonl> [--out FILE]   AC->tasks, task->deps, created/updated/unchanged; exit 1 if any task has no result
# Every verb except cycles first requires `spec.sh approved-sha <specId> --sha <specSha>` to pass; spec files are read from git at that SHA, never the working tree.
# Env: TASKS_REPO (git repo holding the specs, default the project), TASKS_SPEC_PATH (default specs/<id>), SPEC_SH, JIRA_SH (overrides for tests).
# Exit: 0 ok, 1 check failed, 2 usage, 3 not approved / spec unreadable, 4 task contract invalid.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SPEC_SH="${SPEC_SH:-$here/spec.sh}"; JIRA_SH="${JIRA_SH:-$here/jira.sh}"; REPO="${TASKS_REPO:-$top}"
command -v jq >/dev/null || { echo "tasks.sh needs jq" >&2; exit 2; }
die() { echo "tasks: $1" >&2; exit "${2:-1}"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }

verb="${1:-}"; shift 2>/dev/null || true
f="${1:-}"; [ -n "$verb" ] && [ -f "$f" ] || die "usage: tasks.sh acs|trace|cycles|ids|order|render|report <tasks.json> ..." 2
jq -e '(.tasks | type == "array") and ([.tasks[] | (.ref | type == "string" and length > 0)] | all)' "$f" >/dev/null 2>&1 || die "tasks.json: needs a tasks array, each with a ref" 2
specId="$(jq -r '.specId // empty' "$f")"; sha="$(jq -r '.specSha // empty' "$f")"; spath="${TASKS_SPEC_PATH:-specs}/$specId"

gate() {  # approval first, then the spec version at that exact commit must match
  [ -n "$specId" ] && printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die "tasks.json needs specId and a 40-hex specSha" 3
  [ -x "$SPEC_SH" ] || die "spec.sh not found: cannot verify approval, refusing" 3
  "$SPEC_SH" approved-sha "$specId" --sha "$sha" >/dev/null 2>&1 || die "specSha $sha of $specId is not an approved SHA on origin/main: refusing" 3
  local mv; mv="$(git -C "$REPO" show "$sha:$spath/spec.meta.json" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
  [ -z "$mv" ] || [ "$mv" = "$(jq -r '.specVersion' "$f")" ] || die "specVersion in tasks.json differs from $mv at $sha" 3
}
# ids: tasks.json with key/externalId; the key hashes the sorted ACs, sorted scope and optional slug (identity), not the title or position
keyed() {
  local lines out="" r h
  # the change slug is part of the identity: a modified AC always gets a NEW task, never an update of a possibly done one (an empty change hashes as before)
  lines="$(jq -r '.tasks[] | [.ref, ((.slug // "") | tostring), ([.acceptanceCriteria[]?] | sort | join(",")), ([.scope[]?] | sort | join(",")), ((.change // "") | tostring)] | @tsv' "$f")"
  while IFS=$'\t' read -r r s a c ch; do
    h="$(printf '%s|%s|%s%s' "$a" "$c" "$s" "${ch:+|$ch}" | sha256 | cut -c1-10)"; out="$out$r $h"$'\n'
  done <<< "$lines"
  local dup; dup="$(printf '%s' "$out" | awk '{print $2}' | sort | uniq -d | head -1)"
  [ -z "$dup" ] || { echo "tasks: two tasks share the same ACs and scope (add a distinct slug): $(printf '%s' "$out" | awk -v d="$dup" '$2==d{printf "%s ",$1}')" >&2; return 1; }
  jq --arg s "$specId" --argjson m "$(printf '%s' "$out" | jq -Rn '[inputs | select(length>0) | split(" ") | {(.[0]): .[1]}] | add // {}')" \
    '.tasks |= map(. + {key: ("t" + $m[.ref]), externalId: ($s + ":t" + $m[.ref])})' "$f"; }
# rev_changes: slugs of the changes applied in the revision of the spec at specSha (their applied.version = the spec version there)
rev_changes() {
  local ver c; ver="$(git -C "$REPO" show "$sha:$spath/spec.meta.json" 2>/dev/null | jq -r '.version // empty')"
  git -C "$REPO" ls-tree -r --name-only "$sha" -- "$spath/changes" 2>/dev/null | grep '/change\.json$' | while read -r c; do
    git -C "$REPO" show "$sha:$c" | jq -r --arg v "$ver" 'select(.status == "applied" and .applied.version == $v) | .slug'
  done
}
edges() { jq -r '.tasks[] | .ref as $r | (.dependsOn // [])[] | "\($r) \(.)"' "$f"; }

case "$verb" in
  cycles)
    unk="$(jq -r '[.tasks[].ref] as $all | .tasks[] | .ref as $r | (.dependsOn // [])[] | select(. as $d | $all | index($d) | not) | "\($r) -> \(.)"' "$f")"
    [ -z "$unk" ] || die "unknown dependency: $(printf '%s' "$unk" | head -1)"
    out="$( { jq -r '.tasks[].ref | "N " + .' "$f"; edges | sed 's/^/E /'; } | awk '
      $1=="N"{nodes[++n]=$2} $1=="E"{adj[$2]=adj[$2] " " $3}
      function dfs(u,   k,m,v,i,s){ st[u]=1; stack[++sp]=u
        m=split(adj[u],A," "); for(k=1;k<=m;k++){v=A[k]
          if(st[v]==1){ s=""; for(i=1;i<=sp;i++) if(stack[i]==v) break; for(;i<=sp;i++) s=s stack[i] " -> "; print s v; exit 1 }
          if(!st[v]) dfs(v) }
        st[u]=2; sp-- }
      END{ for(i=1;i<=n;i++) if(!st[nodes[i]]) dfs(nodes[i]) }')" || { echo "tasks: dependency cycle: $out" >&2; exit 1; }
    echo "no cycles" ;;
  changes) gate; rev_changes ;;
  acs) gate
    if [ "${2:-}" = --revision ]; then
      sl="$(rev_changes)"; [ -n "$sl" ] || exit 0
      spec="$(git -C "$REPO" archive "$sha" "$spath" 2>/dev/null | tar -xO --exclude='*/changes/*' 2>/dev/null)"
      for c in $sl; do git -C "$REPO" show "$sha:$spath/changes/$c/change.json" | jq -r '.touches[]?'; done | sort -u | while read -r ac; do
        printf '%s\n' "$spec" | grep -Eq "^####[[:space:]]+Scenario:[[:space:]]*$ac([[:space:]]+-|[[:space:]]*$)" && echo "$ac"
      done; exit 0
    fi
    git -C "$REPO" archive "$sha" "$spath" 2>/dev/null | tar -xO 2>/dev/null | grep -Eo '\bAC-[A-Za-z0-9_]+(-[A-Za-z0-9_]+)*(\.[A-Za-z0-9_]+)*' | sort -u || true ;;
  trace) gate; [ -n "${2:-}" ] || die "usage: trace <tasks.json> <ac-list|->" 2
    if [ "$2" = - ]; then al="$(cat)"; else [ -f "$2" ] || die "no such file: $2" 2; al="$(cat "$2")"; fi
    al="$(printf '%s' "$al" | tr ', \t' '\n\n\n' | grep -v '^$' | sort -u)"; [ -n "$al" ] || die "empty AC list" 1
    mapped="$(jq -r '.tasks[].acceptanceCriteria[]?' "$f" | sort -u)"; rc=0
    miss="$(comm -23 <(printf '%s\n' "$al") <(printf '%s\n' "$mapped"))"; [ -z "$miss" ] || { echo "tasks: AC without a task: $(echo $miss)" >&2; rc=1; }
    unk="$(comm -13 <(printf '%s\n' "$al") <(printf '%s\n' "$mapped"))"; [ -z "$unk" ] || { echo "tasks: task references AC not in the spec: $(echo $unk)" >&2; rc=1; }
    orph="$(jq -r '.tasks[] | select((.acceptanceCriteria // []) | length == 0) | .ref' "$f")"; [ -z "$orph" ] || { echo "tasks: orphan task (no AC): $(echo $orph)" >&2; rc=1; }
    [ "$rc" = 0 ] && echo "trace ok: $(printf '%s\n' "$al" | wc -l | tr -d ' ') ACs, $(jq '.tasks|length' "$f") tasks"; exit $rc ;;
  ids) gate; keyed ;;
  order) gate; "$0" cycles "$f" >/dev/null || exit 1
    jq -r '.tasks[] | .ref as $r | "\($r) \($r)", ((.dependsOn // [])[] | "\(.) \($r)")' "$f" | tsort ;;
  render) gate; ref="${2:-}"; [ -n "$ref" ] || die "usage: render <tasks.json> <ref> [--keys MAP] [--json]" 2; shift 2
    map='{}'; asjson=0
    while [ $# -gt 0 ]; do case "$1" in --keys) [ -f "${2:-}" ] || die "--keys needs a file" 2; map="$(cat "$2")"; shift 2 ;; --json) asjson=1; shift ;; *) die "unknown option $1" 2 ;; esac; done
    k="$(keyed)" || exit 1
    t="$(printf '%s' "$k" | jq -c --arg r "$ref" --argjson m "$map" --arg id "$specId" --arg sha "$sha" --arg par "$(jq -r '.parent // empty' "$f")" --argjson v "$(jq '.specVersion' "$f")" '
      . as $all | (.tasks[] | select(.ref == $r)) as $t | if $t == null then empty else
      {externalId: $t.externalId, specId: $id, specVersion: $v, specSha: $sha, acceptanceCriteria: $t.acceptanceCriteria, risk: $t.risk,
       dependencies: [($t.dependsOn // [])[] as $d | ($all.tasks[] | select(.ref == $d) | .externalId) as $e | ($m[$e] // $e)],
       scope: $t.scope, parent: $par, summary: ($t.title // $t.externalId), description: ($t.summary // "")} end')" || exit 4
    [ -n "$t" ] || die "no task with ref $ref" 2
    c="$(printf '%s' "$t" | jq -c 'del(.summary, .description)')"
    desc="$(printf '%s' "$t" | jq -r '.description')"
    text="$(printf '%s\n\n```sdkit-task\n%s\n```\n' "$desc" "$(printf '%s' "$c" | jq .)")"
    printf '%s' "$text" | "$JIRA_SH" validate-task - >/dev/null || die "rendered task $ref fails jira.sh validate-task" 4
    if [ "$asjson" = 1 ]; then printf '%s\n' "$t"; else printf '%s' "$text"; fi ;;
  report) gate; res="${2:-}"; [ -f "$res" ] || die "usage: report <tasks.json> <results.jsonl> [--out FILE]" 2; out=""; [ "${3:-}" = --out ] && out="${4:-}"
    k="$(keyed)" || exit 1
    md="$(jq -rn --argjson k "$k" --slurpfile r "$res" '
      ($r | map(select(type=="object" and .externalId)) | map({(.externalId): .}) | add // {}) as $res |
      ($k.tasks | map(select($res[.externalId] == null))) as $miss |
      "# Task creation report: \($k.specId) v\($k.specVersion) @ \($k.specSha)\n\nParent: \($k.parent)\n",
      "## Results\n\n| Task | externalId | Jira | Result |\n|---|---|---|---|",
      ($k.tasks[] | "| \(.ref) | \(.externalId) | \($res[.externalId].key // "-") | \($res[.externalId].action // "NOT CREATED") |"),
      "\n## Acceptance criteria to tasks\n",
      ([$k.tasks[] | .ref as $r | .acceptanceCriteria[]? | {ac: ., r: $r}] | group_by(.ac)[] | "- \(.[0].ac): \(map(.r) | join(", "))"),
      "\n## Task dependencies\n",
      ($k.tasks[] | "- \(.ref) <- \((.dependsOn // []) | if length == 0 then "none" else join(", ") end)"),
      (if ($miss | length) > 0 then "\n## FAILED\n\nNo result for: \($miss | map(.ref) | join(", ")). This run is NOT a success.\n" else "" end)')"
    if [ -n "$out" ]; then printf '%s\n' "$md" > "$out"; else printf '%s\n' "$md"; fi
    [ -z "$(printf '%s' "$md" | grep -m1 'NOT CREATED')" ] ;;
  *) die "unknown verb $verb" 2 ;;
esac
