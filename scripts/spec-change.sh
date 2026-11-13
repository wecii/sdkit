#!/usr/bin/env bash
# Deterministic facts about a spec change (spec merge, docs/design-spec-merge.md). Pure bash + jq + awk: no model, no network, no git. spec.sh and the
# merge-specs skill call it; it never writes a file. A "root" is a spec directory (a base specs/<id>/ or a change specs/<id>/changes/<slug>/): its
# requirements live in <root>/specs/<capability>/spec.md. Anything under <root>/changes/ is not part of a base and is never read.
#   spec-change.sh parse <root>                          JSON {acs:[{id,capability,section,requirement,withdrawn,hash}], requirements:[{capability,section,title,acs}], noId:[...]}
#   spec-change.sh compute <change-dir> --base <root>    the delta's facts against the base: JSON {added,modified,removed,unchanged,touches,expects,problems}. rc 1 when problems
#   spec-change.sh moved <change-dir> --base <root> [--expects FILE]
#                                                        ids whose text in the base is no longer the one the change expects (expects: change.json, else FILE); rc 1 when any
#   spec-change.sh overlap <change-dir>... --base <root> JSON {collisions:[{id,same,changes}], shared:[{id,changes}]}, changes ordered by createdAt (else argument order)
#   spec-change.sh plan <spec-root> [<slug>...]           JSON for merge-specs stage 1: per open change (default all in <root>/changes/) its facts, moved ACs, cited ACs/ADRs, plus overlap
#   spec-change.sh coverage <spec-root> [--ids-before FILE]
#                                                        after an apply: nothing of any applied change is lost (see below); problems on stdout, rc 1
#   spec-change.sh validate <change-dir> [--base <root>]  change.json schema; with --base also the delta against the base and touches == the delta's. rc 1 + reasons
# AC text and hash. An AC is the block from its `#### Scenario: AC-<capability>-<n> ...` line up to the next heading. Normalised text = the lines of the block,
# CR removed, every run of spaces/tabs collapsed to one space, each line trimmed, empty lines dropped, joined by "\n"; hash = sha256 of that text plus a final "\n".
# The scenario title line is part of the text; a `(withdrawn)` marker after the id marks a withdrawn AC and changes the hash.
# Delta sections (`## ADDED|MODIFIED|REMOVED Requirements`): ADDED ids must be new (a withdrawn id is never reused). A MODIFIED requirement replaces the base one that
# shares an AC id with it; an AC it carries that the base lacks is added, an active one of that base requirement it omits is a problem (withdraw it instead; an omitted withdrawn id is kept by apply), a withdrawn marker
# on an active AC is a removal. REMOVED lists scenarios, or a bare requirement (matched by capability + title) meaning all its active ACs. expects = sha256 of each
# modified or removed AC in the base; touches = added + modified + removed.
# Coverage (applied changes under <root>/changes/): each AC an applied change added or modified is in the base with the same hash and each removed one is withdrawn, unless
# a recorded resolution names it; no AC id twice in the base; every id in FILE (the ids before the apply) still exists; every AC id cited in a base spec.md or tasks.md exists;
# each applied change's own tasks.md mentions every AC it added or modified.
# Exit: 0 ok, 1 problems / moved, 2 usage.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/env.sh" || { echo "spec-change: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "spec-change: jq is required" >&2; exit 2; }
die()   { echo "spec-change: $*" >&2; exit "${RC:-1}"; }
usage() { echo "usage: spec-change.sh parse <root> | compute <change-dir> --base <root> | moved <change-dir> --base <root> [--expects FILE] | overlap <change-dir>... --base <root> | validate <change-dir> [--base <root>]" >&2; exit 2; }

# awk: one row (fields split by \034: a tab would swallow empty fields in read) per requirement / AC: kind, capability, section, requirement, id, withdrawn(0|1), text (lines joined by \037). POSIX awk only (macOS awk).
AWK_PARSE='
function norm(s) { gsub(/\r/, "", s); gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
function endac() { if (inac) { print "AC", cap, sec, req, id, wd, blk }; inac = 0; blk = "" }
BEGIN { OFS = "\034"; sec = ""; req = ""; inac = 0; blk = "" }
{
  line = $0; lvl = 0
  while (substr(line, lvl + 1, 1) == "#") lvl++
  if (lvl > 0 && lvl <= 6 && (substr(line, lvl + 1, 1) == " " || substr(line, lvl + 1, 1) == "\t")) {
    if (lvl <= 4) endac()
    t = norm(substr(line, lvl + 1))
    if (lvl == 2) { sec = ""; req = ""; if (t ~ /^(ADDED|MODIFIED|REMOVED|RENAMED)[ ]+Requirements/) { sec = t; sub(/ .*/, "", sec) } }
    else if (lvl == 3 && t ~ /^Requirement:/) { req = norm(substr(t, 13)); print "REQ", cap, sec, req, "", 0, "" }
    else if (lvl == 4 && t ~ /^Scenario:/) {
      rest = norm(substr(t, 10)); id = ""; wd = 0
      if (match(rest, /^AC-[A-Za-z0-9._-]*-[0-9]+/)) {
        id = substr(rest, 1, RLENGTH); after = substr(rest, RLENGTH + 1)
        if (after ~ /^ *\([Ww]ithdrawn\)/) wd = 1
        inac = 1; blk = norm(line)
      } else { print "NOID", cap, sec, req, "", 0, rest }
    }
    next
  }
  if (inac) { n = norm(line); if (n != "") blk = blk "\037" n }
}
END { endac() }'

# parse_root <root>: the JSON described above on stdout; return 1 when the root has no spec.md
parse_root() {
  local root="$1" f cap rows="" k row kind c s r id wd txt h n=0
  [ -d "$root" ] || { echo "spec-change: no directory $root" >&2; return 1; }
  for f in "$root"/specs/*/spec.md; do
    [ -f "$f" ] || continue
    n=$((n + 1)); cap="$(basename "$(dirname "$f")")"
    while IFS=$'\034' read -r kind c s r id wd txt; do
      [ -n "$kind" ] || continue
      h=""
      if [ "$kind" = AC ]; then h="$(printf '%s\n' "$txt" | tr '\037' '\n' | sdkit_sha256)"; fi
      rows="$rows$kind"$'\t'"$c"$'\t'"$s"$'\t'"$r"$'\t'"$id"$'\t'"$wd"$'\t'"$h"$'\n'
    done <<EOF
$(awk -v cap="$cap" "$AWK_PARSE" "$f")
EOF
  done
  [ "$n" -gt 0 ] || { echo "spec-change: no specs/<capability>/spec.md under $root" >&2; return 1; }
  printf '%s' "$rows" | jq -R -s '
    (split("\n") | map(select(length > 0) | split("\t"))) as $r
    | { acs:   [$r[] | select(.[0] == "AC")   | {id: .[4], capability: .[1], section: .[2], requirement: .[3], withdrawn: (.[5] == "1"), hash: .[6]}],
        noId:  [$r[] | select(.[0] == "NOID") | {capability: .[1], section: .[2], requirement: .[3]}],
        requirements: (reduce ($r[] | select(.[0] == "REQ" or .[0] == "AC")) as $x ([];
            if $x[0] == "REQ" then . + [{capability: $x[1], section: $x[2], title: $x[3], acs: []}]
            elif length > 0 and .[-1].capability == $x[1] and .[-1].title == $x[3] then .[-1].acs += [$x[4]]
            else . + [{capability: $x[1], section: $x[2], title: $x[3], acs: [$x[4]]}] end)) }'
}

# compute_json <change-dir> <base-root>: the facts of the delta against the base (always prints JSON; rc 1 when it has problems)
compute_json() {
  local d b
  d="$(parse_root "$1")" || return 2; b="$(parse_root "$2")" || return 2
  jq -n --argjson d "$d" --argjson b "$b" '
    ($b.acs | map({(.id): .}) | add // {}) as $bm
    | ($d.acs | group_by(.id) | map(select(length > 1) | .[0].id)) as $dups
    | ($d.acs | map(select(.section == "ADDED")))    as $added_sec
    | ($d.requirements | map(select(.section == "MODIFIED"))) as $modreq
    | ($d.acs | map({(.id): .}) | add // {}) as $dm
    # ADDED section
    | [ $added_sec[] | select($bm[.id] == null) | .id ] as $added1
    | [ $added_sec[] | select($bm[.id] != null) | if $bm[.id].withdrawn then "ADDED \(.id) reuses a withdrawn id (withdrawn ids are never reused)" else "ADDED \(.id) exists already in the base (use MODIFIED)" end ] as $p_added
    # MODIFIED section, requirement by requirement
    | [ $modreq[] | . as $r | ($r.acs | map(select($bm[.] != null))) as $inb
        | if ($inb | length) == 0 then {p: "MODIFIED requirement \"\($r.title)\" (\($r.capability)) matches no AC of the base"}
          else ($b.requirements | map(select(.acs | any(. as $a | $inb | index($a)))) | map(.acs) | add | unique | map(select($bm[.].withdrawn | not))) as $baseacs
            | { added: [ $r.acs[] | select($bm[.] == null) ],
                modified: [ $inb[] | select($dm[.].withdrawn | not) | select($dm[.].hash != $bm[.].hash) ],
                removed: [ $inb[] | select($dm[.].withdrawn and ($bm[.].withdrawn | not)) ],
                unchanged: [ $inb[] | select(($dm[.].withdrawn | not) and $dm[.].hash == $bm[.].hash) ],
                p: [ $baseacs[] | select(. as $a | ($r.acs | index($a)) == null) | "MODIFIED requirement \"\($r.title)\" drops \(.) (keep it, or withdraw it with a `(withdrawn)` marker)" ] } end ] as $mods
    # REMOVED section: scenarios, else the whole requirement by capability + title
    | [ $d.acs[] | select(.section == "REMOVED") ] as $rm_acs
    | [ $d.requirements[] | select(.section == "REMOVED" and (.acs | length) == 0) ] as $rm_reqs
    | ([ $rm_acs[] | select($bm[.id] != null and ($bm[.id].withdrawn | not)) | .id ]
       + [ $rm_reqs[] | . as $r | $b.requirements[] | select(.capability == $r.capability and .title == $r.title) | .acs[] | select($bm[.].withdrawn | not) ]) as $removed1
    | ([ $rm_acs[] | select($bm[.id] == null) | "REMOVED \(.id) is not in the base" ]
       + [ $rm_acs[] | select($bm[.id] != null and $bm[.id].withdrawn) | "REMOVED \(.id) is already withdrawn in the base" ]
       + [ $rm_reqs[] | . as $r | select(($b.requirements | map(select(.capability == $r.capability and .title == $r.title)) | length) == 0) | "REMOVED requirement \"\($r.title)\" (\($r.capability)) is not in the base" ]) as $p_rm
    | ([ $mods[] | .added // [] | .[] ] + $added1 | unique) as $added
    | ([ $mods[] | .modified // [] | .[] ] | unique) as $modified
    | ([ $mods[] | .removed // [] | .[] ] + $removed1 | unique) as $removed
    | ([ $mods[] | .unchanged // [] | .[] ] | unique) as $unchanged
    | ($added + $modified + $removed | unique) as $touches
    | { added: $added, modified: $modified, removed: $removed, unchanged: $unchanged, touches: $touches,
        expects: ([ ($modified + $removed)[] | {(.): $bm[.].hash} ] | add // {}),
        problems: ( $p_added + $p_rm + [ $mods[] | .p // [] | if type == "string" then . else .[] end ]
                    + [ $dups[] | "\(.) appears more than once in the delta" ]
                    + [ $d.noId[] | "a scenario without an AC id in \(.capability) (\(.requirement))" ] ) }' || return 2
}

# need_args: sets BASE_ROOT and the positional list in ARGS; each verb picks what it needs
BASE_ROOT=""; EXP_FILE=""; ARGS=()
take_args() {
  ARGS=(); BASE_ROOT=""; EXP_FILE=""
  while [ $# -gt 0 ]; do case "$1" in --base) BASE_ROOT="${2:-}"; shift ;; --expects) EXP_FILE="${2:-}"; shift ;; --*) usage ;; *) ARGS+=("$1") ;; esac; shift; done
}

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
case "$cmd" in
parse) take_args "$@"; [ "${#ARGS[@]}" = 1 ] && [ -z "$BASE_ROOT" ] || usage; parse_root "${ARGS[0]}" || exit 1 ;;
compute)
  take_args "$@"; [ "${#ARGS[@]}" = 1 ] && [ -n "$BASE_ROOT" ] || usage
  out="$(compute_json "${ARGS[0]}" "$BASE_ROOT")"; r=$?; [ "$r" != 2 ] || exit 1
  printf '%s\n' "$out"; [ "$(printf '%s' "$out" | jq '.problems | length')" = 0 ] ;;
moved)
  take_args "$@"; [ "${#ARGS[@]}" = 1 ] && [ -n "$BASE_ROOT" ] || usage
  cd_="${ARGS[0]}"; ef="${EXP_FILE:-$cd_/change.json}"; [ -f "$ef" ] || die "no $ef (the change records what it expects)"
  bj="$(parse_root "$BASE_ROOT")" || exit 1
  out="$(jq -r -n --argjson b "$bj" --slurpfile e "$ef" '
    ($b.acs | map({(.id): .hash}) | add // {}) as $bm
    | ($e[0].expects // {}) | to_entries[] | select($bm[.key] != .value) | .key')" || die "cannot read $ef"
  [ -z "$out" ] || { printf '%s\n' "$out"; exit 1; } ;;
overlap)
  take_args "$@"; [ "${#ARGS[@]}" -ge 1 ] && [ -n "$BASE_ROOT" ] || usage
  items="[]"; i=0
  for c in "${ARGS[@]}"; do
    i=$((i + 1)); slug="$(basename "$c")"; ca=""; [ -f "$c/change.json" ] && ca="$(jq -r '.createdAt // empty' "$c/change.json" 2>/dev/null)"
    out="$(compute_json "$c" "$BASE_ROOT")"; [ "$?" != 2 ] || exit 1
    dj="$(parse_root "$c")" || exit 1
    items="$(jq -c --arg s "$slug" --arg ca "$ca" --argjson i "$i" --argjson c "$out" --argjson d "$dj" \
      '. + [{slug:$s, createdAt:$ca, order:$i, added:$c.added, touched:($c.modified + $c.removed), hashes:($d.acs | map({(.id): .hash}) | add // {})}]' <<< "$items")"
  done
  jq '(sort_by([.createdAt == "", .createdAt, .order])) as $it
      | { collisions: [ ($it | map(.added[] ) | unique[]) as $id | [$it[] | select(.added | index($id))] as $who | select(($who | length) > 1)
                        | {id: $id, same: ([$who[].hashes[$id]] | unique | length == 1), changes: [$who[].slug]} ],
          shared: [ ($it | map(.touched[]) | unique[]) as $id | [$it[] | select(.touched | index($id))] as $who | select(($who | length) > 1) | {id: $id, changes: [$who[].slug]} ] }' <<< "$items" ;;
plan)
  take_args "$@"; [ "${#ARGS[@]}" -ge 1 ] || usage
  root="${ARGS[0]}"; slugs=("${ARGS[@]:1}")
  if [ "${#slugs[@]}" = 0 ]; then
    for c in "$root"/changes/*/; do [ -f "${c}change.json" ] && [ "$(jq -r .status "${c}change.json")" = open ] && slugs+=("$(basename "$c")"); done
  fi
  [ "${#slugs[@]}" -gt 0 ] || die "no open change under $root/changes"
  bj="$(parse_root "$root")" || exit 1; dirs=(); items="[]"
  for sl in "${slugs[@]}"; do
    c="$root/changes/$sl"; [ -f "$c/change.json" ] || die "no change.json in $c"; dirs+=("$c")
    out="$(compute_json "$c" "$root")"; [ "$?" != 2 ] || exit 1
    mv_="$("$0" moved "$c" --base "$root" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
    cites="$( { grep -rhoE 'AC-[A-Za-z0-9._-]*-[0-9]+|ADR-[A-Za-z0-9-]*[0-9]' "$c" --include='*.md' 2>/dev/null || true; } | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0)) | {acs: map(select(startswith("AC-"))), adrs: map(select(startswith("ADR-")))}')"
    caps="$(ls "$c/specs" 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))')"
    items="$(jq -c --slurpfile cj "$c/change.json" --argjson f "$out" --argjson m "$mv_" --argjson ci "$cites" --argjson caps "$caps" \
      '. + [{slug: $cj[0].slug, title: $cj[0].title, kind: $cj[0].kind, label: $cj[0].label, createdAt: $cj[0].createdAt, base: $cj[0].base, resolutions: ($cj[0].resolutions // null),
             added: $f.added, modified: $f.modified, removed: $f.removed, problems: $f.problems, expectsMoved: $m, cites: $ci, capabilities: $caps}]' <<< "$items")"
  done
  ov="$("$0" overlap "${dirs[@]}" --base "$root")" || exit 1
  jq -n --argjson i "$items" --argjson o "$ov" --argjson b "$bj" '{baseAcs: ($b.acs | length), changes: ($i | sort_by(.createdAt)), collisions: $o.collisions, shared: $o.shared}' ;;
coverage)
  idsf=""; take_args "${@/--ids-before/--expects}"; [ "${#ARGS[@]}" = 1 ] || usage; root="${ARGS[0]}"; idsf="$EXP_FILE"
  bj="$(parse_root "$root")" || exit 1; probs=""; res="[]"; applied=()
  for c in "$root"/changes/*/; do [ -f "${c}change.json" ] && [ "$(jq -r .status "${c}change.json")" = applied ] && applied+=("${c%/}"); done
  [ "${#applied[@]}" -gt 0 ] || exit 0
  for c in ${applied[@]+"${applied[@]}"}; do res="$(jq -c --slurpfile cj "$c/change.json" '. + ($cj[0].resolutions // [] | map(.item))' <<< "$res")"; done
  for c in ${applied[@]+"${applied[@]}"}; do
    dj="$(parse_root "$c")" || exit 1; sl="$(basename "$c")"; tk=""; [ -f "$c/tasks.md" ] && tk="$(cat "$c/tasks.md")"
    p="$(jq -r -n --argjson d "$dj" --argjson b "$bj" --argjson r "$res" --arg sl "$sl" --arg tk "$tk" --slurpfile cj "$c/change.json" '
      ($b.acs | map({(.id): .}) | add // {}) as $bm | ($cj[0].touches // []) as $tc
      | ( $d.acs[] | select(.id as $i | $tc | index($i)) | . as $a
          | if $a.section == "REMOVED" then (if ($bm[$a.id].withdrawn // false) or ($r | index($a.id)) then empty else "\($sl): \($a.id) was removed but is not withdrawn in the base" end)
            elif $bm[$a.id] == null then "\($sl): \($a.id) is missing from the base"
            elif $bm[$a.id].hash == $a.hash or ($r | index($a.id)) then empty
            else "\($sl): \($a.id) differs from the base and has no recorded resolution" end ),
        ( $d.acs[] | select((.section == "ADDED" or .section == "MODIFIED") and (.withdrawn | not) and (.id as $i | $tc | index($i))) | .id | . as $i
          | select(($tk | test("(^|[^A-Za-z0-9_-])" + ($i | gsub("[.]"; "\\.")) + "([^0-9A-Za-z_]|$)")) | not) | "\($sl): its tasks.md does not cover \($i)" )')"
    [ -z "$p" ] || probs="$probs$p"$'\n'
  done
  p="$(printf '%s' "$bj" | jq -r '(.acs | group_by(.id) | map(select(length > 1) | .[0].id))[] | "AC id \(.) appears twice in the base"')"; [ -z "$p" ] || probs="$probs$p"$'\n'
  if [ -n "$idsf" ] && [ -f "$idsf" ]; then
    p="$(printf '%s' "$bj" | jq -r --rawfile ids "$idsf" '(.acs | map(.id)) as $now | ($ids | split("\n") | map(select(length > 0)))[] | select(. as $i | $now | index($i) | not) | "AC id \(.) was lost by the apply"')"; [ -z "$p" ] || probs="$probs$p"$'\n'
  fi
  known="$(printf '%s' "$bj" | jq -r '.acs[].id')"
  for f in "$root"/specs/*/spec.md "$root/tasks.md"; do
    [ -f "$f" ] || continue
    for t in $(grep -oE 'AC-[A-Za-z0-9._-]*-[0-9]+' "$f" | sort -u); do printf '%s\n' "$known" | grep -qxF "$t" || probs="$probs$(basename "$(dirname "$f")")/$(basename "$f"): reference to $t does not resolve"$'\n'; done
  done
  [ -z "$probs" ] || { printf '%s' "$probs"; exit 1; } ;;
validate)
  take_args "$@"; [ "${#ARGS[@]}" = 1 ] || usage
  c="${ARGS[0]}"; cj="$c/change.json"; slug="$(basename "$c")"; [ -f "$cj" ] || die "no change.json in $c"
  jq -e . "$cj" >/dev/null 2>&1 || die "$cj is not valid JSON"
  probs="$(jq -r --arg slug "$slug" '
    def hex64: type == "string" and test("^[0-9a-f]{64}$");
    def str: type == "string" and length > 0;
    [ (if (.slug | str) and .slug == $slug then empty else "slug must be a non-empty string equal to the directory name (\($slug))" end),
      (if (.title | str) then empty else "title is missing" end),
      (if (.kind | IN("fix", "feature")) then empty else "kind must be fix or feature" end),
      (if (.label | type == "string" and test("^[0-9]+\\.[0-9]+$")) then empty else "label must look like 1.1" end),
      (if (.status | IN("open", "applied")) then empty else "status must be open or applied" end),
      (if (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) then empty else "createdAt must be an ISO UTC time" end),
      (if (.base | type == "object") and (.base.version | type == "string" and test("^[0-9]+\\.[0-9]+$")) and (.base.contentHash | hex64) then empty else "base needs a version and a sha256 contentHash" end),
      (if (.expects | type == "object") and ((.expects | to_entries) | all(.key | startswith("AC-")) and all(.value | hex64)) then empty else "expects must map AC ids to sha256 hashes" end),
      (if (.touches | type == "array") and (.touches | all(type == "string" and startswith("AC-"))) then empty else "touches must be an array of AC ids" end),
      (if (.renames == null) or ((.renames | type == "object") and (.renames | to_entries | all(.key | startswith("AC-")) and all(.value | type == "string" and startswith("AC-")))) then empty else "renames must map AC ids to AC ids" end),
      (if (.resolutions == null) or ((.resolutions | type == "array") and (.resolutions | all((.item | str) and (.decision | str) and (.why | str) and (.by | str)))) then empty else "each resolution needs item, decision, why and by" end),
      (if .status != "applied" then empty elif (.applied | type == "object") and (.applied.version | str) and (.applied.at | str) and (.applied.sha | str) then empty else "an applied change needs applied {version, at, sha}" end)
    ] | .[]' "$cj" 2>&1)" || die "cannot read $cj: $probs"
  if [ -n "$BASE_ROOT" ] && [ -z "$probs" ]; then
    out="$(compute_json "$c" "$BASE_ROOT")"; [ "$?" != 2 ] || die "cannot read the delta of $c or the base $BASE_ROOT"
    probs="$(printf '%s' "$out" | jq -r --slurpfile cj "$cj" '
      .problems[],
      (if (.touches | sort) == (($cj[0].touches // []) | sort) then empty else "touches in change.json (\(($cj[0].touches // []) | sort | join(","))) differ from the delta (\(.touches | join(",")))" end),
      (if ((.expects | keys) | sort) == (($cj[0].expects // {}) | keys | sort) then empty else "expects in change.json names other ACs than the delta modifies or removes" end)')"
  fi
  [ -z "$probs" ] || { printf 'spec-change: %s\n' "$probs" | sed '2,$s/^/spec-change: /'; exit 1; }
  echo "spec-change: $slug ok" ;;
*) usage ;;
esac
