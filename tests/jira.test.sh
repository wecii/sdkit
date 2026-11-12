#!/usr/bin/env bash
# F07/F08 Jira core: fetch, contract rejection, idempotent upsert, egress opt-in, failed calls leave no success output. Fake curl (tests/stubs/jira-curl); no network, no token.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; J="$ROOT/scripts/jira.sh"; S="$ROOT/tests/stubs"
T="$(mktemp -d)"; mkdir -p "$T/proj/.sdkit" "$T/bin" "$T/st/issues"; export CLAUDE_PROJECT_DIR="$T/proj"; trap 'rm -rf "$T"' EXIT
cp "$S/jira-curl" "$T/bin/curl"; export PATH="$T/bin:$PATH" FAKE_LOG="$T/log" FAKE_STATE="$T/st"
for f in ok nosha dep; do cp "$S/jira-issue-$f.json" "$T/st/issues/$(jq -r .key "$S/jira-issue-$f.json").json"; done
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
run() { JIRA_BASE_URL=https://jira.example JIRA_EGRESS="${EG-allow}" JIRA_TOKEN_ENV=MY_JIRA_TOK MY_JIRA_TOK=tok-SECRET999 "$J" "$@"; }
TASK='{"externalId":"S1:T9","specId":"S1","specVersion":"3","specSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","acceptanceCriteria":["AC-1"],"risk":"high","dependencies":[],"scope":["src/**"],"parent":"PRJ-1"}'
jq -e . "$S"/jira-issue-*.json >/dev/null; eq "fixtures are valid JSON" "$?" 0
eq "fetch normalises (CRLF description, parent from Jira)" "$(run fetch PRJ-7 | jq -c '[.externalId, .risk, .parent, .statusCategory]')" '["S1:T2","low","PRJ-1","new"]'
eq "token only on stdin, never in argv"   "$(grep -c 'tok-SECRET999' "$T/log"):$(grep '^ARGS' "$T/log" | grep -c 'tok-SECRET999')" "1:0"
o="$(run fetch PRJ-8 2>&1)"; eq "missing sha / empty AC rejected (4), no JSON out" "$?:$(printf '%s' "$o" | grep -c '^{')" "4:0"
eq "a bad sha is rejected (4)"            "$(printf '%s' "$TASK" | sed 's/b\{40\}/zz/' | "$J" validate-task >/dev/null 2>&1; echo $?)" 4
eq "deps-ready: open dependency => not ready (1)" "$(run deps-ready PRJ-7 | jq -c .ready):$(run deps-ready PRJ-7 >/dev/null; echo $?)" "false:1"
: > "$T/log"; a="$(run upsert S1:T9 "$TASK")"; b="$(run upsert S1:T9 "$TASK")"
eq "upsert twice: create then update, one issue" "$(jq -r .action <<< "$a"),$(jq -r .action <<< "$b"):$(grep -c '^REQ POST issue ' "$T/log"):$(jq -r .key <<< "$a" | grep -c "$(jq -r .key <<< "$b")")" "created,updated:1:1"
eq "assignee is never sent"               "$(grep -ci 'assignee' "$T/log")" 0
eq "egress off => 3, nothing sent"        "$(: > "$T/log"; EG= run fetch PRJ-7 >/dev/null 2>&1; echo $?):$(grep -c '^REQ' "$T/log")" "3:0"
o="$(FAKE_MODE=500 run upsert S1:T10 "${TASK//T9/T10}" 2>&1)"; rc=$?; eq "HTTP 500: non-zero, no success output" "$rc:$(printf '%s' "$o" | grep -c '"key"')" "5:0"
r="$(run change-request PRJ-7 '{"reason":"AC-1 contradicts AC-2"}')"; eq "change-request: created and linked to the subtask" "$(jq -r .blocks <<< "$r"):$(grep '^REQ POST issueLink' "$T/log" | grep -c 'PRJ-7')" "PRJ-7:1"
# token written in the personal settings file
printf 'JIRA_API_TOKEN=tok-FROMFILE1\n' > "$T/proj/.sdkit/sdkit.local.env"; : > "$T/log"
o="$(env -u MY_JIRA_TOK JIRA_BASE_URL=https://jira.example JIRA_EGRESS=allow "$J" fetch PRJ-7 2>&1)"; eq "token from sdkit.local.env is used (stdin only)" "$?:$(grep -c 'tok-FROMFILE1' "$T/log"):$(grep '^ARGS' "$T/log" | grep -c 'tok-FROMFILE1')" "0:1:0"
printf 'JIRA_API_TOKEN=tok-COMMITTED\n' > "$T/proj/.sdkit/sdkit.env"
o="$(env -u MY_JIRA_TOK JIRA_BASE_URL=https://jira.example JIRA_EGRESS=allow "$J" fetch PRJ-7 2>&1)"; eq "token in the shared sdkit.env is refused (3)" "$?:$(printf '%s' "$o" | grep -c 'tok-COMMITTED')" "3:0"
rm -f "$T/proj/.sdkit/sdkit.env" "$T/proj/.sdkit/sdkit.local.env"
echo "jira: $pass passed, $failed failed"; [ "$failed" = 0 ]
