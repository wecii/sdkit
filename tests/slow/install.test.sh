#!/usr/bin/env bash
# Installed-distribution integrity: what init.sh puts into a project must contain every runtime script the installed scripts call, doctor must notice a
# missing one, and the installed copy must run on its own (no source checkout, no plugin). Scratch repos, fake claude, no network.
set -u
KIT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failed=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else failed=$((failed + 1)); echo "  FAIL $1 (got '$2', wanted '$3')"; fi; }
export PATH="$KIT/tests/stubs:$PATH" OPENSPEC_STUB_LOG="$T/openspec.log"
mkrepo() { mkdir -p "$T/$1" && ( cd "$T/$1" && git init -q -b main . && git config user.email t@t && git config user.name t && echo a > f && git add -A && git commit -qm i ); echo "$T/$1"; }

# the sibling scripts each installed script calls, followed transitively from the entry points (computed from the source, so a new dependency cannot be forgotten)
closure() {
  local todo="$*" seen="" s d
  while [ -n "$todo" ]; do
    set -- $todo; s="$1"; shift; todo="$*"
    case " $seen " in *" $s "*) continue ;; esac
    seen="$seen $s"; [ -f "$KIT/scripts/$s.sh" ] || continue
    for d in $(grep -oE '\$\{?(here|dirname[^}]*)\}?/[A-Za-z0-9_-]+\.sh' "$KIT/scripts/$s.sh" | sed -E 's#.*/([A-Za-z0-9_-]+)\.sh#\1#' | sort -u); do todo="$todo $d"; done
    for d in $(grep -oE '"\$\(dirname "\$0"\)/[A-Za-z0-9_-]+\.sh"|"\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/[A-Za-z0-9_-]+\.sh"' "$KIT/scripts/$s.sh" | sed -E 's#.*/([A-Za-z0-9_-]+)\.sh.*#\1#'); do todo="$todo $d"; done
  done
  for s in $seen; do [ -f "$KIT/scripts/$s.sh" ] && printf '%s ' "$s"; done   # (a name with no file here is an optional sibling, not installable)
}
NEEDED="$(closure run-role route recover pr-check dispatch knowledge usage workflow audit | tr " " "\n" | grep -vx report | tr "\n" " ")"   # report.sh is a separate, still unreleased feature
eq "the closure is non-trivial (sanity)" "$([ "$(echo $NEEDED | wc -w)" -ge 15 ] && echo yes)" yes

check_install() {  # <label> <dir> [extra init args]
  local label="$1" d="$2"; shift 2
  ( cd "$d" && "$KIT/bin/init.sh" "$@" . >/dev/null 2>&1 ); local miss="" s
  for s in $NEEDED; do [ -x "$d/.sdkit/scripts/$s.sh" ] || miss="$miss $s"; done
  eq "$label: every runtime script is installed and executable" "${miss:- none}" " none"
  eq "$label: the kit's own adapters.d is installed"          "$([ -x "$d/.sdkit/adapters.d/litellm.sh" ] && echo yes)" yes
  eq "$label: adapters.json, tiers.env and the role texts are installed" "$([ -f "$d/.sdkit/adapters.json" ] && [ -f "$d/.sdkit/tiers.env" ] && [ -f "$d/.sdkit/roles/verifier.md" ] && echo yes)" yes
  eq "$label: doctor reports no missing component"            "$("$KIT/bin/doctor.sh" "$d" 2>&1 | grep -c 'MISSING\| missing or not executable\|missing: run\|FAIL .*script')" 0
}
check_install "codex"        "$(mkrepo codex)"  --host codex --stack generic
check_install "all hosts"    "$(mkrepo all)"    --host claude,codex,opencode,cursor,gemini --stack generic
check_install "claude copy"  "$(mkrepo copy)"   --host claude --mode copy --stack generic

echo "doctor notices a missing mandatory script"
d="$T/codex"
for s in dod-check recover telemetry; do
  mv "$d/.sdkit/scripts/$s.sh" "$T/$s.bak"
  eq "doctor flags a missing $s.sh (exit non-zero)" "$("$KIT/bin/doctor.sh" "$d" >/dev/null 2>&1; [ $? != 0 ] && echo flagged)" flagged
  mv "$T/$s.bak" "$d/.sdkit/scripts/$s.sh"
done

echo "the installed copy runs without the source checkout"
d="$T/all"; mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "{\\"result\\":\\"ok\\",\\"usage\\":{\\"input_tokens\\":3,\\"output_tokens\\":2}}"\n' > "$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
printf 'check it\n' > "$d/h.md"
mkdir -p "$d/openspec/changes/x"; printf '## Definition of Done\n- D1: works | Verified by: unit test\n' > "$d/openspec/changes/x/proposal.md"
mkdir -p "$d/.sdkit/.sdd"; echo '{"task":"x","phase":"verify","proposal":"openspec/changes/x/proposal.md"}' > "$d/.sdkit/.sdd/state.json"
out="$(cd "$d" && env -i HOME="$HOME" PATH="$T/fakebin:/usr/bin:/bin:$(dirname "$(command -v jq)")" .sdkit/scripts/run-role.sh verifier --handoff h.md --host claude --dry-run 2>&1)"
eq "run-role --dry-run works from the installed scripts alone" "$(printf '%s' "$out" | grep -c 'claude')" 1
out="$(cd "$d" && env -i HOME="$HOME" PATH="$T/fakebin:/usr/bin:/bin:$(dirname "$(command -v jq)")" .sdkit/scripts/run-role.sh verifier --handoff h.md --host claude 2>&1)"; rc=$?
eq "a verifier run with an open proposal reaches the host (dod-check is installed; not 'DoD not verifiable', not missing)" "$(printf '%s' "$out" | grep -c 'DoD not verifiable\|dod-check.sh is missing')" 0
mv "$d/.sdkit/scripts/dod-check.sh" "$T/dc.bak"
out="$(cd "$d" && env -i HOME="$HOME" PATH="$T/fakebin:/usr/bin:/bin:$(dirname "$(command -v jq)")" .sdkit/scripts/run-role.sh verifier --handoff h.md --host claude 2>&1)"; rc=$?
eq "without dod-check.sh the verifier is refused (2), never silently run" "$rc:$(printf '%s' "$out" | grep -c 'dod-check.sh is missing')" "2:1"
mv "$T/dc.bak" "$d/.sdkit/scripts/dod-check.sh"

echo "no machine-local file is tracked"
eq "git tracks no .DS_Store, history.jsonl or local settings" "$(git -C "$KIT" ls-files 2>/dev/null | grep -E '(^|/)\.DS_Store$|^bench/history\.jsonl$|^\.sdkit/sdkit\.local\.env$|\.test-cache' | wc -l | tr -d ' ')" 0
eq ".gitignore covers them"                                  "$(n=0; for f in .DS_Store bench/history.jsonl .sdkit/sdkit.local.env; do git -C "$KIT" check-ignore -q "$f" && n=$((n+1)); done; echo $n)" 3

echo "install: $pass passed, $failed failed"; [ "$failed" = 0 ]
