#!/usr/bin/env bash
# Open a pull request for the current branch. Host comes from PR_HOST in <project-dir>/sdkit.env (default: bitbucket).
# Usage: open-pr.sh "<title>" <description-file> [destination-branch]   (destination defaults to BASE_BRANCH)
#   PR_HOST=bitbucket  Bitbucket REST API. Basic auth needs the account EMAIL (BITBUCKET_EMAIL, else git config user.email); the token
#                      is read from the git remote URL (or BITBUCKET_TOKEN / PR_TOKEN_REPO) and never printed.
#   PR_HOST=github     `gh pr create` (needs gh, authenticated with `gh auth login` or GH_TOKEN).
#   PR_HOST=gitlab     `glab mr create` (needs glab, authenticated with `glab auth login` or GITLAB_TOKEN).
#   PR_HOST=auto       picks one of the above from the origin URL (github.com, gitlab.*, bitbucket.org; GH_HOST / GITLAB_HOST for
#                      self-hosted instances).
#   --repo-dir D       (first, optional) operate on the repo D instead of the current directory.
#   --reuse            (optional) if an open PR/MR already exists for the source branch, print its URL and exit 0 instead of creating a second one.
# Details: the kit's docs/hosts.md.
set -eu
REPO_DIR=""; REUSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:?--repo-dir needs a directory}"; shift 2 ;;
    --reuse) REUSE=1; shift ;;
    *) break ;;
  esac
done
[ -z "$REPO_DIR" ] || cd "$REPO_DIR" || { echo "cannot enter $REPO_DIR" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT"
. "$(dirname "${BASH_SOURCE[0]}")/env.sh" || { echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }; sdkit_env_load "$ROOT"; export KIT_DIR
PR_HOST="${PR_HOST:-bitbucket}"
if [ "$PR_HOST" = auto ]; then
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  case "$origin_url" in
    *github.com[:/]*) PR_HOST=github ;;
    *bitbucket.org[:/]*) PR_HOST=bitbucket ;;
    *gitlab.*) PR_HOST=gitlab ;;
    *) if [ -n "${GH_HOST:-}" ] && [[ "$origin_url" == *"$GH_HOST"[:/]* ]]; then PR_HOST=github
       elif [ -n "${GITLAB_HOST:-}" ] && [[ "$origin_url" == *"${GITLAB_HOST#*://}"[:/]* ]]; then PR_HOST=gitlab
       else echo "PR_HOST=auto: cannot tell the host from origin '$origin_url'; set PR_HOST to bitbucket, github or gitlab" >&2; exit 2; fi ;;
  esac
fi
case "$PR_HOST" in
  bitbucket|github|gitlab) ;;
  *) echo "PR_HOST=$PR_HOST is not supported (bitbucket, github, gitlab, auto). Open the PR by hand." >&2; exit 2 ;;
esac
TITLE="${1:?title}"; DESCRIPTION_FILE="${2:?description file}"; DEST="${3:-${BASE_BRANCH:-develop}}"
[ -r "$DESCRIPTION_FILE" ] || { echo "description file not readable: $DESCRIPTION_FILE" >&2; exit 2; }
SOURCE="$(git rev-parse --abbrev-ref HEAD)"
git rev-parse --verify -q "origin/$SOURCE" >/dev/null || { echo "push $SOURCE first (git push -u origin $SOURCE)"; exit 1; }

case "$PR_HOST" in
  github)
    command -v gh >/dev/null || { echo "PR_HOST=github needs the gh CLI (https://cli.github.com), then gh auth login" >&2; exit 2; }
    if [ "$REUSE" = 1 ]; then
      existing="$(gh pr list --head "$SOURCE" --state open --json url --jq '.[0].url // empty')" || { echo "gh pr list failed" >&2; exit 1; }
      [ -z "$existing" ] || { echo "$existing"; exit 0; }
    fi
    exec gh pr create --base "$DEST" --head "$SOURCE" --title "$TITLE" --body-file "$DESCRIPTION_FILE" ;;
  gitlab)
    command -v glab >/dev/null || { echo "PR_HOST=gitlab needs the glab CLI (https://gitlab.com/gitlab-org/cli), then glab auth login" >&2; exit 2; }
    if [ "$REUSE" = 1 ]; then
      existing="$(glab mr list --source-branch "$SOURCE" --output json 2>/dev/null | jq -r '.[0].web_url // empty' 2>/dev/null || true)"
      [ -z "$existing" ] || { echo "$existing"; exit 0; }
    fi
    exec glab mr create --source-branch "$SOURCE" --target-branch "$DEST" --title "$TITLE" --description "$(cat "$DESCRIPTION_FILE")" --yes ;;
esac

# Bitbucket. The PR is opened against the repo of the current directory. The token comes from that repo's origin URL; if the URL
# carries no credentials (credential-helper setups, sibling repos such as gitops), set PR_TOKEN_REPO in sdkit.env to a
# local repo whose origin URL does, or export BITBUCKET_TOKEN.
TOKEN_REMOTE="$(git -C "${PR_TOKEN_REPO:-$ROOT}" remote get-url origin)"
ACCOUNT_EMAIL="${BITBUCKET_EMAIL:-$(git config user.email || true)}"
[ -n "$ACCOUNT_EMAIL" ] || { echo "set BITBUCKET_EMAIL or git config user.email (the Bitbucket account email)" >&2; exit 2; }
REMOTE="$(git remote get-url origin)"
PR_TOKEN="${BITBUCKET_TOKEN:-}" PR_EMAIL="$ACCOUNT_EMAIL" PR_REMOTE="$REMOTE" PR_TOKEN_REMOTE="$TOKEN_REMOTE" PR_TITLE="$TITLE" PR_SOURCE="$SOURCE" \
PR_DEST="$DEST" PR_DESC="$DESCRIPTION_FILE" PR_REUSE="$REUSE" python3 -I - <<'PY'
import base64, json, os, re, urllib.error, urllib.request
remote = os.environ["PR_REMOTE"]
creds = re.match(r"https://([^@/]+:[^@/]+)@bitbucket\.org/", os.environ["PR_TOKEN_REMOTE"])
if not creds and not os.environ.get("PR_TOKEN"):
    raise SystemExit("no token: the origin URL carries none; set BITBUCKET_TOKEN or PR_TOKEN_REPO (see the script header)")
repo_match = re.match(r"https://(?:[^@/]+@)?bitbucket\.org/([^/]+/[^/]+?)(?:\.git)?$", remote)
if not repo_match:
    raise SystemExit("origin is not a Bitbucket URL")
token = os.environ.get("PR_TOKEN") or creds.group(1).split(":", 1)[1]
repo = repo_match.group(1)
auth = base64.b64encode(f"{os.environ['PR_EMAIL']}:{token}".encode()).decode()
body = {
    "title": os.environ["PR_TITLE"],
    "source": {"branch": {"name": os.environ["PR_SOURCE"]}},
    "destination": {"branch": {"name": os.environ["PR_DEST"]}},
    "close_source_branch": True,
    "description": open(os.environ["PR_DESC"]).read(),
}
if os.environ.get("PR_REUSE") == "1":
    import urllib.parse
    q = urllib.parse.quote(f'source.branch.name="{os.environ["PR_SOURCE"]}" AND state="OPEN"')
    lookup = urllib.request.Request(f"https://api.bitbucket.org/2.0/repositories/{repo}/pullrequests?q={q}", headers={"Authorization": f"Basic {auth}"})
    try:
        with urllib.request.urlopen(lookup) as response:
            found = json.load(response).get("values") or []
            if found:
                print(found[0]["links"]["html"]["href"]); raise SystemExit(0)
    except urllib.error.HTTPError as err:
        raise SystemExit(f"HTTP {err.code} while looking for an existing PR: {err.read().decode()[:300]}")
request = urllib.request.Request(
    f"https://api.bitbucket.org/2.0/repositories/{repo}/pullrequests", data=json.dumps(body).encode(), method="POST",
    headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(request) as response:
        pr = json.load(response)
        print(f"PR #{pr['id']} {pr['state']} -> {pr['destination']['branch']['name']}: {pr['links']['html']['href']}")
except urllib.error.HTTPError as err:
    hint = " (check that BITBUCKET_EMAIL is the Bitbucket account email)" if err.code == 401 else ""
    raise SystemExit(f"HTTP {err.code}: {err.read().decode()[:300]}{hint}")
PY
