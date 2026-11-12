#!/usr/bin/env bash
# scripts/spec.sh (F06): publish gated on a fresh review, one PR per branch, one version bump per change, atomic meta, no pre-spec content, approved SHA only from main.
# Deterministic: a local bare repo as origin and a fake gh in PATH. Run: tests/spec.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
O="$T/origin.git"; R="$T/r"; BIN="$T/bin"; mkdir -p "$BIN"; git init -q --bare -b main "$O"
git_repo "$R"; cd "$R"; git remote add origin "$O"; git push -q origin main
mkdir -p .sdkit specs/s1 prespec; printf 'BASE_BRANCH=main\nSTACK=generic\nPR_HOST=github\nSPEC_REVIEW_MAX_ROUNDS=9\nPRESPEC_DIR=prespec\n' > .sdkit/sdkit.env
echo "# s1 v1" > specs/s1/spec.md; echo "body" > "$T/body.md"; echo '[]' > "$T/none.json"
# fake gh: `pr list` prints the URL once a PR was created, `pr create` counts, `pr edit` is logged
cat > "$BIN/gh" <<EOS
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr list") [ -f "$T/failpr" ] && exit 1; [ -f "$T/pr" ] && echo "https://example.test/pr/1"; exit 0 ;;
  "pr create") [ -f "$T/failpr" ] && exit 1; echo x >> "$T/pr"; echo "https://example.test/pr/1" ;;
  "pr edit") echo e >> "$T/edits" ;;
esac
EOS
chmod +x "$BIN/gh"; export PATH="$BIN:$PATH" CLAUDE_PROJECT_DIR="$R"
S="$KIT/scripts/spec.sh"; RV="$KIT/scripts/review.sh"
reviewed() { "$RV" begin s1 >/dev/null && "$RV" record s1 --verdict PASS --isolation fresh --findings "$T/none.json" >/dev/null; }
pub() { "$S" publish s1 --title "Spec s1" --body-file "$T/body.md"; }
ver() { jq -r .version specs/s1/spec.meta.json; }
hist() { jq '.history | length' specs/s1/spec.meta.json; }
created() { [ -f "$T/pr" ] && wc -l < "$T/pr" | tr -d ' ' || echo 0; }
"$S" init-meta s1 >/dev/null

echo "gate"
eq "publish without a review is refused (rc 1)" "$(rc pub)" 1

echo "first publish, identical re-run, update"
reviewed; check "publish with a fresh PASS" pub
eq "version 0.1, one PR, branch on origin" "$(ver)/$(created)/$(git --git-dir="$O" rev-parse --verify -q refs/heads/spec/s1 >/dev/null && echo b)" "0.1/1/b"
check "identical second run succeeds" pub
eq "no duplicate PR, no version bump" "$(ver)/$(created)/$(hist)" "0.1/1/1"
echo "# s1 v2" >> specs/s1/spec.md; reviewed; check "update publishes" pub
eq "bumped exactly once (0.2), PR reused" "$(ver)/$(created)/$(hist)" "0.2/1/2"
eq "changed is empty right after a publish" "$("$S" changed s1)" ""

echo "failed push, pre-spec content"
echo "# s1 v3" >> specs/s1/spec.md; reviewed; before="$(cat specs/s1/spec.meta.json)"
git remote set-url origin "$T/nowhere.git"
eq "failed push is refused (rc 1)" "$(rc pub)" 1
eq "meta untouched after the failed push" "$(cat specs/s1/spec.meta.json)" "$before"
git remote set-url origin "$O"
echo secret > prespec/raw.md; git add -f prespec/raw.md
eq "staged pre-spec path refused (rc 1)" "$(rc pub)" 1
git reset -q HEAD -- prespec/raw.md; rm -f prespec/raw.md
check "retry finishes the job" pub
eq "version 0.3 after the retry" "$(ver)" "0.3"

echo "PR step fails after the version was recorded"
echo "# s1 v4" >> specs/s1/spec.md; reviewed; touch "$T/failpr"
eq "failed PR step is reported (rc 1)" "$(rc pub)" 1
eq "version already recorded (0.4) and pushed" "$(ver)/$(git --git-dir="$O" show refs/heads/spec/s1:specs/s1/spec.meta.json | jq -r .version)" "0.4/0.4"
rm -f "$T/failpr"; check "rerun only opens the PR" pub
eq "no extra version after the rerun" "$(ver)/$(hist)" "0.4/4"

echo "content merged earlier, version never recorded (PR opened by hand)"
mkdir -p specs/s2; echo "# s2" > specs/s2/spec.md; "$S" init-meta s2 >/dev/null; git add specs/s2; git commit -q -m "spec s2 merged by hand"
git push -q origin HEAD:main; git fetch -q origin; git checkout -q -B spec/s2 origin/main
"$RV" begin s2 >/dev/null && "$RV" record s2 --verdict PASS --isolation fresh --findings "$T/none.json" >/dev/null
check "publish records the version although the content is already on main" "$S" publish s2 --title "Spec s2" --body-file "$T/body.md"
eq "the branch is ahead of main by exactly the meta commit" "$(git rev-list --count origin/main..spec/s2)" 1
git checkout -q spec/s1

echo "approval"
check "promote prepares 1.0" "$S" promote s1
eq "promote on main is refused (rc 1)" "$(cd "$R" && git checkout -q main && rc "$S" promote s1)" 1
git checkout -q spec/s1; git push -q origin spec/s1
S1="$(git rev-parse HEAD)"
eq "unmerged SHA rejected (rc 1)" "$(rc "$S" approved-sha s1 --sha "$S1")" 1
git push -q origin spec/s1:main
check "merged SHA accepted" "$S" approved-sha s1 --sha "$S1"
finish spec
