# Managed mode (`SDD_MANAGED=on`)

Read at step 0 when `<project-dir>/sdkit.env` has `SDD_MANAGED=on` (set by `SDKIT_ENV=developer`). The analyst side already wrote and approved the spec and split it into Jira subtasks; this repo implements one subtask. The phases and every gate stay the same (`intake → proposed → red → green → verified → pr → done`); managed mode only adds checks. Contract: `docs/design-role-aware.md`, sections "Task contract" and "Managed execution".

What does not happen here: no PRD, architecture or spec is written or regenerated, the OpenSpec skills (`openspec-*` / `opsx:*`) are not invoked, and nothing under `SPECS_DIR` (default `specs/`, the read-only approved-specs submodule) is edited (`<sdd> gate edit` denies it).

## Steps mapped to Jira

| Step | Managed mode |
|---|---|
| 0. Intake | `<sdd> start --ticket <KEY> [--risk <label>] [--profile ...]`. It fetches the subtask (`jira.sh fetch`), validates the task contract (`jira.sh validate-task`), checks that the pinned `specSha` is a commit in `SPECS_DIR` and that the submodule's HEAD contains it, and that every dependency is done (`jira.sh deps-ready`). Any failure refuses the start and says why (a missing field, an unknown revision, the open dependencies). The risk comes from the task; `--risk` can only raise it, the risk floor still applies. Show the user the ticket, the spec revision and the risk before you continue. |
| 1. Explore | Read the spec at the pinned revision (`git -C <SPECS_DIR> show <specSha>:<path>`) and the acceptance criteria the task names; `scout` for the code. No `openspec-explore`. |
| 2. Plan gate | As usual (`references/plan-gate.md`), on the task's `scope` and acceptance criteria. Scope beyond the task's `scope` is a question for the user, not a silent extension. |
| 3. Propose | `start` wrote `<project-dir>/work/<KEY>/proposal.md` with one `D<n>: ... \| Verified by: ...` line per acceptance criterion. Refine each condition from the spec text, keep the D ids and a method on every line (`<kit>/scripts/dod-check.sh <proposal>`), write `design.md` next to it for `high`. `<sdd> advance proposed` re-fetches the contract (it must still pin the same `specSha`), re-checks the revision and the dependencies, and runs `dod-check.sh`. |
| 4-6. Implement, verify | Unchanged. `<sdd> advance verified` also re-checks that the pinned `specSha` still resolves; the attestation records `ticket` and `specSha`. |
| 7. PR | Push and open the PR against `<diff-base>` (`resolve-base.sh`: the release branch with `BASE_BRANCH_MODE=release`), then `<sdd> advance pr` (it records the PR head). Then `<sdd> evidence-sync --pr <url>`: the evidence summary and the PR link as a Jira comment, then the status (`JIRA_REVIEW_STATUS`, default `In Review`; `--status none` to leave it). Safe to re-run: the same evidence is sent once, and a failed call records nothing. |
| 8. Closeout | After the merge: `<sdd> done --merged` (= `advance done`): it checks that the PR head is in the resolved base and refuses otherwise, so done is never declared. A squash merge is not detected: tell the user and let them confirm in Jira. No `openspec-sync-specs` / `openspec-archive-change`. The rest of §8 (memory, telemetry, work dir, worktrees) as usual. |

## Spec defect: block, change request, revalidate

When the spec is wrong, contradictory or not implementable as written (a spec gap in §6 terms), do not work around it and do not edit `SPECS_DIR`:

1. `<sdd> block --spec-change --reason "<what is wrong>" [--section <spec section>] [--proposal "<suggested fix>"]`. It files the change request in Jira (`jira.sh change-request`, linked as blocking the subtask) and only then sets the block; when the call fails it exits non-zero and nothing is blocked: fix the Jira access and run it again. It also moves the subtask to `JIRA_BLOCKED_STATUS` (default `Blocked`) when that transition exists (a warning otherwise).
2. While blocked, every `<sdd> advance` and `<sdd> gate` (code edits, push, PR) refuses. Tell the user the change request key and stop.
3. Resume only when the analyst side has approved and merged the revised spec AND updated the subtask to pin the new revision: update the submodule (`git -C <SPECS_DIR> fetch && git -C <SPECS_DIR> checkout <new sha>`, commit the pointer), then `<sdd> revalidate --sha <new sha>`. It refuses the same SHA, a revision `spec.sh approved-sha` does not confirm, and a contract that still pins the old one; it re-runs the intake checks, regenerates the DoD (the old one is kept as `proposal.md.prev`), drops every verdict, evidence record and the attestation of the old revision, and returns the task to `intake`, then runs the proposed gate again. Re-apply your DoD refinements and continue from §3; RED and verification run again.

`<sdd> status` shows `ticket=`, the pinned spec and `blocked=` while a block is set; `<sdd> transitions` lists the managed additions.
