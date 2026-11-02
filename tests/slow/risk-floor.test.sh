#!/usr/bin/env bash
# Risk floor (RISK_FLOOR_GLOBS, ADR-0005): off by default, checked against the files the diff really touches, enforced when the tests go
# green, when the task is verified and in ci-check, where an attestation of a lower risk does not count. Run: tests/slow/risk-floor.test.sh
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
expect() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then ok "$n"; else bad "$n"; sed 's/^/        /' "$T/out"; fi; }
refuse() { local n="$1"; shift; if "$@" >"$T/out" 2>&1; then bad "$n (should have failed)"; else ok "$n"; fi; }
says() { local n="$1" p; shift; for p in "$@"; do grep -q -- "$p" "$T/out" || { bad "$n (no '$p' in: $(head -c 200 "$T/out" | tr '\n' ' '))"; return; }; done; ok "$n"; }
SDD="$KIT/scripts/sdd.sh"
export SDKIT_GREEN="${TMPDIR:-/tmp}/sdkit-green.$$"   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }
n=0

# repo <floor> [mode]: a repo on branch feat (cut from main), settings committed on main; prints nothing, cd's into it
repo() {
  n=$((n + 1)); R="$T/r$n"; mkdir -p "$R" && cd "$R" || exit 1
  git init -q -b main . && git config user.email t@t && git config user.name t
  mkdir -p .sdkit src services/payments docs openspec/changes/x
  printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=%s\nRISK_FLOOR_GLOBS=%s\n' "${2:-strict}" "$1" > .sdkit/sdkit.env
  printf 'work/\n.sdd/\n.verify-cache/\n' > .sdkit/.gitignore
  echo base > README.md; echo base > services/payments/pay.go; echo base > src/other.go
  git add -A && git commit -qm base && git checkout -qb feat
  export CLAUDE_PROJECT_DIR="$R" VERIFY_BASE=main
  printf '# D\n## Race and ordering scenario\ntwo writers\n' > openspec/changes/x/design.md
  printf '# P\n## Definition of Done\n- D1: it works | Verified by: unit test\n' > openspec/changes/x/proposal.md
}
# open <risk>: a task that is ready for code (phase red)
open() {
  "$SDD" start t1 --risk "$1" --proposal openspec/changes/x/proposal.md >/dev/null && "$SDD" advance proposed >/dev/null && sdd_red >/dev/null
}
PASSBLOCK='DOD\n- D1 it works | PASS | t_test.go:1\nFINDINGS\n- none\nVERIFY\n- command: verify.sh | result: green | ok\nVERDICT: PASS'
verdict() { printf '{"agent_type":"verifier","last_assistant_message":"%s"}' "$PASSBLOCK" | "$KIT/hooks/record-verdict.sh"; }
# high risk needs a trusted PASS from verifier, reviewer and security-auditor (F04): a registered spawn and a SubagentStop per role
REV='- MINOR | a:1 | n | x | y\nSUMMARY: 0 blockers, 0 major, 1 minor\nVERDICT: PASS'
AUD='NO FINDINGS\nSUMMARY: 0 critical, 0 high, 0 medium, 0 low\nVERDICT: PASS'
trusted() {  # trusted <role> <message> <agent id>
  printf '{"tool_input":{"subagent_type":"%s"}}' "$1" | "$KIT/hooks/guard-budget.sh"
  printf '{"agent_type":"%s","agent_id":"%s","last_assistant_message":"%s"}' "$1" "$3" "$2" | "$KIT/hooks/record-verdict.sh"
}
all_trusted() { trusted verifier "$PASSBLOCK" v1 && trusted reviewer "$REV" r1 && trusted security-auditor "$AUD" s1; }
# finish <risk> <file>: the whole flow on one file, up to and including verified; leaves the attestation
finish() {
  open "$1" && echo "// $1" >> "$2" && sdd_green >/dev/null || return 1
  if [ "$1" = high ]; then all_trusted; elif [ "$1" != low ]; then verdict; fi
  "$SDD" advance verified
}

echo "off by default"
repo ""
expect "empty RISK_FLOOR_GLOBS: a low task on a payments file verifies" finish low services/payments/pay.go
ATT=.sdkit/attestations/t1.json
expect "its attestation says floor low"          bash -c "[ \"\$(jq -r .floor $ATT)\" = low ]"
expect "ci-check passes as before"               "$SDD" ci-check
repo ""; sed -i.bak '/RISK_FLOOR_GLOBS/d' .sdkit/sdkit.env; rm -f .sdkit/sdkit.env.bak; git commit -qam x
expect "key absent entirely: nothing changes"    finish low services/payments/pay.go

echo "floor high on services/payments/*"
G='high:services/payments/*'
repo "$G"; open low >/dev/null; echo x >> services/payments/pay.go
refuse "low task touching a floored file: green refused" sdd_green
says "the reason names the file and the level" 'services/payments/pay.go' 'high' 
repo "$G"; open medium >/dev/null; echo x >> services/payments/pay.go
refuse "medium task touching it: green refused"  sdd_green
repo "$G"; expect "high task touching it verifies" finish high services/payments/pay.go
expect "attestation records floor high and risk high" bash -c "[ \"\$(jq -r .floor $ATT)\" = high ] && [ \"\$(jq -r .risk $ATT)\" = high ]"
expect "ci-check passes for it"                  "$SDD" ci-check
repo "$G"; expect "low task on a non-matching file verifies" finish low src/other.go
repo "$G"; expect "medium task on a non-matching file verifies" finish medium src/other.go
echo "the floor is taken from the real diff, not the scope the task started with"
repo "$G"; open low >/dev/null; echo x >> src/other.go
expect "green on a harmless file"                sdd_green
echo x >> services/payments/pay.go
refuse "a floored file added before verified: refused" "$SDD" advance verified
says "named in the reason"                        'services/payments/pay.go' 
echo "an untracked new file under a floored path counts too"
repo "$G"; open low >/dev/null; echo x > services/payments/new.go
refuse "untracked floored file: green refused"   sdd_green
echo "ordinary workflow commands cannot lower it"
repo "$G"; open low >/dev/null; echo x >> services/payments/pay.go
refuse "low: refused"                            sdd_green
"$SDD" abort >/dev/null
open low >/dev/null; refuse "abort + start low again: still refused" sdd_green
refuse "start while a task is open"              "$SDD" start t2 --risk low --proposal openspec/changes/x/proposal.md
expect "the state file is not editable by hand"  bash -c "printf '%s' '{\"tool_input\":{\"command\":\"jq .risk=\\\"high\\\" .sdkit/.sdd/state.json\"}}' | $KIT/hooks/guard-pr.sh | grep -q deny"

echo "levels: medium floor"
M='medium:migrations/*.sql,medium:*/auth/*'
repo "$M"; mkdir -p migrations db/auth; echo x > migrations/001.sql; echo x > db/auth/a.go; git add -A; git commit -qm m
open low >/dev/null; echo y >> migrations/001.sql
refuse "low touching migrations/*.sql: refused"  sdd_green
repo "$M"; mkdir -p migrations db/auth; echo x > migrations/001.sql; echo x > db/auth/a.go; git add -A; git commit -qm m
expect "medium touching it verifies"             finish medium migrations/001.sql
repo "$M"; mkdir -p db/auth; echo x > db/auth/a.go; git add -A; git commit -qm m
open low >/dev/null; echo y >> db/auth/a.go
refuse "a path glob (*/auth/*) matches too"      sdd_green
echo "the strictest matching level wins"
repo "medium:src/*,high:src/other.go"; open medium >/dev/null; echo x >> src/other.go
refuse "medium task on a file matching medium and high: refused" sdd_green
says "names high" 'high'
echo "low:... entries never block a task"
repo "low:src/*"; expect "a low floor changes nothing for a low task" finish low src/other.go

echo "modes"
repo "$G" guided; open low >/dev/null; echo x >> services/payments/pay.go
expect "guided: warns, does not refuse"          sdd_green
says "the warning is shown" 'warning'
repo "$G" off;    open low >/dev/null; echo x >> services/payments/pay.go
expect "off: ignored"                            sdd_green

echo "invalid configuration fails closed"
for bad_cfg in 'urgent:src/*' 'high' 'high:' 'HIGH:src/*' 'medium:a,oops'; do
  repo "$bad_cfg"
  refuse "start refuses '$bad_cfg'"              "$SDD" start t1 --risk high --proposal openspec/changes/x/proposal.md
  refuse "floor --validate rejects '$bad_cfg'"   "$SDD" floor --validate
  expect "floor --validate exits 2"              bash -c "'$SDD' floor --validate >/dev/null 2>&1; [ \$? = 2 ]"
  echo 'x' >> src/other.go
  refuse "ci-check fails on '$bad_cfg'"          "$SDD" ci-check
done
repo "$G"; expect "a valid value validates"      "$SDD" floor --validate
repo "$G"; echo x >> services/payments/pay.go
expect "floor prints level and file"             bash -c "[ \"\$('$SDD' floor)\" = 'high services/payments/pay.go' ]"
repo "$G"; expect "floor prints low when nothing matches" bash -c "[ \"\$('$SDD' floor)\" = low ]"
D="$T/doc"; mkdir -p "$D" && ( cd "$D" && git init -q -b main . && "$KIT/bin/init.sh" --stack go . >/dev/null 2>&1; sed -i.bak 's/^RISK_FLOOR_GLOBS=.*/RISK_FLOOR_GLOBS=bogus/' .sdkit/sdkit.env )
expect "doctor reports it"                       bash -c "'$KIT/bin/doctor.sh' '$D' 2>&1 | grep -q 'FAIL  RISK_FLOOR_GLOBS is invalid'"
( cd "$D" && sed -i.bak 's/^RISK_FLOOR_GLOBS=.*/RISK_FLOOR_GLOBS=high:src\/*/' .sdkit/sdkit.env )
expect "doctor accepts a valid one"              bash -c "'$KIT/bin/doctor.sh' '$D' 2>&1 | grep -q 'ok    RISK_FLOOR_GLOBS is well-formed'"
expect "the shipped template has the key, empty" bash -c "grep -q '^RISK_FLOOR_GLOBS=\$' '$KIT/templates/sdkit.env'"

# att <risk> <verdict> [name]: an attestation for the diff as it is right now (the fingerprint covers sdkit.env too, so call it after the last edit)
att() { mkdir -p .sdkit/attestations; jq -n --arg fp "$("$SDD" fingerprint)" --arg r "$1" --arg v "$2" '{task:"t1",risk:$r,verdict:$v,fingerprint:$fp} | if $r == "high" and $v == "PASS" then .evidence = ({verifier:1,reviewer:1,"security-auditor":1} | map_values({result:"PASS",trust:"spawned",fingerprint:$fp})) else . end' > ".sdkit/attestations/${3:-t1}.json"; }
env_file() { printf 'BASE_BRANCH=main\nSTACK=generic\n%b' "$1" > .sdkit/sdkit.env; }

echo "CI: a lower-risk attestation does not satisfy a higher floor"
repo ""; env_file 'SDD_MODE=strict\nRISK_FLOOR_GLOBS=high:services/payments/*\n'; git commit -qam floor-on-branch
echo x >> services/payments/pay.go
att low ""
refuse "floor high: a low attestation fails"      "$SDD" ci-check
says "and says why" 'below the risk floor high'
att high ""
refuse "risk raised by hand, no verifier PASS: fails" "$SDD" ci-check
says "the missing PASS is what it reports" 'needs a verifier PASS'
att medium PASS
refuse "medium + PASS is still below high"        "$SDD" ci-check
att high PASS
expect "high + PASS satisfies it"                 "$SDD" ci-check
att low "" aa-low; att high PASS zz-high
expect "low and high+PASS side by side: passes"   "$SDD" ci-check
rm .sdkit/attestations/aa-low.json; att low "" t1; rm .sdkit/attestations/zz-high.json
refuse "only the low one left: fails again"       "$SDD" ci-check
repo ""; echo x >> services/payments/pay.go; att low ""
expect "no floor anywhere: the low attestation passes" "$SDD" ci-check

echo "CI: the pull request cannot lift the floor it is held to (main carries the floor)"
repo "$G"; echo x >> services/payments/pay.go
env_file 'SDD_MODE=strict\nRISK_FLOOR_GLOBS=\n'; att low ""
refuse "PR empties RISK_FLOOR_GLOBS: the base still applies" "$SDD" ci-check
says "reason is the floor" 'below the risk floor high'
env_file 'SDD_MODE=strict\n'; att low ""
refuse "PR deletes the key: same"                 "$SDD" ci-check
env_file 'SDD_MODE=strict\nRISK_FLOOR_GLOBS=low:services/*\n'; att low ""
refuse "PR swaps in a harmless floor: base wins"  "$SDD" ci-check
env_file 'SDD_MODE=off\nRISK_FLOOR_GLOBS=\n'; att low ""
refuse "PR sets SDD_MODE=off: base is on, still checked" "$SDD" ci-check
says "the base branch's settings judge it" 'below the risk floor high'
env_file "SDD_MODE=strict\nRISK_FLOOR_GLOBS=$G\nSDD_FREE_GLOBS=services/*\n"; att low ""
refuse "PR frees the floored path via SDD_FREE_GLOBS: still gated" "$SDD" ci-check
env_file "SDD_MODE=strict\nRISK_FLOOR_GLOBS=$G\n"; att high PASS
expect "with a real high + PASS the same PR passes" "$SDD" ci-check
echo "a base branch that is itself invalid"
repo "bogus"; echo x >> src/other.go
refuse "invalid on the base: ci-check fails"      "$SDD" ci-check
echo "first adoption: no settings file on the base"
repo ""; git checkout -q main; git rm -q .sdkit/sdkit.env; git commit -qm 'no settings yet'; git checkout -q feat
env_file 'SDD_MODE=off\n'; echo x >> src/other.go
expect "no base file and mode off: skipped, as before" "$SDD" ci-check
echo "floored files in the free area still need an attestation"
repo "high:docs/*"; echo x >> docs/note.md
refuse "docs file matching the floor: gated"      "$SDD" ci-check
repo ""; echo x >> docs/note.md
expect "docs file with no floor: free, as before" "$SDD" ci-check

echo
echo "risk floor tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
