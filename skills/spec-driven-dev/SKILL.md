---
name: spec-driven-dev
description: End-to-end, project-agnostic spec-driven task workflow — analyst intake (tracker ticket or free text), risk classification, a detailed plan gate with the user before any proposal, propose with a test-verified Definition of Done, risk-branched test-first implementation by role, independent verification, PR, and closeout. Use this instead of manually chaining opsx:explore/propose/apply/verify/archive for any new task.
license: MIT
metadata:
  author: spec-driven-kit
  version: "3.0"
---

Orchestrates the full task lifecycle by driving the existing `openspec-*` (`opsx:*`) skills in sequence and adding what they do not: a completeness check, a plan gate, role-based work (optionally parallel), a risk-scaled independent verification gate and a closing loop. It does not reimplement `opsx:explore`/`propose`/`apply`/`verify`/`archive`/`sync`.

You are the **orchestrator** (`core/roles/orchestrator.md`). Roles are agents named in `agents/`: `analyst`, `scout`, `engineer`, `developer`, `test-writer`, `devsecops`, `verifier`, `reviewer`, `security-auditor`. How to ask the user, run a role or run roles in parallel on your host: `references/hosts.md`. How to brief a role: `references/handoff.md`. Model per task (`size:` in tasks, `TIER` in the handoff): `references/model-routing.md`, read when you write the execution plan. Token rules: `rules/token-economy.md`; test rules: `rules/test-first.md`. Read a reference only at the step that names it.

**Progress**: at the start and end of every step print one line `[sdkit] Step <n>/<total>: <name> — started|done` (`references/progress.md`: format, the step list per risk, how `total` is counted; read it once the risk label is confirmed).

## Resume

State lives in a file, not in your head: `<kit>/scripts/state.sh <slug> show` prints `<project-dir>/work/<slug>/state.json` (step, risk, branch, task statuses, retries, verdict). If one exists for this task, continue from its `step` instead of starting over; update it at every step (`state.sh <slug> set step <n>`, `task <id> <status>`). Create it once the risk label is confirmed: `state.sh <slug> init <risk> <branch>`.

## Project configuration (read first)

`<project-dir>` is the project-side directory, normally `.sdkit/` (it holds `sdkit.env`, personal; everything else in it is shared through git). A repo set up before 1.0 may still use `.claude/`, `.codex/` or `.agentkit/` with `project.env`: look for it, do not assume. Write new project knowledge there (memory, pitfalls, ADRs), never into a host folder. Pass it to every role in the handoff.

This skill contains no project facts. Before step 0, read:

| File | Provides |
|---|---|
| `<project-dir>/sdkit.env` | `BASE_BRANCH`, `DIFF_BASE_CMD`, `VERIFY_CMD`, `TRACKER`, `PROTECTED_PATHS` |
| `<project-dir>/project.md` | tracker tooling, PR tooling, **release flow / branch source**, test layout, protected-code rule, **risk rubric** |
| `<project-dir>/known-pitfalls.md` | bug classes the verifier must scan every diff for |
| `<project-dir>/memory/INDEX.md` | only when `MEMORY=1`: durable project facts, one line each; open an entry when relevant (`references/memory.md`) |
| `<project-dir>/rules/*.md` | language and style conventions (branch naming, commits, tests) |

If `project.md` has no risk rubric, stop and ask the user to define one; never invent criteria. Throughout this document:
- `<kit>` is the kit's script root (see `references/hosts.md`).
- `<verify>` is `VERIFY_CMD` from `sdkit.env`, or when empty `<kit>/stacks/<STACK>/scripts/verify.sh`. Pipe its output through `tail -40`; the summary line and failures are what matter.
- `<diff-base>` is the output of `DIFF_BASE_CMD`, or when empty `<kit>/scripts/resolve-base.sh`.
- `<sdd>` is `<kit>/scripts/sdd.sh`, the phase machine (`intake → proposed → red → green → verified → pr → done`). **You never decide that a phase is done: `<sdd> advance` checks the gate itself and refuses when it does not hold.** Hooks and the git hooks ask the same script (`<sdd> gate`) and block code changes, push and PR out of phase (`SDD_MODE` in `sdkit.env`: `strict` is the default and denies, `guided` asks or warns, `off` disables). Never write `<project-dir>/.sdd/` by hand. `state.sh` stays the resume record; `<sdd>` is the gate.
- `<branch-source>` is the ref new branches are cut from: the "Branch source" rule in `project.md`, defaulting to `<diff-base>`.

## 0. Intake: analyst and risk label

**Input**: a ticket ID or a free-text description.

1. Fetch the ticket with the tracker tooling in `project.md` when a ticket ID is given and `TRACKER` is set; otherwise use the text as is.
2. Run the `analyst` role on it (handoff: the raw task text or ticket body, paths `project.md` and the component areas if known). It returns `READINESS`, a brief, `GAPS`, `ASSUMPTIONS` and a proposed risk label.
3. `NEEDS-INFO`: put the gaps to the user with the host's question tool, at most 4 per round, each with the analyst's suggested default as the first option. Fold the answers into the brief and re-run the analyst only if the answers opened new gaps. Do not continue while a gap that affects the Definition of Done is open.
4. Show the final brief and the proposed risk label, and let the user confirm or override the label. The confirmed label drives every branch below; never re-decide it without the user. Then open the gate: `<sdd> start <slug> --risk <label> [--profile small|standard|high-assurance] --proposal openspec/changes/<change>/proposal.md`; the profile is process weight, never a lower gate (`references/workflow.md`). Until the proposal passes `<sdd> advance proposed`, only docs, specs and project files can change.
5. **Risk is independent of ticket priority.** A low-priority ticket can still be `medium`/`high` and gets that flow.
6. Roles never call other roles. A role may end its answer with `NEEDS-LOOKUP: <question>` lines; run `scout` once for them and hand the answer back as a path.

## 1. Explore

Invoke `openspec-explore` with the brief. Ground the problem in the real code. Use `scout` for "where is / who calls" questions instead of reading broadly; do not read a file over ~150 lines whole in this session, ask `scout` or read the range you need (`references/delegation.md`, "Keep this session thin"). Do not skip this for `low`; wrong assumptions get caught here.

## 2. Plan gate (before any proposal)

Read `references/plan-gate.md` and run it. In short: for `medium`/`high` the `engineer` role drafts design, test strategy and the task split; you assemble `<project-dir>/work/<slug>/plan.md`; then you walk the user through it in batched, detailed questions (depth by risk), apply and propagate every edit, and only after the user chooses `Approve and propose` do you continue. The user can ask to update the plan at any later step; re-run only the affected rounds.

## 3. Propose (Definition of Done verified by tests)

Invoke `openspec-propose` with `plan.md` as input to produce `proposal.md` / `design.md` / `specs/` / `tasks.md`. Then require in `proposal.md` a **Definition of Done**: one line per acceptance criterion in the form `D<n>: <testable condition> | Verified by: <unit test|integration test|manual check|none: reason>`. Tasks carry `role:` / `writes:` / `after:` and `size:` (`references/parallel.md`). With `ROUTING=on` (check `<project-dir>/sdkit.env`) read `references/model-routing.md` now and give **every delegated task** a `size:`: `<sdd> advance proposed` refuses a tasks.md with a `role:` task that has none.

`high`: `design.md` must contain the **race/ordering/timing scenario**; if it is missing write it now or stop and ask.

The proposal is **incomplete** (do not proceed) until the DoD with Verified-by entries is present. `<sdd> advance proposed` proves it (it fails without a DoD list, and for `high` without the race/ordering/timing section); from then on only test files can change until RED. Check it with `<kit>/scripts/check-plan-parity.sh <plan.md> <proposal.md> <tasks.md>`; any difference is fixed or reported to the user (see the end of `references/plan-gate.md`).

## 4. Branch and role-based, test-first implementation

Branch per `rules/git.md` and the "Release flow" section of `project.md`: `git fetch`, then create `<type>/<short-description>` from `<branch-source>`. If `project.md` says the release is frozen (or no branch source resolves), **stop and ask** instead of branching from the integration branch.

**Testability check before the first test** (`rules/test-first.md`). If the code under test cannot be exercised without real infrastructure (for example a handler takes a concrete, unmockable client), stop before writing throwaway tests, name exactly what blocks it, and give the user 2-3 options with the host's question tool (add a small interface scoped to the call site / skip automated coverage and record the gap / add integration-test infrastructure). Only then proceed; update the DoD item's Verified-by if coverage changes.

Delegation: before the first spawn read `references/delegation.md` (spawn or not, result size, budgets, cache, keeping this session thin). Tests to `test-writer`, code to `developer`, pipeline/infra files to `devsecops`, each with a handoff brief (with `CONTRACTS=1` also the contract lines and the result line: `references/contract.md`; a valid contract is never a verification). Only a change of one file plus its test, at `low` risk, is yours to write in this session. Run tests, builds and linters through `<kit>/scripts/capped.sh -- <command>`: the log stays in a file, the conversation gets the failures and the tail. To run independent tasks at the same time follow `references/parallel.md` (`<kit>/scripts/plan-waves.sh` for waves, `<kit>/scripts/worktree.sh` for isolation); otherwise run tasks in order.

### `low` risk
1. Test(s) from the DoD. `<sdd> advance red --test-cmd "<command running them>"` runs it and refuses unless it FAILS; check the log for the right reason (not a compile error). Production code is editable only after this.
2. Implement, then `<sdd> advance green` (re-runs the command; refuses while it fails).
3. `<sdd> advance verified` (runs `<verify>` for `low`). 4. Go to §7; no separate verifier.

### `medium` risk
Same as `low`, then §5 is **mandatory**: `<sdd> advance verified` refuses without a verifier PASS for the current diff.

### `high` risk: separate roles, never collapsed
Use fresh role runs, never a fork of this session, so each reasons independently.
- **[A] `test-writer`**: from `design.md`'s scenario, writes a regression test against **real infrastructure** at the integration-test location in `project.md`, confirms **RED** for the expected reason, then appends the test file's repo-relative path to `<project-dir>/.frozen` (the `frozen-tests` guard denies further edits to listed files).
- **[B] `developer`**: given the frozen test, `design.md` and `proposal.md` (not [A]'s reasoning), implements to **GREEN**. If blocked by the frozen test, the fix belongs in the implementation.
- **[C] `verifier`**: §5, always mandatory.

Delete `<project-dir>/.frozen` when the task is verified or abandoned.

## 5. Independent verification gate

**Who**: the `verifier` role (`verifier-deep` for `high`), started fresh (never a fork), with `references/hosts.md` for how. For a different model family, set `VERIFIER_HOST` and run it with `<kit>/scripts/run-role.sh`. It receives only: the path to `proposal.md` (and `design.md` for `high`), `<diff-base>`, the risk label. Never the implementer's conversation or rationale.

Run it with `verifier` (`medium`) or `verifier-deep` (`high`, strong tier). It runs `<verify>`, checks every DoD item and its Verified-by evidence, scans `known-pitfalls.md`, and returns the `DOD / FINDINGS / VERIFY / VERDICT` block defined in its role.

`high` only: also run `reviewer` and `security-auditor` on the final diff, in parallel (read-only), plus the host skills named in `EXTRA_REVIEW_SKILLS` when that is set (empty by default; the roles already know the project's rules and pitfalls). Report findings as `CONFIRMED` or `PLAUSIBLE`. Changes to pipelines or infrastructure always get `security-auditor`. At `high`, `<sdd> advance verified|pr|done` need a PASS from each of the three roles, from a registered run on this diff (`<sdd> evidence`; other hosts: `run-role.sh`; details: `references/hosts.md`).

Check the verifier's output with `<kit>/scripts/parse-verdict.sh - --proposal <proposal.md>`; it is the only validator (structure, PASS/FAIL per DoD item, verdict consistent with the findings, every DoD item judged). A verdict is recorded against a fingerprint of the current diff, so your own claim counts for nothing and any later edit makes it stale. Recording depends on the host: **Claude Code: do not pass `--record`**; the `SubagentStop` hook runs the same validation and records a well-formed verdict itself (the `guard-pr` hook denies `--record` there), and a malformed one is reported back to you instead of recorded. **other hosts: pass `--record`** (`parse-verdict.sh - --proposal <proposal.md> --record`); they have no such hook, and a malformed block records nothing. Then `<sdd> advance verified` on PASS; it writes `<project-dir>/attestations/<slug>.json`, the proof the CI gate checks. **Commit it with the change** (any file edited after this makes it stale: re-verify and let it be rewritten). Exit codes: exit 0 = PASS, 1 = BLOCK, 2 = malformed or inconsistent (ask the verifier for the exact format once; this does not count as a retry).

**Blocking**: `VERDICT: BLOCK` (any DoD `FAIL` or any `CONFIRMED` finding) blocks the PR. `PLAUSIBLE` findings are recorded, never block. `PASS` goes to §7. `low` skips this section; `medium` and `high` cannot.

## 6. Failure routing and loop limit

On `BLOCK`, classify the cause:
- **Implementation bug** (sound DoD, code does not meet it): back to `developer` for **exactly one** retry, handing it only the failing items/findings. Take the retry with `state.sh <slug> retry <task>`: exit 0 means go ahead, exit 1 means the retry is spent, stop. No need to involve the user for this first retry.
- **Spec gap** (DoD item inconsistent, unsatisfiable, or the brief was ambiguous): back to the plan gate for the affected rounds and **tell the user immediately**. Do not retry against a broken target.

A **second** `BLOCK` on the same task, whatever the cause, stops automatic retries. Summarize what failed both times, the diff and branch state, and wait for the user. Never run a third automatic loop.

## 7. PR and merge

`git push`, `gh pr create`, `glab mr create` and `open-pr.sh` are denied (hook) and blocked (git pre-push) unless the task is `verified` and the diff is unchanged since. After the PR is open: `<sdd> advance pr`.

Per `rules/git.md` and the PR tooling in `project.md`: commit in the conventional format, push, and **open the PR yourself** (never hand it back as a to-do; the kit ships `scripts/open-pr.sh` for Bitbucket, GitHub and GitLab, see `docs/hosts.md`) against the merge target in `project.md`. State what changed, why, and how to test, plus the verification result (DoD PASS summary; for `high` the findings with verdicts) and the last `<verify>` output. Relay the post-merge steps from `project.md`'s release flow to the user; do not run them.

## 8. Closeout

After merge, `<sdd> advance done` (closes the gate and clears `.frozen`), then invoke `openspec-sync-specs` (fold specs into `openspec/specs/`) and `openspec-archive-change` (close the change). If `openspec/` is gitignored, this runs locally only. If `MEMORY=1`, first promote what the task learned (`references/memory.md`: candidates from `notes.md`, the user picks). With `TELEMETRY=1`, run `<kit>/scripts/telemetry.sh archive <slug>` first. Then delete `<project-dir>/work/<slug>/` (it holds `state.json`) and remove task worktrees (`<kit>/scripts/worktree.sh clean`).

## Guardrails

- Never let the same role or session both implement a change and decide it is verified.
- Never skip the Definition of Done, its Verified-by entries, or the plan gate, however small the task looks.
- Never classify risk silently; the user confirms or overrides it before branching.
- Never propose before the user approved the plan; never leave `proposal.md` and `plan.md` silently different.
- Never loop verification more than once automatically.
- Never parallelize tasks with overlapping `writes:`, or the verifier with the implementer.
- If a required artifact (brief, plan, proposal, design scenario, project config) is missing or unclear, stop and ask. Do not guess.
- Never silently work around a testability blocker or drop DoD coverage because of one.
- Never use a profile to skip a gate: `small` is for `low` only, `high-assurance` adds checks; `<sdd> policy` states what the task requires.
- Never change code, push or open a PR outside the phases that allow it, and never work around a denial; do the step it names.
- Never hardcode project facts (branch names, tools, paths, rubric) into this skill; they belong in `<project-dir>/project.*`.
