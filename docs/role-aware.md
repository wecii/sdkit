# Role-aware environments

Two experiences on top of the same kit, chosen once with `sdkit init --env analyst|developer` and kept as `SDKIT_ENV` in `sdkit.env`. The design contract is [design-role-aware.md](design-role-aware.md); settings are in [guide.md](guide.md) §10.

| `SDKIT_ENV` | Repo | What you do |
|---|---|---|
| `standalone` (default) | any | The plain spec-driven workflow with OpenSpec. Unchanged |
| `analyst` | a specs repo | Write, review and version specs; split an approved spec into Jira tasks. No stack, no OpenSpec |
| `developer` | a source repo | Implement Jira tasks against a pinned, read-only approved spec (managed execution, `SDD_MANAGED=on`) |

"Role" here means a kit role (subagent) or a person's job; the person's jobs are analyst, Tech Lead and developer.

## Analyst flow

1. Put raw input in the git-ignored pre-spec directory (`PRESPEC_DIR`, default `prespec/`). `sdkit prespec check <name>` verifies it exists, is not empty, is ignored and untracked. Its content is never committed (`spec.sh publish` refuses it).
2. `/generate-specs <name>` asks the open questions, drafts the PRD, ADRs and feature specs (acceptance criteria with stable ids `AC-<feature>-<n>`) in `work/spec-draft/<id>/`, reviews the draft in fresh subagents (`scripts/review.sh`, rubric in `review.d/<artifact>.env`), corrects it, then runs `openspec-propose` so the output is an OpenSpec change in `specs/<id>/` (`proposal.md`, `design.md`, `tasks.md`, `specs/`), and reviews that output once more for fidelity. At most `SPEC_REVIEW_MAX_ROUNDS` rounds per review, then a person decides. Prose is written in `ANALYST_LANGUAGE` (default `tr`; set it in `sdkit.env`).
3. `spec.sh publish` needs a fresh PASS bound to the document's current content hash, commits on `spec/<id>`, pushes (never force) and opens or updates one PR. A review PASS is not approval.
4. The Tech Lead approves by merging; the last commit of the approval PR sets version 1.0 and status approved (`spec.sh promote`).
5. `/generate-tasks <id> --sha <SHA>` (only for an approved SHA reachable from the base branch) traces every acceptance criterion to a task, rejects cycles, and creates or updates Jira subtasks idempotently by `externalId`. It never assigns anyone.
6. `/update-specs <id>` changes an existing spec, or answers a change request (below). After approval every change is a delta under `specs/<id>/changes/<slug>/` on branch `spec/<id>--<slug>`; changes on the same base are siblings, and `/merge-specs <id>` merges them into the next revision (design: [design-spec-merge.md](design-spec-merge.md)). `spec.sh check <id>` is the one command the Tech Lead runs before merging; `generate-tasks` refuses a revision with unmerged siblings and creates only the tasks of the changes in it.

## Developer flow

```
/spec-driven-dev PROJ-123        # managed: sdd.sh start --ticket PROJ-123
```

The ticket's task contract is fetched and validated, the pinned `specSha` must resolve in the read-only `SPECS_DIR` submodule and its dependencies must be done. The phases (`intake, proposed, red, green, verified, pr, done`) and all gates are the standalone ones; OpenSpec is not used. When verification passes, `sdd.sh evidence-sync` comments the evidence and PR link on the ticket and moves it to `JIRA_REVIEW_STATUS`. `sdd.sh done --merged` requires the PR head to be merged into the resolved base. Step detail: `skills/spec-driven-dev/references/managed.md`.

## Version policy and 1.0 promotion

0.1 is the first draft, 0.N are pre-approval updates, 1.0 is the first approved version, 1.N compatible changes, N.0 breaking ones (`publish --breaking`). The immutable reference is the git commit SHA; the version is a label. Sequence: publish (0.N, status draft) -> review PASS -> approval PR whose last commit is `promote` (1.0, approved) -> human merge = approval -> `generate-tasks` accepts that SHA. A publish after approval sets the status back to draft.

## Jira task contract

A subtask carries a fenced `sdkit-task` JSON block in its description: `externalId` (`<specId>:<taskKey>`, the upsert key), `specId`, `specVersion`, `specSha`, `acceptanceCriteria[]`, `risk`, `dependencies[]` (Jira keys), `scope[]`, `parent`. A missing field rejects the intake (`jira.sh` exit 4). The task key is a hash of ACs and scope, so reordering or retitling does not create a duplicate. Enable with `TRACKER=jira`, `JIRA_*` in `sdkit.env` and, personally, `JIRA_EGRESS=allow` and `JIRA_TOKEN_ENV`. Without egress there is no network call; the Jira MCP path is used by the skills instead, with `jira.sh validate-task` as the validator.

## Spec-change request loop

When the spec is wrong or unclear, the developer runs `sdd.sh block --spec-change --reason R`. A change-request issue is filed (blocking the ticket), the ticket moves to `JIRA_BLOCKED_STATUS`, and `advance` and `gate` refuse while the task is blocked. The analyst answers with `/update-specs`, the Tech Lead merges a new approved revision, and the developer resumes with `sdd.sh revalidate --sha NEW`: old evidence is dropped and the task returns to intake/proposed.

## EGM integration and honest limitations

The spec review is designed to use the EGM `egm-review-loop` skill, or the `spec-reviewer` role through `run-role.sh`. `review.sh` keeps the evidence honest: fresh isolation only, hash-bound, stale after any edit, `isolation=none` never PASS, accepted findings need a person.

Not verified:
- EGM end to end, and live Jira and GitHub calls. Tests use stubs and fake `curl`.
- Fresh-subagent isolation on non-Claude hosts. Such a host records `NOT_RUN`, never PASS.
- Whether a skill may invoke `egm-review-loop` (`disable-model-invocation: true`).

## Migration and compatibility

- The default `SDKIT_ENV=standalone` is unchanged: same phases, OpenSpec, scripts. `upgrade` keeps the value and appends new settings (commented where they need your input).
- Managed mode does not use OpenSpec. A task opened with `--ticket` keeps its managed gates even if `SDD_MANAGED` changes later.
- The legacy flow remains; without `SDD_MANAGED=on` the managed commands are unknown commands.
- Versions are not bumped by this change; promotion to 1.0 of the kit itself follows the release procedure in CONTRIBUTING.md.

## Unresolved decisions

- Squash-merge detection for `sdd.sh done --merged` (a squashed head is not an ancestor of the base).
- Telemetry reject codes for the new refusals (spec, review, managed).
- Git writes inside `specs/` are not blocked by `guard-pr`; the submodule is read-only by convention and by `sdd.sh` checks only.
- Jira REST paths and the search endpoint (`JIRA_SEARCH_PATH`, `JIRA_API_VERSION`) are unverified against a live Jira.
