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
#                               exit 0 only when S is reachable from origin/<base> and the spec meta AT S says status approved; prints id, version, sha.
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
usage() { echo "usage: spec.sh init-meta <id> | hash <id> | status <id> | changed <id> | branch <id> | publish <id> --title T --body-file F [--breaking] | promote <id> | approved-sha <id> --sha S" >&2; exit 2; }
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

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
id="${1:-}"; [ $# -gt 0 ] && shift
okname "$id" || usage
case "$cmd" in
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
  "$HERE/review.sh" check "$id" || die "publish needs a fresh PASS review of the current content (review.sh check $id)"
  bad="$(prespec_staged)"; [ -z "$bad" ] || die "refusing: staged paths inside the pre-spec directory '$PRESPEC' (never committed):
$bad"
  [ -f "$(meta_of "$id")" ] || "$0" init-meta "$id" >/dev/null || die "cannot create meta"
  h="$(cur_hash "$id")"; [ -n "$h" ] || die "cannot hash $d"
  n="$(jq '.history | length' "$(meta_of "$id")")"
  b="spec/$id"
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
  if [ "$n" -eq 0 ]; then newv="0.1"; else newv="$(bump "$(mget "$id" .version)" "$brk")"; fi
  ensure_branch "$id" || die "cannot switch to spec/$id (never forced)"
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
  if [ "${PR_HOST:-}" = github ] && command -v gh >/dev/null 2>&1; then
    ( cd "$REPO" && gh pr edit "$b" --title "$title" --body-file "$bf" >/dev/null ) || echo "spec: warning: could not update the PR title/body" >&2
  fi
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
  echo "spec: '$id' approved v$(printf '%s' "$m" | jq -r .version) at $full" ;;
*) usage ;;
esac
