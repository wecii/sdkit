#!/usr/bin/env bash
# Shared by the tests in tests/*.test.sh. Source it after `set -u`:  . "$(dirname "$0")/lib/common.sh"
# Gives: KIT (repo root), T (scratch dir, removed on exit), counters, ok/bad/check/nocheck/eq/rc, finish <name>, and git_repo <dir> (a repo on main with one commit).
# Keep a test file under ~15 s alone (fast.sh runs them in parallel and flags a file over 30 s): few cases, one scratch repo shared by many cases.
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
nocheck() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (should have failed)"; else ok "$n"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
# git_repo <dir>: a repo on branch main with one commit (identity set locally)
git_repo() { mkdir -p "$1" && ( cd "$1" && git init -q -b main . && git config user.email t@t && git config user.name t && { [ -e README ] || echo a > README; } && git add -A && git commit -qm init ); }
# finish <name>: print the totals and exit 1 when anything failed
finish() { echo; echo "$1: $pass passed, $fail failed"; [ "$fail" = 0 ]; }
