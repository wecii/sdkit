# Parallel work

Default is sequential. Parallel runs multiply token use, so use them only when they save wall-clock time on genuinely independent work.

## When
Use parallel only if all hold: risk is `medium` or `high`, at least two tasks have disjoint write sets, and the host can run subagents
(or you can run separate CLI processes, see `hosts.md`). Otherwise run tasks in order.

## Task format (in `tasks.md` and plan.md section 5)
```
- [ ] T3 Add retry to the importer | role: developer | size: medium | writes: services/importer/ | after: T1
```
- `role:` one of `developer`, `test-writer`, `devsecops`, `engineer`.
- `size:` `small|medium|large`: picks the model tier for the task (`model-routing.md`). Optional with `ROUTING=off`; with `ROUTING=on` (tiered) `sdd.sh advance proposed` refuses a task that names a `role:` and has no `size:`. `plan-waves.sh` shows it and otherwise ignores it.
- `writes:` comma-separated paths or directories the task may change. Anything not listed is read-only for that task.
- `after:` task ids that must be merged first (omit if none).

`scripts/plan-waves.sh tasks.md` groups tasks into waves: tasks in one wave have no dependency on each other and no overlapping
`writes:`. Tasks with overlapping writes land in different waves. Run it, show the user the waves in the plan, and follow them. A wave never has more than `MAX_PARALLEL` tasks: a larger group is split and the rest waits for the next wave.

## Safe parallel pairs
| Pair | Why it is safe |
|---|---|
| `test-writer` ‖ `developer` on one DoD item | Only when the test and the interface are fixed in the plan first; the developer must not edit the tests |
| `developer` ‖ `developer` | Disjoint `writes:` only |
| `developer` ‖ `devsecops` | Source vs pipeline/infra files |
| `reviewer` ‖ `security-auditor` | Both read-only on the same final diff |

Never parallelize: the `verifier` with the implementer, two writers on one file, anything that depends on an unmerged result.

## Isolation
Each writing task runs in its own git worktree so nothing collides on disk:
```
scripts/worktree.sh add T3        # new worktree + branch from the current branch
scripts/worktree.sh path T3       # absolute path: put it in the handoff as WORKTREE
scripts/worktree.sh merge T3 tasks.md   # check T3's changes against its writes:, then merge (fast-fail on conflict)
scripts/worktree.sh clean         # remove merged worktrees
```
The orchestrator merges wave by wave, runs `<verify> --fast` after each merge, and only then starts the next wave. A merge conflict
means the write sets were wrong: stop, tell the user, fix the plan.

A task that strays outside its `writes:` set is not merged (`scripts/check-writes.sh`, also usable by hand while the role works). Isolation does not depend on the host's own worktree feature, so it works the same everywhere: the handoff carries `WORKTREE`, and a host that cannot pin a subagent's directory runs the role as a separate process with `scripts/run-role.sh <role> --handoff <file> --cwd <worktree>`.

## Limits
`MAX_PARALLEL` in `<project-dir>/sdkit.env` (default 3) is the most subagents or `run-role.sh` processes running at once. `plan-waves.sh` enforces it when it builds waves; never start more than that, also not for read-only reviewers, unless the user raises it. Each gets a handoff brief (`handoff.md`), not the conversation.

## Dispatch rules (opt-in, `scripts/dispatch.sh`)
`PARALLEL=on` (personal `sdkit.local.env`) is required; off by default. `dispatch.sh claim <id> tasks.md` refuses a task that is already active or done, whose `after:` tasks are not done, whose `writes:` overlap an active claim, or when `MAX_PARALLEL` claims are active. `done <id>` after the merge; every recorded verifier/reviewer/auditor PASS is then stale and must be re-run on the merged diff. `release <id>` for an interrupted task. Parallel runs multiply token use: the wall-time saving is not assumed, measure it.
