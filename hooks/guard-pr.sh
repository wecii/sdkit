#!/usr/bin/env bash
# PreToolUse(Bash): push and PR creation need a verified task whose diff is unchanged since (scripts/sdd.sh gate push).
# Also keeps the model away from the workflow state and the hook-only verdict/evidence/spawn commands.
. "$(dirname "$0")/lib.sh"
command="$(jget .tool_input.command)"
[ -z "$command" ] && exit 0
sdd="$(kit_cmd "" scripts/sdd.sh)"
mode="$("$sdd" mode)"
[ "$mode" = off ] && exit 0

printf '%s' "$command" | grep -qE '\.sdd/|hooks/(record-verdict|guard-budget)\.sh' && \
  decide deny "The workflow state and verdicts are written only by sdd.sh and the verifier hook, never by hand."
# An attestation is written only by sdd.sh, but the author commits it ("commit it with the change"), so git add/commit/status/diff and a
# mention in a commit or PR text must pass. Deny only a command that writes the file: a redirection, or a write verb, aimed at attestations/.
att_write='(^|[^-=>])>>?[[:space:]]*[^;&|]*attestations/|(^|[^A-Za-z0-9_.-])(tee|cp|mv|rm|touch|truncate|dd|install|ln|chmod|sed[[:space:]]+-[A-Za-z]*i|perl[[:space:]]+-[A-Za-z]*i)([[:space:]]+[^;&|]*)?[[:space:]][^;&|]*attestations/'
printf '%s' "$command" | grep -qE "$att_write" && \
  decide deny "Attestations are written only by sdd.sh. You may git add and commit one, but not edit, copy, move or delete it."
# the hook-only subcommands anywhere in a command that runs the kit, not only right after sdd.sh (S=_evidence; sdd.sh $S ... is the same call).
# A regex over a command string is a speed bump, not a boundary: docs/guide.md "What the guards cannot stop".
printf '%s' "$command" | grep -qE 'sdd\.sh|parse-verdict\.sh|run-role\.sh' && printf '%s' "$command" | grep -qE '(^|[^A-Za-z0-9])_(verdict|evidence|spawn)([^A-Za-z0-9]|$)' && \
  decide deny "The workflow state and verdicts are written only by sdd.sh and the verifier hook, never by hand."
# Claude Code records the verdict in the SubagentStop hook (record-verdict.sh), so recording by hand there would be forging one.
# Hosts without that hook (adapt.sh and the OpenCode plugin set SDKIT_HOST) record with parse-verdict.sh --record, which validates the block first.
[ -z "${SDKIT_HOST:-}" ] && printf '%s' "$command" | grep -qE 'parse-verdict\.sh' && printf '%s' "$command" | grep -qE -- '--record' && \
  decide deny "On Claude Code the verifier hook records the verdict. Run parse-verdict.sh without --record to check the block."

# skipping the git hooks is not a way around the phase gate
printf '%s' "$command" | grep -qE -- '--no-verify|core\.hooksPath|(^|[^A-Za-z0-9_])(SDD_SKIP|GUARD_SKIP_VERIFY)=' && {
  [ "$mode" = strict ] && decide deny "Skipping the git hooks (--no-verify, core.hooksPath, SDD_SKIP, GUARD_SKIP_VERIFY) is the user's call, not the agent's." || decide ask "This command skips the git hooks."; }
# git with options before push (git -C . push, git -c k=v push), through command/env/a path/a subshell; PR creation through the API too
git_cmd='(^|[;&|(`'"'"'"]|\$\()[[:space:]]*((command|env|exec|nohup)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:];&|]*/)?'
printf '%s' "$command" | grep -qE "${git_cmd}(git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create|glab[[:space:]]+mr[[:space:]]+create|gh[[:space:]]+api[[:space:]].*pulls|[^[:space:]]*open-pr\.sh)" || exit 0
reason="$("$sdd" gate push)" && exit 0
[ "$mode" = strict ] && decide deny "$reason" || decide ask "$reason"
