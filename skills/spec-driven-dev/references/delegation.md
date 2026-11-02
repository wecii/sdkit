# Delegation, budgets and cache

Read this when you write the execution plan (plan section 5) and before the first spawn. `model-routing.md` says which model a task gets; this says whether to spawn at all, what comes back, and how to keep the bill measurable.

## Spawn or do it yourself
A spawn costs a role prompt, a handoff and a result to read. Do it yourself when the work is one or two files, or needs the conversation you already hold. Spawn when:
| Situation | Role |
|---|---|
| a question about where something is or who calls it | `scout` (light), once, with all the questions batched |
| work whose result can be checked without your reasoning (independent check) | `verifier`, `reviewer`, `security-auditor` |
| a write set disjoint from yours that you do not need to watch | `developer`, `test-writer`, `devsecops` (`parallel.md`) |
| a design or a plan check | `engineer`, `analyst` |
`low` risk usually means no spawns beyond the analyst. Roles never spawn roles; the call tree is always orchestrator, then role, never deeper.

## What comes back
- The role answers in at most 15 lines plus its structured block. Read-only roles cannot write files, so when the long form is worth keeping store the answer yourself under `<project-dir>/work/<slug>/out/<role>-<n>.md` (`run-role.sh --out`, or write the text). Writing roles put their long form at the handoff's `OUT:` path.
- Read the stored file only when the summary is not enough. Never paste a role's long output into your own next handoff: give its path.
- `SUBAGENT_RESULT_MAX_LINES` (`sdkit.env`) makes the `SubagentStop` hook warn when an answer is longer. It warns; it never blocks.
- Scout answers: before spawning, `<kit>/scripts/lookup-cache.sh get <slug> "<question>"`; after, `put`. A hit costs nothing; the entry is dropped when HEAD or the uncommitted diff changes.

## Keep this session thin
Every token that enters this session is read again on every later turn, so a result carried for 100 turns costs 100 times its size. This session holds decisions and state; content stays in files or in a role's own context.
- **Reading**: a file over ~150 lines is not read whole here. Ask `scout` (batch the questions), or read the range you need. A hit in `lookup-cache.sh` costs nothing.
- **Running**: tests, builds, linters and anything that can print more than ~40 lines go through `<kit>/scripts/capped.sh -- <command>`. It prints the exit code, the failure lines and the tail, and stores the full log under `work/<slug>/out/cmd-*.log`; open the log only when that is not enough. `NOISY_CMD_PATTERNS` (`sdkit.env`) makes the `guard-noisy` hook ask for it on commands you list.
- **Writing**: implementation goes to `developer` / `test-writer` / `devsecops`. This session keeps the plan, the gate and the 15-line answers.
- **Boundaries**: after `advance proposed` and `advance green` the state is in files (`CONTEXT_HINT=1` prints a note). A `/clear`, a new session or a compaction there loses nothing; resume as below.
- **Measure**: `<kit>/scripts/usage.sh context` shows which tool results this session carried and what carrying them cost (tokens x the turns after each). Cap or delegate the top entries.

## Budgets (all off until `sdkit.env` sets them)
| Setting | Effect |
|---|---|
| `MAX_SPAWNS` | `state.sh <slug> spawn` counts every spawn; past the limit the next one needs the user |
| `TOKEN_BUDGET_TASK` | `usage.sh budget` compares the ledger (in + out + cache-write) with it; warns at `TOKEN_BUDGET_WARN_PCT` (70), stops at 100% |
| `SDD_MODE` | `strict` asks before the spawn that goes over, `guided` only warns, `off` ignores both |
On Claude Code the `guard-budget` hook does the counting on every `Agent` call. Elsewhere `run-role.sh` does it at the spawn point (exit 3 when over; re-run with `--ignore-budget` once the user agreed). The token budget needs `USAGE_LOG=1`; the spawn limit does not. On a host that reports no tokens the ledger stays empty and the token budget stays silent: it never guesses.
When a budget stops you, tell the user what is used, what is left and what the next step would cost, and let them choose: continue, raise the limit, or stop. Do not shrink the verification to fit.

## Cache
The model's prompt cache works on an identical prefix and is per model, with a short lifetime. So:
- Keep the fixed lines of a handoff first and the per-spawn lines last (`handoff.md` is in that order).
- Within a wave, give same-tier tasks the same model; switching model mid-chain throws the cache away.
- Start the spawns of a wave together, not minutes apart.
- Do not edit the standing files (`project.md`, rules) in the middle of a task.
`usage.sh report` prints the cache hit rate, so a change here can be measured.

## Keep the session resumable
At each step boundary run `state.sh <slug> set step <n>`, and put what you learned in `work/<slug>/notes.md` (with `MEMORY:` lines when `MEMORY=1`, see `memory.md`). After that `/clear` or a compaction loses nothing: resume from `state.sh <slug> show`, `plan.md` and `notes.md`. Suggest a clear to the user at a boundary when the conversation has grown large; never in the middle of a step.
