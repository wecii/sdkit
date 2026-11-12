#!/usr/bin/env bash
# Jira REST transport for scripts/jira.sh (F07/F08). Deterministic and mockable (tests use a fake curl). Off unless configured. Contract: docs/design-role-aware.md.
# (The Jira MCP path is different: MCP tools are called by the agent skill itself; this adapter and scripts/jira.sh are the contract and the validator.)
#   jira.sh capabilities | get KEY | search JQL | create JSON | update KEY JSON | comment KEY TEXT | transitions KEY | transition KEY ID | link JSON
# Prints the raw Jira response body on stdout on success (2xx). Settings (sdkit.local.env / environment; the token is never read from a repo file):
#   JIRA_BASE_URL       e.g. https://acme.atlassian.net                           (required)
#   JIRA_EGRESS=allow   REQUIRED: task text leaves this machine. No value, no request.
#   JIRA_TOKEN_ENV      NAME of the variable holding the token (default JIRA_API_TOKEN). The variable is the environment, or JIRA_API_TOKEN=... in the
#                       personal git-ignored sdkit.local.env (scripts/jira.sh exports it); never in the committed sdkit.env
#   JIRA_USER           if set: Basic auth user:token (Jira Cloud); else Bearer token (Data Center PAT)
#   JIRA_API_VERSION    REST version, default 2 (description is plain text);  JIRA_SEARCH_PATH  default search (search/jql on *.atlassian.net, where the old /search was removed)
# The token goes to curl on stdin (-K -), never on the command line. Exit: 0 ok, 2 usage, 3 egress off / no token / 401 / 403, 5 not found or any other failure.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verb="${1:-}"; shift 2>/dev/null || true
case "$verb" in
  capabilities) echo '{"noninteractive":"declared","tool_use":"none","model_selection":"none","usage_reporting":"none","structured_output":"none","cancellation":"none","timeout":"kit","cost_reporting":"none"}'; exit 0 ;;
  get|search|create|update|comment|transitions|transition|link) ;;
  *) exit 3 ;;
esac
tok=""
die() { local m="jira adapter: $1"; [ -n "$tok" ] && m="${m//"$tok"/***}"; m="$(printf '%s' "$m" | "$here/../scripts/redact.sh")"; echo "$m" >&2; exit "${2:-5}"; }
keyok() { case "$1" in [A-Z]*-[0-9]*) case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; esac; return 0 ;; esac; return 1; }
[ "${JIRA_EGRESS:-}" = allow ] || die "JIRA_EGRESS=allow is not set: task text would leave this machine, so nothing was sent" 3
base="${JIRA_BASE_URL:-}"; case "$base" in http://*|https://*) ;; *) die "JIRA_BASE_URL is not set (http[s]://host)" 2 ;; esac
tv="${JIRA_TOKEN_ENV:-JIRA_API_TOKEN}"; case "$tv" in ''|*[!A-Za-z0-9_]*) die "JIRA_TOKEN_ENV must be a variable NAME such as JIRA_API_TOKEN, not the token itself: put the token in sdkit.local.env as JIRA_API_TOKEN=... (or export it)" 2 ;; esac
tok="${!tv:-}"; [ -n "$tok" ] || die "no token: the variable named by JIRA_TOKEN_ENV ($tv) is empty" 3
api="${base%/}/rest/api/${JIRA_API_VERSION:-2}"
method=GET; path=""; body=""
case "$verb" in
  get) keyok "${1:-}" || die "bad issue key" 2; path="issue/$1?fields=summary,description,status,parent,labels,issuetype" ;;
  search) [ -n "${1:-}" ] || die "no JQL" 2; method=POST; path="${JIRA_SEARCH_PATH:-}"; if [ -z "$path" ]; then path=search; [[ "$base" == *.atlassian.net* ]] && path=search/jql; fi; body="$(jq -nc --arg j "$1" '{jql: $j, fields: ["summary","labels","status"], maxResults: 10}')" ;;
  create) [ -n "${1:-}" ] || die "no body" 2; method=POST; path=issue; body="$1" ;;
  update) keyok "${1:-}" || die "bad issue key" 2; method=PUT; path="issue/$1"; body="${2:-}"; [ -n "$body" ] || die "no body" 2 ;;
  comment) keyok "${1:-}" || die "bad issue key" 2; [ -n "${2:-}" ] || die "no text" 2; method=POST; path="issue/$1/comment"; if [ "${JIRA_API_VERSION:-2}" = 3 ]; then body="$(jq -nc --arg t "$2" '{body: {version: 1, type: "doc", content: [{type: "paragraph", content: [{type: "text", text: $t}]}]}}')"; else body="$(jq -nc --arg t "$2" '{body: $t}')"; fi ;;
  transitions) keyok "${1:-}" || die "bad issue key" 2; path="issue/$1/transitions" ;;
  transition) keyok "${1:-}" || die "bad issue key" 2; [ -n "${2:-}" ] || die "no transition id" 2; method=POST; path="issue/$1/transitions"; body="$(jq -nc --arg i "$2" '{transition: {id: $i}}')" ;;
  link) [ -n "${1:-}" ] || die "no body" 2; method=POST; path=issueLink; body="$1" ;;
esac
hp="${base#*://}"; hp="${hp%%/*}"
# the audit record comes first: no record, no egress (metadata only: host, verb; never the content)
"$here/../scripts/audit.sh" log egress adapter=jira host="$hp" verb="$verb" bytes="${#body}" >/dev/null 2>&1 || die "could not write the audit record, so nothing was sent" 3
args=(-sS --max-time "${JIRA_TIMEOUT_S:-60}" -K - -X "$method" -w $'\n%{http_code}')
[ -n "$body" ] && args+=(-d "$body")
out="$( { if [ -n "${JIRA_USER:-}" ]; then printf 'header = "Authorization: Basic %s"\n' "$(printf '%s:%s' "$JIRA_USER" "$tok" | base64 | tr -d '\n')"; else printf 'header = "Authorization: Bearer %s"\n' "$tok"; fi
  printf 'header = "Content-Type: application/json"\nheader = "Accept: application/json"\n'; } | curl "${args[@]}" "$api/$path" 2>&1)" || die "request failed: $(printf '%s' "$out" | head -c 300)" 5
code="${out##*$'\n'}"; resp="${out%$'\n'*}"
case "$code" in
  2??) [ -n "$resp" ] && printf '%s\n' "$resp"; exit 0 ;;
  401|403) die "HTTP $code (auth refused)" 3 ;;
  404) die "HTTP 404 (not found)" 5 ;;
  *) die "HTTP $code: $(printf '%s' "$resp" | head -c 300)" 5 ;;
esac
