#!/usr/bin/env bash
# Jira task contract (F07/F08): the deterministic, mockable side of the tracker integration. Contract: docs/design-role-aware.md ("Task contract").
# Transport is adapters.d/jira.sh (REST via curl). The Jira MCP path is separate: MCP tools are called by the agent skill itself; this script is the
# contract and the validator either way (validate-task needs no network).
#   jira.sh validate-task [FILE|-]        a description with a fenced ```sdkit-task block, or already-normalised JSON (stdin when no file); prints the task JSON
#   jira.sh fetch KEY                     the issue as normalised task JSON (+ key, status, statusCategory); 4 when the contract is not met
#   jira.sh deps-ready KEY                {"ready":bool,"pending":[...]}; exit 0 only when every dependency is in the "done" status category, else 1
#   jira.sh upsert EXTERNAL_ID JSON       idempotent by externalId (label sdkit-ext-<externalId>): create the subtask or update it; never sets an assignee
#   jira.sh comment KEY TEXT | transition KEY STATUS
#   jira.sh change-request KEY JSON       a spec-change request issue (JSON: reason [, section, proposal, specId, specSha]) linked as blocking KEY
# Settings: see adapters.d/jira.sh, plus JIRA_PROJECT (default: the parent's project), JIRA_SUBTASK_TYPE (Sub-task), JIRA_CHANGE_TYPE (Task), JIRA_LINK_TYPE (Blocks).
# Exit: 0 ok, 1 deps-ready: not ready, 2 usage, 3 egress/auth, 4 contract invalid, 5 not found / external failure. A failed call prints no success output.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$here/env.sh" ] && { . "$here/env.sh" 2>/dev/null; SDKIT_ENV_QUIET=1 sdkit_env_load "$top" 2>/dev/null; }
command -v jq >/dev/null || { echo "jira.sh needs jq" >&2; exit 2; }
AD="$here/../adapters.d/jira.sh"; [ -x "$top/${KIT_DIR:-.sdkit}/adapters.d/jira.sh" ] && AD="$top/${KIT_DIR:-.sdkit}/adapters.d/jira.sh"
export JIRA_BASE_URL="${JIRA_BASE_URL:-}" JIRA_EGRESS="${JIRA_EGRESS:-}" JIRA_TOKEN_ENV="${JIRA_TOKEN_ENV:-}" JIRA_USER="${JIRA_USER:-}" JIRA_API_VERSION="${JIRA_API_VERSION:-2}"
[ -n "$JIRA_TOKEN_ENV" ] || unset JIRA_TOKEN_ENV
die() { echo "jira: $1" >&2; exit "${2:-5}"; }
# The token may be written in the personal, git-ignored sdkit.local.env (JIRA_API_TOKEN=..., or the variable named by JIRA_TOKEN_ENV): the
# settings files are loaded as shell variables, so export it for the adapter. Never accepted from the committed sdkit.env, and refused when
# sdkit.local.env is inside a git work tree but not ignored. A token already in the environment needs none of this.
_kd="$top/${KIT_DIR:-.sdkit}"; _tv="${JIRA_TOKEN_ENV:-JIRA_API_TOKEN}"; case "$_tv" in ''|*[!A-Za-z0-9_]*) _tv="" ;; esac
if [ -n "$_tv" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?$_tv=" "$_kd/sdkit.local.env" 2>/dev/null; then
  ! grep -Eq "^[[:space:]]*(export[[:space:]]+)?$_tv=" "$_kd/sdkit.env" 2>/dev/null || die "$_tv is set in the shared sdkit.env: a token must never be committed. Remove it there (rotate the token) and keep it only in sdkit.local.env" 3
  if git -C "$top" rev-parse --is-inside-work-tree >/dev/null 2>&1 && ! git -C "$top" check-ignore -q "$_kd/sdkit.local.env" 2>/dev/null; then
    die "sdkit.local.env holds the token but is not git-ignored: add it to .gitignore first" 3
  fi
  [ -z "${!_tv:-}" ] || export "$_tv"
fi
ad() { "$AD" "$@"; }   # stdout = response body; the adapter's exit code is the caller's

PROBLEMS='def nes: type == "string" and test("\\S");
  def sarr: type == "array" and all(.[]; nes);
  . as $t | if ($t | type) != "object" then ["not a JSON object"] else [
  (if ($t.specId | nes) and ($t.externalId | nes) and ($t.externalId | startswith($t.specId + ":")) and (($t.externalId | length) > ($t.specId | length) + 1) then empty else "externalId (<specId>:<taskKey>) / specId" end),
  (if ($t.specVersion | type) == "number" or ($t.specVersion | nes) then empty else "specVersion" end),
  (if ($t.specSha | type) == "string" and ($t.specSha | test("^[0-9a-f]{40}$")) then empty else "specSha (40 hex)" end),
  (if ($t.acceptanceCriteria | sarr) and ($t.acceptanceCriteria | length) > 0 then empty else "acceptanceCriteria (non-empty array)" end),
  (if $t.risk == "low" or $t.risk == "medium" or $t.risk == "high" then empty else "risk (low|medium|high)" end),
  (if $t.dependencies | sarr then empty else "dependencies (array)" end),
  (if ($t.scope | sarr) and ($t.scope | length) > 0 then empty else "scope (non-empty array)" end),
  (if $t.parent | nes then empty else "parent" end)] end | join(", ")'

# task_from <text|json>: print the task object found in a description (fenced sdkit-task block) or the JSON itself
task_from() {
  local in="$1" blk
  if printf '%s' "$in" | jq -e 'type == "object"' >/dev/null 2>&1; then printf '%s' "$in" | jq -c .; return 0; fi
  blk="$(printf '%s\n' "$in" | tr -d '\r' | awk '/^[ \t]*```[ \t]*sdkit-task[ \t]*$/{f=1;next} f&&/^[ \t]*```[ \t]*$/{exit} f{print}')"
  [ -n "$blk" ] || return 1
  printf '%s' "$blk" | jq -c 'select(type == "object")' 2>/dev/null
}
check() {  # <task json>: exit 4 naming the failing fields
  local p; p="$(printf '%s' "$1" | jq -r "$PROBLEMS" 2>/dev/null)" || die "unreadable task JSON" 4
  [ -z "$p" ] || die "contract invalid, missing or malformed: $p" 4
}
desc_text() { jq -r 'if (.fields.description | type) == "string" then .fields.description elif (.fields.description | type) == "object" then ([.fields.description | .. | .text? // empty] | join("\n")) else "" end'; }
normalise() {  # <issue json> -> task JSON + key/status; exit 4 if the contract is not met
  local iss="$1" d t
  d="$(printf '%s' "$iss" | desc_text)"
  t="$(task_from "$d")" || die "$(printf '%s' "$iss" | jq -r .key): no sdkit-task block in the description" 4
  [ -n "$t" ] || die "$(printf '%s' "$iss" | jq -r .key): sdkit-task block is not a JSON object" 4
  t="$(jq -nc --argjson t "$t" --argjson i "$iss" '$t + (if $i.fields.parent.key then {parent: $i.fields.parent.key} else {} end)')"
  check "$t"
  jq -nc --argjson t "$t" --argjson i "$iss" '$t + {key: $i.key, status: ($i.fields.status.name // null), statusCategory: ($i.fields.status.statusCategory.key // null)}'
}
block_of() { printf '%s' "$1" | jq -c '{externalId, specId, specVersion, specSha, acceptanceCriteria, risk, dependencies, scope, parent}'; }
desc_of() { printf '%s\n\n```sdkit-task\n%s\n```\n' "${2:-}" "$(block_of "$1" | jq .)"; }
label_of() { printf 'sdkit-ext-%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.:-' '_')"; }
projkey() { printf '%s' "${JIRA_PROJECT:-${1%%-*}}"; }

verb="${1:-}"; shift 2>/dev/null || true
case "$verb" in
  validate-task)
    if [ -n "${1:-}" ] && [ "$1" != - ]; then [ -f "$1" ] || die "no such file: $1" 2; in="$(cat "$1")"; else in="$(cat)"; fi
    t="$(task_from "$in")" || die "no sdkit-task block and not JSON" 4
    [ -n "$t" ] || die "sdkit-task block is not a JSON object" 4
    check "$t"; printf '%s\n' "$t" ;;
  fetch) [ -n "${1:-}" ] || die "usage: fetch KEY" 2
    iss="$(ad get "$1")" || exit $?
    out="$(normalise "$iss")" || exit $?; printf '%s\n' "$out" ;;
  deps-ready) [ -n "${1:-}" ] || die "usage: deps-ready KEY" 2
    iss="$(ad get "$1")" || exit $?
    t="$(normalise "$iss")" || exit $?
    pending='[]'
    for d in $(printf '%s' "$t" | jq -r '.dependencies[]'); do
      di="$(ad get "$d")" || exit $?
      [ "$(printf '%s' "$di" | jq -r '.fields.status.statusCategory.key // ""')" = done ] || pending="$(jq -c --arg d "$d" --arg s "$(printf '%s' "$di" | jq -r '.fields.status.name // "?"')" '. + [{key: $d, status: $s}]' <<< "$pending")"
    done
    jq -nc --argjson p "$pending" --arg k "$1" '{key: $k, ready: ($p | length == 0), pending: $p}'
    [ "$pending" = '[]' ] ;;
  upsert) [ -n "${1:-}" ] && [ -n "${2:-}" ] || die "usage: upsert EXTERNAL_ID JSON" 2
    ext="$1"; t="$(task_from "$2")" || die "task JSON is not an object" 4; [ -n "$t" ] || die "task JSON is not an object" 4
    check "$t"; [ "$(printf '%s' "$t" | jq -r .externalId)" = "$ext" ] || die "externalId argument does not match the JSON" 4
    lbl="$(label_of "$ext")"; parent="$(printf '%s' "$t" | jq -r .parent)"
    summary="$(printf '%s' "$t" | jq -r --arg e "$ext" '(.summary // $e) | tostring')"; note="$(printf '%s' "$2" | jq -r '.description? // ""' 2>/dev/null)"
    desc="$(desc_of "$t" "$note")"
    found="$(ad search "labels = \"$lbl\"")" || exit $?
    key="$(printf '%s' "$found" | jq -r '[.issues[]? | select((.fields.labels // []) | index($lbl))] | .[0].key // empty' --arg lbl "$lbl" 2>/dev/null)"
    # (the label is re-checked here so a loose search match can never be updated by mistake)
    if [ -n "$key" ]; then
      [ "$(printf '%s' "$found" | jq '[.issues[]?] | length')" -le 1 ] || echo "jira: warning: several issues carry $lbl; updating $key" >&2
      ad update "$key" "$(jq -nc --arg s "$summary" --arg d "$desc" '{fields: {summary: $s, description: $d}}')" >/dev/null || exit $?
      act=updated
    else
      body="$(jq -nc --arg p "$(projkey "$parent")" --arg ty "${JIRA_SUBTASK_TYPE:-Sub-task}" --arg par "$parent" --arg s "$summary" --arg d "$desc" --arg l "$lbl" \
        '{fields: {project: {key: $p}, issuetype: {name: $ty}, parent: {key: $par}, summary: $s, description: $d, labels: [$l, "sdkit"]}}')"
      r="$(ad create "$body")" || exit $?
      key="$(printf '%s' "$r" | jq -r '.key // empty' 2>/dev/null)"; [ -n "$key" ] || die "create returned no issue key" 5
      act=created
    fi
    jq -nc --arg k "$key" --arg e "$ext" --arg a "$act" '{key: $k, externalId: $e, action: $a}' ;;
  comment) [ -n "${1:-}" ] && [ -n "${2:-}" ] || die "usage: comment KEY TEXT" 2
    ad comment "$1" "$2" >/dev/null || exit $?; jq -nc --arg k "$1" '{key: $k, commented: true}' ;;
  transition) [ -n "${1:-}" ] && [ -n "${2:-}" ] || die "usage: transition KEY STATUS" 2
    tr="$(ad transitions "$1")" || exit $?
    id="$(printf '%s' "$tr" | jq -r --arg s "$2" '[.transitions[]? | select((.name | ascii_downcase) == ($s | ascii_downcase) or ((.to.name // "") | ascii_downcase) == ($s | ascii_downcase) or .id == $s)] | .[0].id // empty')"
    [ -n "$id" ] || die "$1: no transition to '$2' from its current status" 4
    ad transition "$1" "$id" >/dev/null || exit $?; jq -nc --arg k "$1" --arg s "$2" '{key: $k, transitioned: $s}' ;;
  change-request) [ -n "${1:-}" ] && [ -n "${2:-}" ] || die "usage: change-request KEY JSON" 2
    key="$1"; printf '%s' "$2" | jq -e 'type == "object" and (.reason | type == "string" and test("\\S"))' >/dev/null 2>&1 || die "change request needs a JSON object with a non-empty reason" 4
    printf '%s' "$key" | grep -Eq '^[A-Z][A-Z0-9_]*-[0-9]+$' || die "bad issue key" 2
    blk="$(printf '%s' "$2" | jq -c --arg k "$key" '{blocked: $k, reason, section: (.section // null), proposal: (.proposal // null), specId: (.specId // null), specSha: (.specSha // null)}')"
    summary="[spec-change] $key: $(printf '%s' "$2" | jq -r '.reason' | head -n1 | cut -c1-120)"
    desc="$(printf 'Spec change requested by sdkit while implementing %s. Implementation is blocked until the spec is revised and approved.\n\n```sdkit-change-request\n%s\n```\n' "$key" "$(printf '%s' "$blk" | jq .)")"
    body="$(jq -nc --arg p "$(projkey "$key")" --arg ty "${JIRA_CHANGE_TYPE:-Task}" --arg s "$summary" --arg d "$desc" --arg b "sdkit-blocked-$key" \
      '{fields: {project: {key: $p}, issuetype: {name: $ty}, summary: $s, description: $d, labels: ["sdkit", "sdkit-spec-change", $b]}}')"
    r="$(ad create "$body")" || exit $?
    crk="$(printf '%s' "$r" | jq -r '.key // empty' 2>/dev/null)"; [ -n "$crk" ] || die "create returned no issue key" 5
    # the change request blocks the subtask: Jira "Blocks" has outward "blocks" / inward "is blocked by"
    ad link "$(jq -nc --arg ty "${JIRA_LINK_TYPE:-Blocks}" --arg a "$crk" --arg b "$key" '{type: {name: $ty}, inwardIssue: {key: $b}, outwardIssue: {key: $a}}')" >/dev/null \
      || { echo "jira: change request $crk was created but could not be linked to $key" >&2; exit 5; }
    jq -nc --arg k "$crk" --arg b "$key" '{key: $k, blocks: $b, kind: "spec-change"}' ;;
  *) echo "usage: jira.sh validate-task|fetch|deps-ready|upsert|comment|transition|change-request ..." >&2; exit 2 ;;
esac
