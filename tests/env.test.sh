#!/usr/bin/env bash
# SDKIT_ENV (standalone | analyst | developer): init --env, persistence through upgrade, the git-ignored pre-spec dir, `sdkit prespec check`, doctor per env.
# Run: tests/env.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
export PATH="$KIT/tests/stubs:$PATH" OPENSPEC_STUB_LOG="$T/openspec-stub.log"
SDKIT="$KIT/bin/sdkit"
mk() { git_repo "$1"; }   # a repo on main with one commit
val() { sed -n 's/^SDKIT_ENV=//p' "$1/.sdkit/sdkit.env" | tail -1; }

echo "default and bad value"
D="$T/std"; mk "$D"; ( cd "$D" && "$SDKIT" init --host claude . >/dev/null 2>&1 )
eq "default env is standalone"            "$(val "$D")" standalone
nocheck "standalone makes no prespec dir" test -e "$D/prespec"
nocheck "standalone gets no env-only keys" grep -qE '^(PRESPEC_DIR|SPECS_DIR|SDD_MANAGED)=' "$D/.sdkit/sdkit.env"
eq "unknown --env exits 2"                "$(rc "$SDKIT" init --env bogus "$D")" 2

echo "analyst"
A="$T/an"; mk "$A"; ( cd "$A" && "$SDKIT" init --host claude --env analyst . >/dev/null 2>&1 )
eq "analyst persisted"                    "$(val "$A")" analyst
check "analyst keys added"                bash -c "grep -q '^PRESPEC_DIR=prespec' '$A/.sdkit/sdkit.env' && grep -q '^SPEC_REVIEW_MAX_ROUNDS=4' '$A/.sdkit/sdkit.env'"
check "prespec README placeholder"        test -f "$A/prespec/README.md"
check "analyst gets openspec/ for the propose step" test -d "$A/openspec"
check "analyst language defaults to tr"   grep -q '^ANALYST_LANGUAGE=tr' "$A/.sdkit/sdkit.env"
( cd "$A" && "$SDKIT" init --host claude --env analyst . >/dev/null 2>&1 )
eq "re-init does not duplicate the ignore line" "$(grep -cx '/prespec/' "$A/.gitignore")" 1
( cd "$A" && git add -A && git commit -qm setup && echo '# idea' > prespec/feat.md )
eq "git status is clean with a prespec"   "$(git -C "$A" status --porcelain)" ""
( cd "$A" && "$SDKIT" upgrade . >/dev/null 2>&1 )
eq "upgrade keeps analyst"                "$(val "$A")" analyst

echo "prespec check"
chk() { ( cd "$A" && "$SDKIT" prespec check "$@" ); }
check "valid prespec passes"              chk feat
eq "missing exits 1"                      "$(rc chk nope)" 1
: > "$A/prespec/empty.md"; eq "empty exits 1" "$(rc chk empty)" 1
echo x > "$A/prespec/tr.md"; git -C "$A" add -f prespec/tr.md
eq "tracked exits 1"                      "$(rc chk tr)" 1
eq "no name exits 2"                      "$(rc chk)" 2

echo "developer and doctor"
V="$T/dev"; mk "$V"; ( cd "$V" && "$SDKIT" init --host claude --env developer . >/dev/null 2>&1 )
eq "developer persisted"                  "$(val "$V")" developer
check "developer keys added"              bash -c "grep -q '^SDD_MANAGED=on' '$V/.sdkit/sdkit.env' && grep -q '^SPECS_DIR=specs' '$V/.sdkit/sdkit.env'"
check "developer doctor warns on missing specs/" bash -c "'$KIT/bin/doctor.sh' '$V' 2>&1 | grep -q 'warn  .*specs/'"
check "analyst doctor checks openspec"    bash -c "'$KIT/bin/doctor.sh' '$A' 2>&1 | grep -qiE 'openspec'"
check "analyst doctor checks prespec ignored" bash -c "'$KIT/bin/doctor.sh' '$A' 2>&1 | grep -q 'prespec.*git-ignored'"
finish env
