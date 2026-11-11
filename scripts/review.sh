#!/usr/bin/env bash
# Deterministic half of the spec review (F04). The review itself is done by FRESH subagents (EGM `egm-review-loop`, or the `spec-reviewer` role through
# run-role.sh); this script only keeps the evidence honest. Contract: docs/design-role-aware.md, section "Review adapter".
#   review.sh plan <artifact> [--json]      print the resolved rubric: reviewers, standards (reviewer=standard), context files. Source: <project-dir>/review.d/<artifact>.env,
#                                           else the kit's templates/review.d/<artifact>.env (shipped: prd, adr, feature-spec). Keys: REVIEWERS, STANDARDS, CONTEXT.
#   review.sh hash <id> [--target P]        the contentHash of the document (sha256 over the sorted files: sha256 + relative path each). Excludes spec.meta.json and acceptances.jsonl
#   review.sh begin <id> [--target P]       open a review round: remember the contentHash, count the round. Past SPEC_REVIEW_MAX_ROUNDS (default 4) it refuses (exit 3): no
#                                           unbounded retry, a person decides (raise the setting or change the document's approach).
#   review.sh record <id> --verdict PASS|BLOCK|PARTIAL|NOT_RUN --isolation fresh|none [--findings FILE]
#                                           store the round's evidence, bound to the contentHash seen at `begin`. One record per round. FILE is a JSON array
#                                           [{id, severity: BLOCKER|MAJOR|MINOR, evidence, disposition: open|fixed|accepted}] or the spec-reviewer lines
#                                           `- <id> | <SEVERITY> | <where> | <text>` (disposition open). Malformed findings store nothing (exit 2).
#                                           isolation=none can never be PASS (rejected), a PASS with an open BLOCKER/MAJOR is rejected, and a finding marked `accepted`
#                                           needs a valid acceptance. A host with no fresh-subagent facility records NOT_RUN.
#   review.sh check <id>                    exit 0 only when the latest evidence is PASS, isolation=fresh, its hash equals the document's CURRENT hash (an edit makes
#                                           it stale) and no BLOCKER/MAJOR is open. Otherwise exit 1 and the reason on stdout.
#   review.sh accept <id> <finding-id> --who W --why Y
#                                           a person accepts one finding of the latest evidence. Keyed on finding id + a hash of its text: a changed finding is not
#                                           accepted any more. Append-only <target>/acceptances.jsonl (committed with the document). Nothing is accepted by default.
# Where things live: the document is specs/<id>/ (SPECS_DIR, default `specs`; or --target, remembered from `begin`). Evidence and the round counter are local state in
# <project-dir>/work/review/<id>/state.json (the project dir comes from scripts/env.sh); the acceptances are NOT local: <target>/acceptances.jsonl, or
# <file>.acceptances.jsonl beside a single-file target. Both are outside the hash.
# Exit: 0 ok, 1 not satisfied / refused by a rule, 2 usage or malformed input, 3 round cap reached.
#
# UNVERIFIED: EGM `egm-review-loop` has `disable-model-invocation: true` in its frontmatter. Whether another skill (generate-specs / update-specs) may invoke it, and
# whether it runs end to end from here, has NOT been verified. Names used in review.d (design_critic, structural, style, comprehension, implementation_readiness,
# heilmeier-standard, feature-spec-standard, implementation-readiness-standard ...) were checked against egm 0.1.1 files only. Where EGM cannot be invoked, run the
# `spec-reviewer` role and record NOT_RUN or the verdict it gives; never PASS without a fresh isolated reviewer.
set -u
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/env.sh" || { echo "review: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }
sdkit_env_load "$PROJECT_DIR"
MAX_ROUNDS="${SPEC_REVIEW_MAX_ROUNDS:-4}"; case "$MAX_ROUNDS" in ''|*[!0-9]*) MAX_ROUNDS=4 ;; esac
SPEC_DIR="${SPECS_DIR:-specs}"
WORK="$PROJECT_DIR/$KIT_DIR/work/review"
command -v jq >/dev/null 2>&1 || { echo "review: jq is required" >&2; exit 2; }

die()   { echo "review: $*" >&2; exit "${RC:-2}"; }
usage() { echo "usage: review.sh plan <artifact> [--json] | hash <id> | begin <id> | record <id> --verdict V --isolation I [--findings F] | check <id> | accept <id> <finding-id> --who W --why Y" >&2; exit 2; }
now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
okname() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }

# target_path <id> <override>: the document (a directory or one file)
target_path() {
  local t="$2"
  [ -n "$t" ] || t="$(jq -r '.target // empty' "$WORK/$1/state.json" 2>/dev/null)"
  [ -n "$t" ] || t="$SPEC_DIR/$1"
  case "$t" in /*) ;; *) t="$PROJECT_DIR/$t" ;; esac
  [ -e "$t" ] || { echo "review: no document at $t" >&2; return 1; }
  printf '%s\n' "$t"
}
# content_hash <target>
content_hash() {
  local t="$1" d f list
  if [ -d "$t" ]; then d="$t"; list="$(cd "$d" && find . -type f ! -name spec.meta.json ! -name acceptances.jsonl ! -name .DS_Store | LC_ALL=C sort)"
  else d="$(dirname "$t")"; list="./$(basename "$t")"; fi
  [ -n "$list" ] || { echo "review: $t has no files to hash" >&2; return 1; }
  while IFS= read -r f; do printf '%s  %s\n' "$(cd "$d" && sdkit_sha256 < "$f")" "$f"; done <<EOF | sdkit_sha256
$list
EOF
}
acc_file() { if [ -d "$1" ]; then printf '%s/acceptances.jsonl\n' "$1"; else printf '%s.acceptances.jsonl\n' "$1"; fi; }
# fhash <finding json>: hash of what a finding says (id, severity, evidence); disposition is not part of it
fhash() { printf '%s' "$1" | jq -c '[.id,.severity,.evidence]' | sdkit_sha256; }
# accepted_ok <acceptances file> <id> <hash>
accepted_ok() { [ -f "$1" ] && jq -e --arg i "$2" --arg h "$3" 'select(.finding == $i and .finding_sha256 == $h)' "$1" >/dev/null 2>&1; }
# blocking <findings json> <acceptances file>: ids of BLOCKER/MAJOR findings still open (open, or `accepted` without a valid acceptance)
blocking() {
  local n i f id disp out=""
  n="$(printf '%s' "$1" | jq 'length')"; i=0
  while [ "$i" -lt "$n" ]; do
    f="$(printf '%s' "$1" | jq -c ".[$i]")"; i=$((i + 1))
    case "$(printf '%s' "$f" | jq -r .severity)" in BLOCKER|MAJOR) ;; *) continue ;; esac
    id="$(printf '%s' "$f" | jq -r .id)"; disp="$(printf '%s' "$f" | jq -r .disposition)"
    case "$disp" in
      fixed) ;;
      accepted) accepted_ok "$2" "$id" "$(fhash "$f")" || out="$out $id" ;;
      *) out="$out $id" ;;
    esac
  done
  printf '%s\n' "${out# }"
}
# load_findings <file>: a validated, normalised JSON array on stdout; the problem on stderr and return 1
load_findings() {
  local raw j
  [ -f "$1" ] || { echo "findings file '$1' not found" >&2; return 1; }
  raw="$(cat "$1")"
  case "$(printf '%s' "$raw" | tr -d '[:space:]' | cut -c1)" in
    '['|'{') j="$(printf '%s' "$raw" | jq -c . 2>/dev/null)" || { echo "findings are not valid JSON" >&2; return 1; } ;;
    *) j="$(printf '%s\n' "$raw" | tr -d '\r' | awk -F'|' '
         /^[ \t]*[-*][ \t]+[A-Za-z0-9._-]+[ \t]*\|/ { sub(/^[ \t]*[-*][ \t]+/, "", $0); n = split($0, p, "|"); if (n < 4) { bad = 1; next }
           t = p[4]; for (k = 5; k <= n; k++) t = t "|" p[k]
           gsub(/^[ \t]+|[ \t]+$/, "", p[1]); gsub(/^[ \t]+|[ \t]+$/, "", p[2]); gsub(/^[ \t]+|[ \t]+$/, "", p[3]); gsub(/^[ \t]+|[ \t]+$/, "", t)
           print p[1] "\t" toupper(p[2]) "\t" p[3] ": " t; next }
         /^[ \t]*[-*][ \t]/ { bad = 1 }
         END { if (bad) exit 3 }' \
        | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")) | map({id: .[0], severity: .[1], evidence: .[2], disposition: "open"})')" \
        || { echo "findings lines must read '- <id> | <BLOCKER|MAJOR|MINOR> | <where> | <text>'" >&2; return 1; } ;;
  esac
  printf '%s' "$j" | jq -e '
    type == "array" and all(.[]; type == "object"
      and (.id | type == "string" and length > 0)
      and (.severity | IN("BLOCKER","MAJOR","MINOR"))
      and (.evidence | type == "string" and (gsub("\\s"; "") | length > 0))
      and (.disposition | IN("open","fixed","accepted")))
    and ([.[].id] | length == (unique | length))' >/dev/null 2>&1 \
    || { echo "malformed findings: need an array of {id (unique), severity BLOCKER|MAJOR|MINOR, evidence (non-empty), disposition open|fixed|accepted}" >&2; return 1; }
  printf '%s\n' "$j"
}
save_state() { local tmp; tmp="$(mktemp "$WORK/$1/.state.XXXXXX")" && printf '%s\n' "$2" > "$tmp" && mv "$tmp" "$WORK/$1/state.json"; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
case "$cmd" in
plan)
  art="${1:-}"; shift; json=0; [ "${1:-}" = --json ] && json=1
  okname "$art" || usage
  rf="$PROJECT_DIR/$KIT_DIR/review.d/$art.env"; [ -f "$rf" ] || rf="$PLUGIN_ROOT/templates/review.d/$art.env"
  [ -f "$rf" ] || die "no rubric for '$art' (looked for $PROJECT_DIR/$KIT_DIR/review.d/$art.env and the kit's templates/review.d/$art.env)"
  REVIEWERS=""; STANDARDS=""; CONTEXT=""; SDKIT_ENV_QUIET=1 sdkit_env_load_file "$rf"
  [ -n "${REVIEWERS// /}" ] || die "$rf sets no REVIEWERS"
  for p in $STANDARDS; do
    case "$p" in *=?*) ;; *) die "$rf: STANDARDS entry '$p' is not reviewer=standard" ;; esac
    case " $REVIEWERS " in *" ${p%%=*} "*) ;; *) die "$rf: STANDARDS names '${p%%=*}', which is not in REVIEWERS" ;; esac
  done
  if [ "$json" = 1 ]; then
    jq -n --arg a "$art" --arg s "$rf" --arg r "$REVIEWERS" --arg st "$STANDARDS" --arg c "$CONTEXT" \
      '{artifact:$a, source:$s, reviewers:($r|split(" ")|map(select(length>0))), standards:($st|split(" ")|map(select(length>0)|split("=")|{key:.[0],value:.[1]})|from_entries), context:($c|split(" ")|map(select(length>0)))}'
  else
    echo "artifact:  $art"; echo "source:    $rf"; echo "reviewers: $REVIEWERS"; echo "standards: ${STANDARDS:-none}"; echo "context:   ${CONTEXT:-none}"
  fi ;;
hash|begin)
  id="${1:-}"; shift; okname "$id" || usage; tgt=""
  while [ $# -gt 0 ]; do case "$1" in --target) tgt="${2:-}"; shift ;; *) usage ;; esac; shift; done
  t="$(target_path "$id" "$tgt")" || exit 2
  h="$(content_hash "$t")" || exit 2
  if [ "$cmd" = hash ]; then echo "$h"; exit 0; fi
  mkdir -p "$WORK/$id" || die "cannot create $WORK/$id"; sdkit_lock "$WORK/$id/state.json"
  prev=0; [ -f "$WORK/$id/state.json" ] && prev="$(jq -r '.round // 0' "$WORK/$id/state.json" 2>/dev/null || echo 0)"
  if [ "$prev" -ge "$MAX_ROUNDS" ]; then
    sdkit_unlock "$WORK/$id/state.json"
    echo "review: round cap reached for '$id' ($prev of SPEC_REVIEW_MAX_ROUNDS=$MAX_ROUNDS used). No further automatic round: a person decides (rework the document by hand or raise SPEC_REVIEW_MAX_ROUNDS)." >&2; exit 3
  fi
  rel="$t"; case "$t" in "$PROJECT_DIR"/*) rel="${t#"$PROJECT_DIR"/}" ;; esac
  st="$( { [ -f "$WORK/$id/state.json" ] && cat "$WORK/$id/state.json"; } || echo '{}')"
  save_state "$id" "$(printf '%s' "$st" | jq -c --arg id "$id" --arg t "$rel" --arg h "$h" --arg at "$(now)" --argjson r "$((prev + 1))" \
    '. + {id:$id, target:$t, contentHash:$h, round:$r, pending:true, begunAt:$at}')"
  sdkit_unlock "$WORK/$id/state.json"
  echo "review: round $((prev + 1)) of $MAX_ROUNDS opened for '$id' at $h" ;;
record)
  id="${1:-}"; shift; okname "$id" || usage; verdict=""; iso=""; ff=""
  while [ $# -gt 0 ]; do case "$1" in --verdict) verdict="${2:-}"; shift ;; --isolation) iso="${2:-}"; shift ;; --findings) ff="${2:-}"; shift ;; *) usage ;; esac; shift; done
  case "$verdict" in PASS|BLOCK|PARTIAL|NOT_RUN) ;; *) die "--verdict must be PASS|BLOCK|PARTIAL|NOT_RUN" ;; esac
  case "$iso" in fresh|none) ;; *) die "--isolation must be fresh|none" ;; esac
  [ "$verdict" = PASS ] && [ "$iso" = none ] && { echo "review: isolation=none can never be PASS (a review in the author's context is not a review); record NOT_RUN or run a fresh reviewer" >&2; exit 2; }
  sf="$WORK/$id/state.json"; [ -f "$sf" ] || die "no review round open for '$id': run review.sh begin first"
  if [ -n "$ff" ]; then fj="$(load_findings "$ff")" || exit 2
  elif [ "$verdict" = NOT_RUN ]; then fj='[]'
  else die "--findings FILE is required (an empty array [] is a review with no findings)"; fi
  [ "$(jq -r '.pending // false' "$sf")" = true ] || { echo "review: round $(jq -r .round "$sf") of '$id' already has its evidence; begin a new round" >&2; exit 1; }
  t="$(target_path "$id" "")" || exit 2
  bl="$(blocking "$fj" "$(acc_file "$t")")"
  if [ "$verdict" = PASS ] && [ -n "$bl" ]; then echo "review: PASS contradicts the findings: BLOCKER/MAJOR still open or accepted without a valid acceptance:$bl" >&2; exit 2; fi
  sdkit_lock "$sf"
  save_state "$id" "$(jq -c --arg v "$verdict" --arg i "$iso" --argjson f "$fj" --arg at "$(now)" \
    '. + {pending:false, evidence:{verdict:$v, isolation:$i, contentHash:.contentHash, round:.round, at:$at, findings:$f}}' "$sf")"
  sdkit_unlock "$sf"
  echo "review: $verdict ($iso) recorded for '$id' round $(jq -r .round "$sf"), bound to $(jq -r .contentHash "$sf")" ;;
check)
  id="${1:-}"; okname "$id" || usage; sf="$WORK/$id/state.json"
  fail() { echo "review: NOT approved: $*"; exit 1; }
  [ -f "$sf" ] && [ "$(jq -r '.evidence // empty | .verdict // empty' "$sf")" != "" ] || fail "no review evidence for '$id'"
  t="$(target_path "$id" "")" || fail "the document is gone"
  cur="$(content_hash "$t")" || fail "cannot hash the document"
  v="$(jq -r .evidence.verdict "$sf")"; iso="$(jq -r .evidence.isolation "$sf")"; eh="$(jq -r .evidence.contentHash "$sf")"
  [ "$eh" = "$cur" ] || fail "stale: the document changed after the review (reviewed $eh, now $cur); begin a new round"
  [ "$iso" = fresh ] || fail "isolation is '$iso', not fresh"
  [ "$v" = PASS ] || fail "latest verdict is $v"
  bl="$(blocking "$(jq -c .evidence.findings "$sf")" "$(acc_file "$t")")"
  [ -z "$bl" ] || fail "BLOCKER/MAJOR still open:$bl"
  echo "review: approved '$id' (PASS, fresh, round $(jq -r .evidence.round "$sf"), $cur)" ;;
accept)
  id="${1:-}"; fid="${2:-}"; shift 2 2>/dev/null || usage; okname "$id" || usage; [ -n "$fid" ] || usage; who=""; why=""
  while [ $# -gt 0 ]; do case "$1" in --who) who="${2:-}"; shift ;; --why) why="${2:-}"; shift ;; *) usage ;; esac; shift; done
  [ -n "${who//[[:space:]]/}" ] && [ -n "${why//[[:space:]]/}" ] || die "accept needs --who \"<who accepts>\" and --why \"<reason>\" (nothing is accepted by default)"
  sf="$WORK/$id/state.json"; [ -f "$sf" ] || die "no review evidence for '$id'"
  f="$(jq -c --arg i "$fid" '(.evidence.findings // [])[] | select(.id == $i)' "$sf")"
  [ -n "$f" ] || { echo "review: finding '$fid' is not in the latest evidence of '$id'" >&2; exit 1; }
  t="$(target_path "$id" "")" || exit 2; af="$(acc_file "$t")"
  line="$(jq -nc --arg ts "$(now)" --arg id "$id" --arg fi "$fid" --arg h "$(fhash "$f")" --arg s "$(printf '%s' "$f" | jq -r .severity)" --arg w "$who" --arg y "$why" --arg ch "$(jq -r .evidence.contentHash "$sf")" \
    '{v:1, ts:$ts, id:$id, finding:$fi, finding_sha256:$h, severity:$s, who:$w, why:$y, contentHash:$ch}')"
  sdkit_lock "$af"; printf '%s\n' "$line" >> "$af"; sdkit_unlock "$af"
  echo "review: finding $fid accepted by $who (recorded in $af); this binds the finding as written now" ;;
*) usage ;;
esac
