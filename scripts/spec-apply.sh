#!/usr/bin/env bash
# The file-writing half of applying a spec change (docs/design-spec-merge.md §4, §6). spec.sh apply runs it on a scratch copy of the spec directory and
# copies the result back only when the coverage check passes. Pure bash + awk + sed + jq: no model, no git. Facts come from spec-change.sh.
#   spec-apply.sh renumber <spec-root> <slug>...   AC ids the changes ADD that the base or an earlier change (createdAt order) already holds are renumbered to
#                                                  the next free number of their prefix, in the later change's own files (*.md), and recorded in its change.json
#                                                  `renames`. Prints `<slug> <old> <new>` per rename.
#   spec-apply.sh delta <spec-root> <slug>         write the change's delta into the base files: ADDED requirements are appended, a MODIFIED requirement replaces the
#                                                  base requirement it shares an AC id with (withdrawn base ACs it omits are kept), a REMOVED AC (or a bare requirement,
#                                                  matched by title) is rewritten as `(withdrawn)`. The id of a removed AC is kept.
# A capability's spec.md is cut into items: preamble (P), `## ` headings (H) and `### Requirement:` blocks (R); only R items are ever edited.
# Exit: 0 ok, 1 a step failed, 2 usage.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/spec-change.sh"
command -v jq >/dev/null 2>&1 || { echo "spec-apply: jq is required" >&2; exit 2; }
die()   { echo "spec-apply: $*" >&2; exit 1; }
usage() { echo "usage: spec-apply.sh renumber <spec-root> <slug>... | delta <spec-root> <slug>" >&2; exit 2; }

# split_items <file> <dir>: 0001.P, 0002.H, 0003.R.ADDED ... (the section in force is the suffix of an R item)
split_items() {
  mkdir -p "$2" && awk -v dir="$2" '
    function open_item(kind) { if (cur != "") close(cur); n++; cur = sprintf("%s/%04d.%s", dir, n, kind); printf "" > cur }
    BEGIN { n = 0; cur = ""; sec = "NONE"; open_item("P") }
    /^## / { t = $0; sub(/^## +/, "", t); sec = "NONE"; if (t ~ /^(ADDED|MODIFIED|REMOVED|RENAMED) +Requirements/) { sec = t; sub(/ .*/, "", sec) }; open_item("H"); print > cur; next }
    /^### +Requirement:/ { open_item("R." sec); print > cur; next }
    { print > cur }
    END { if (cur != "") close(cur) }' "$1"
}
# ids_of <file>: AC ids of the scenarios in a block, in order
ids_of() { sed -n -E 's/^####[[:space:]]+Scenario:[[:space:]]*(AC-[A-Za-z0-9._-]*-[0-9]+).*/\1/p' "$1"; }
title_of() { sed -n -E '1s/^###[[:space:]]+Requirement:[[:space:]]*//p' "$1" | sed -E 's/[[:space:]]+$//'; }
is_withdrawn() { grep -Eq "^####[[:space:]]+Scenario:[[:space:]]*$2[[:space:]]*\([Ww]ithdrawn\)" "$1"; }
# ac_block <file> <id>: the scenario block of one AC
ac_block() { awk -v id="$2" '
  /^#+[ \t]/ { lvl = 0; while (substr($0, lvl + 1, 1) == "#") lvl++; if (on && lvl <= 4) on = 0
    if (!on && lvl == 4 && index($0, "Scenario:") && match($0, /AC-[A-Za-z0-9._-]*-[0-9]+/) && substr($0, RSTART, RLENGTH) == id) on = 1 }
  on { print }' "$1"; }
# withdraw_ac <file> <id> <slug>: rewrite one scenario as withdrawn (the id stays)
withdraw_ac() { local tmp; tmp="$(mktemp "$1.XXXXXX")" || return 1
  awk -v id="$2" -v slug="$3" '
    function head(l) { lvl = 0; while (substr(l, lvl + 1, 1) == "#") lvl++; return lvl }
    { if ($0 ~ /^#+[ \t]/) { lvl = head($0); if (skip && lvl <= 4) skip = 0
        if (!skip && lvl == 4 && index($0, "Scenario:") && match($0, /AC-[A-Za-z0-9._-]*-[0-9]+/) && substr($0, RSTART, RLENGTH) == id) {
          t = substr($0, RSTART + RLENGTH); sub(/^[ \t]*\([Ww]ithdrawn\)/, "", t); sub(/^[ \t]*-?[ \t]*/, "", t)
          printf "#### Scenario: %s (withdrawn) - %s\n- **THEN** WITHDRAWN: removed by change %s. The id is kept and never reused\n\n", id, t, slug; skip = 1; next } }
      if (!skip) print }' "$1" > "$tmp" && mv "$tmp" "$1" || { rm -f "$tmp"; return 1; }; }
# join_items <dir> <out>: the items back into one file, a blank line after an item that does not end with one
join_items() { local f; : > "$2"; for f in "$1"/*; do cat "$f" >> "$2"; [ -z "$(tail -n 1 "$f" | tr -d '[:space:]')" ] || echo >> "$2"; done; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
case "$cmd" in
renumber)
  root="${1:-}"; [ -d "$root" ] && [ $# -ge 2 ] || usage; shift
  slugs="$(for s in "$@"; do printf '%s\t%s\n' "$(jq -r '.createdAt // ""' "$root/changes/$s/change.json" 2>/dev/null)" "$s"; done | LC_ALL=C sort | cut -f2)"
  baseids="$("$SC" parse "$root" | jq -r '.acs[].id')" || exit 1; claimed="$baseids"
  for s in $slugs; do
    c="$root/changes/$s"; dj="$("$SC" parse "$c")" || exit 1; mine=""
    ownids="$(printf '%s' "$dj" | jq -r '.acs[].id')"   # the new number must not hit another id of this same change
    for id in $(printf '%s' "$dj" | jq -r '.acs[] | select(.section != "REMOVED") | .id'); do
      sec="$(printf '%s' "$dj" | jq -r --arg i "$id" '[.acs[] | select(.id == $i)][0].section')"
      if printf '%s\n' "$claimed" | grep -qxF "$id" && { [ "$sec" = ADDED ] || ! printf '%s\n' "$baseids" | grep -qxF "$id"; }; then
        pre="${id%-*}"; max="$( { printf '%s\n' "$claimed"; printf '%s\n' "$ownids"; } | grep -E "^${pre}-[0-9]+$" | sed 's/.*-//' | sort -n | tail -1)"; new="$pre-$((max + 1))"
        while IFS= read -r f; do sed -E -i.bak "s/(^|[^A-Za-z0-9_-])$id([^0-9A-Za-z_]|\$)/\\1$new\\2/g; s/(^|[^A-Za-z0-9_-])$id([^0-9A-Za-z_]|\$)/\\1$new\\2/g" "$f" && rm -f "$f.bak"; done <<EOF
$(find "$c" -type f -name '*.md')
EOF
        tmp="$(mktemp "$c/.cj.XXXXXX")" && jq --arg o "$id" --arg n "$new" '.renames = ((.renames // {}) + {($o): $n}) | .touches |= map(if . == $o then $n else . end)' "$c/change.json" > "$tmp" && mv "$tmp" "$c/change.json" || die "cannot record the rename in $c/change.json"
        claimed="$claimed"$'\n'"$new"; echo "$s $id $new"
      else mine="$mine $id"; fi
    done
    for id in $mine; do printf '%s\n' "$claimed" | grep -qxF "$id" || claimed="$claimed"$'\n'"$id"; done
  done ;;
delta)
  root="${1:-}"; slug="${2:-}"; [ -d "$root" ] && [ -n "$slug" ] || usage; c="$root/changes/$slug"; [ -d "$c/specs" ] || die "no delta in $c"
  W="$(mktemp -d)" || die "no scratch directory"; trap 'rm -rf "$W"' EXIT
  for df in "$c"/specs/*/spec.md; do
    [ -f "$df" ] || continue; cap="$(basename "$(dirname "$df")")"; bf="$root/specs/$cap/spec.md"
    if [ ! -f "$bf" ]; then mkdir -p "$root/specs/$cap"; printf '# %s\n\n## Requirements\n\n' "$cap" > "$bf"; fi
    rm -rf "$W/b" "$W/d"; split_items "$bf" "$W/b" && split_items "$df" "$W/d" || die "cannot read $cap"
    next=9000
    for di in "$W"/d/*.R.*; do
      [ -f "$di" ] || continue; sec="${di##*.R.}"; dids="$(ids_of "$di")"
      case "$sec" in
        ADDED) next=$((next + 1)); cp "$di" "$W/b/$next.R.ADDED" ;;
        MODIFIED)
          hit=""; for bi in "$W"/b/*.R.*; do [ -f "$bi" ] || continue; for i in $dids; do ids_of "$bi" | grep -qxF "$i" && { hit="$bi"; break; }; done; [ -z "$hit" ] || break; done
          [ -n "$hit" ] || die "$slug: MODIFIED requirement '$(title_of "$di")' matches nothing in $cap"
          cp "$hit" "$W/old.item"; cp "$di" "$hit"; [ -z "$(tail -n 1 "$hit" | tr -d '[:space:]')" ] || echo >> "$hit"
          for i in $(ids_of "$W/old.item"); do
            is_withdrawn "$W/old.item" "$i" && ! printf '%s\n' "$dids" | grep -qxF "$i" && ac_block "$W/old.item" "$i" >> "$hit"
          done ;;
        REMOVED)
          if [ -n "$dids" ]; then
            for i in $dids; do for bi in "$W"/b/*.R.*; do [ -f "$bi" ] && ids_of "$bi" | grep -qxF "$i" && { is_withdrawn "$bi" "$i" || withdraw_ac "$bi" "$i" "$slug" || die "cannot withdraw $i"; break; }; done; done
          else
            t="$(title_of "$di")"; found=0
            for bi in "$W"/b/*.R.*; do [ -f "$bi" ] && [ "$(title_of "$bi")" = "$t" ] || continue; found=1
              for i in $(ids_of "$bi"); do is_withdrawn "$bi" "$i" || withdraw_ac "$bi" "$i" "$slug" || die "cannot withdraw $i"; done; done
            [ "$found" = 1 ] || die "$slug: REMOVED requirement '$t' matches nothing in $cap"
          fi ;;
        *) ;;
      esac
    done
    join_items "$W/b" "$W/out.md" && cp "$W/out.md" "$bf" || die "cannot write $bf"
  done ;;
*) usage ;;
esac
