#!/usr/bin/env bash
# Managed execution (F09/F10/F12, SDD_MANAGED=on): start --ticket from a Jira task contract, the pinned specSha in a specs submodule, deps, the proposed gate,
# block --spec-change, revalidate, and standalone left alone. Fake jira.sh (SDD_JIRA_CMD) and a local bare repo as the specs remote; no network.
# Run: tests/managed.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
SDD="$KIT/scripts/sdd.sh"; export KIT

# the specs repo: S1 approved at SHA1, revised and approved again at SHA2 (both on main)
SB="$T/specs.git"; git init -q --bare -b main "$SB"; git_repo "$T/sw"
( cd "$T/sw" && mkdir -p specs/S1 && echo '# S1' > specs/S1/spec.md \
  && jq -n '{id:"S1",version:"1.0",status:"approved"}' > specs/S1/spec.meta.json && git add -A && git commit -qm v1.0 \
  && echo '- AC-2 revised' >> specs/S1/spec.md && jq -n '{id:"S1",version:"1.1",status:"approved"}' > specs/S1/spec.meta.json && git commit -qam v1.1 \
  && git remote add origin "$SB" && git push -q origin main )
SHA2="$(git -C "$T/sw" rev-parse HEAD)"; SHA1="$(git -C "$T/sw" rev-parse HEAD~1)"

# fake jira.sh: contracts in $FAKE_JIRA/<KEY>.json, open dependencies in $FAKE_JIRA/pending, every write fails while $FAKE_JIRA/fail exists
FJ="$T/fj"; mkdir -p "$FJ"; export FAKE_JIRA="$FJ" SDD_JIRA_CMD="$T/jira.sh"
cat > "$T/jira.sh" <<'EOF'
#!/usr/bin/env bash
d="$FAKE_JIRA"; echo "$*" >> "$d/log"
case "$1" in
  fetch) [ -f "$d/$2.json" ] || exit 5; jq -c --arg k "$2" '. + {key:$k}' "$d/$2.json" ;;
  deps-ready) if [ -s "$d/pending" ]; then jq -nc --arg k "$2" --argjson p "$(cat "$d/pending")" '{key:$k,ready:false,pending:$p}'; exit 1; fi; jq -nc --arg k "$2" '{key:$k,ready:true,pending:[]}' ;;
  change-request) [ -f "$d/fail" ] && { echo "jira: HTTP 500" >&2; exit 5; }; jq -nc --arg k "$2" '{key:"PRJ-900",blocks:$k,kind:"spec-change"}' ;;
  transition|comment) [ -f "$d/fail" ] && exit 5; echo '{}' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$T/jira.sh"
task() { jq -n --arg s "$1" '{externalId:"S1:T1",specId:"S1",specVersion:"1.0",specSha:$s,acceptanceCriteria:["AC-1","AC-2"],risk:"medium",dependencies:["PRJ-5"],scope:["src/**"],parent:"PRJ-1"}'; }
task "$SHA1" > "$FJ/PRJ-7.json"; task "$SHA1" | jq 'del(.specSha)' > "$FJ/PRJ-8.json"; task "$(printf 'e%.0s' $(seq 40))" > "$FJ/PRJ-9.json"

# the developer repo: specs/ is a submodule pinned at SHA1
R="$T/r"; git_repo "$R"; cd "$R"
git -c protocol.file.allow=always submodule add -q "$SB" specs 2>/dev/null; git -C specs checkout -q "$SHA1"
mkdir -p .sdkit; printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MANAGED=on\nSPECS_DIR=specs\n' > .sdkit/sdkit.env
git add -A && git commit -qm base && git checkout -qb feat
export CLAUDE_PROJECT_DIR="$R" VERIFY_BASE=main
st() { jq -r "$1" .sdkit/.sdd/state.json 2>/dev/null; }

echo "start --ticket: the contract, the pinned specSha and the dependencies"
o="$("$SDD" start --ticket PRJ-8 2>&1)"; eq "missing contract field (specSha) rejected, no task" "$?:$([ -f .sdkit/.sdd/state.json ] && echo state)" "1:"
o="$("$SDD" start --ticket PRJ-9 2>&1)"; eq "unresolvable specSha rejected" "$?:$(grep -c 'not a commit in specs/' <<< "$o")" "1:1"
echo '[{"key":"PRJ-5","status":"In Progress"}]' > "$FJ/pending"
o="$("$SDD" start --ticket PRJ-7 2>&1)"; eq "open dependency blocks start (pending list shown)" "$?:$(grep -c 'PRJ-5 (In Progress)' <<< "$o"):$([ -f .sdkit/.sdd/state.json ] && echo state)" "1:1:"
rm -f "$FJ/pending"
check "happy path: start opens the task"  "$SDD" start --ticket PRJ-7
eq "state keeps ticket, spec, deps, ACs; DoD seeded and dod-check clean" \
  "$(st '[.ticket,.specId,.specSha,.deps[0],(.acceptanceCriteria|length),.phase] | join(",")'):$("$KIT/scripts/dod-check.sh" .sdkit/work/PRJ-7/proposal.md | head -1)" \
  "PRJ-7,S1,$SHA1,PRJ-5,2,intake:dod ok: 2 item(s) automated=2 static=0 manual=0 post-deploy=0 none=0"
echo '[{"key":"PRJ-5","status":"In Progress"}]' > "$FJ/pending"
nocheck "advance proposed refused while a dependency is open" "$SDD" advance proposed
rm -f "$FJ/pending"
check "advance proposed once the gate holds" "$SDD" advance proposed
eq "specs/ is never edited from the developer repo (gate edit)" "$(rc "$SDD" gate edit "$R/specs/specs/S1/spec.md")" 1

echo "block --spec-change and revalidate"
"$SDD" _evidence verifier PASS >/dev/null
touch "$FJ/fail"
nocheck "a failed change-request call fails the block" "$SDD" block --spec-change --reason "AC-2 contradicts AC-1"
eq "... and sets no flag" "$(st '.blocked // "none"')" none
rm -f "$FJ/fail"
check "block --spec-change files the request" "$SDD" block --spec-change --reason "AC-2 contradicts AC-1" --section AC-2
eq "flag set; advance red and a test edit (allowed in proposed) refuse" "$(st '.blocked.kind + ":" + .blocked.ref'):$(rc "$SDD" advance red --test-cmd false):$(rc "$SDD" gate edit "$R/a_test.go")" "spec-change:PRJ-900:1:1"
nocheck "revalidate with the same sha refused" "$SDD" revalidate --sha "$SHA1"
task "$SHA2" > "$FJ/PRJ-7.json"; git -C specs checkout -q "$SHA2"
check "revalidate with a new approved sha" "$SDD" revalidate --sha "$SHA2"
eq "flag cleared, pinned to the new sha, old evidence dropped, back at proposed" "$(st '[(.blocked // "none"), .specSha, (.evidence // "none"), .phase] | join(",")')" "none,$SHA2,none,proposed"

echo "standalone (SDD_MANAGED unset) is unchanged"
S="$T/s"; git_repo "$S"; mkdir -p "$S/.sdkit"; printf 'BASE_BRANCH=main\nSTACK=generic\n' > "$S/.sdkit/sdkit.env"
eq "start <slug> as before, no managed fields; --ticket and block are not commands there" \
  "$(CLAUDE_PROJECT_DIR="$S" rc "$SDD" start t1 --risk low --proposal p.md):$(jq -c '[.managed, .ticket]' "$S/.sdkit/.sdd/state.json"):$(CLAUDE_PROJECT_DIR="$S" rc "$SDD" start --ticket PRJ-7):$(CLAUDE_PROJECT_DIR="$S" rc "$SDD" block --spec-change --reason x)" \
  "0:[null,null]:1:2"

finish managed
