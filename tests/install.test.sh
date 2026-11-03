#!/usr/bin/env bash
# Installed-distribution integrity: init.sh puts every runtime script the installed scripts call into the project, doctor notices a missing one,
# and the installed copy runs on its own (no source checkout). One scratch repo, fake claude, no network. Run: tests/install.test.sh
set -u
. "$(dirname "$0")/lib/common.sh"
export PATH="$KIT/tests/stubs:$PATH" OPENSPEC_STUB_LOG="$T/openspec.log"

# the sibling scripts the entry points call, followed transitively (computed from the source, so a new dependency cannot be forgotten)
closure() {
  local todo="$*" seen="" s d
  while [ -n "$todo" ]; do
    set -- $todo; s="$1"; shift; todo="$*"
    case " $seen " in *" $s "*) continue ;; esac
    seen="$seen $s"; [ -f "$KIT/scripts/$s.sh" ] || continue
    for d in $(grep -oE '(\$\{?(here|dirname[^}]*)\}?|\$\(dirname "[^"]*"\))/[A-Za-z0-9_-]+\.sh' "$KIT/scripts/$s.sh" | sed -E 's#.*/([A-Za-z0-9_-]+)\.sh#\1#' | sort -u); do todo="$todo $d"; done
  done
  for s in $seen; do [ -f "$KIT/scripts/$s.sh" ] && printf '%s ' "$s"; done
}
NEEDED="$(closure run-role route recover pr-check dispatch knowledge usage workflow audit | tr " " "\n" | grep -vx report | tr "\n" " ")"   # report.sh is a separate, unreleased feature
eq "closure is non-trivial (sanity)" "$([ "$(echo $NEEDED | wc -w)" -ge 15 ] && echo yes)" yes

d="$T/all"; git_repo "$d"
( cd "$d" && "$KIT/bin/init.sh" --host claude,codex,opencode,cursor,gemini --stack generic . >/dev/null 2>&1 )
miss=""; for s in $NEEDED; do [ -x "$d/.sdkit/scripts/$s.sh" ] || miss="$miss $s"; done
eq "every runtime script is installed and executable" "${miss:- none}" " none"
check "adapters.d, adapters.json, tiers.env and role texts installed" bash -c "[ -x '$d/.sdkit/adapters.d/litellm.sh' ] && [ -f '$d/.sdkit/adapters.json' ] && [ -f '$d/.sdkit/tiers.env' ] && [ -f '$d/.sdkit/roles/verifier.md' ]"
eq "doctor reports no missing component" "$("$KIT/bin/doctor.sh" "$d" 2>&1 | grep -c 'MISSING\| missing or not executable\|missing: run\|FAIL .*script')" 0

mv "$d/.sdkit/scripts/recover.sh" "$T/recover.bak"
nocheck "doctor flags a missing mandatory script" "$KIT/bin/doctor.sh" "$d"
mv "$T/recover.bak" "$d/.sdkit/scripts/recover.sh"

# the installed copy runs without the source checkout
mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "{\\"result\\":\\"ok\\",\\"usage\\":{\\"input_tokens\\":3,\\"output_tokens\\":2}}"\n' > "$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
printf 'check it\n' > "$d/h.md"
mkdir -p "$d/openspec/changes/x" "$d/.sdkit/.sdd"; printf '## Definition of Done\n- D1: works | Verified by: unit test\n' > "$d/openspec/changes/x/proposal.md"
echo '{"task":"x","phase":"verify","proposal":"openspec/changes/x/proposal.md"}' > "$d/.sdkit/.sdd/state.json"
rr() { (cd "$d" && env -i HOME="$HOME" PATH="$T/fakebin:/usr/bin:/bin:$(dirname "$(command -v jq)")" .sdkit/scripts/run-role.sh verifier --handoff h.md --host claude "$@" 2>&1); }
eq "run-role --dry-run works from the installed scripts alone" "$(rr --dry-run | grep -c '^(cd .* claude -p')" 1
eq "verifier with an open proposal is not refused (dod-check installed)" "$(rr | grep -c 'DoD not verifiable\|dod-check.sh is missing')" 0
mv "$d/.sdkit/scripts/dod-check.sh" "$T/dc.bak"
out="$(rr)"; eq "without dod-check.sh the verifier is refused" "$(printf '%s' "$out" | grep -c 'dod-check.sh is missing')" 1
mv "$T/dc.bak" "$d/.sdkit/scripts/dod-check.sh"

eq "git tracks no machine-local file" "$(git -C "$KIT" ls-files 2>/dev/null | grep -E '(^|/)\.DS_Store$|^bench/history\.jsonl$|^\.sdkit/sdkit\.local\.env$|\.test-cache' | wc -l | tr -d ' ')" 0
eq ".gitignore covers them" "$(n=0; for f in .DS_Store bench/history.jsonl .sdkit/sdkit.local.env; do git -C "$KIT" check-ignore -q "$f" && n=$((n+1)); done; echo $n)" 3
finish install
