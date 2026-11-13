#!/usr/bin/env bash
# Deterministic mechanics of a published spec (F06). The writing and the review are done by skills (generate-specs / update-specs); this script only keeps
# branch, PR, version and metadata honest. Contract: docs/design-role-aware.md, section "Spec metadata". Operates on the repo in CLAUDE_PROJECT_DIR (else the cwd's).
#   spec.sh init-meta <id>      create specs/<id>/spec.meta.json (version 0.0 = never published, status draft) when missing; never overwrites
#   spec.sh hash <id>           the contentHash (review.sh hash)
#   spec.sh status <id>         version, status, branch, hash, whether the hash is the published one, review verdict and whether review.sh check passes
#   spec.sh changed <id>        spec files that really changed (worktree + untracked) since the last published SHA in the history; every file before the first publish
#   spec.sh branch <id>         switch to spec/<id>, creating it from origin/<base> (else HEAD) when missing. Never forces, never resets.
#   spec.sh publish <id> --title T --body-file F [--breaking]
#                               needs `review.sh check <id>` to pass (a fresh PASS bound to the current hash; there is no way around it). Commits the spec files on
#                               spec/<id>, pushes (never force), creates the PR to <base> or reuses and updates the one that exists, and only then records the new
#                               version in spec.meta.json (history: version, sha, at, contentHash) in a second commit that is pushed too. A failure before that leaves
#                               the meta untouched and a re-run finishes the job. Same content as the last publish = no-op, no new version. Version: 0.1 first,
#                               then +0.1 each publish (0.N before approval, 1.N after); --breaking = N+1.0. A publish after approval sets status draft again.
#   spec.sh promote <id>        the approval PR's last commit: version 1.0 (or the current 1.N, a revision) and status approved, committed on the PR branch.
#                               Does not push, merge or approve: the Tech Lead's merge is the approval. Refuses on the base/protected branches and on unpublished edits.
#   spec.sh approved-sha <id> --sha S
#                               exit 0 only when S is reachable from origin/<base> and the spec meta AT S says status approved; prints id, version, sha. A spec with changes/
#                               must also be whole at S: no open change merged alone, no unmerged sibling, coverage OK, base hash = recorded hash (gate d).
#   spec.sh change new <id> <slug> [--title T] [--kind fix|feature]
#                               a change on an approved base: branch spec/<id>--<slug> from origin/<base>, changes/<slug>/{change.json,intent.md}; label = base +0.1.
#                               Refuses when the base is not approved on origin/<base> or the slug exists. The analyst never types a sha or a version.
#   spec.sh change refresh <id> <slug>   recompute expects/touches in change.json from the delta (refuses on delta problems, see spec-change.sh compute)
#   spec.sh change status <id> [<slug>]  one line per change: label, status, whether the base moved under it
#   spec.sh drift <id> [<slug>]  git fetch, then the open changes of <id> on other branches (siblings) and whether the base moved since <slug> was written. Exit 3 on drift
#   spec.sh check <id>           OK (exit 0) or what is missing (exit 1): changes not applied, siblings not merged in, coverage problems. The Tech Lead runs it before merging
#   spec.sh apply <id> [<slug>...]
#                               write the open changes (default all in the worktree) into the base as the next revision. One change on an unmoved base: done, exit 0.
#                               Siblings or a moved base: the facts go to work/spec-merge/<id>/plan.json and exit 3 until every change has `resolutions` (merge-specs
#                               records them); then ids are renumbered and the deltas applied in createdAt order (a later MODIFIED of the same AC wins, so merge-specs puts
#                               the merged text into the deltas). Everything runs on a scratch copy, copied back only when the coverage check passes.
#                               Branches: base spec/<id>, changes spec/<id>--<slug> (spec/<id> and spec/<id>/<slug> cannot coexist in git).
#   publish on a change branch (spec/<id>--<slug>): an open change commits only changes/<slug>/, needs `review.sh check <id>--<slug>` (the change's own review, bound
#                               to the hash of its directory), pushes, opens or updates its PR (no version bump); an applied revision records its version (set by apply, not
#                               bumped again) and needs the review of the change (one change) or of the base `<id>` (a merge of siblings). The PR body gets a status block:
#                               `SIBLINGS: ...: do not merge alone, merge-specs first`, or `applied against base <hash>`.
# Pre-spec content (PRESPEC_DIR, default prespec) is never committed: publish refuses when a staged path is inside it.
# Settings (sdkit.env): SPECS_DIR (specs), PRESPEC_DIR (prespec), BASE_BRANCH (main here), PROTECTED_BRANCHES (extra, space separated), PR_HOST (open-pr.sh).
# Exit: 0 ok, 1 refused / not satisfied / a step failed, 2 usage.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
. "$HERE/env.sh" || { echo "spec: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }
sdkit_env_load "$REPO"; export CLAUDE_PROJECT_DIR="$REPO"
command -v jq >/dev/null 2>&1 || { echo "spec: jq is required" >&2; exit 2; }
SPEC_DIR="${SPECS_DIR:-specs}"; PRESPEC="${PRESPEC_DIR:-prespec}"; PRESPEC="${PRESPEC%/}"; BASE="${BASE_BRANCH:-main}"
G() { git -C "$REPO" "$@"; }
die()   { echo "spec: $*" >&2; exit "${RC:-1}"; }
usage() { echo "usage: spec.sh change new|refresh|status <id> ... | drift <id> [slug] | check <id> | apply <id> [slug...] | init-meta <id> | hash <id> | status <id> | changed <id> | branch <id> | publish <id> --title T --body-file F [--breaking] | promote <id> | approved-sha <id> --sha S" >&2; exit 2; }
now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
okname() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
dir_of()  { printf '%s/%s\n' "$SPEC_DIR" "$1"; }
meta_of() { printf '%s/%s/spec.meta.json\n' "$REPO/$SPEC_DIR" "$1"; }
mget() { jq -r "$2 // empty" "$(meta_of "$1")" 2>/dev/null; }
need_dir() { [ -d "$REPO/$(dir_of "$1")" ] || die "no spec directory $(dir_of "$1")"; }
# wmeta <id> <json>: atomic write
wmeta() { local f tmp; f="$(meta_of "$1")"; tmp="$(mktemp "$(dirname "$f")/.meta.XXXXXX")" && printf '%s\n' "$2" | jq . > "$tmp" && mv "$tmp" "$f" || { rm -f "${tmp:-}"; return 1; }; }
cur_hash() { "$HERE/review.sh" hash "$1" 2>/dev/null; }
branch_now() { G rev-parse --abbrev-ref HEAD 2>/dev/null; }
is_protected() { local b="$1" p; [ "$b" = "$BASE" ] && return 0; for p in main master develop trunk ${PROTECTED_BRANCHES:-}; do [ "$b" = "$p" ] && return 0; done; case "$b" in release/*|hotfix/*) return 0 ;; esac; return 1; }
prespec_staged() { G diff --cached --name-only 2>/dev/null | grep -E "^($PRESPEC)(/|$)" || true; }
bump() { # bump <version> <breaking 0|1>
  local maj="${1%%.*}" min="${1#*.}"
  if [ "$2" = 1 ]; then echo "$((maj + 1)).0"; else echo "$maj.$((min + 1))"; fi
}
ensure_branch() {
  local b="spec/$1" cur; cur="$(branch_now)"
  [ "$cur" = "$b" ] && return 0
  if G show-ref --verify -q "refs/heads/$b"; then G checkout -q "$b" || return 1
  elif G show-ref --verify -q "refs/remotes/origin/$b"; then G checkout -q -b "$b" --track "origin/$b" || return 1
  elif G show-ref --verify -q "refs/remotes/origin/$BASE"; then G checkout -q -b "$b" "origin/$BASE" || return 1
  else G checkout -q -b "$b" || return 1; fi
}

SC="$HERE/spec-change.sh"; SA="$HERE/spec-apply.sh"
cdir_of() { printf '%s/changes/%s\n' "$(dir_of "$1")" "$2"; }
# ref_changes <id>: "<ref> <slug>" for every change branch of the spec, remote ones first (a slug appears once)
ref_changes() {
  { G for-each-ref --format='%(refname:short)' "refs/remotes/origin/spec/$1--*" "refs/heads/spec/$1--*" 2>/dev/null; } | while read -r r; do
    [ -n "$r" ] && printf '%s %s\n' "$r" "${r#*"spec/$1--"}"; done | awk '!seen[$2]++'
}
# ref_status <ref> <id> <slug>: the status of the change recorded on that ref (empty when it has none)
ref_status() { G show "$1:$(cdir_of "$2" "$3")/change.json" 2>/dev/null | jq -r '.status // empty' 2>/dev/null; }
# pr_body <id> <body-file>: a copy of the body with the status block (gate b); prints the path
pr_body() {
  local out sl sib; out="$(mktemp)"; cat "$2" > "$out"; sl="$(own_slug "$1")"
  [ -n "$sl" ] || { printf '%s\n' "$out"; return 0; }
  sib="$("$0" drift "$1" "$sl" 2>/dev/null | grep '^SIBLINGS:' || true)"
  if [ -n "$sib" ]; then printf '\n\n%s: do not merge alone, merge-specs first\n' "$sib" >> "$out"
  elif [ "$(jq -r .status "$REPO/$(cdir_of "$1" "$sl")/change.json" 2>/dev/null)" = applied ]; then
    printf '\n\napplied against base %s\n' "$(jq -r '.base.contentHash[0:12]' "$REPO/$(cdir_of "$1" "$sl")/change.json")" >> "$out"
  else printf '\n\nno siblings at publish time\n' >> "$out"; fi
  printf '%s\n' "$out"
}
own_slug() { local b; b="$(branch_now)"; case "$b" in "spec/$1--"*) echo "${b#*"spec/$1--"}" ;; esac; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
sub=""; if [ "$cmd" = change ]; then sub="${1:-}"; [ $# -gt 0 ] && shift; fi
id="${1:-}"; [ $# -gt 0 ] && shift
okname "$id" || usage
case "$cmd" in
change)
  case "$sub" in
  new)
    slug="${1:-}"; [ $# -gt 0 ] && shift; title=""; kind=feature
    while [ $# -gt 0 ]; do case "$1" in --title) title="${2:-}"; shift ;; --kind) kind="${2:-}"; shift ;; *) usage ;; esac; shift; done
    okname "$slug" || usage; case "$slug" in *--*) die "a slug cannot contain '--' (it separates the id from the slug in the branch name)" ;; esac
    case "$kind" in fix|feature) ;; *) usage ;; esac; [ -n "$title" ] || title="$slug"
    G fetch -q origin 2>/dev/null || true
    src=HEAD; G rev-parse --verify -q "origin/$BASE" >/dev/null && src="origin/$BASE"
    m="$(G show "$src:$(dir_of "$id")/spec.meta.json" 2>/dev/null)" || die "no spec '$id' on $src"
    [ "$(printf '%s' "$m" | jq -r .status)" = approved ] || die "'$id' is not approved on $src: a change needs an approved base (before approval, edit the spec in place)"
    b="spec/$id--$slug"; G show-ref --verify -q "refs/heads/$b" && die "branch $b exists (the slug is taken)"
    G show-ref --verify -q "refs/remotes/origin/$b" && die "branch origin/$b exists (the slug is taken)"
    G checkout -q -b "$b" "$src" || die "cannot create $b from $src (commit or stash your edits)"
    ver="$(mget "$id" .version)"; cd_="$REPO/$(cdir_of "$id" "$slug")"; mkdir -p "$cd_/specs" || die "cannot create $cd_"
    jq -n --arg s "$slug" --arg t "$title" --arg k "$kind" --arg l "$(bump "$ver" 0)" --arg at "$(now)" --arg v "$ver" --arg h "$(cur_hash "$id")" \
      '{slug:$s, title:$t, kind:$k, label:$l, status:"open", createdAt:$at, base:{version:$v, contentHash:$h}, expects:{}, touches:[]}' > "$cd_/change.json"
    printf '# %s\n\nWhy this change exists and what the author meant (read by merge-specs).\n' "$title" > "$cd_/intent.md"
    echo "spec: change '$slug' on '$id' v$ver, label $(bump "$ver" 0), branch $b. Write the delta under $(cdir_of "$id" "$slug")/specs/" ;;
  refresh)
    slug="${1:-}"; okname "$slug" || usage; cd_="$REPO/$(cdir_of "$id" "$slug")"; [ -f "$cd_/change.json" ] || die "no change '$slug' in $id"
    out="$("$SC" compute "$cd_" --base "$REPO/$(dir_of "$id")")" || { printf '%s\n' "$out" | jq -r '.problems[]?' >&2; die "the delta has problems (above)"; }
    tmp="$(mktemp "$cd_/.cj.XXXXXX")" && jq --argjson f "$out" '. + {expects:$f.expects, touches:$f.touches}' "$cd_/change.json" > "$tmp" && mv "$tmp" "$cd_/change.json" || die "cannot write change.json"
    echo "spec: '$slug' touches $(printf '%s' "$out" | jq -r '.touches | length') AC(s)" ;;
  status)
    one="${1:-}"; for c in "$REPO/$(dir_of "$id")"/changes/*/; do
      [ -f "${c}change.json" ] || continue; sl="$(basename "$c")"; [ -z "$one" ] || [ "$one" = "$sl" ] || continue
      mv_=no; "$SC" moved "${c%/}" --base "$REPO/$(dir_of "$id")" >/dev/null 2>&1 || mv_=yes
      echo "change=$sl label=$(jq -r .label "${c}change.json") status=$(jq -r .status "${c}change.json") base=$(jq -r .base.version "${c}change.json") base_moved=$mv_"
    done ;;
  *) usage ;;
  esac ;;
drift)
  own="${1:-}"; [ -n "$own" ] || own="$(own_slug "$id")"
  G fetch -q origin 2>/dev/null || true; sib=""
  while read -r ref sl; do
    [ -n "$ref" ] && [ "$sl" != "$own" ] && [ "$(ref_status "$ref" "$id" "$sl")" = open ] && sib="$sib${sib:+, }$sl"
  done <<EOF
$(ref_changes "$id")
EOF
  rc_=0
  if [ -n "$sib" ]; then echo "SIBLINGS: $sib"; rc_=3; fi
  if [ -n "$own" ] && [ -f "$(meta_of "$id")" ]; then
    own_h="$(jq -r '.base.contentHash // empty' "$REPO/$(cdir_of "$id" "$own")/change.json" 2>/dev/null)"
    if G rev-parse --verify -q "origin/$BASE" >/dev/null; then
      nowv="$(G show "origin/$BASE:$(dir_of "$id")/spec.meta.json" 2>/dev/null)" && [ -n "$own_h" ] && [ "$(printf '%s' "$nowv" | jq -r .contentHash)" != "$own_h" ] \
        && { echo "BASE: moved to v$(printf '%s' "$nowv" | jq -r .version) since '$own' was written"; rc_=3; }
    fi
  fi
  [ "$rc_" = 0 ] && echo "drift: none"; exit "$rc_" ;;
check)
  need_dir "$id"; root="$REPO/$(dir_of "$id")"; G fetch -q origin 2>/dev/null || true; probs=""
  for c in "$root"/changes/*/; do [ -f "${c}change.json" ] && [ "$(jq -r .status "${c}change.json")" = open ] && probs="$probs- not applied: $(basename "$c")"$'\n'; done
  while read -r ref sl; do
    [ -n "$ref" ] || continue; [ -d "$root/changes/$sl" ] && continue
    [ "$(ref_status "$ref" "$id" "$sl")" = open ] && probs="$probs- sibling not merged in: $sl ($ref): run merge-specs"$'\n'
  done <<EOF
$(ref_changes "$id")
EOF
  cov="$("$SC" coverage "$root" 2>&1)" || probs="$probs$(printf '%s\n' "$cov" | sed 's/^/- /')"$'\n'
  if [ -z "$probs" ]; then echo "spec: check OK for '$id'"; else printf 'spec: check FAILED for %s:\n%s' "$id" "$probs"; exit 1; fi ;;
apply)
  need_dir "$id"; root="$REPO/$(dir_of "$id")"; slugs=("$@")
  if [ "${#slugs[@]}" = 0 ]; then for c in "$root"/changes/*/; do [ -f "${c}change.json" ] && [ "$(jq -r .status "${c}change.json")" = open ] && slugs+=("$(basename "$c")"); done; fi
  [ "${#slugs[@]}" -gt 0 ] || die "no open change to apply in $(dir_of "$id")"
  for sl in "${slugs[@]}"; do [ "$(jq -r .status "$root/changes/$sl/change.json" 2>/dev/null)" = open ] || die "'$sl' is not an open change of '$id'"; done
  W="$(mktemp -d)" || die "no scratch directory"; trap 'rm -rf "$W"' EXIT
  cp -R "$root" "$W/spec" && "$SC" parse "$root" | jq -r '.acs[].id' > "$W/ids" || die "cannot read the spec"
  # siblings on other branches that are not in this worktree: the analyst merges those branches in with git first, then merge-specs
  sibs=""; while read -r ref sl; do
    [ -n "$ref" ] || continue; [ -d "$root/changes/$sl" ] && continue
    [ "$(ref_status "$ref" "$id" "$sl")" = open ] && sibs="$sibs${sibs:+, }$sl"
  done <<EOF
$(ref_changes "$id")
EOF
  [ -z "$sibs" ] || { echo "SIBLINGS: $sibs. Merge their branches into this one with git, then run merge-specs; nothing was changed"; exit 3; }
  needs=0; [ "${#slugs[@]}" -gt 1 ] && needs=1; h="$(cur_hash "$id")"
  for sl in "${slugs[@]}"; do
    [ "$(jq -r .base.contentHash "$root/changes/$sl/change.json")" = "$h" ] || needs=1
    "$SC" moved "$root/changes/$sl" --base "$root" >/dev/null 2>&1 || needs=1
  done
  if [ "$needs" = 1 ]; then
    pf="$REPO/${KIT_DIR:-.sdkit}/work/spec-merge/$id/plan.json"; mkdir -p "$(dirname "$pf")" || die "cannot create $(dirname "$pf")"
    "$SC" plan "$root" "${slugs[@]}" > "$pf.tmp" && mv "$pf.tmp" "$pf" || die "cannot write the plan"
    un="$(jq -r '[.changes[] | select(.resolutions == null) | .slug] | join(", ")' "$pf")"
    if [ -n "$un" ]; then echo "spec: '$id' needs a semantic merge (siblings or a moved base): plan at $pf; no resolutions recorded for: $un. Run merge-specs; nothing was changed"; exit 3; fi
    "$SA" renumber "$W/spec" "${slugs[@]}" || die "renumbering failed; nothing was changed"
  fi
  for sl in "${slugs[@]}"; do
    out="$("$SC" compute "$W/spec/changes/$sl" --base "$W/spec")" || { printf '%s\n' "$out" | jq -r '.problems[]?' >&2; die "$sl: the delta has problems (above); nothing was changed"; }
    # touches is derived from the delta, so a forgotten `change refresh` cannot make the coverage check vacuous (expects keeps what was recorded)
    tmp="$(mktemp "$W/cj.XXXXXX")" && jq --argjson f "$out" '.touches = $f.touches | .expects = ($f.expects + (.expects // {}))' "$W/spec/changes/$sl/change.json" > "$tmp" && mv "$tmp" "$W/spec/changes/$sl/change.json" || die "cannot update change.json"
  done
  order="$(for sl in "${slugs[@]}"; do printf '%s\t%s\n' "$(jq -r .createdAt "$W/spec/changes/$sl/change.json")" "$sl"; done | LC_ALL=C sort | cut -f2)"
  # one change on an unmoved base: base +0.1 (= its label). A merge: one step past the highest of the base and the siblings' labels (siblings share 1.1, the merge is 1.2)
  top="$(mget "$id" .version)"
  if [ "$needs" = 1 ]; then top="$( { echo "$top"; for sl in "${slugs[@]}"; do jq -r .label "$root/changes/$sl/change.json"; done; } | sort -t. -k1,1n -k2,2n | tail -1)"; fi
  newv="$(bump "$top" 0)"; sha="$(G rev-parse HEAD 2>/dev/null || echo unknown)"
  for sl in $order; do
    "$SA" delta "$W/spec" "$sl" || die "$sl: applying the delta failed; nothing was changed"
    if [ -s "$W/spec/changes/$sl/tasks.md" ]; then { [ -f "$W/spec/tasks.md" ] && echo; printf '## Change: %s\n\n' "$sl"; cat "$W/spec/changes/$sl/tasks.md"; } >> "$W/spec/tasks.md"; fi
    tmp="$(mktemp "$W/cj.XXXXXX")" && jq --arg v "$newv" --arg at "$(now)" --arg sha "$sha" '.status = "applied" | .applied = {version:$v, at:$at, sha:$sha}' "$W/spec/changes/$sl/change.json" > "$tmp" && mv "$tmp" "$W/spec/changes/$sl/change.json" || die "cannot update change.json"
  done
  tmp="$(mktemp "$W/meta.XXXXXX")" && jq --arg v "$newv" '.version = $v | .status = "draft"' "$W/spec/spec.meta.json" > "$tmp" && mv "$tmp" "$W/spec/spec.meta.json" || die "cannot update the meta"
  cov="$("$SC" coverage "$W/spec" --ids-before "$W/ids" 2>&1)" || { printf '%s\n' "$cov" >&2; die "the coverage check failed (above); nothing was changed"; }
  cp -R "$W/spec/." "$root/" || die "cannot write back"
  echo "spec: applied ${slugs[*]} to '$id' as revision $newv (coverage OK). Next: review, publish, then promote" ;;
init-meta)
  need_dir "$id"; f="$(meta_of "$id")"
  if [ -f "$f" ]; then echo "spec: meta exists for '$id' (version $(mget "$id" .version), $(mget "$id" .status))"; exit 0; fi
  wmeta "$id" "$(jq -n --arg id "$id" '{id:$id, version:"0.0", status:"draft", contentHash:"", review:{}, history:[]}')" || die "cannot write $f"
  echo "spec: created $f (version 0.0: never published)" ;;
hash) need_dir "$id"; exec "$HERE/review.sh" hash "$id" ;;
status)
  need_dir "$id"; [ -f "$(meta_of "$id")" ] || die "no spec.meta.json for '$id': run spec.sh init-meta $id"
  h="$(cur_hash "$id")"; pub=no; [ -n "$h" ] && [ "$h" = "$(mget "$id" .contentHash)" ] && pub=yes
  rv=fail; "$HERE/review.sh" check "$id" >/dev/null 2>&1 && rv=pass
  echo "id=$id version=$(mget "$id" .version) status=$(mget "$id" .status) branch=$(branch_now) hash=$h published_hash=$pub review_verdict=$(mget "$id" .review.verdict) review_check=$rv" ;;
changed)
  need_dir "$id"; d="$(dir_of "$id")"; last="$(jq -r '.history[-1].sha // empty' "$(meta_of "$id")" 2>/dev/null)"
  if [ -z "$last" ]; then ( cd "$REPO" && find "$d" -type f | sort )
  else
    G cat-file -e "$last^{commit}" 2>/dev/null || die "published SHA $last is not in this clone (git fetch)"
    { G diff --name-only "$last" -- "$d"; G ls-files --others --exclude-standard -- "$d"; } | sort -u
  fi | grep -v -e '/spec\.meta\.json$' -e '/acceptances\.jsonl$' || true ;;
branch)
  need_dir "$id"; ensure_branch "$id" || die "cannot switch to spec/$id (never forced: resolve by hand)"; echo "spec/$id" ;;
publish)
  title=""; bf=""; brk=0
  while [ $# -gt 0 ]; do case "$1" in --title) title="${2:-}"; shift ;; --body-file) bf="${2:-}"; shift ;; --breaking) brk=1 ;; *) usage ;; esac; shift; done
  [ -n "$title" ] && [ -r "$bf" ] || usage
  need_dir "$id"; d="$(dir_of "$id")"
  "$HERE/open-pr.sh" --repo-dir "$REPO" --check || die "the PR host is not ready (list above): fill it in and run publish again; nothing was committed or pushed"
  slug="$(own_slug "$id")"; cst=""; [ -z "$slug" ] || cst="$(jq -r '.status // empty' "$REPO/$(cdir_of "$id" "$slug")/change.json" 2>/dev/null)"
  rkey="$id"
  if [ -n "$cst" ]; then
    rkey="$id--$slug"
    if [ "$cst" = applied ]; then
      ncs=0; for c in "$REPO/$d"/changes/*/; do [ "$(jq -r '.applied.version // empty' "${c}change.json" 2>/dev/null)" = "$(mget "$id" .version)" ] && ncs=$((ncs + 1)); done
      [ "$ncs" -le 1 ] || rkey="$id"   # a merge of siblings is reviewed as the whole revision
    fi
  fi
  "$HERE/review.sh" check "$rkey" || die "publish needs a fresh PASS review of the current content (review.sh check $rkey)"
  bad="$(prespec_staged)"; [ -z "$bad" ] || die "refusing: staged paths inside the pre-spec directory '$PRESPEC' (never committed):
$bad"
  if [ "$cst" = open ]; then   # an open change: its directory only, the base and its version are untouched
    G add -- "$d/changes/$slug" || die "git add failed"
    if ! G diff --cached --quiet -- "$d/changes/$slug"; then G commit -q -m "docs(spec): $id change $slug" -- "$d/changes/$slug" || die "commit failed"; fi
    G push -q -u origin "$(branch_now)" || die "push failed; fix the remote and run publish again"
    pb="$(pr_body "$id" "$bf")"; url="$(cd "$REPO" && "$HERE/open-pr.sh" --repo-dir "$REPO" --reuse "$title" "$pb" "$BASE")" || die "opening the pull request failed: run publish again"
    ( cd "$REPO" && "$HERE/open-pr.sh" --repo-dir "$REPO" --update "$title" "$pb" >/dev/null ) || echo "spec: warning: could not update the PR title/body" >&2
    echo "spec: published change '$slug' of '$id' (label $(jq -r .label "$REPO/$(cdir_of "$id" "$slug")/change.json")) -> $(printf '%s\n' "$url" | tail -1)"; exit 0
  fi
  [ -f "$(meta_of "$id")" ] || "$0" init-meta "$id" >/dev/null || die "cannot create meta"
  h="$(cur_hash "$id")"; [ -n "$h" ] || die "cannot hash $d"
  n="$(jq '.history | length' "$(meta_of "$id")")"
  b="spec/$id"; [ -z "$cst" ] || b="$(branch_now)"
  if [ "$n" -gt 0 ] && [ "$h" = "$(mget "$id" .contentHash)" ]; then
    # Same content as the recorded version: no new version. The PR may still be missing (an earlier run recorded the version but
    # stopped at the PR step), so when this branch is ahead of the base, push it and open or reuse the PR.
    if [ "$(branch_now)" = "$b" ] && G rev-parse --verify -q "origin/$BASE" >/dev/null && [ "$(G rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)" -gt 0 ]; then
      G push -q -u origin "$b" || die "push failed; fix the remote and run publish again"
      url="$(cd "$REPO" && "$HERE/open-pr.sh" --repo-dir "$REPO" --reuse "$title" "$bf" "$BASE")" || die "opening the pull request failed; the version is already recorded, run publish again (it only opens the PR)"
      echo "spec: '$id' unchanged since version $(mget "$id" .version): pull request $(printf '%s\n' "$url" | tail -1)"; exit 0
    fi
    echo "spec: '$id' unchanged since version $(mget "$id" .version): nothing to publish"; exit 0
  fi
  if [ "$n" -eq 0 ]; then newv="0.1"
  elif [ "$cst" = applied ] && [ "$(jq -r '.history[-1].version' "$(meta_of "$id")")" != "$(mget "$id" .version)" ]; then newv="$(mget "$id" .version)"   # apply already set the revision
  else newv="$(bump "$(mget "$id" .version)" "$brk")"; fi
  [ -n "$cst" ] || ensure_branch "$id" || die "cannot switch to spec/$id (never forced)"
  is_protected "$b" && die "branch $b is protected"
  G add -- "$d" || die "git add failed"
  if ! G diff --cached --quiet -- "$d"; then
    G commit -q -m "docs(spec): $id v$newv" -- "$d" || die "commit failed"
  fi
  # The version is recorded in a commit BEFORE the push and the PR: the PR then always has a diff (even when the content was merged
  # earlier and only the meta is new) and the meta travels with the spec in the same PR. A failed push rolls the meta commit back.
  sha="$(G rev-parse HEAD)"; old="$(cat "$(meta_of "$id")")"
  new="$(printf '%s' "$old" | jq -c --arg v "$newv" --arg h "$h" --arg sha "$sha" --arg at "$(now)" --arg id "$id" \
    --argjson rv "$(jq -c '.evidence // {} | {verdict, contentHash, round, at}' "$REPO/${KIT_DIR:-.sdkit}/work/review/$id/state.json" 2>/dev/null || echo '{}')" \
    '. + {id:$id, version:$v, status:"draft", contentHash:$h, review:$rv} | .history += [{version:$v, sha:$sha, at:$at, contentHash:$h}]')" || die "cannot compute the new meta"
  wmeta "$id" "$new" || die "cannot write the meta"
  restore_meta() { printf '%s\n' "$old" > "$(meta_of "$id")"; G reset -q HEAD -- "$(dir_of "$id")/spec.meta.json" 2>/dev/null || true; }
  if ! { G add -- "$(dir_of "$id")/spec.meta.json" && G commit -q -m "chore(spec): record $id v$newv" -- "$(dir_of "$id")/spec.meta.json"; }; then
    restore_meta; die "recording the version failed; meta restored, run publish again"
  fi
  if ! G push -q -u origin "$b"; then
    G reset -q --soft HEAD~1 && restore_meta
    die "push failed; meta and version untouched, fix the remote and run publish again"
  fi
  url="$(cd "$REPO" && "$HERE/open-pr.sh" --repo-dir "$REPO" --reuse "$title" "$bf" "$BASE")" || die "pushed and recorded $id v$newv, but opening the pull request failed: fix the cause and run publish again (it only opens the PR)"
  url="$(printf '%s\n' "$url" | tail -1)"
  pb="$(pr_body "$id" "$bf")"
  ( cd "$REPO" && "$HERE/open-pr.sh" --repo-dir "$REPO" --update "$title" "$pb" >/dev/null ) || echo "spec: warning: could not update the PR title/body" >&2
  echo "spec: published '$id' v$newv at $sha on $b -> $url" ;;
promote)
  need_dir "$id"; b="$(branch_now)"
  is_protected "$b" && die "refusing on '$b': promote only prepares a commit on the approval PR branch, nobody commits to a protected branch"
  [ -f "$(meta_of "$id")" ] || die "no spec.meta.json for '$id'"
  [ "$(mget "$id" .status)" = approved ] && die "'$id' is already approved at $(mget "$id" .version)"
  [ "$(jq '.history | length' "$(meta_of "$id")")" -gt 0 ] || die "'$id' was never published"
  [ "$(cur_hash "$id")" = "$(mget "$id" .contentHash)" ] || die "the content changed since the last publish: review and publish first"
  [ -z "$(G status --porcelain -- "$(dir_of "$id")")" ] || die "uncommitted changes under $(dir_of "$id")"
  v="$(mget "$id" .version)"; case "$v" in 0.*) v="1.0" ;; esac
  sha="$(G rev-parse HEAD)"
  wmeta "$id" "$(jq -c --arg v "$v" --arg sha "$sha" --arg at "$(now)" '. + {version:$v, status:"approved"} | .history += [{version:$v, sha:$sha, at:$at, contentHash:.contentHash}]' "$(meta_of "$id")")" || die "cannot write the meta"
  G add -- "$(dir_of "$id")/spec.meta.json" && G commit -q -m "chore(spec): promote $id to v$v" -- "$(dir_of "$id")/spec.meta.json" || die "commit failed"
  echo "spec: prepared 'approved v$v' for '$id' on $b. Push it with git push; the Tech Lead's merge is the approval (nothing was pushed or merged)" ;;
approved-sha)
  sha=""; while [ $# -gt 0 ]; do case "$1" in --sha) sha="${2:-}"; shift ;; *) usage ;; esac; shift; done
  [ -n "$sha" ] || usage
  G fetch -q origin "$BASE" 2>/dev/null || true
  full="$(G rev-parse --verify -q "$sha^{commit}")" || die "unknown commit $sha"
  G show-ref --verify -q "refs/remotes/origin/$BASE" || die "no origin/$BASE to check against"
  G merge-base --is-ancestor "$full" "origin/$BASE" || die "$sha is not reachable from origin/$BASE: the approval PR is not merged"
  m="$(G show "$full:$(dir_of "$id")/spec.meta.json" 2>/dev/null)" || die "no spec meta for '$id' at $sha"
  [ "$(printf '%s' "$m" | jq -r .status 2>/dev/null)" = approved ] || die "'$id' is not approved at $sha"
  # Gate (d): a revision of a spec that has changes must be whole. Nothing is generated from an open change merged alone, from a revision with unmerged siblings, or
  # from a base that does not cover its applied changes. A spec without changes/ is not affected.
  if G cat-file -e "$full:$(dir_of "$id")/changes" 2>/dev/null; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    G archive "$full" "$(dir_of "$id")" | tar -x -C "$tmp" 2>/dev/null || die "cannot read '$id' at $sha"
    root="$tmp/$(dir_of "$id")"; ver="$(printf '%s' "$m" | jq -r .version)"; probs=""
    for c in "$root"/changes/*/; do [ -f "${c}change.json" ] && [ "$(jq -r .status "${c}change.json")" = open ] && probs="$probs open change $(basename "$c") is in this revision but not applied;"; done
    while read -r ref sl; do
      [ -n "$ref" ] && [ ! -d "$root/changes/$sl" ] && [ "$(ref_status "$ref" "$id" "$sl")" = open ] || continue
      bv="$(G show "$ref:$(cdir_of "$id" "$sl")/change.json" | jq -r '.base.version')"
      [ "$(printf '%s\n%s\n' "$bv" "$ver" | sort -t. -k1,1n -k2,2n | tail -1)" = "$ver" ] && probs="$probs sibling $sl (written on base $bv) is not merged into this revision;"
    done <<EOF
$(ref_changes "$id")
EOF
    cov="$("$SC" coverage "$root" 2>&1)" || probs="$probs the base does not cover its applied changes ($(printf '%s' "$cov" | head -1));"
    [ "$("$HERE/review.sh" hash "$id" --target "$root" 2>/dev/null)" = "$(printf '%s' "$m" | jq -r .contentHash)" ] || probs="$probs the base content does not match its recorded hash;"
    [ -z "$probs" ] || die "'$id' at $sha is not a consistent revision:$probs no task is generated from it (run spec.sh check $id)"
  fi
  echo "spec: '$id' approved v$(printf '%s' "$m" | jq -r .version) at $full" ;;
*) usage ;;
esac
