#!/usr/bin/env bash
# PreToolUse(Bash): a command that matches NOISY_CMD_PATTERNS (comma-separated globs, e.g. "npm test*,go test*,pytest*,*gradlew*") should run through
# scripts/capped.sh, so a long log does not stay in the conversation (every token is re-read on every later turn).
# Off unless NOISY_CMD_PATTERNS is set. Guided mode asks; strict mode asks too (it is a cost nudge, never a safety gate); SDD_MODE=off ignores it.
# A command already wrapped (contains capped.sh), a subagent call (it has its own context) and a pipe to tail/head/grep/wc pass untouched.
. "$(dirname "$0")/lib.sh"
[ -n "${NOISY_CMD_PATTERNS:-}" ] || exit 0
[ "${SDD_MODE:-strict}" = off ] && exit 0
[ -z "$(jget '.agent_type // .subagent_type')" ] || exit 0
cmd="$(jget .tool_input.command)"; [ -n "$cmd" ] || exit 0
case "$cmd" in *capped.sh*) exit 0 ;; esac
# the output is already cut by the command itself
printf '%s' "$cmd" | grep -qE '\|[[:space:]]*(tail|head|grep|wc|tee [^|]*>)|>[[:space:]]*[^&[:space:]]' && exit 0
scrubbed="$(printf '%s' "$cmd" | sed -E 's/^[[:space:]]+//; s/^(env |time |cd [^;&|]+(&&|;)[[:space:]]*)//')"
if matches_glob_list "$scrubbed" "$NOISY_CMD_PATTERNS"; then
  decide ask "Long output stays in the conversation and is re-read on every later turn. Run it through the capped runner: <kit>/scripts/capped.sh -- $cmd"
fi
exit 0
