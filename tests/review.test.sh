#!/usr/bin/env bash
# scripts/review.sh (F04): evidence bound to the content hash, fresh isolation only, bounded rounds, acceptances keyed on the finding text.
# Deterministic: no host, no network. Run: tests/review.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
R="$T/r"; git_repo "$R"; cd "$R"; mkdir -p .sdkit specs/s1
printf 'BASE_BRANCH=main\nSTACK=generic\nSPEC_REVIEW_MAX_ROUNDS=2\n' > .sdkit/sdkit.env; echo "# spec" > specs/s1/spec.md
export CLAUDE_PROJECT_DIR="$R"; RV="$KIT/scripts/review.sh"
echo '[]' > "$T/none.json"
echo '[{"id":"F1","severity":"BLOCKER","evidence":"AC2 cannot be tested","disposition":"open"}]' > "$T/blk.json"
echo '[{"id":"F1","severity":"BLOCKER","evidence":"AC2 cannot be tested","disposition":"accepted"}]' > "$T/acc.json"
echo '[{"id":"F1","severity":"BLOCKER","evidence":"reworded","disposition":"accepted"}]' > "$T/acc2.json"

echo "plan"
check "plan resolves the shipped rubric" bash -c "'$RV' plan feature-spec | grep -q 'reviewers: design_critic'"

echo "fresh PASS, then stale"
"$RV" begin s1 >/dev/null
eq "malformed findings rejected (rc 2)" "$(rc "$RV" record s1 --verdict PASS --isolation fresh --findings /dev/null)" 2
printf '[{"id":"F1","severity":"HUGE","evidence":"x","disposition":"open"}]' > "$T/bad.json"
eq "bad severity rejected (rc 2)" "$(rc "$RV" record s1 --verdict BLOCK --isolation fresh --findings "$T/bad.json")" 2
eq "isolation=none PASS rejected (rc 2)" "$(rc "$RV" record s1 --verdict PASS --isolation none --findings "$T/none.json")" 2
eq "PASS with an open blocker rejected (rc 2)" "$(rc "$RV" record s1 --verdict PASS --isolation fresh --findings "$T/blk.json")" 2
nocheck "no evidence yet: check fails" "$RV" check s1
check "fresh PASS recorded" "$RV" record s1 --verdict PASS --isolation fresh --findings "$T/none.json"
check "check passes on the same content" "$RV" check s1
echo "more" >> specs/s1/spec.md
nocheck "stale after an edit" "$RV" check s1

echo "round cap, NOT_RUN, accept"
"$RV" begin s1 >/dev/null
check "NOT_RUN with isolation none is recorded" "$RV" record s1 --verdict NOT_RUN --isolation none
nocheck "NOT_RUN is never approved" "$RV" check s1
eq "third round refused (rc 3)" "$(rc "$RV" begin s1)" 3
echo "final verification round (outside the cap)"
check "--final opens one verification round after the cap" "$RV" begin s1 --final
eq "--final does not raise the round count" "$(jq -r .round .sdkit/work/review/s1/state.json)" 2
check "the final round records evidence" "$RV" record s1 --verdict PASS --isolation fresh --findings "$T/none.json"
check "the final round can approve" "$RV" check s1
eq "a second --final is refused (rc 3)" "$(rc "$RV" begin s1 --final)" 3
mkdir -p specs/s3; echo a > specs/s3/spec.md; "$RV" begin s3 >/dev/null
eq "--final before the cap is refused (rc 1)" "$(rc "$RV" begin s3 --final)" 1
mkdir -p specs/s2; echo a > specs/s2/spec.md
"$RV" begin s2 >/dev/null; "$RV" record s2 --verdict BLOCK --isolation fresh --findings "$T/blk.json" >/dev/null
nocheck "accept needs who and why" "$RV" accept s2 F1
nocheck "accept without who and without JIRA_USER is refused" env JIRA_USER= "$RV" accept s2 F1 --why "x"
check "accept by a person" "$RV" accept s2 F1 --who ana --why "known gap, tracked in T-9"
check "accept defaults who to JIRA_USER" env JIRA_USER=ana@corp.com "$RV" accept s2 F1 --why "known gap"
eq "the Jira user is recorded as who" "$(tail -1 specs/s2/acceptances.jsonl | jq -r .who)" ana@corp.com
"$RV" begin s2 >/dev/null
eq "an edited finding is not covered by the acceptance (rc 2)" "$(rc "$RV" record s2 --verdict PASS --isolation fresh --findings "$T/acc2.json")" 2
check "the unedited finding is accepted" "$RV" record s2 --verdict PASS --isolation fresh --findings "$T/acc.json"
check "check passes with the accepted blocker" "$RV" check s2
finish review.test
