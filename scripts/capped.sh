#!/usr/bin/env bash
# Run a noisy command (tests, build, lint) and keep only what matters in the conversation: the exit code, the failure lines and the tail.
# The full output goes to <project-dir>/work/<slug>/out/cmd-<time>.log; read it only if the summary is not enough.
#   capped.sh [--lines N] [--slug S] -- <command> [args...]     (one quoted argument runs through bash -c)
# N defaults to CAPPED_LINES (sdkit.env, else 40). Output of N lines or fewer is printed as is. Exit code = the command's exit code.
# Why: every token that enters the session is re-read on each later turn, so a 3000-line test log costs its size times the turns left.
set -u
top="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
. "$(dirname "${BASH_SOURCE[0]}")/env.sh" || { echo "sdkit: env.sh is missing next to $(basename "$0"): run sdkit upgrade" >&2; exit 1; }; sdkit_env_load "$top"
lines="${CAPPED_LINES:-40}"; slug=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lines) lines="${2:-}"; shift 2 ;;
    --slug) slug="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
case "$lines" in ''|*[!0-9]*|0) lines=40 ;; esac
[ -n "$slug" ] || slug="$(sdkit_active_slug "$top" 2>/dev/null)"; slug="${slug:-_misc}"
case "$slug" in *[!A-Za-z0-9_.-]*) slug=_misc ;; esac
dir="$top/$KIT_DIR/work/$slug/out"; mkdir -p "$dir" 2>/dev/null || dir="${TMPDIR:-/tmp}"
log="$dir/cmd-$(date +%s)-$$.log"

if [ $# -eq 1 ]; then (cd "$top" && bash -c "$1") > "$log" 2>&1; else (cd "$top" && "$@") > "$log" 2>&1; fi
rc=$?
total="$(wc -l < "$log" | tr -d ' ')"
if [ "$total" -le "$lines" ]; then cat "$log"; exit "$rc"; fi

# failure lines first (they are what the next step needs), then the tail; both bounded
echo "[capped] exit $rc, $total lines. Full output: ${log#"$top"/}"
fails="$(grep -nEi 'FAIL|ERROR|panic|exception|traceback|not ok|✗|✘|assert' "$log" | head -30)"
if [ -n "$fails" ]; then echo "--- failure lines (line: text)"; printf '%s\n' "$fails" | cut -c1-240; fi
echo "--- last $(( lines / 2 )) lines"
tail -n "$(( lines / 2 ))" "$log" | cut -c1-240
exit "$rc"
