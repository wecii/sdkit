#!/usr/bin/env bash
# Risk floor (RISK_FLOOR_GLOBS): off by default, taken from the files the diff really touches, enforced at green and verified, strictest level wins, guided/off modes, invalid config fails closed, ci-check ignores a lower-risk attestation and a PR cannot lift the floor main carries.
# Run: tests/risk-floor.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
SDD="$KIT/scripts/sdd.sh"
export SDKIT_GREEN="$T/green"   # RED fails until the test marks it green; GREEN re-runs the same command (sdd.sh binds them)
export VERIFY_BASE=main
sdd_red()   { rm -f "$SDKIT_GREEN"; "$SDD" advance red --test-cmd '[ -f "$SDKIT_GREEN" ]'; }
sdd_green() { touch "$SDKIT_GREEN"; "$SDD" advance green; }
out() { "$@" 2>&1; }   # stdout and stderr together, for `says`
n=0
# repo <floor> [mode]: a repo on branch feat (cut from main) with the settings committed on main; cd's into it
repo() {
  n=$((n + 1)); R="$T/r$n"; mkdir -p "$R" && cd "$R" || exit 1
  git init -q -b main . && git config user.email t@t && git config user.name t
  mkdir -p .sdkit src services/payments docs openspec/changes/x
  printf 'BASE_BRANCH=main\nSTACK=generic\nSDD_MODE=%s\nRISK_FLOOR_GLOBS=%s\n' "${2:-strict}" "$1" > .sdkit/sdkit.env
  printf 'work/\n.sdd/\n.verify-cache/\n' > .sdkit/.gitignore
  echo base > README.md; echo base > services/payments/pay.go; echo base > src/other.go; echo base > src/mid.go; echo base > plain.txt
  printf '# D\n## Race and ordering scenario\ntwo writers\n' > openspec/changes/x/design.md
  printf '# P\n## Definition of Done\n- D1: it works | Verified by: unit test\n' > openspec/changes/x/proposal.md
  git add -A && git commit -qm base && git checkout -qb feat
  export CLAUDE_PROJECT_DIR="$R"
}
# open <risk>: a task that is ready for code (phase red)
open() { "$SDD" start t1 --risk "$1" --proposal openspec/changes/x/proposal.md >/dev/null && "$SDD" advance proposed >/dev/null && sdd_red >/dev/null; }
# a trusted PASS per role (a registered spawn and a SubagentStop), as the evidence rules ask for at high risk
PASSBLOCK='DOD\n- D1 it works | PASS | t_test.go:1\nFINDINGS\n- none\nVERIFY\n- command: verify.sh | result: green | ok\nVERDICT: PASS'
REV='- MINOR | a:1 | n | x | y\nSUMMARY: 0 blockers, 0 major, 1 minor\nVERDICT: PASS'
AUD='NO FINDINGS\nSUMMARY: 0 critical, 0 high, 0 medium, 0 low\nVERDICT: PASS'
trusted() {  # trusted <role> <message> <agent id>
  printf '{"tool_input":{"subagent_type":"%s"}}' "$1" | "$KIT/hooks/guard-budget.sh"
  printf '{"agent_type":"%s","agent_id":"%s","last_assistant_message":"%s"}' "$1" "$3" "$2" | "$KIT/hooks/record-verdict.sh"
}
# att <risk> <verdict> [name]: an attestation for the diff as it is now (the fingerprint covers sdkit.env too, so call it after the last edit)
att() { mkdir -p .sdkit/attestations; jq -n --arg fp "$("$SDD" fingerprint)" --arg r "$1" --arg v "$2" '{task:"t1",risk:$r,verdict:$v,fingerprint:$fp} | if $r == "high" and $v == "PASS" then .evidence = ({verifier:1,reviewer:1,"security-auditor":1} | map_values({result:"PASS",trust:"spawned",fingerprint:$fp})) else . end' > ".sdkit/attestations/${3:-t1}.json"; }
env_file() { printf 'BASE_BRANCH=main\nSTACK=generic\n%b' "$1" > .sdkit/sdkit.env; }

echo "off by default"
repo ""
open low >/dev/null; echo x >> services/payments/pay.go; sdd_green >/dev/null
check "empty RISK_FLOOR_GLOBS: a low task on a payments file verifies" "$SDD" advance verified
eq "…its attestation says floor low"                  "$(jq -r .floor .sdkit/attestations/t1.json)" low
check "…and ci-check passes"                          "$SDD" ci-check

echo "floors on one repo: high on payments, medium on docs and src/mid.go, high on src/other.go too"
repo "high:services/payments/*,medium:docs/*,medium:src/*,high:src/other.go,low:README.md"
open low >/dev/null; echo x > services/payments/new.go
nocheck "an untracked floored file counts: green refused" sdd_green
rm services/payments/new.go; echo x >> plain.txt; echo x >> README.md
check "a file with no floor and a low floor entry: green ok" sdd_green
echo x >> services/payments/pay.go
nocheck "a floored file added later: verified refused" "$SDD" advance verified
says_file="$(out "$SDD" advance verified)"
check "…the reason names the file and the level"      grep -q 'services/payments/pay.go.*high\|high.*services/payments/pay.go' <<< "$says_file"
"$SDD" abort >/dev/null; git checkout -q services/payments/pay.go
open low >/dev/null; echo x >> docs/note.md 2>/dev/null
nocheck "low task touching a medium floor: green refused" sdd_green
"$SDD" abort >/dev/null; rm -f docs/note.md
open medium >/dev/null; echo x >> src/mid.go; sdd_green >/dev/null && echo x >> src/other.go
nocheck "medium task passes medium files; the strictest match (high) wins on src/other.go" "$SDD" advance verified
"$SDD" abort >/dev/null; git checkout -q src/mid.go src/other.go
check "the model cannot edit the state file by hand (guard-pr denies)" bash -c "printf '%s' '{\"tool_input\":{\"command\":\"jq .risk=\\\"high\\\" .sdkit/.sdd/state.json\"}}' | '$KIT/hooks/guard-pr.sh' | grep -q deny"
open high >/dev/null; echo x >> services/payments/pay.go; sdd_green >/dev/null
trusted verifier "$PASSBLOCK" v1; trusted reviewer "$REV" r1; trusted security-auditor "$AUD" s1
check "a high task touching it verifies"              "$SDD" advance verified
eq "…attestation records floor and risk high"         "$(jq -r '.floor + "/" + .risk' .sdkit/attestations/t1.json)" high/high
check "…and ci-check passes"                          "$SDD" ci-check

echo "modes: guided warns, off ignores"
repo "high:services/payments/*" guided; open low >/dev/null; echo x >> services/payments/pay.go
check "guided: green is allowed"                      sdd_green
repo "high:services/payments/*" off; open low >/dev/null; echo x >> services/payments/pay.go
check "off: ignored"                                  sdd_green

echo "invalid configuration fails closed"
repo "urgent:src/*"
nocheck "start refuses it"                            "$SDD" start t1 --risk high --proposal openspec/changes/x/proposal.md
eq "floor --validate exits 2"                         "$(rc "$SDD" floor --validate)" 2
echo x >> src/other.go
nocheck "ci-check fails on it"                        "$SDD" ci-check
repo "high:services/payments/*"
check "a valid value validates"                       "$SDD" floor --validate
echo x >> services/payments/pay.go
eq "floor prints level and file"                      "$("$SDD" floor)" "high services/payments/pay.go"

echo "CI: a lower-risk attestation does not satisfy a higher floor, and the PR cannot lift the floor main carries"
repo "high:services/payments/*"; echo x >> services/payments/pay.go
env_file 'SDD_MODE=strict\nRISK_FLOOR_GLOBS=high:services/payments/*\n'; att low ""
nocheck "a low attestation fails the floor"           "$SDD" ci-check
check "…and says why"                                 grep -q 'below the risk floor high' <<< "$(out "$SDD" ci-check)"
att medium PASS
nocheck "medium + PASS is still below high"           "$SDD" ci-check
att high ""
nocheck "risk raised by hand, no verifier PASS: fails" "$SDD" ci-check
att high PASS
check "high + PASS satisfies it"                      "$SDD" ci-check
env_file 'SDD_MODE=strict\nRISK_FLOOR_GLOBS=\n'; att low ""
check "…PR empties RISK_FLOOR_GLOBS: base floor still applies" grep -q 'below the risk floor high' <<< "$(out "$SDD" ci-check)"
nocheck "…and the low attestation fails"              "$SDD" ci-check
env_file 'SDD_MODE=off\nRISK_FLOOR_GLOBS=\n'; att low ""
nocheck "PR sets SDD_MODE=off: base mode still gates" "$SDD" ci-check
env_file 'SDD_MODE=strict\nRISK_FLOOR_GLOBS=high:services/payments/*\nSDD_FREE_GLOBS=services/*\n'; att low ""
nocheck "PR frees the floored path via SDD_FREE_GLOBS: still gated" "$SDD" ci-check
repo "high:docs/*"; echo x >> docs/note.md
nocheck "a floored docs file in the free area still needs an attestation" "$SDD" ci-check

check "the shipped template has the key, empty"       grep -q '^RISK_FLOOR_GLOBS=$' "$KIT/templates/sdkit.env"
finish risk-floor
