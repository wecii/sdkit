#!/usr/bin/env bash
# Is this repository safe to hand out (brew tap, clones)? Scans the working tree and, with --history, every added line in
# every ref. Exit 1 on a finding. Run it before tagging a release.
#   hard findings   secret-shaped strings, credentials in URLs, quoted credential assignments
#   soft findings   machine paths, project/customer names, e-mail addresses (listed in packaging/scan-allow.txt when intended)
# Usage: scan-publishable.sh [--history]
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
HISTORY=0; [ "${1:-}" = "--history" ] && HISTORY=1
SECRET='-----BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9]{32,}|AIza[0-9A-Za-z_-]{35}|ATBB[A-Za-z0-9_=-]{20,}|glpat-[A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.'
ASSIGN='(password|passwd|secret|api[_-]?key|apikey|access[_-]?token|auth[_-]?token|bearer)[A-Za-z_]*[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$ ]{8,}["'"'"']'
URLCRED='://[^/[:space:]:@]+:[^/[:space:]@]+@[A-Za-z0-9.-]+'
SOFT='/Users/[A-Za-z]|/home/[a-z]+/|C:\\Users'
fail=0
report() { # <label> <severity> <lines>
  [ -n "$3" ] || return 0
  printf '%s [%s]\n%s\n' "$1" "$2" "$(printf '%s\n' "$3" | cut -c1-160 | head -8)"; [ "$2" = hard ] && fail=1
}
allow() { [ -f packaging/scan-allow.txt ] && grep -vE '^(#|$)' packaging/scan-allow.txt || echo '^$^'; }

tree() { git ls-files -z | grep -zvE '^packaging/(scan-publishable\.sh|scan-allow\.txt)$|^tests/security\.test\.sh$' | xargs -0 grep -InE -e "$1" 2>/dev/null; }
report "tree: secret-shaped strings" hard "$(tree "$SECRET")"
report "tree: quoted credential assignments" hard "$(tree "$ASSIGN" | grep -iE -e "$ASSIGN")"
report "tree: credentials in URLs" hard "$(tree "$URLCRED" | grep -vE -f <(allow))"
report "tree: machine paths / names / identities" soft "$(tree "$SOFT" | grep -vE -f <(allow))"

if [ "$HISTORY" = 1 ]; then
  added="$(git log --all -p --no-color -U0 | grep -E -e '^\+' | grep -vE -e '^\+\+\+')"
  report "history: secret-shaped strings" hard "$(printf '%s\n' "$added" | grep -E -e "$SECRET" | grep -vE -f <(allow))"
  report "history: credentials in URLs" hard "$(printf '%s\n' "$added" | grep -E -e "$URLCRED" | grep -vE -f <(allow))"
  report "history: author identities (cannot be removed without rewriting history)" soft "$(git log --all --format='%an <%ae>' | sort | uniq -c)"
fi
[ "$fail" = 0 ] && echo "scan: no hard findings" || echo "scan: HARD FINDINGS, do not publish"
exit "$fail"
