# Step progress line

Read once, when the risk label is confirmed (end of §0), and keep to it. The user should always see how far a run is.

## Format
One line, printed as plain text in the conversation (no tool call, no file), at the start and at the end of every step:

```
[sdkit] orchestrator · Step <n>/<total>: <name> — started
[sdkit] orchestrator · Step <n>/<total>: <name> — done
```

`—` is an em dash. Other outcomes replace `done` with `skipped` or `stopped: <short reason>` (waiting on the user, refused gate). The `orchestrator ·` prefix names who prints the line (subagents print their own `[sdkit] <role> done …` line from the host hook).

## Token usage on the line (only when the phase move printed a `usage:` line)
When `USAGE_LINE=1`, `sdd.sh advance` prints `usage: orchestrator: … | task total: …` on stderr: the running totals from the usage ledger (`usage.sh live show`; hook on Claude, rollout file on Codex). Append that text to the `done` line verbatim, after ` · `:
`[sdkit] orchestrator · Step 5/8: implement — done · orchestrator: in 41k (fresh 3k, cache read 36k, cache write 2k), out 6.2k, hit 88% | task total: …` (a role the host gave no token data for reads `not measured`: copy it as is)
Never write token numbers yourself and never estimate them: if there is no `usage:` line (setting off, no phase move at this step), the line stays as above. The numbers are as of the last turn or subagent end, not of this instant.

## The step list
`<n>` counts the steps that run for this change, in order; it is not the `§` number. `<total>` is the length of that list.

| name | runs |
|---|---|
| `intake` (§0) | always |
| `explore` (§1) | always |
| `plan` (§2) | always |
| `propose` (§3) | always |
| `implement` (§4) | always |
| `verify` (§5) | `medium`, `high`; not `low` |
| `pr` (§7) | always |
| `closeout` (§8) | always |

So `total` is 7 for `low`, 8 for `medium` and `high`. §6 (failure routing) is not a step: a retry stays inside `verify` and prints no new line, a spec gap that goes back to `plan` reprints that step's lines with the same numbers.

## Rules
- Before the risk label is confirmed the total is unknown: the `intake` start line uses `?` (`Step 1/?: intake — started`); its `done` line and every later line carry the real total.
- A step the user or a gate skips still prints `— skipped` with its number, and the total is not changed afterwards. If something changes the list mid-run (risk label overridden), say so in one line and use the new total from then on.
- Resume (`state.sh <slug> show`): print no catch-up lines; continue with the recorded step's `started` line and its ordinal in the list.
- Every host prints the same text; no host-specific tool is involved.
