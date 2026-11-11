# spec-driven-kit guide

This guide describes every part of the kit (skill, agent, hook, script, configuration) and how they work together.
For a quick install see `README.md`; for PR hosts see `hosts.md`.

Contents: 1. What it is · 2. Overview · 3. Plugin side and project side ·
4. Flow: spec-driven-dev · 5. Skills · 6. Roles ·
7. Hooks and guards · 8. Verification engine ·
9. Helper scripts · 10. Configuration reference ·
11. Install flows · 12. Permission model · 13. Limits ·
14. Extending · 15. File map ·
16. Hosts: Claude Code, Codex, OpenCode, Cursor, Gemini · 17. Parallel work · 18. Token economy

---

## 1. What it is

Instead of tackling a task with Claude Code "in one go, unchecked", the kit runs it through **a defined process**:

```
task ──► analyst (anything missing?) ──► risk label (you confirm) ──► explore
     ──► PLAN GATE (you approve in detail) ──► proposal + test-verified "Definition of Done"
     ──► test first (RED) ──► implement with roles (GREEN, in parallel if needed)
     ──► independent verification ──► PR (the agent opens it) ──► closeout
```

The kit is an **agent development library**: roles and flow are written tool-independently, and adapters are generated for Claude Code, Codex, OpenCode, Cursor and Gemini CLI (section 16).

It tries to guarantee four things:

1. **The same model cannot both write the code and say "done".** For medium and high risk, verification is done by a separate agent that never saw the implementation.
2. **Rules are a mechanism, not a reminder.** A dangerous or wrong step (`kubectl` against prod, reading a secret file, merging `develop` into a feature
   branch, saying "done" with broken code) is blocked by hooks or needs approval.
3. **Test-first thinking.** Every Definition of Done item says how it is verified; a test that can be written is written before the code (`rules/test-first.md`).
4. **Project knowledge is not in the kit.** Risk criteria, rules, test layout and project-specific checks live in the project dir
   in the repo. The kit contains nothing project-specific, so it works in every repo.

Two extra principles: **tokens are neither wasted nor starved** (section 18), and **nothing moves on to the proposal (`propose`) until you approve the implementation plan** (section 4, step 2).

---

## 2. Overview

| Part | Count | What it does |
|---|---|---|
| **Skill** | 7 | Instruction sets that run the task: `spec-driven-dev` (main flow, loaded progressively via `references/`), `incident-to-rule`, `scaffold-init`, `scaffold-doctor`, and the role-aware trio `generate-specs`, `update-specs`, `generate-tasks` ([role-aware.md](role-aware.md)) |
| **Role** | 11 | Tool-independent definitions under `core/roles/`: `orchestrator`, `analyst`, `scout`, `engineer`, `developer`, `test-writer`, `devsecops`, `reviewer`, `security-auditor`, `spec-reviewer`, `verifier`. Ten are generated as subagents; `verifier`'s strong-tier twin `verifier-deep` (via `deep: strong`) is generated too, so **11 role files** per host |
| **Hook** | 19 + 1 | 19 checks that run automatically during tool steps and session boundaries in Claude Code (including `guard-readonly`, `usage-log`, `guard-budget`, `guard-noisy`, `result-size`, `check-contract`, `value-report`) and the `adapt.sh` shim through which other hosts call the same hooks. Where there are no hooks, git hooks enforce most of the same rules |
| **Verification engine** | 1 core + steps per stack | `scripts/verify-core.sh` (diff base, changed files, `verify.d`, green-result cache) + `stacks/<stack>/scripts/steps.sh` (the stack's own checks) |
| **Stack** | 7 | `go`, `spring-boot` and `jvm` (Maven/Gradle), `python`, `nextjs`, `react-native` (the last two share the `stacks/_node/` helper) and `generic` if detection fails. Contract: `stacks/README.md` |
| **Script** | 38 | `sdd.sh`, `resolve-base.sh`, `open-pr.sh`, `guard.sh`, `plan-waves.sh`, `worktree.sh`, `state.sh`, `parse-verdict.sh`, `check-plan-parity.sh`, `dod-check.sh`, `digest.sh`, `test-select.sh`, `adapter.sh`, `dispatch.sh`, `knowledge.sh`, `recover.sh`, `redact.sh`, `audit.sh`, `pr-check.sh`, `check-writes.sh`, `usage.sh`, `pricing.sh`, `telemetry.sh`, `contract.sh`, `workflow.sh`, `route.sh`, `memory.sh`, `lookup-cache.sh`, `capped.sh`, `run-role.sh` + `verify-core.sh` and `verify-lib.sh` (engine; not run directly) |
| **Rules** | 4+ | `core/rules/`: `general`, `git`, `test-first`, `token-economy` (+ stack rules) |
| **Templates** | | Project-side files to fill in for a new repo (`templates/`, `stacks/go/`, `core/rules/`) |
| **Host** | 5 | `claude`, `codex`, `opencode`, `cursor`, `gemini`; role/guard format in `bin/emit/<host>.sh` + `core/hosts.env` (section 16) |
| **Tools** | 6 | `bin/init.sh`, `bin/doctor.sh`, `bin/sync.sh`, `bin/upgrade.sh` (`bin/migrate.sh` for `--migrate`), `bin/build-adapters.sh` + the single command `bin/sdkit` |

With the plugin installed, the names you see are namespaced: `spec-driven-kit:spec-driven-dev`,
`spec-driven-kit:verifier`. The slash command also works without the namespace: `/spec-driven-dev`. In Codex the skill is invoked with `$spec-driven-dev`; for other hosts see the table in section 16.

---

## 3. Plugin side and project side

The kit has two parts, and the split between them determines everything.

| | Where it lives | Who writes it | Examples |
|---|---|---|---|
| **Plugin side** (generic) | This repo, installed as a Claude Code plugin | Kit maintainers | skills, agents, hooks, verification engine, scripts |
| **Project side** (specific) | `.sdkit/` in each repo (`.claude`, `.codex` or `.agentkit` in pre-1.0 installs; see below) | That project's team | `sdkit.env` (the team's shared settings), `project.md`, `rules/`, `known-pitfalls.md`, `adr/`, `verify.d/`, `memory/` (all in git) and the personal `sdkit.local.env` |

The plugin side **reads the project side at run time**. Nothing is hard-coded: branch name, risk criteria, protected paths and
prod cluster name always come from the project files.

### Run modes

| Mode | When | How |
|---|---|---|
| **plugin** (default) | Normal use (Claude only) | The repo holds only the project side. Hooks, agents, skills and scripts come from the installed plugin |
| **copy** | Environment where the plugin cannot be installed | `init.sh --mode copy` copies hooks/agents/skills to `.claude/` and kit scripts to `<project-dir>/scripts/`; `sdkit.env` points to them; `sync.sh` updates them |

Hooks and scripts use the path in `VERIFY_CMD` / `DIFF_BASE_CMD` (relative to the repo) if set, otherwise the plugin's own script.

### Project dir: `.sdkit/`
Since 1.0 there is a single project dir for every host: **`.sdkit/`**. It **is committed and is the same for everyone**; only personal or generated files stay out (`.sdkit/.gitignore`). Skills, role texts and docs refer to this directory as `<project-dir>`. In pre-1.0 installs the directory is `.claude`, `.codex` or `.agentkit` and the settings file is `project.env`; all of these keep working, and `sdkit upgrade --migrate` moves them to `.sdkit/`.

| Under `.sdkit/` | Git | Note |
|---|---|---|
| `sdkit.env`, `project.md`, `rules/`, `known-pitfalls.md`, `adr/`, `verify.d/`, `roles.d/`, `memory/`, `attestations/` | **yes** | Shared by the team; updated over time (updates always target this place). `sdkit.env` is the team's machine-readable policy: release flow, protected paths and branches, prod cluster, secret patterns, stack and verification settings, memory location |
| `sdkit.local.env` | no | Personal, read after `sdkit.env` and overrides it: token budget and limits, `USAGE_LOG`, `USAGE_LINE`, `MAX_PARALLEL`, memory behaviour (`MEMORY_AUTOLOAD`, `MEMORY_PROMOTE` ...), host and model choice |
| `work/`, `.frozen`, `.verify-cache/`, `.sdd/` | no | Run time |
| `hooks/`, `roles/`, `tiers.env`, `scripts/*` (except `sdd.sh`, `resolve-base.sh` and `env.sh`, for CI), `.scaffold-*` | no | `sdkit init` generates the same for everyone |

In the host directories (`.claude/`, `.codex/`, `.cursor/`, `.gemini/`, `.opencode/`) only the basic entry files are committed: `AGENTS.md` and `.claude/CLAUDE.md` (kit block). Everything the kit generates there (on Claude `settings.local.json`, roles, hooks, `.agents/`, `.githooks/`) is written to this clone's `.git/info/exclude`; the project's `.gitignore` is not touched. The kit does not interfere with the project's own skill, command and agent files. The kit's `CLAUDE.md` and `AGENTS.md` blocks tell the agent to write new knowledge to `.sdkit/`, not to the host directory.

### Who edits what (ownership)

**Rule: a developer never changes a single line in the kit repo.** They clone the kit and install it into their own repo with `init.sh`; the only place they edit is their own repo.
The kit leaves everything that can be configured in a file on the project side:

| File | Owner | When the kit is updated |
|---|---|---|
| `project.md`, `rules/`, `known-pitfalls.md`, `verify.d/`, `adr/`, `roles.d/`, `memory/`, the project's own skills/agents/commands and the host's own memory files | **Project** | The kit never touches them again |
| `sdkit.env` | **Team** | Committed shared policy. The kit only appends settings that are new in the template; it does not touch existing lines and values |
| `sdkit.local.env` | **Each developer** | Not in git; same rule: only new settings are added |
| `AGENTS.md`, `CLAUDE.md`, `.codex/config.toml` | **Shared**: the kit writes only the block marked `spec-driven-kit:begin … :end`; everything outside the markers belongs to the project | `sync.sh` refreshes only the block |
| `.claude/settings.json` (if present), `.cursor/hooks.json`, `.gemini/settings.json` | **Shared**: the kit adds only its own keys and entries (plugin, marketplace, permissions, `adapt.sh` / kit hooks); your env, permissions, hooks and other keys stay as they are | `sync.sh` refreshes only the kit entries |
| `.sdkit/scripts/`, `.sdkit/hooks/`, `.sdkit/roles/`, `.githooks/`, host role files (`.codex/agents/` …), `.agents/skills/`, on Claude `.claude/settings.local.json` | **Kit** (managed copy; do not edit, not in git) | `sync.sh` updates them; gives `CONFLICT` if you changed them locally |

To customize the kit's behaviour, instead of editing a kit file: add project knowledge to a role's job → `<project-dir>/roles.d/<role>.md`
(each role also reads it if present; it cannot relax the rules); OpenCode's old `bash` permission key → `OPENCODE_SHELL_KEY=bash` in `sdkit.env`; model/tier →
`RUN_ROLE_MODEL_*` in `sdkit.env`; risks, test layout, release flow → `project.md`. Do not write notes inside the marked block; write your own text outside the markers. `.scaffold-shared` records which share of which file belongs to the kit; `sync.sh --check` and `doctor.sh` check
that the kit's share is up to date. First `upgrade` in an existing repo: if `AGENTS.md`/`CLAUDE.md` has no markers, the block is appended at the end; text written by
old kit versions that is still in the file is deleted by hand once.

### The three main project-side files

- **`sdkit.env`**: read by machines (hooks and scripts `source` it). Branch, stack, tracker, protected paths, optional modules. See section 10.
- **`project.md`**: read by humans and the model. Tracker tool, PR tool, commit scopes, test layout, protected-code rule, **risk rubric**,
  release flow (if any). The flow does not start without the rubric.
- **`known-pitfalls.md`**: the classes of bugs the project has had. The verifier checks every diff against this list.

---

## 4. Flow: spec-driven-dev

The main skill. Starts with `/spec-driven-dev <ticket or description>`. It runs the steps below in order, calling the OpenSpec skills
(`openspec-explore`, `openspec-propose`, `openspec-sync-specs`, `openspec-archive-change`). The main session plays the **orchestrator** role.
The skill is kept short; details are under `references/` and read only at the relevant step (`plan-gate.md`, `parallel.md`, `handoff.md`, `hosts.md`, `model-routing.md`, `progress.md`).

**Progress line.** At the start and at the end of every step the orchestrator prints one line, `[sdkit] orchestrator · Step 5/8: implement — started` / `… — done`, so the developer sees which step runs and how many are left. The total counts only the steps that run for this change (7 for `low`, which has no verification step; 8 for `medium` and `high`); failure routing (§6) is not a step. Before the risk label is confirmed the total is shown as `?`. The format and counting rules are defined once in `skills/spec-driven-dev/references/progress.md`.

### Step 0: Input, analyst and risk label
- If a ticket number is given and `TRACKER` is set, the ticket is fetched; otherwise the description becomes the task directly.
- The **`analyst` role** reviews the task: goal, testable acceptance criteria, scope and out of scope, errors/edge cases, data impact, performance/security
  requirements, dependencies, testability. It finds what can be answered from the code itself and asks the user only what the code cannot answer.
  Output: `READINESS: READY|NEEDS-INFO`, task brief, `GAPS` (what is missing, why it matters, question, suggested default), `ASSUMPTIONS`, proposed risk label.
- The analyst runs at `low` risk too (cheap and consistent; depth is set by tier, not by risk). Roles do not call other roles: lookup questions it cannot answer are written at the end of its output as `NEEDS-LOOKUP: <soru>` lines, and the orchestrator runs `scout` **once** and hands the answer back as a path.
- If `NEEDS-INFO`, the gaps are asked to you as at most 4 questions per round (suggested default as the first option). No progress while a gap that affects the DoD is open.
- **You confirm or change** the risk label (`low` / `medium` / `high`); after that it does not change unless you say so. Risk is independent of ticket priority.
- The task state is written with `state.sh <slug> init <risk> <branch>` to `<project-dir>/work/<slug>/state.json` (see "Resuming" below).

### Step 1: Explore
`openspec-explore` grounds the problem in the code. "Where is it defined / who calls it" questions go to the cheap `scout` role. Not skipped at `low` risk either.

### Step 2: Plan gate (before the proposal)
The final check of what will be done, **before** `propose`, by asking you in detail. The plan is kept in `<project-dir>/work/<slug>/plan.md` (personal, not in git).
At `medium`/`high` risk the `engineer` role prepares the draft design, test strategy and task split; at `low` risk the orchestrator drafts them itself.

Plan sections: scope and out of scope · assumptions and open questions · **DoD (each item with "Verified by")** · design (rejected alternatives, race scenario for `high`) ·
execution plan (tasks, waves, roles) · cost shape (size, number of agent runs; no made-up token counts) · risks and rollout · decision log.

How it asks: in rounds, at most 4 questions per round, as many rounds as needed; one decision per question (no nested questions; it splits them) and every decision the section hides is asked; each question quotes the relevant text and offers `Onayla` and concrete alternatives; a free-form answer is always possible.

| Risk | Rounds |
|---|---|
| `low` | Scope + DoD + execution, one question per item, then final approval |
| `medium` | Scope/assumptions · DoD and test strategy item by item · execution and cost · final approval |
| `high` | In addition to the above, a design and race scenario round and a risks/rollout round · final approval |

**Updating:** every answer is applied to the plan and written to the decision log. Changes **propagate**: if the DoD changes, test strategy and tasks are rechecked;
if the design changes, the DoD and tasks. Only sections that changed and have consequences are shown again. At any later step you can say "update the plan";
only the affected rounds are repeated, and `proposal.md`/`tasks.md` are updated with the OpenSpec skills.
The final approval has three options: `Approve and propose` / `Edit a section` / `Stop here`. Only the first moves on to `propose`.

### Step 3: Proposal and test-verified Definition of Done
`openspec-propose` produces `proposal.md` / `design.md` / `specs/` / `tasks.md` from the plan input. A **Definition of Done** is added to `proposal.md`: every acceptance criterion is a concrete
condition plus a **Verified by** entry. The line format is fixed: `D<n>: <text> | Verified by: <unit test|integration test|manual check|none: reason>`.
Parity between the plan, `proposal.md` and `tasks.md` is checked not by an LLM's eye but by `scripts/check-plan-parity.sh plan.md proposal.md tasks.md` (any difference is fixed or reported to you). `tasks.md` tasks carry `role:` / `writes:` / `after:`
(section 17). At `high` risk a race/ordering/timing scenario in `design.md` is mandatory. The proposal must follow the plan item by item; any deviation is reported to you.

### Step 4: Branch and test-first implementation with roles
The branch is created according to the "branch source" rule in `project.md` (default: the diff base; in a project with a release flow, the active release branch).
If the release is frozen, no branch is created and the user is asked.

**Testability** is checked first: if the code cannot be tested without real infrastructure (for example a concrete client type), the skill stops, says which type/call
is in the way and offers 2-3 options. It does not silently add an abstraction or silently cut scope.

Assignment: tests go to the `test-writer` role, code to `developer`, pipeline/infrastructure files to `devsecops`, each with a handoff (`handoff.md`). Small `low` tasks
can be done in a single session. Independent tasks can run in parallel (section 17).

| Risk | Process |
|---|---|
| **low** | Write a test from the DoD → RED → implement → GREEN → verify → PR. No separate verifier |
| **medium** | Same as low + **mandatory independent verification** (Step 5) |
| **high** | Three separate roles: **[A]** `test-writer` (regression test against real infrastructure; sees RED; adds the test file to the `<project-dir>/.frozen` list), **[B]** `developer` (gets the frozen test but cannot change it; only brings it to GREEN), **[C]** `verifier`. Plus `reviewer` + `security-auditor`, started together with the verifier (all read-only) |

At `high` risk the roles are started fresh, not with `fork`; that way B does not inherit A's "what the solution should look like" framing.

### Step 5: Independent verification gate
`verifier` (at `high` risk its strong-tier twin `verifier-deep`) is started from scratch and gets only: the `proposal.md` path (+ `design.md` for `high`), the diff base, the risk label. It first runs the verify command (if red, it skips the expensive
reading), then checks every DoD item and its **Verified-by evidence** (a test that does not exist, or that passes without the change too, does not count as evidence), scans `known-pitfalls.md` and
returns a `DOD / FINDINGS / VERIFY / VERDICT` block (section 6). The orchestrator passes the output through `parse-verdict.sh - --proposal proposal.md`: 0 PASS, 1 BLOCK, 2 malformed or inconsistent (the verifier is asked once for the right format; this does not count as a retry). Verify uses a cache internally; if the verifier needs to see a clean run, `--no-cache` (section 8).
At `high` risk `reviewer` + `security-auditor` also run; if `EXTRA_REVIEW_SKILLS` is set, the host's own review skills are added. If the verifier should come from a different model family, `VERIFIER_HOST` + `run-role.sh` (sections 9, 16).

- Any DoD item `FAIL` or any `CONFIRMED` finding → `VERDICT: BLOCK` → no PR.
- `PLAUSIBLE` findings are recorded but do not block.

### Step 6: Failure routing and loop limit
- **Implementation failure** (DoD item is sound, the code does not meet it) → **one full** retry to `developer`, with only the failed items. The retry is taken with `state.sh <slug> retry <task>`: exit 0 continue, 1 retry already used (stop and ask the user). The limit is enforced by the script, not by memory.
- **Spec gap** (DoD item inconsistent/impossible to meet) → back to the plan gate (affected rounds) and inform the user right away.
- **A second BLOCK** on the same task → automatic retries stop; it summarizes what happened and leaves the decision to the user. There is no third automatic loop.

### Step 7: PR
Conventional commit, branch push, and **the skill opens the PR itself** (leaves no work for the user). PR description: what changed, why, how to
test it, verification result. The target branch is in `project.md`. Post-merge steps are passed on to the user; the skill does not run them.

### Step 8: Closeout
After merge, `openspec-sync-specs` and `openspec-archive-change`; `<project-dir>/work/<slug>/` is deleted and the task worktrees are cleaned up.

### Resuming (resume)
State is kept in a file: `scripts/state.sh <slug> show` → `<project-dir>/work/<slug>/state.json` (step, risk, branch, task states, retries, verdict; personal, not in git).
After `/clear`, compaction or a crash, if the file exists the skill does not start over; it continues from the recorded `step`. At closeout it is deleted together with `work/<slug>/`.

### Invariants
The same role/session cannot both implement and say "verified"; DoD and Verified-by cannot be skipped; no proposal is written before the plan is approved; the risk label cannot be assigned silently;
verification never loops automatically more than once; overlapping `writes:` do not run in parallel; the risk label decides the process even if the task looks small; project knowledge is not embedded in the skill.

---

### Enforcement: phase machine

The order of the flow depends on a mechanism, not on the skill text. `scripts/sdd.sh` holds the phase (`intake → proposed → red → green → verified → pr → done`),
checks the gate of every transition **itself**, and hooks read the state and block an out-of-order step.

F03 ([design-workflow.md](design-workflow.md)): `sdd.sh start --profile small|standard|high-assurance` chooses the process weight (default `standard` = the flow below, unchanged; a profile does not lower risk or gates); `sdd.sh transitions` prints the valid transitions and their inputs, `sdd.sh policy` the task's actual rules; a rejected transition does not change the state and carries a `reason` in telemetry.

| Transition / step | Gate |
|---|---|
| `start` | No task is opened without the risk label the user confirmed and the proposal path |
| `advance proposed` | Rejected if `proposal.md` has no itemized "Definition of Done" (high: if `design.md` has no race/ordering/timing section) |
| `advance red` | `--test-cmd` is run and must **fail**; a passing test does not count as evidence |
| `advance green` | The same command must now **pass** |
| `advance green` / `verified` | If `RISK_FLOOR_GLOBS` is set, the task's risk cannot be below the floor of the files the diff touches (strict rejects, guided warns) |
| `advance verified` | low: the verify command must pass. medium/high: a verifier `PASS` record for the **current diff** is required |
| `git push`, `gh pr create`, `glab mr create`, `open-pr.sh` | The hook rejects without the `verified` phase and an unchanged diff |

The decision is made in one place, `sdd.sh gate`; Claude hooks, the Cursor/Gemini/OpenCode adapters and git `pre-commit`/`pre-push` all ask the same thing, so the rule is the same on every host. Hooks: `guard-phase` (with no task and in `intake` only docs/spec/`.claude/`; in `proposed` only test files),
`guard-pr` (push/PR gate, rejects editing the state file by hand), `record-verdict` (when the verifier finishes, records the `VERDICT` line with the current diff
fingerprint; the implementing session's claim does not count, and any later edit makes the verdict stale).

`SDD_MODE` (`sdkit.env`): `strict` rejects (**default**, also strict if empty), `guided` asks in the hook / warns in the git hook, `off` disables. Test file patterns are changed with `SDD_TEST_GLOBS`,
always-free paths with `SDD_FREE_GLOBS`. Tests: `tests/sdd.test.sh`.

**Server-side gate (CI).** The phase state is git-ignored, so CI cannot see it. That is why `advance verified` writes `<project-dir>/attestations/<task>.json`
(task, risk, verdict, fingerprint of the changed files, kit version); you **commit** it with the change. CI runs `sdd.sh ci-check`:
for every diff that contains a code change it requires an attestation for that diff, and for medium/high it requires a verifier `PASS`; if only docs/spec/project files
change, it does not look for an attestation. If a file changes after verification the fingerprint no longer matches; you verify again and refresh the attestation. The fingerprint is computed
from the point where the PR branched off its target branch, so it does not change when the target branch moves on. Templates: `templates/ci/` (`init.sh --ci bitbucket|github|gitlab`).
Limit: the attestation file can be produced by anyone with write access to the repo; so it makes skipping the rule harder, it does not stop bad intent. To rely on it,
protect the `attestations/` path with CODEOWNERS / mandatory code review.

**Machine install and drift.** If the repo has no kit scripts (e.g. Claude plugin mode), the git hooks use the kit registered on the machine: `<kit>/bin/install.sh`
(`--status`, `--uninstall`). Whether the managed copies in the repo match the kit can be checked in CI with `sync.sh --check` (changes no files, exit 1 on drift);
`doctor.sh` reports the same check, the version difference, the machine registration and whether the CI gate exists.

`parse-verdict.sh` is the **single validator** for the verdict; on Claude the `record-verdict` hook calls it with `--record` when the verifier finishes (a malformed or self-contradicting block is not recorded and is reported to the orchestrator; a manual `--record` there is rejected by `guard-pr`). On hosts without SubagentStop the orchestrator runs `parse-verdict.sh --record` (`guard-pr` allows this in the adapters via `SDKIT_HOST`). One-time skip: `SDD_SKIP=1` (git hook).

Limit: hooks guard against straying onto the wrong path, not against a determined attacker (for example they do not fully
close off writing files via `Bash`). Non-Claude tools and a direct `git push` are covered by the git hooks; a git hook can be skipped with `--no-verify`, so the layer that cannot be skipped is CI (below).

## 5. Skills

| Skill | When | What it does |
|---|---|---|
| `spec-driven-dev` | On every new task | The flow above (analyst, plan gate, implementation with roles, verification) |
| `incident-to-rule` | After a bug is fixed | Turns the incident into a lasting guard (below) |
| `scaffold-init` | When setting up a new repo, **once** | Asks which hosts (Claude/Codex/OpenCode/Cursor/Gemini), runs `init.sh --host ...`, starts `openspec init`, helps fill in `project.md`, runs doctor at the end |
| `scaffold-doctor` | After install, or if something seems not to work | Runs `doctor.sh` and says what to change where for every `FAIL` |
| `generate-specs` | Analyst environment (`SDKIT_ENV=analyst`) | Turns pre-specs into a PRD, feature spec or ADR in the specs repo, reviewed by `spec-reviewer` until `SPEC_REVIEW_MAX_ROUNDS`, then a PR ([role-aware.md](role-aware.md)) |
| `update-specs` | Analyst environment | Changes an approved spec (including a spec-change request from a developer) and bumps its version |
| `generate-tasks` | Analyst environment | Splits an approved spec into Jira subtasks that follow the task contract, or answers a change request |

### incident-to-rule
To stop a fixed bug from coming back in the same class, the **strongest suitable guard** is chosen (first match wins):

1. **Lint rule**: if a linter can catch it, add it to `LINT_CONFIG`
2. **Verify policy**: if a grep/diff pattern can catch it, add an executable file under `<project-dir>/verify.d/`
3. **Regression test**: if a test can break on the bug
4. **Hook**: if it must be blocked/approved before a tool call happens, add a hook to the project
5. **Pitfall entry**: if none of the above is possible, in `known-pitfalls.md` (symptom, root cause, incident, "how it shows up in a diff")

It must first describe the bug as a **general mechanism** (symptom, root cause, its trace in the diff). A mechanical guard is preferred over prose.
The guard is verified by first **breaking** on a diff that reproduces the original bug and then **passing** on the fix. If a design decision is needed, an ADR is added.

---

## 6. Roles

Roles are defined **tool-independently** under `core/roles/*.md` (fields: `kind`, `access`, `tier`, `independent`). `bin/build-adapters.sh` generates every host's role files from them (Claude `agents/`; `adapters/{codex,opencode,cursor,gemini}/`; 11 files per host: 10 subagent roles + `verifier-deep`); do not edit the generated files by hand, edit the source and run the script (`--check` checks whether they are up to date).
Subagent roles run in a **separate context** from the main session; they do not see the conversation history, only the handoff (`handoff.md`) and the files in the repo.

| Role | Access | Tier | Independent | Job |
|---|---|---|---|---|
| `orchestrator` | session | strong | | Runs the flow, splits the work, owns the plan and the summary (the main session, not a subagent) |
| `analyst` | read-only | standard | | Judges whether the task prompt is complete; lists gaps, assumptions, questions |
| `scout` | read-only | **light** | | Cheap code search: where is it defined, who calls it; answer of at most 15 lines |
| `engineer` | design files only | strong | | Design, options and trade-offs, ADRs, race scenario, test strategy, task split (`writes:`/`after:`) |
| `developer` | code | standard | | Implements to the agreed design and tests; does not say "verified", does not weaken the test |
| `test-writer` | tests only | standard | | Writes tests, does not touch production code |
| `devsecops` | infrastructure/pipeline | standard | | CI/CD, container, IaC, dependency and secret hygiene, least privilege; does not touch prod, dry-run/plan only |
| `reviewer` | read-only | standard | yes | Reviews the diff against rules and pitfalls |
| `security-auditor` | read-only | standard | yes | Attack-oriented review (authorization, injection, leaks, pipeline permissions) |
| `spec-reviewer` | read-only | standard | yes | Reviews a spec document against a `review.d/` checklist and answers `SPEC-REVIEW` (`scripts/review.sh`); analyst environment |
| `verifier` | read-only | standard | yes | Independent DoD gate (`medium`) |
| `verifier-deep` | read-only | strong | yes | Same body as `verifier` (`deep: strong` in the source), used at `high` risk; generated as a separate file |

**Tier = cost class.** Roles declare a tier (`light`/`standard`/`strong`), not a model name; the mapping is in `core/tiers.env` (Claude: haiku/sonnet/opus aliases;
Codex: `model_reasoning_effort`; OpenCode/Cursor/Gemini: `*_MODEL_<KATMAN>`; if the models are empty, inherited from the session). So when a model changes, one place is updated.

**Size per task.** The role's fixed tier is the default; if a task in `tasks.md` has the optional `size: small|medium|large` field, the tier is chosen from it
(small → light, medium → standard, large → strong). Without `size:` the role's own tier applies (previous behaviour). Floor: independent roles
(`verifier`, `reviewer`, `security-auditor`) never go below their own tier, only above; `high` risk verification is always strong (`verifier-deep`).
The size criteria (number of files touched, mechanical vs. new logic, risk, open design decision, race/ordering) are in `skills/spec-driven-dev/references/model-routing.md`;
the orchestrator shows the sizes in the plan (section 5), and the user can change them at plan approval. The chosen tier travels in the handoff's `TIER:` field.
In Claude Code the orchestrator passes the `model` parameter from `CLAUDE_MODEL_<KATMAN>` on every `Agent` call; on other hosts the model in the role file is fixed, so
a role that needs a different model per task runs as a separate process with `run-role.sh --tier`.

**Independence rule:** the implementing role (`developer`, `devsecops`) is never the verifying role; independent roles (`verifier`, `reviewer`, `security-auditor`)
receive only the artifacts, not the implementer's reasoning.

**Roles do not call other roles.** If a lookup cannot be answered, the role ends its output with `NEEDS-LOOKUP: <soru>` lines (currently `analyst` and `engineer`); the orchestrator runs `scout` once and hands the answer back as a path.

**Read-only roles are enforced** (not just by instructions), per host:

| Host | Mechanism |
|---|---|
| Claude Code | `hooks/guard-readonly.sh` (PreToolUse `Bash\|Edit\|Write\|NotebookEdit`): finds the role from `agent_type` in the hook input; if the agent file has no `Edit`/`Write` tool, it rejects file-writing tools and modifying shell commands (`>` redirection, `rm`, `sed -i`, `git commit/checkout/...`, dependency installs). Without `agent_type` (main session, old version) it is silently off |
| OpenCode | `permission:` allow-list in the generated role file (`edit: deny`, for the shell `"*": deny` + the `READONLY_SHELL_ALLOW` allow-list) |
| Cursor | `readonly: true` in the role file |
| Gemini | `tools:` list in the role file (no write tools) |
| Codex | `sandbox_mode = "read-only"` in the role TOML (note: it may also block some build caches) |

**`analyst` output:**
```
READINESS: READY|NEEDS-INFO
BRIEF  (title, testable criteria, components, proposed risk)
GAPS   - <missing item> | <why it matters> | <question> | <suggested default>
ASSUMPTIONS - <assumption> | <what breaks if wrong>
```

**`verifier` output** (the format is strict):
```
DOD
- <item> | PASS|FAIL | <evidence>
FINDINGS
- CONFIRMED|PLAUSIBLE | <file:line> | <problem> | <failure scenario>
VERIFY
- command: <what was run> | result: green|red | <summary>
VERDICT: PASS|BLOCK
```
An item without evidence is `FAIL`; if the reported test does not exist or does not exercise the item, `FAIL`. `CONFIRMED` only if the exact line can be shown. If a file in `<project-dir>/.frozen` changed
in the diff, that is a `CONFIRMED` workflow violation.

**`reviewer`:** `BLOCKER|MAJOR|MINOR | file:line | rule | problem | suggestion`; does not report style nits that the linter catches.
**`security-auditor`:** authorization, authentication, injection, secrets, input limits, error leaks, pipeline permissions; if there are no findings, `NO FINDINGS` and what it checked.
**`test-writer`:** DoD items first, then error paths/validation/happy path/edge cases; `TestSubject_Condition_ExpectedResult`; `errors.Is`.

---

## 7. Hooks and guards

Hooks run automatically during Claude's tool calls and the model cannot skip them. They can return three kinds of result:

| Decision | Meaning |
|---|---|
| **deny** | The call is not made; the model sees the reason |
| **ask** | The call is put to the user for approval |
| **block** (Stop) | The session cannot say "done"; the model keeps fixing |

Hooks are originally **specific to Claude Code**. Gemini and Cursor call the same hook scripts through the `hooks/adapt.sh` shim, OpenCode through a JS plugin (below); still, events such as Stop-verify and SessionStart do not exist on those hosts. Everywhere there are git hooks (at commit/push time) as a fallback (section 16). Hook decisions **override** the `allow` rules in `settings.json`: even if `git checkout` is allowed, `guard-git` rejects a wrong branch source.

| Hook | Event / match | Decision | What it does | Setting | When it is off |
|---|---|---|---|---|---|
| `session-context.sh` | SessionStart | info | At session start reports the branch, ticket (`ABC-123` in the branch name), the matching OpenSpec change, the active release and its state (open/frozen) | `BASE_BRANCH_MODE` | Never off; release info only in release mode |
| `check-tools.sh` | SessionStart | info | Reports missing tools with the install command: `jq`, `git`, `openspec` (if `openspec/` exists) and the stack's `tools.sh` list | `STACK` | Silent if no tool is missing |
| `guard-secrets.sh` | PreToolUse: Read, Edit, Write | **deny** | Rejects reading/writing a file that matches `SECRET_GLOBS` | `SECRET_GLOBS` | If `SECRET_GLOBS` is empty |
| `guard-protected.sh` | PreToolUse: Edit, Write | **ask** | Asks for approval before changing a file under `PROTECTED_PATHS` | `PROTECTED_PATHS` | If empty |
| `frozen-tests.sh` | PreToolUse: Edit, Write | **deny** | Blocks changes to the test files listed in `<project-dir>/.frozen` | `<project-dir>/.frozen` | If the file does not exist |
| `guard-prod.sh` | PreToolUse: Bash | **ask** | Asks for approval on **modifying** `kubectl` commands against a prod cluster | `PROD_KUBE_CLUSTERS` | If empty |
| `guard-git.sh` | PreToolUse: Bash | **deny** / **ask** | Enforces the release flow rules (below) | `BASE_BRANCH_MODE=release` | If there is no release mode |
| `guard-readonly.sh` | PreToolUse: Bash, Edit, Write, NotebookEdit | **deny** | Blocks a read-only role (reviewer, verifier ...) from changing files (section 6) | `agent_type` (hook input) | If there is no `agent_type` |
| `post-edit-fmt.sh` | PostToolUse: Edit, Write | none | Formats the written file with the stack's `fmt.sh` (Go: `gofmt`) | `STACK` | No-op if the formatter is not installed |
| `stop-verify.sh` | Stop | **block** | Blocks saying "done" if uncommitted changes are broken in the stack's fast check (`--fast`) | `VERIFY_CMD` | If the verify script cannot be found |
| `value-report.sh` | SessionEnd, SessionStart | none | Value Report at session level (`scripts/report.sh`): on `SessionEnd` it marks the session as finished and stores its summary; on `SessionStart` it recovers old sessions cut off without an end signal as `interrupted`. Writes nothing to stdout, never blocks. | `VALUE_REPORT` | Silent unless `VALUE_REPORT` is `on`. Details: [design-report.md](design-report.md) |
| `usage-log.sh` | Stop, SubagentStop | none | Writes token usage from the transcript to the `usage.sh` ledger, and with `TELEMETRY=1` also as an `agent.end` event (tokens, tool call count, estimated duration) (section 18). With `USAGE_LINE=1` it also prints a one-line usage summary when a subagent finishes | `USAGE_LOG=1`, `TELEMETRY=1` or `USAGE_LINE=1` | If none is 1 |
| `guard-budget.sh` | PreToolUse: Agent | **ask** (strict) / warning (guided) | Counts every subagent spawn (`state.sh spawn`) and checks the task token budget (`usage.sh budget`); asks when the limit is exceeded (section 18) | `MAX_SPAWNS`, `TOKEN_BUDGET_TASK` | If both are empty, `SDD_MODE=off`, or there is no active task |
| `guard-noisy.sh` | PreToolUse: Bash | **ask** | Asks to run a command that matches `NOISY_CMD_PATTERNS` through `scripts/capped.sh`, so a long log does not stay in the session (a cost nudge, not a safety gate). Passes wrapped, piped-to-`tail`/`head`/`grep`, redirected and subagent calls | `NOISY_CMD_PATTERNS` | If empty or `SDD_MODE=off` |
| `result-size.sh` | SubagentStop | none | Warns (does not block) if the role's last answer is longer than `SUBAGENT_RESULT_MAX_LINES` lines | `SUBAGENT_RESULT_MAX_LINES` | If empty |
| `check-contract.sh` | PreToolUse: Agent; SubagentStop | **ask** (strict, only on an invalid handoff) / warning | Validates and records a handoff that carries a `CONTRACT:` line; checks the `HANDOFF-RESULT` line in the subagent's last answer. Does not touch the verdict or the phase | `CONTRACTS=1` | If empty, or the handoff has no `CONTRACT:` |

### Details

**guard-secrets**: Applies the globs to the file name (basename) or the full path. Default: `.env*`, `*credentials*`, `*.pem`.
It covers only **file tools**; it does not see a Bash command such as `cat .env`. That is why the `deny` list in `settings.json` also forbids `Read` on the same files (see section 12).

**guard-protected**: Compares the path relative to the project root; asks for approval if it starts with a prefix in `PROTECTED_PATHS`. The message points to `project.md`
(for example "may only be changed under this condition").

**frozen-tests**: At high risk in `spec-driven-dev`, role **[A]** adds the test file (path relative to the repo, one per line) to `<project-dir>/.frozen`.
The implementer then has to fix the code instead of "fixing" this test. The file is deleted when the task is finished/abandoned. The file is personal, not in git.

**guard-prod**: "Modifying" commands: `apply, delete, rollout, scale, patch, edit, replace, create, run, set, annotate, label, exec, cp, drain,
cordon, taint`. `get/describe/logs` are free. The target context is the `--context` in the command or the active context; it asks if the name of the **cluster the context points to**
matches the `PROD_KUBE_CLUSTERS` prefixes. Because it looks at the cluster name, every context alias that points to the same prod is covered.

**guard-git** (only with `BASE_BRANCH_MODE=release`):
1. On a feature branch, **rejects** pulling the **main branch** (`develop`) in with `git merge|pull|rebase`. Reason: work that has not passed test yet leaks into the release package.
2. **Rejects** creating a new branch with `git checkout -b` / `git switch -c` from the main branch (or while on the main branch without giving a start point); suggests the active release branch.
3. Asks for **approval** on a direct `git push` to an env branch in `PROTECTED_BRANCHES`.
It is regex-based; unusual syntax (aliases, calls from inside a script) can slip through.

**guard-readonly**: Splits the command on `&&`, `||`, `;`, `|` and checks each part; rejects output redirection other than to `/dev/null`, `rm/mv/cp/mkdir/touch/tee`, in-place `sed -i`, `git` commands that change the repo, and installs such as `npm install`. Read commands (`git diff/log/show`, `ls`, `cat`, `grep`, verify, test) are free. It is regex-based: an error preventer, not a strict boundary.

**usage-log**: Never blocks; exits silently if there is no transcript or the format is unexpected. Details in section 18.
(Up to 0.5.0 the `SubagentStop` key was defined twice in `hooks.json` and `settings.copy.json`; since the last definition wins in JSON, subagent usage was never written. Now `record-verdict`, `usage-log`, `result-size` are in a single array; `tests/budget.test.sh` checks that the key is not repeated.)

**guard-budget**: Runs only if `MAX_SPAWNS` or `TOKEN_BUDGET_TASK` is set. The most recently updated `work/<slug>/state.json` counts as the active task; if there is none, it is silent. If the limit is exceeded, in `strict` mode it asks the user, in `guided` mode it only prints a warning, in `off` mode it does nothing. For the below-threshold warning (`TOKEN_BUDGET_WARN_PCT`) it gives no permission decision, it only writes a message; so it does not change the normal permission flow. A rejected spawn is counted too. It never blocks on its own error.

**result-size**: Takes the answer from the `last_assistant_message` field, otherwise from the subagent transcript. It only warns; writing the output to a file is requested by the role texts and the handoff (`OUT:`).

**check-contract**: Agent contracts (F02, [design-contracts.md](design-contracts.md)). On PreToolUse it looks for a `CONTRACT:` line in `tool_input.prompt` (if there is none it is a legacy handoff and it exits silently); if there is one it validates it with `contract.sh issue` and records it under `work/<task>/contracts/`. If invalid, it asks in `strict`, warns in `guided`, stays quiet in `off`. On SubagentStop it checks the last message (otherwise the last text of the transcript) with `check-result --record --legacy-ok`; if invalid, it gives the orchestrator one `systemMessage`. **It never blocks, never records the verdict, never changes the phase**: independent verification still goes through `record-verdict` + `parse-verdict` + `sdd.sh`. Not run on live Claude Code; there is no hook for Cursor/Gemini/OpenCode/Codex (`run-role.sh` or `contract.sh` by hand).

**`adapt.sh <gemini|cursor> <hook>`**: Converts the host's tool call JSON (Gemini `read_file/write_file/replace/run_shell_command`, Cursor `beforeShellExecution/beforeReadFile/afterFileEdit/preToolUse`) into the Claude format the hooks read, runs the hook unchanged, and converts `permissionDecision` back to the host's protocol: Gemini deny = exit 2 + stderr; Cursor `{"permission":"deny"}`. On a host that does not support `ask`, `ask` falls back to `deny` with the reason "needs explicit approval" (`ask` is supported in the Cursor shell). For OpenCode, `.opencode/plugins/spec-driven-kit-guard.js` calls the same hook scripts.

**stop-verify**: Runs the verification engine with `--fast --since-head`, i.e. vets+builds only **uncommitted** changes. On failure it gives the last 30
lines back to the model and asks it to fix them. Thanks to the `stop_hook_active` check it does not block again on the second Stop caused by its own block
(no infinite loop). Timeout 180 s.

---

## 8. Verification engine and `verify.d`

The engine has two parts: the shared **core** `scripts/verify-core.sh` and each stack's own steps `stacks/<stack>/scripts/steps.sh`. The entry point `stacks/<stack>/scripts/verify.sh` is a thin wrapper (finds the core, loads `steps.sh`, calls `verify_main`). Hooks, skills and `make verify` all call it.

```
verify.sh [--fast] [--since-head] [--no-cache]
  --fast         only cheap checks (per stack: vet+build, typecheck, compile; no tests and no lint)
  --since-head   only uncommitted changes (the Stop hook uses this), not the whole branch
  --no-cache     ignore the green-result cache
```

### What the core does (in order)
1. Finds the **diff base** (`resolve-base.sh`; in a release flow the active release branch, otherwise `origin/BASE_BRANCH`).
2. Collects the changed files: committed, staged, unstaged and **untracked** files; those matching the stack's `STACK_SOURCE_RE` become `CHANGED_SRC`. If nothing changed, it exits 0 with "nothing changed".
3. **Cache:** key = the full tree state (HEAD + diff + untracked file contents + flags + `sdkit.env` + `verify.d` policies). If the same key previously finished **green**, its output is replayed ("cached"). A failure is never cached. The last 20 entries are kept under `<project-dir>/.verify-cache/`.
4. `stack_run`: the stack's checks (below).
5. Runs the **project policies** (`<project-dir>/verify.d/*.sh`).
6. Summary line: `verify: N failure(s), M warning(s)`. Exit code 0 only if there are no failures.

### Stacks
| Stack | Detection | Checks (summary) |
|---|---|---|
| `go` | `go.mod` | `gofmt`, `go vet`, `go build` in the changed **go.mod modules**; unless `--fast`, `go test ./...` and `golangci-lint --new-from-rev` (new code only). If `SHARED_MODULE` changes, the `DEPENDENT_MODULES_GLOB` modules are added too; `INTEGRATION_MODULE_GLOB` modules are vetted/built, not run |
| `spring-boot` | Spring Boot in the Maven/Gradle file | per-module compile, unless `--fast` tests and (if configured) spotless/checkstyle; the wrapper (`./mvnw`, `./gradlew`) is tried first, forced with `JAVA_BUILD_TOOL` |
| `jvm` | Non-Spring Maven/Gradle file (Java/Kotlin) | Same engine as `spring-boot`: per-module compile, unless `--fast` tests and (if configured) spotless/checkstyle; formatting `google-java-format` / `ktlint` |
| `python` | `pyproject.toml`, `setup.py`, `setup.cfg` or `requirements.txt` | per-package syntax (`py_compile`); unless `--fast`, `ruff`, `mypy` if configured, `pytest` (otherwise `unittest`). If `uv.lock`/`poetry.lock` exists, tools run via `uv run`/`poetry run`, forced with `PY_RUNNER`. A missing tool is a warning, not a failure |
| `generic` | none (fallback) | `VERIFY_FAST_CMD` and `VERIFY_TEST_CMD` from `sdkit.env` run at the repo root; if both are empty, only the `verify.d` policies run and a warning is given |
| `nextjs` | `next` in `package.json` | per-package typecheck, unless `--fast` lint and test; `next build` if `VERIFY_BUILD` is set; package manager from the lockfile or `NODE_PM` |
| `react-native` | `react-native` in `package.json` | typecheck/lint/test (without eslint, a local prettier runs `prettier --check` on the changed files as the lint step); `tools.sh` adds `xcrun` / `adb` hints when `ios/` / `android/` exist; `verify.d.example/40-expo` (off until enabled) runs `expo install --check` on `package.json` changes and warns on prebuild-relevant app config changes and toggled NativeWind transform classes; shares the `stacks/_node/scripts/node-lib.sh` helper with `nextjs`. Rules: `rn-idioms.md`, `rn-testing.md` and `expo-idioms.md` (Expo apps; a bare app can delete it); `known-pitfalls.md` is seeded with React Native / Expo list, layout and navigation pitfalls |

Every stack provides: `detect.sh`, `scripts/{verify,steps,fmt,tools}.sh`, `permissions.txt`, `rules/`, `verify.d.example/`, and optionally a `known-pitfalls.md` seed (otherwise `init` writes the neutral template). The full contract is in `stacks/README.md`. A repo has **a single `STACK`**; a monorepo with multiple stacks is out of scope.
Stack rule: verify only what changed, keep `--fast` really cheap, a missing tool is a `warn` (skipped), print little output.

#### React Native / Expo: third-party skills
The kit does not vendor framework skills: they change upstream every week and install in one command. For `STACK=react-native`, `init` prints these recommendations (the Expo one only when `expo` is a dependency):

| Skill set | Install | Use |
|---|---|---|
| Expo (`expo/skills`, MIT: expo-router, expo-native-ui, expo-design-system, expo-data-fetching, expo-animation, eas-*) | Claude Code: `claude plugin install expo@claude-plugins-official`; other hosts: `npx skills add expo/skills` | Expo apps |
| `vercel-react-native-skills` (`vercel-labs/agent-skills`, MIT) | `npx skills add vercel-labs/agent-skills` | React Native rules |
| `react-native-best-practices` (`callstackincubator/agent-skills`, MIT) | `npx skills add callstackincubator/agent-skills` | Performance |
| NativeWind migration skills (NativeWind team, MIT) | from the NativeWind repository | Only when upgrading NativeWind |

`npx skills add` writes the skills to `.agents/skills/` (and may link them from `.claude/skills/`). That is not a non-Claude host install: `doctor` runs its host checks only when the kit's block is in `AGENTS.md` or `.agents/skills/spec-driven-dev` exists. On `react-native` repos, `doctor` warns about Expo skills that upstream has removed (`building-native-ui`, split into expo-native-ui and expo-router; `expo-tailwind-setup`). The kit's own rules (`rn-idioms.md`, `expo-idioms.md`) stay the project's conventions; where a third-party skill disagrees, the project's rules win.

### verify.d protocol
Project-specific checks are **executable** (`chmod +x`) files in `<project-dir>/verify.d/`. The engine runs all of them in alphabetical order.

- A line `FAIL: <mesaj>` counts as a failure, `WARN: <mesaj>` as a warning.
- A policy that prints no `FAIL:` line but exits non-zero also counts as a failure.
- Files starting with `_` are helpers and are not run.
- The engine provides these variables: `VERIFY_ROOT`, `VERIFY_MERGE_BASE`, `VERIFY_CHANGED` (file list, one per line), `VERIFY_CHANGED_SRC` (on Go also `VERIFY_CHANGED_GO`), and
  `VERIFY_LIB` (helper function file; contains `added_lines <pathspec...>`: lines added after the base, untracked files included).

Example (from `stacks/<stack>/verify.d.example/`; `init` installs these with the `.example` extension; remove the extension to use one):

```bash
#!/usr/bin/env bash
. "${VERIFY_LIB:?run this through the verify engine}"
added="$(added_lines '*.go' ':!*_test.go')"
echo "$added" | grep -nE 'log\.Printf|fmt\.Println' && echo "FAIL: debug printing added"
exit 0
```

`init` brings three examples per stack (Go: forbidden patterns `10-`, `.up.sql`/`.down.sql` pair `20-`, OpenAPI update `30-`; other stacks: forbidden patterns, migration/env/local change, and dependency/OpenAPI examples). All of them must be adapted to the project's directory layout.

---

## 9. Helper scripts

### `scripts/resolve-base.sh`
Prints what a branch is diffed against and **which branch it is created from**.

| Situation | Output |
|---|---|
| `BASE_BRANCH_MODE=release` | The **newest** `origin/<RELEASE_BRANCH_PREFIX>*` branch HEAD derives from (the one with the fewest commits after the fork point; on a tie, the newer one) |
| no release branch / mode off | `origin/BASE_BRANCH` |
| `VERIFY_BASE` environment variable given | that value (overrides everything) |

The `--frozen` flag prints `frozen` if a `freeze/<ad>` tag exists for that release, otherwise `open`.

### `scripts/open-pr.sh`
Opens a PR for the current branch: `open-pr.sh "<title>" <description-file> [destination-branch]`. Without a target, `BASE_BRANCH`.
The branch must be pushed first. `PR_HOST` is `bitbucket` (REST API), `github` (`gh pr create`), `gitlab` (`glab mr create`) or `auto` (picked from the `origin` URL); other values exit with code 2 without going to the network ([hosts.md](hosts.md)).
Credentials: email from `BITBUCKET_EMAIL`, otherwise `git config user.email`; password from the `origin` URL, otherwise `BITBUCKET_TOKEN`, otherwise `PR_TOKEN_REPO`
(from the URL of another local repo). The password is never printed.

### `scripts/guard.sh`
Tool-independent guards; called from the git hooks (`adapters/git/pre-commit`, `pre-push`). `pre-commit`: `SECRET_GLOBS` matches in staged files, tests listed in `<project-dir>/.frozen`
(**rejects**), anything under `PROTECTED_PATHS` (rejects; after approval `ALLOW_PROTECTED=1`). `pre-push`: push to `PROTECTED_BRANCHES` (rejects; `ALLOW_PROTECTED_PUSH=1`),
and rejects the push if `verify.sh --fast --since-head` is red (`GUARD_SKIP_VERIFY=1` skips it deliberately). The "ask" in the Claude hooks is "reject + approval flag" here, because a git hook cannot ask a question.

### `scripts/plan-waves.sh <tasks.md>`
Splits tasks into **waves** by dependency (`after:`) and write set (`writes:`). Tasks in the same wave are independent of each other and their write paths do not overlap
(two paths overlap if one equals the other or is its parent directory). Exits 1 on an unknown id or a cycle. Task format in section 17.

### `scripts/worktree.sh add|path|merge|clean|list <task-id>`
Git worktrees for parallel tasks: `add` creates `../<repo>-wt/<id>` and the `wt/<branch>/<id>` branch from HEAD; `path` prints its path (for `WORKTREE:` in the handoff); `merge <id> [tasks.md]` first checks the task's changes against its `writes:` set (`check-writes.sh`; a task that goes outside it is not merged), then merges the branch with `--no-ff` (on a conflict it aborts and exits:
the write sets were wrong, the plan is fixed); `clean` deletes merged worktrees.

### `scripts/check-writes.sh <tasks.md> <task-id> <base-ref> [head-ref]`
Exits 1 and lists the files if the task changed files outside its `writes:` set. If `head-ref` is given, committed changes are checked; otherwise the working tree + untracked files. A task without `writes:` is read-only. 2: usage error or unknown task.

### `scripts/env.sh`
Not run, sourced; every script and hook uses it. `sdkit_env_load <root>` finds the project dir and **parses** `sdkit.env` + `sdkit.local.env` (does not run them as shell: `KEY=value`, quoted values, `export`, `: "${K:=v}"`, `$AD`/`${AD}`; anything else is reported as `file:line` and ignored; keys such as `PATH`, `IFS`, `BASH_*` are rejected; migration note in `upgrading.md`). Also `sdkit_active_slug` (the open SDD task, otherwise the newest `work/*/state.json`), `sdkit_lock`/`sdkit_unlock` (`mkdir`-based lock; parallel agents write the state and the ledger at the same time) and the default stack.

### `scripts/state.sh <slug> init|show|get|set|task|retry|path`
Task state in `<project-dir>/work/<slug>/state.json` (for resuming). `task <id> todo|doing|done|blocked`; `retry <id>` exits 0 the first time and counts it, exits 1 if the retry is used up (single automatic retry rule). Requires `jq`.

### `scripts/parse-verdict.sh <dosya|-> [--proposal proposal.md]`
Validates the verifier output: `DOD / FINDINGS / VERIFY / VERDICT` order, every DoD line `PASS|FAIL`, every finding `CONFIRMED|PLAUSIBLE`, whether `VERDICT` follows the rule (`BLOCK` if any `FAIL` or `CONFIRMED`). With `--proposal` it also checks that the verifier judged as many items as the DoD in the proposal file. Exit: 0 PASS, 1 BLOCK, 2 malformed/inconsistent. F08: the input is first normalized with format-only rules (CRLF, `**` emphasis, `*`/`1.` bullet markers, lowercase `pass/fail/confirmed/plausible`, `**VERDICT:** **PASS**`); nothing is inferred, a missing token stays missing. The error message names the kind: `MALFORMED[format]` (shape; asked again once) or `MALFORMED[semantic]` (the content contradicts itself or lacks evidence: a PASS with a FAIL, `PASS | manual`, `PASS | post-deploy`, `PASS | n/a`, empty evidence, a skipped DoD item; the verdict is never corrected). `manual`/`post-deploy` is not PASS evidence.

### `scripts/dod-check.sh <proposal.md>`
F08 early DoD check; before an expensive role runs, it classifies the `D<n>: ... | Verified by: <method>` lines: `automated`, `static`, `manual`, `post-deploy`, `none: <reason>`. An item without a method, a `none` without a reason, a duplicate id, an unknown method → exit 1 (every problem is printed). `run-role.sh` calls this before starting the verifier when an open proposal exists (no cost, `exit 2`). Exit: 0 ok, 1 problem, 2 usage.

### `scripts/digest.sh output|envelope|stats`
F09 bounded views. `output`: for long command output (default >60 lines) the first 10 lines + every error line (FAIL/ERROR/panic/CONFIRMED...) + the last 15 lines + the path of the full text. `envelope --role R --ref F`: for a role's long answer, `ENVELOPE/1` (verdict, DoD counts, FAIL/CONFIRMED/BLOCKER lines verbatim, evidence path); a short answer (<1500 bytes) is printed as is. The envelope is a **view, not a decision**: the decision is `parse-verdict.sh` on the full answer. `run-role.sh --envelope` / `RESULT_ENVELOPE=1` (off by default). Sizes are written to `work/<slug>/context.jsonl`; `stats` summarizes.

### `scripts/test-select.sh list|run`
F10 changed file → focused test mapping (`<project-dir>/test-map.conf` or `tests/test-map.conf`: `ERE => command ;; command | ALL | NONE`, mandatory `@all =>`, optional `@always =>`). A path not in the map, or a shared module, selects the whole suite (no guessing). `run`: runs with `pipefail`, time per command, a summary line; only a green result is cached, keyed by the full-tree identity. T0-T3 policy: Implementation Roadmap §3.

### `bench/costbase.sh capture|compare`
F11 fixed-data baseline that calls no model (`bench/baselines/*.costbase.json`): format-only verdict retries (normalization off/on), semantic errors never being accepted, context bytes, the number of tests selected on a small patch. **Cost per task was NOT measured** (a live run is needed). `compare` refuses if the fixture/map differs.

### `scripts/report.sh` (Value Report)
Task and session value report: roles/models, token categories, API-equivalent cost, **observed** optimizations and savings (evidence hierarchy, baseline source, scope, confidence, measured/estimated distinction; with insufficient evidence "N/A — insufficient baseline data"). No new ledger: it reads `usage.sh`, `telemetry.sh`, and the routing/context/test-selection records; no LLM call. `sdkit report task|session|latest|history [--detailed|--json|--markdown]`, `regenerate`. Full design, formulas and limits: [design-report.md](design-report.md).

### Phase F12-F20 scripts (short)
- `adapter.sh capabilities|usage|cancel|status|validate <host|ext:ad>`: the execution adapter contract; an unsupported capability honestly says "unsupported" (exit 3). Details: [design-adapters.md](design-adapters.md). `adapters.d/litellm.sh`: optional, text-only, off by default.
- `route.sh` + `ROUTE_COST_ENFORCE=hard`: hard cost policy, reservation, unknown = does not pass ([design-routing.md](design-routing.md) F14).
- `dispatch.sh claim|done|release|status`: idempotent (`PARALLEL`, on by default) parallel dispatch; dependency, write conflict, `MAX_PARALLEL`.
- `knowledge.sh put|get|list|clear`: task notes tied to the file content hash; independent roles are refused.
- `telemetry.sh trace`: task → phase → role → execution → request trace, no content ([design-telemetry.md](design-telemetry.md) F17).
- `recover.sh scan|apply`: safely and idempotently closes half-finished record jobs; does not rerun anything, does not touch a BLOCK.
- `redact.sh`, `audit.sh log|show|verify|policy`: secret filter, hash-chained audit trail, static enforcement audit ([design-security.md](design-security.md)).
- `dod-check.sh accept|accepted|acceptances`: only a person (`--by`, `--reason` required) can accept a manual/post-deploy/none DoD item; it is tied to the item text and becomes invalid if the text changes. `parse-verdict.sh` counts an `accepted: <who>` evidence only if a record exists; the evidence-token parsing is a heuristic filter, not proof.
- `route.sh reservations`, `SDKIT_CHILD_RUN`: stale reservation lifetime and the `run-role.sh` child-session marker (the Stop hook does not write the same tokens twice; not verified live).
- `pricing.sh refresh|status`: the price table `<project-dir>/pricing.json` (public AWS Bedrock list; `sdkit init` installs it, `sdkit doctor --update-pricing` refreshes it; a table you edited is never replaced). [design-usage.md](design-usage.md) §3.
- `usage.sh window|reconcile`: the share of a cumulative session transcript that belongs to the open task, and filling in subagent runs that were unreadable at SubagentStop.
- `pr-check.sh [--milestone]` + `bench/history.sh`: cheap PR check (T0+T1), T3 at a milestone, and fixture regression history; `templates/ci/pr-check.yml` is an example, not installed.

### `scripts/check-plan-parity.sh <plan.md> <proposal.md> [tasks.md] [--loose]`
Deterministically checks plan ↔ proposal ↔ tasks parity. DoD line `D<n>: <text> | Verified by: <type>`; by default id, text and Verified-by must match (`--loose`: only id and Verified-by). If `tasks.md` is given, the "Execution plan" tasks in the plan are compared on `role/writes/after`. Exit: 0 equal, 1 difference (printed), 2 usage error/DoD not found.

### `scripts/usage.sh log|report|budget [slug]`
Token ledger (section 18). `budget [slug]` compares the tokens the task used (`in + out + cache-write`; cache reads are cheap so they are not counted) with `TOKEN_BUDGET_TASK`: below the threshold (`TOKEN_BUDGET_WARN_PCT`, 70) exit 0, at the threshold 3, at 100% 4; if there is no budget or the ledger is empty, silent exit 0. `log --role R [--tier --host --model --in --out --cache-read --cache-write --slug --id]`; silent no-op unless `USAGE_LOG=1` (overridden with `--force`). `report` prints totals per role and tier, the grand total and the cache hit rate (`cache_read / (in + cache_read + cache_write)`).

### `scripts/telemetry.sh emit|summary|list|validate|archive|run-id`
Structured event log (`work/<slug>/events.jsonl`) and its summary; turned on with `TELEMETRY=1`, a silent no-op when off. `emit` never fails under any condition. `summary` gives a run's status, phase and agent durations, tokens (measured/total runs, with a quality label), estimated cost if there is a price table, retry/failure counts and verification results (`--json` machine-readable). Schema, metric table and limits: [design-telemetry.md](design-telemetry.md). Benchmark: `bench/run.sh`.

### `scripts/contract.sh issue|check-result|close|pending|status|id`
Agent contracts (F02, [design-contracts.md](design-contracts.md)): the handoff (`CONTRACT: 1`, `ID: <task>/<label>`, the existing `ROLE/READ/SCOPE/OUT` lines) and the agent's last line `HANDOFF-RESULT/1 | id | role | status | artifacts | blockers | next` are validated deterministically; no model call. Categories: `no-result malformed unsupported-version missing-field bad-value inconsistent id-mismatch role-mismatch task-mismatch unknown-id duplicate stale unsafe-path missing-artifact out-of-scope`. Exit: 0 valid and `done`, 1 valid but `partial|blocked|failed`, 2 invalid; **0 does not mean verified** (verdict and phase stay with `parse-verdict.sh` / `sdd.sh`). `--record` writes the acceptance to `work/<task>/contracts/<label>.json` (the first valid answer wins, later ones are `duplicate`). `RETRY-OF:` marks the old id `superseded`. With `TELEMETRY=1` it writes a `contract.check` event.

### `scripts/workflow.sh policy|contracts|require|gate|announce|profiles`
Workflow profiles and agent contract policy (F03, [design-workflow.md](design-workflow.md)). It only **reads**: the profile and risk from the task's `.sdd/state.json`, `CONTRACTS` from the settings; `sdd.sh` keeps managing the phase and `contract.sh` the contract. `policy [--json]` prints the rules that apply to the task (profile, verifier, contract level); `contracts --role R` prints `off|optional|required`; `require` exits 1 if a handoff with a mandatory contract has no marker (called by the hook and `run-role.sh`); `gate green|verified` exits 1 in high-assurance if an agent is unanswered/left partial (called by `sdd.sh`). Profiles: `small` (low risk only, no contract overhead), `standard` (default, today's flow), `high-assurance` (independent verifier PASS at every risk + mandatory contracts for writing/deciding roles). A profile never lowers risk or gates; it is chosen with `sdd.sh start --profile` and is fixed for the whole task.

### `scripts/memory.sh status|init|add|index|search|stale|autoload|candidates|promote`
Project memory (section 19). All are silent no-ops unless `MEMORY=1`.

### `scripts/lookup-cache.sh get|put|clear <slug> [soru]`
Stores scout answers for the duration of the task (`work/<slug>/lookups/`). An answer is valid only for the same HEAD and the same uncommitted diff; it is dropped when the code changes. The question is lowercased and its whitespace normalized, so the same question asked again with different wording hits. `get` prints the answer and returns 0 on a hit, 1 on a miss.

### `scripts/run-role.sh <role> --handoff F [--cwd D] [--host H] [--tier T] [--model M] [--out F] [--ignore-budget] [--dry-run]`
If `MAX_SPAWNS` / `TOKEN_BUDGET_TASK` is set (and `SDD_MODE` is not `off`), it counts the spawn and checks the budget before running; at the limit it stops with exit 3 in `strict` mode (`--ignore-budget` after user approval), in `guided` mode it warns and continues. Runs a role as a **separate headless process**: fresh context (only the handoff), pinned to a directory (the task worktree) with `--cwd`, in the host's read-only mode for read-only roles. The role text comes from `core/roles/<role>.md` or `<project-dir>/roles/`; `verifier-deep` runs with the strong-tier model. Host order: `--host`, `VERIFIER_HOST` for independent roles, then `RUN_ROLE_HOST`; model: `--model`, then `RUN_ROLE_MODEL_<KATMAN>`; if `--tier light|standard|strong` (`small|medium|large` also works) is given, it replaces the role's tier (floor for independent roles: the role's own tier) and the model is also resolved from `<HOST>_MODEL_<KATMAN>` in `core/tiers.env`; on Codex `model_reasoning_effort` (`CODEX_EFFORT_<KATMAN>`) changes instead of the model. Without `--tier` the previous behaviour stays as is. With `VERIFIER_HOST` the verifier can run on another provider (real independence). 127 if the CLI is missing. Records token usage to `usage.sh` where the host writes it. **The flag spellings per CLI are not validated live:** print the command with `--dry-run` and compare it with `<cli> --help`.

### `scripts/route.sh decide|explain|outcome|classify|registry|capabilities|validate|log`
Orchestration decisions (F06, [design-routing.md](design-routing.md)): which adapter and model, with which budget, run / reuse / retry / escalate / stop. Pure shell+jq, no model call; every decision carries a reason code.
With `ROUTING=on`, `run-role.sh` **consumes** this decision (if the decision is not `execute|retry|escalate` it starts nothing: exit 3 budget, 2 policy rejection, **7 valid evidence was reused (success-like, no retry)**, **8 not run and no valid result (never success)**; `--rerun <neden>` for a deliberate rerun).
With `ROUTING=off` (default) `run-role.sh` works as before. `route.sh explain --role R` shows the decision in five lines and records nothing. `route.sh capabilities --probe` checks the capability flags against the installed CLIs' `--help` output (no model call). Gate roles (verifier, reviewer, security-auditor) never go past the risk floor, the mandatory gates or the evidence rules; a standing BLOCK is not re-judged on the same diff by another provider.

### `scripts/verify-core.sh`
Not run directly; the stack's `verify.sh` loads it (section 8). `verify-lib.sh` is the `verify.d` helper (shared by all stacks).

### `bin/build-adapters.sh [--check]`
Generates `agents/*.md` (Claude) and `adapters/{codex,opencode,cursor,gemini}/` from `core/roles/*.md`; the per-host format is in `bin/emit/<host>.sh`, host tool/permission names in `core/hosts.env`, the tier mapping in `core/tiers.env`. `--check` checks whether the generated files are up to date (before a release).

### Role-aware scripts (`SDKIT_ENV=analyst|developer`)
Details, flows and limits: [role-aware.md](role-aware.md).
- `scripts/spec.sh`: spec lifecycle in the specs repo (`init-meta`, `status`, `branch`, `publish`, `promote`, `approved-sha`; versions 0.1, 0.N, 1.0). Pre-spec content (`PRESPEC_DIR`) is never committed. `open-pr.sh` also serves it.
- `scripts/review.sh`: evidence for the spec review (`plan`, `begin`, `record`, `check`, `accept`) with the `spec-reviewer` role and `review.d/*.env` checklists; stops after `SPEC_REVIEW_MAX_ROUNDS` rounds for a human decision.
- `scripts/tasks.sh`: deterministic core of `generate-tasks`: AC-to-task trace, dependency cycles, stable ids, Jira description render, report (`templates/change-request.md` for change requests).
- `scripts/jira.sh` + `adapters.d/jira.sh`: the Jira task contract (`validate-task`, `fetch`, `deps-ready`, `upsert`, `comment`, `transition`, `change-request`). Network only with `JIRA_EGRESS=allow` (personal) and a token read from the variable named in `JIRA_TOKEN_ENV`.
- `scripts/sdd.sh start --ticket KEY` (with `SDD_MANAGED=on`): managed execution, see [role-aware.md](role-aware.md).

---

## 10. Configuration reference

### `<project-dir>/sdkit.env` and `sdkit.local.env`

`sdkit.env` is the team's shared policy and is committed. `sdkit.local.env` is personal, not in git, read after `sdkit.env`, and overrides the shared value (for example `MAX_PARALLEL=2` on your own machine). Keys marked **(personal)** below go in `sdkit.local.env`; the rest in `sdkit.env`. In pre-1.0 installs both are in a single `project.env`.

| Variable | Default | Meaning |
|---|---|---|
| `BASE_BRANCH` | auto-detected | Integration branch (`develop`, `main` ...) |
| `RISK_FLOOR_GLOBS` | empty (off) | Optional risk floor: `seviye:glob,seviye:glob` (e.g. `high:services/payments/*,medium:migrations/*.sql`). The strictest match among the files the diff actually touches is the lower bound for the task's risk label; checked by `advance green`/`verified` and CI (`ci-check`, which also reads the base branch's `sdkit.env`). A malformed value does not stay off, it is rejected. Details: `upgrading.md` |
| `CONTRACTS` | empty (off) | If `1`, the Claude Code hook (`check-contract`) checks handoffs that carry `CONTRACT:` and the `HANDOFF-RESULT` line in subagent answers ([design-contracts.md](design-contracts.md)). `run-role.sh` checks a handoff with a `CONTRACT:` line regardless of this setting. Team setting (`sdkit.env`) |
| `STACK` | `go` (in one place: `scripts/env.sh`; `doctor` warns if empty) | Stack: `go`, `spring-boot`, `jvm`, `python`, `nextjs`, `react-native`, `generic` (one per repo) |
| `SDKIT_ENV` | `standalone` | Install persona: `standalone` (the plain spec-driven workflow, unchanged), `analyst` (specs repo: write and review specs, no stack, no OpenSpec) or `developer` (source repo: approved specs from a read-only submodule, tasks from Jira). Set by `sdkit init --env`; upgrade keeps it |
| `PRESPEC_DIR` | `prespec` | Git-ignored directory with raw pre-specs (analyst). Never committed |
| `SPECS_DIR` | `specs` | Specs directory: the specs repo's spec folder (analyst) or the read-only approved-specs submodule (developer) |
| `SPEC_REVIEW_MAX_ROUNDS` | `2` | Most `spec-reviewer` rounds per spec before a human decides. `AGENT_SPEC_REVIEWER_TIER` sets its tier (`standard`) |
| `SDD_MANAGED` | `on` in the developer env, else empty | Managed execution: `sdd.sh start --ticket KEY` takes the task from Jira and pins the approved spec revision |
| `TRACKER` | empty | `jira` enables the keys below (read only then) |
| `JIRA_BASE_URL`, `JIRA_USER`, `JIRA_PROJECT`, `JIRA_SUBTASK_TYPE`, `JIRA_CHANGE_TYPE`, `JIRA_LINK_TYPE`, `JIRA_API_VERSION`, `JIRA_SEARCH_PATH` | empty / `Sub-task` / `3` | Jira connection and issue types; commented out in `sdkit.env` until set |
| `JIRA_BLOCKED_STATUS`, `JIRA_REVIEW_STATUS` | `Blocked`, `In Review` | Status names the ticket moves to when a change request blocks the task, and when evidence is synced |
| `SDD_JIRA_CMD` | empty (`scripts/jira.sh`) | Replaces the Jira command (tests, or a bridge with the same verbs and exit codes) |
| `JIRA_EGRESS`, `JIRA_TOKEN_ENV` **(personal)** | empty | `allow` lets `jira.sh` call the API from this machine; the name of the variable that holds the token (the token never goes in a settings file) |
| `VERIFY_FAST_CMD`, `VERIFY_TEST_CMD` | empty | `generic` only: fast check and test command (run at the repo root) |
| `PY_RUNNER` | empty | `python` only: tool prefix (`uv run`, `poetry run`); if empty, from the lockfile |
| `VERIFY_CMD` | empty | Empty: the plugin's engine. Set: path relative to the repo (copy mode) |
| `DIFF_BASE_CMD` | empty | Empty: the plugin's `resolve-base.sh`. Set: path relative to the repo |
| `LINT_CONFIG` | `<project-dir>/golangci.yml` | golangci-lint configuration (relative to the repo) |
| `TRACKER` | `none` | `jira` or `none` (with `none` the task is free text) |
| `PR_HOST` | `auto` in new `sdkit.env` (script default `bitbucket`) | PR host: `bitbucket`, `github`, `gitlab`, `auto` |
| `PROTECTED_PATHS` | empty | Comma-separated, root-relative path prefixes. `guard-protected` asks for approval |
| `SECRET_GLOBS` | `.env*,*credentials*,*.pem` | File patterns blocked by `guard-secrets` |
| `PROD_KUBE_CLUSTERS` | empty | Prod cluster name prefixes. **If not set, the kubectl guard is off** |
| `BASE_BRANCH_MODE` | empty | If `release`, the release-branch flow is on (`guard-git`, release-aware base) |
| `RELEASE_BRANCH_PREFIX` | `release/` | Release branch prefix |
| `FREEZE_TAG_PREFIX` | `freeze/` | Freeze tag prefix |
| `PROTECTED_BRANCHES` | empty | Env branches where a direct push needs approval |
| `SERVICES_DIR` | `services` | Directory the example OpenAPI policy looks at |
| `SHARED_MODULE` | empty | Shared Go module whose dependents are also built when it changes |
| `DEPENDENT_MODULES_GLOB` | empty | Glob of the dependent modules (`services/*`) |
| `INTEGRATION_MODULE_GLOB` | `tests/*` | Modules that go to real infrastructure: vetted/built, not tested (also applies to Spring Boot; empty = all are tested) |
| `NODE_PM` | empty | Node stacks: `npm\|pnpm\|yarn\|bun`; if empty, from the lockfile |
| `VERIFY_BUILD` | empty | Node stacks: whether to run `next build` etc. in full verification |
| `JAVA_BUILD_TOOL` | empty | Spring Boot: `maven\|gradle` (if detection is wrong) |
| `VALUE_REPORT` **(personal)** | `on` | If `on`, when a task finishes (`sdd.sh advance done`, `abort`) a compact Value Report is written to stderr and stored in `work/_reports/`; at session end a summary is stored. Read-only, no LLM call. Empty = automatic output off (the commands still work). [design-report.md](design-report.md) |
| `REPORT_BASELINE_MODEL` | empty | Baseline model of the Value Report routing counterfactual (an id in `pricing.json`). If empty, routing savings are `N/A`; the kit does not invent a model |
| `USAGE_LOG` **(personal)** | `1` | If `1`, the token ledger is on (section 18); empty = off |
| `USAGE_LINE` **(personal)** | `1` | If `1`, a finished subagent prints `[sdkit] <role> done — in: 12.4k (cache read 8.8k, write 0.9k), out: 1.8k, cache hit: 71%` (Claude hook and `run-role.sh`). `in` = fresh + cache read + cache write; cache hit = cache read / in. `USAGE_LINE=1` also switches the ledger on (`USAGE_LOG` is not needed), because the step line reads it: `sdd.sh advance` prints a `usage:` line (`usage.sh live show`: the orchestrator's own share and the task total, from the same ledger the Value Report reads), which the orchestrator appends to its step `done` line (`progress.md`). The orchestrator's share comes from the Claude hook, or, on Codex, from its rollout file (`usage.sh live pull`: the task's share of the session's cumulative counters). A run whose host gave no token data is counted as `not measured`, never as 0; Gemini, OpenCode and Cursor give none for the orchestrator today. Where the host gave no token data the line says `token usage not available` instead of numbers. Needs no `USAGE_LOG`; empty = off |
| `TELEMETRY` **(personal)** | `1` (new setup) | If `1`, the `work/<slug>/events.jsonl` event log is on (section 18, [design-telemetry.md](design-telemetry.md)); empty = off |
| `EXTRA_REVIEW_SKILLS` | empty | Extra host skills for reviewer + security-auditor at `high` risk, space-separated (e.g. `code-review security-review`) |
| `ROUTING` | `on` (new setup; unset = off) | If `on`, `run-role.sh` takes the adapter/model/budget/retry decision from `route.sh`; detailed `ROUTE_*` settings ([design-routing.md](design-routing.md) §9): `ROUTE_POLICY`, `ROUTE_FIXED_MODEL`, `ROUTE_DOWNGRADE_LOW`, `ROUTE_FLOOR_*`, `ROUTE_FALLBACK_HOSTS`, `ROUTE_MAX_RETRIES/ESCALATIONS/ATTEMPTS`, `ROUTE_ESCALATE_TO`, `ROUTE_BACKOFF_S`, `ROUTE_PREFER_<ROL>`. Team setting (`sdkit.env`) |
| `AGENT_<ROLE>_TIER` | the role's own tier (listed for each role) | The tier a role runs at: `light` / `standard` / `strong` (`AGENT_ENGINEER_TIER=standard`, `AGENT_SECURITY_AUDITOR_TIER=strong`). Claude Code: `light`→`haiku`, `standard`→`sonnet`, `strong`→`opus` (`CLAUDE_MODEL_*` in the kit's `core/tiers.env`). The session start tells the orchestrator which roles moved, the `Agent` hook refuses a spawn with another model (`SDD_MODE`: strict refuses, guided warns); `run-role.sh` and `route.sh` apply it themselves. `verifier`, `reviewer`, `security-auditor` can go up, never below their own tier; high-risk verification stays strong. `sdkit doctor` flags a typo. A task's `size:` can still move one task |
| `ROUTE_REQUIRE_SIZE` | `1` | With `ROUTING=on` and `ROUTE_POLICY=tiered`, `sdd.sh advance proposed` refuses a `tasks.md` whose `role:` tasks lack `size:` (reason `no-task-size`). `0` = not required |
| `ROUTE_ROLE_TOKENS`, `ROUTE_TIMEOUT_S`, `ROUTE_BUDGET_COST` **(personal)** | empty | Per-role tokens, seconds per run, estimated USD limit (the money limit is always advisory). `TOKEN_BUDGET_TASK`/`MAX_SPAWNS` are also checked by `route.sh` |
| `RUN_ROLE_HOST` **(personal)** | empty | Default host for `run-role.sh` (`claude\|codex\|opencode\|cursor\|gemini`) |
| `VERIFIER_HOST` **(personal)** | empty | Host for the independent roles (verifier, reviewer, security-auditor); another provider = real independence |
| `RUN_ROLE_MODEL_LIGHT/STANDARD/STRONG` **(personal)** | empty | Host-specific model id per tier for `run-role.sh` |
| `MAX_PARALLEL` **(personal)** | `3` | Maximum subagents/processes running at the same time; `plan-waves.sh` splits a larger wave (positive integer; 3 if invalid) |
| `TOKEN_BUDGET_TASK` **(personal)** | empty | The most tokens a task may use (`in + out + cache-write`); needs `USAGE_LOG=1`. Empty = no budget |
| `TOKEN_BUDGET_WARN_PCT` **(personal)** | `70` | Warn from this percentage of the budget on |
| `MAX_SPAWNS` **(personal)** | empty | Maximum subagent spawns per task; when exceeded, `strict` asks, `guided` warns. Empty = no limit |
| `SUBAGENT_RESULT_MAX_LINES` **(personal)** | empty | `result-size` warns if a role's answer is longer than this |
| `NOISY_CMD_PATTERNS` | empty | Comma-separated globs of commands with long output (`npm test*,go test*,pytest*`); `guard-noisy` asks to run them through `capped.sh`. Empty = off |
| `CAPPED_LINES` **(personal)** | `40` | Lines `capped.sh` keeps of a command's output (failure lines come on top); shorter output is printed whole |
| `CONTEXT_HINT` **(personal)** | `1` | `sdd.sh advance proposed|green` prints a one-line note on stderr that a `/clear` or new session loses nothing at this boundary |
| `MEMORY` | `1` | If `1`, project memory is on (section 19); empty = off (`sdkit init --no-memory`) |
| `MEMORY_DIR` | `memory` | Directory of the entries: relative to `<project-dir>` or an absolute path |
| `MEMORY_VCS` | `commit` | `commit` = shared by the team, `ignore` = personal (`init --memory-vcs` writes the `.gitignore` line; can be changed later) |
| `MEMORY_AUTOLOAD` **(personal)** | `1` | If `1`, the session hook puts `INDEX.md` into the context |
| `MEMORY_INDEX_MAX` **(personal)** | `100` | Maximum entries and maximum injected `INDEX.md` lines |
| `MEMORY_STALE_DAYS` **(personal)** | `90` | `memory.sh stale` flags entries not updated for this many days |
| `MEMORY_PROMOTE` **(personal)** | `ask` | At closeout, ask the user about the `MEMORY:` candidates (`ask`), take all of them (`auto`) or none (`off`) |

Environment-only variables: `VERIFY_BASE` (override the diff base), `VERIFY_POLICY_DIR` (default `<project-dir>/verify.d`),
`BITBUCKET_EMAIL`, `BITBUCKET_TOKEN`, `PR_TOKEN_REPO`. An environment variable overrides the default in `sdkit.env` (for `PR_HOST` the `: "${PR_HOST:=auto}"` form makes this work).

### `<project-dir>/project.md` sections
Tracker · Branches and PRs (including commit scopes) · Release flow (optional) · Verification · Test layout · Protected code · **Risk rubric** · Known pitfalls.
`scaffold-doctor` fails if a `TODO` is left or the rubric is missing.

### Other project files
`rules/` (project rules; `init` copies the general and Go rules, the project edits them) · `golangci.yml` · `adr/` · `CLAUDE.md` (map) ·
`.gitignore` (personal files: `settings.local.json`, `.frozen`, `.cc-writes/`, `scheduled_tasks.lock`, `memory/`, `work/`, `.verify-cache/`). Non-Claude hosts also write `AGENTS.md`, `.agents/skills/`, `.githooks/` and their own directories to the repo root (section 16).

---

## 11. Install flows

### New repo (once, by the person setting the repo up)
```bash
git clone <this-repo> ~/spec-driven-kit
~/spec-driven-kit/bin/init.sh /path/repo      # detects the stack and base branch itself
# fill in <project-dir>/project.md and sdkit.env, remove the extension from the verify.d/*.example files you want
~/spec-driven-kit/bin/doctor.sh /path/repo    # until there are 0 failures
git add <project-dir> .claude && git commit      # <project-dir>: the directory init wrote
```
`init.sh` options: `--host` (comma-separated list: `claude,codex,opencode,cursor,gemini`; default `claude`), `--dir .sdkit` (default; an existing legacy directory is kept), `--no-memory`, `--memory-vcs commit|ignore`, `--mode plugin|copy` (Claude only), `--stack go|spring-boot|jvm|python|nextjs|react-native|generic` (if not given, `go`, `spring-boot`, `react-native`, `jvm`, `nextjs`, `python` are detected in this order; the first match wins, `generic` if none), `--marketplace-url <url>`, `--force`. **It never overwrites project-side files (project.*, rules, settings.json ...), even if they exist**;
they are written once and are yours after that. `--force` overwrites only the (managed) files copied from the kit in copy mode.

### Developer (repo already set up)
```bash
git clone <repo> && cd <repo>
claude      # accept trust and the plugin
/spec-driven-dev <ticket or description>
```
If the prompt does not appear: `/plugin marketplace add <bu-repo-url>` and `/plugin install spec-driven-kit@spec-driven-kit`.

### What `doctor.sh` checks
`jq`, git repository · whether `sdkit.env` loads, `BASE_BRANCH` exists, `VERIFY_CMD` is executable · whether `project.md` is filled in (no bare `TODO` left) and has a risk rubric ·
`known-pitfalls.md`, `CLAUDE.md`, `<project-dir>/.gitignore` · whether there is an active `verify.d` policy (warning if not) · whether `settings.json` is valid and has a `deny` list ·
in plugin mode whether the plugin is enabled and the marketplace address is defined, in copy mode whether the hooks are wired · non-Claude hosts (detected by the kit block in `AGENTS.md` or `.agents/skills/spec-driven-dev`; third-party skills in `.agents/skills` from `npx skills add` do not count): `AGENTS.md`, `.agents/skills`, whether kit scripts (`verify-core`, `state`, `parse-verdict`, `run-role` ... ) are executable, `hooks/adapt.sh`, `core.hooksPath`, role files for the installed host (`.codex/agents`, `.opencode/agents` + guard plugin, `.cursor/agents` + valid `hooks.json`, `.gemini/agents` + valid `settings.json`) · whether each host's CLI is installed (warning only: only `run-role.sh` needs it) · on `react-native`, outdated third-party Expo skills (warning) · the stack's `tools.sh` list (on `PATH` or in the repo's `node_modules/.bin`; failure if a `required` one is missing, warning if an `optional` one is missing) and `openspec`.

### `upgrade.sh` (updating)
Moves a project that uses the kit to the new version: detects the hosts (from the presence of `.codex/`, `.opencode/agents`, `.cursor/agents`, `.gemini/agents`; `AGENTS.md`/`.agents/skills` for the old 0.3 Codex layout), the mode and the stack, adds new files (does not touch existing ones), adds missing lines to `.gitignore`, runs `sync.sh` in copy or non-Claude installs, and finishes with `doctor.sh`. The plugin side is refreshed separately with `/plugin`. Details and manual steps per version: [upgrading.md](upgrading.md). **Claude projects in copy mode:** `.claude/settings.json` is owned by the project, so new hooks (`guard-readonly` for PreToolUse `Bash|Edit|Write|NotebookEdit`, `usage-log` for Stop and SubagentStop) must be merged by hand; source `templates/settings.copy.json`.

### `sync.sh` (copy mode only)
Updates the copies in the project when the kit changes. A file edited locally that also changed in the kit is not overwritten: it shows the difference (`--force` takes the kit version).

---

## 12. Permission model

Two layers work together:

1. **`settings.json` rules** (committed in the project): `permissions.deny` always wins: `rm -rf`, `git push --force/-f`, `git reset --hard`,
   reading `.env*` / `*.pem` / `*credentials*`. `permissions.allow` allows routine commands (Edit/Write, `make`, read-only `git`,
   `git add/commit/push/checkout/switch`, `kubectl get/describe/logs`, `openspec`, `jq`, `ls`, `cat`) and adds the chosen stack's `permissions.txt` patterns (e.g. Go: `go`; Node: the package manager; Spring: `mvn`/`gradle`/wrapper); `init` writes them to `settings.json` so there is no flood of permission prompts on day one.
2. **Hooks** (from the plugin): can give **deny/ask** on top of an `allow` rule. So even an allowed command can be rejected for a reason
   such as a wrong branch source.

Personal permissions go in `settings.local.json` (not in git).

Trust: before the **trust prompt** for a project, Claude Code applies only the user settings; until then the project's `permissions.allow` and
the plugin the project defines do not take effect. This is normal behaviour, not a kit problem.

---

## 13. Limits and known gaps

- **The Codex, OpenCode, Cursor and Gemini adapters are not validated on live installs.** The file layouts are generated to each tool's documented format; only the Claude Code path was tried end to end. Unvalidated points:
  - Codex: that the multi-agent feature is enabled in the version you use, and the key names; the read-only sandbox may block build caches.
  - OpenCode: whether the shell permission key is `shell` or `bash` (`bash` in old versions; `OPENCODE_SHELL_KEY` in `core/hosts.env`), and whether plugin hooks fire inside subagents.
  - Cursor: hooks and subagents exist in the IDE, undocumented in the CLI; `--output-format json` gives no token usage (the ledger stays empty on this host).
  - Gemini: subagents may be behind an experimental flag; the write/edit tool names (`write_file`, `replace`) and the `context.fileName` array format are not validated.
  - `run-role.sh` flag spellings per CLI: print with `--dry-run`, compare with `<cli> --help`.
  - Model choice by task size (`--tier`, `size:`): the Codex, OpenCode, Cursor and Gemini paths were tested only with `--dry-run`; no real model call was made. Codex's `-c model_reasoning_effort=...` flag and OpenCode's `anthropic/claude-*-5-5` model ids are not validated on a live install. The `core/tiers.env` models for Cursor and Gemini are deliberately left empty (the kit does not make up model names): until they are filled in, `--tier` does not change the session's model.
- **Guarantees are weaker on non-Claude hosts.** There is no Stop-verify and no SessionStart; the secret/frozen/protected/push guards run at tool-call time on Gemini/Cursor/OpenCode (shim/plugin), but those paths themselves have not been tried; on Codex they run only at commit/push time (git hook, CI). On a host that does not support `ask`, the approval prompt falls back to `deny`. Independent verification depends on subagent support or `run-role.sh`; otherwise it must be done in a separate session.
- **The project-side directory is `.sdkit/`** (`.claude` / `.codex` / `.agentkit` in old installs); scripts/hooks find it by looking for it by name, no other name is supported. Claude Code's own files (`CLAUDE.md`, `settings.local.json`, in copy mode `agents/ skills/ hooks/`) stay under `.claude/`.
- **Token usage:** the kit keeps an optional ledger (`USAGE_LOG=1`, section 18), but measurement depends on the host; on Claude it comes from the hook, in `run-role.sh` from where the CLI writes it, and on some hosts it is missing.
- **One `STACK` per repo** (`go`, `spring-boot`, `jvm`, `python`, `nextjs`, `react-native`, `generic`). A monorepo with multiple stacks is out of scope. For an unrecognized language `init` falls back to `generic`; you write the build/test commands in `sdkit.env`. For a new stack, section 14.
- **The verification cache** knows only green results and the full tree state. If something outside the tree changed (environment, network, external service, a file read outside `verify.d`), an old green may look valid: when in doubt, `--no-cache`.
- **Bitbucket is the only PR host.** For GitHub/GitLab there is only a [setup note](hosts.md).
- **Guards work with regular expressions and simple matching.** `guard-secrets` does not see `cat .env` in Bash (the `deny` list is there for that); `guard-git` can miss unusual git
  syntax or calls from inside scripts; `guard-prod` only looks at `kubectl`; `guard-readonly` can miss an unknown write command. These are not a security **boundary**, they are error-preventing safety nets.
- **`stop-verify` runs only the fast check of uncommitted changes** (`--fast`: vet/build on Go); it does not run tests and lint (to stay fast). For full verification, `verify.sh` (no flags).
- **It depends on OpenSpec.** `spec-driven-dev` calls the OpenSpec skills; the CLI must be installed. OpenSpec files are not included in the kit.
- **The plugin install prompt** is expected on first open, after the trust prompt; in some environments it may not appear, and the two `/plugin` commands are the fallback.
- **In headless (`claude -p`) mode** project settings are ignored in an untrusted project.

---

## 14. Extending

**Adding a project-specific check:** write `<project-dir>/verify.d/NN-ad.sh` (`FAIL:`/`WARN:` protocol), `chmod +x`.

**Adding a project-specific hook (Claude):** a script under `.claude/hooks/` in the repo, wired in `settings.json`. It complements the plugin hooks, it does not replace them.
The script reads the tool call from stdin with `jq` and writes the `permissionDecision` (`deny`/`ask`) JSON (see `hooks/lib.sh`: `jget`, `decide`).

**Adding a new role:** write `core/roles/<ad>.md` (`kind`, `access`, `tier`, `independent`), run `bin/build-adapters.sh`, update the `core/roles/README.md` table and section 6 of this guide. The role must contain nothing project-specific.

**Adding a new host:** `bin/emit/<host>.sh` (generates the role format: `emit_<host>_begin/role`), the host's tool/permission names in `core/hosts.env`, model tier keys in `core/tiers.env`, a `--host` branch in `init.sh` (host files and guard wiring; a translation in `hooks/adapt.sh` if needed), checks in `doctor.sh` (role files, CLI), a headless call in `scripts/run-role.sh`, a column in `skills/spec-driven-dev/references/hosts.md`; then run `bin/build-adapters.sh` and commit the output.

**New risk criterion / rule:** edit the `project.md` rubric and `rules/`; no need to touch the kit.

**Adding a new stack** (contract: `stacks/README.md`): under `stacks/<ad>/`
1. `detect.sh` (0 if `$1` is a project of this stack), added to the `STACKS` order in `init.sh`
2. `scripts/steps.sh` (`STACK_SOURCE_RE` and `stack_run`; the core `scripts/verify-core.sh` handles the flags, the cache and `verify.d`) and a thin `scripts/verify.sh`
3. `scripts/fmt.sh` (always exits 0), `scripts/tools.sh` (`required|komut|ipucu`), `permissions.txt`
4. `rules/`, `verify.d.example/` and the linter configuration, if any

**Updating the kit:** make the change in this repo, bump the version in `.claude-plugin/plugin.json` and `marketplace.json`, push. Repos that use the plugin
get the update with `/plugin`; those in copy mode run `sync.sh`.

---

## 15. File map

```
spec-driven-kit/
├── .claude-plugin/        plugin.json, marketplace.json
├── core/
│   ├── roles/             TOOL-INDEPENDENT role definitions (source), README.md
│   ├── tiers.env          tier -> model mapping (Claude, Codex, OpenCode, Cursor, Gemini)
│   ├── hosts.env          host tool/permission names (read-only shell allow-list, Gemini tools, OpenCode key)
│   └── rules/             general, git, test-first, token-economy     (language-independent)
├── skills/                spec-driven-dev (+ references/), incident-to-rule, scaffold-init, scaffold-doctor, generate-specs, update-specs, generate-tasks
├── agents/                GENERATED Claude agents (including verifier-deep; from core/roles; do not edit by hand)
├── adapters/
│   ├── codex/ opencode/   GENERATED role files (+ config.toml.snippet; OpenCode guard plugin plugins/)
│   ├── cursor/ gemini/    GENERATED role files + hooks.json / settings.json
│   └── git/               pre-commit, pre-push (call guard.sh)
├── hooks/                 hooks.json (event wiring) + lib.sh + 19 hooks + adapt.sh (Gemini/Cursor shim)
├── scripts/               env (settings reader, lock, active task), sdd, resolve-base, open-pr, guard, plan-waves, worktree, state, parse-verdict, check-plan-parity,
│                          check-writes, usage, telemetry, contract, workflow, route, memory, lookup-cache, run-role, verify-core, verify-lib,
│                          spec, tasks, review, jira   (role-aware; stack-independent)
├── adapters.d/            execution adapters: litellm.sh, jira.sh (task-contract adapter)
├── bench/                 run.sh (benchmark driver), scenarios/ (4 F01 + 5 contract scenarios), stub-host/ (fake host CLIs for simulated mode); see design-telemetry.md, design-contracts.md
├── stacks/
│   ├── README.md          stack contract
│   ├── _node/scripts/     node-lib.sh (shared by nextjs and react-native)
│   ├── go/                detect.sh, permissions.txt, golangci.yml, known-pitfalls.md, rules/, verify.d.example/,
│   │   └── scripts/       verify.sh (wrapper), steps.sh, fmt.sh, tools.sh
│   └── spring-boot/ jvm/ python/ nextjs/ react-native/ generic/    same structure
├── tests/                 run.sh (script smoke tests), sdd.test.sh, shared.test.sh, memory.test.sh, hardening.test.sh, telemetry.test.sh, usage.test.sh, budget.test.sh, route.test.sh
├── templates/             sdkit.env, project.md, known-pitfalls.md, CLAUDE.md, AGENTS.md, adr/, settings.*.json, claude.gitignore
├── bin/                   init.sh, doctor.sh, sync.sh, upgrade.sh, build-adapters.sh, lib.sh, emit/<host>.sh
└── docs/                  guide.md (this file), cheatsheet.md, hosts.md, README.md
```

The project side in a repo after `init.sh`:

```
<repo>/.sdkit/             the single project dir; in git, except personal and generated files (its own .gitignore)
├── project.md  known-pitfalls.md  adr/  verify.d/  roles.d/  golangci.yml (Go only)      (in git)
├── rules/                 general + test-first + token-economy + stack rules (copy, the project edits them)  (in git)
├── memory/                project memory: INDEX.md + entries (MEMORY=1; personal with MEMORY_VCS=ignore)  (in git)
├── attestations/          verification records, for the CI gate (in git)
├── sdkit.env              the team's shared settings: release flow, protected paths, stack ... (in git)
├── sdkit.local.env        PERSONAL settings: budgets, limits, memory behaviour, host/model (not in git)
├── work/<slug>/           plan.md, state.json, notes.md, usage.jsonl, out/, lookups/ (not in git)
├── scripts/ roles/ hooks/ tiers.env   kit copies, generated by the install (not in git; except sdd.sh, resolve-base.sh and env.sh, for CI)
└── .verify-cache/ .frozen .sdd/ .scaffold-*   run time (not in git)
<repo>/.claude/            (Claude host) CLAUDE.md (kit block, in git), settings.local.json (not in git); in copy mode agents/ skills/ hooks/
<repo>/AGENTS.md  .agents/skills/  .githooks/                                         (non-Claude hosts)
<repo>/.codex/{config.toml,agents/}  .opencode/{agents/,plugins/spec-driven-kit-guard.js}
<repo>/.cursor/{agents/,hooks.json}  .gemini/{agents/,settings.json}               (the respective host)
```

---

## 16. Hosts: Claude Code, Codex, OpenCode, Cursor, Gemini

The kit has three layers; which of them is portable is clear.

| Layer | Content | Portability |
|---|---|---|
| **A. Markdown** | Roles, flow (`SKILL.md`), rules, `AGENTS.md` | Every tool reads it. The `SKILL.md` format is shared |
| **B. CLI scripts** | `verify.sh`, `resolve-base.sh`, `guard.sh`, `plan-waves.sh`, `worktree.sh`, `state.sh`, `parse-verdict.sh`, `run-role.sh` ... | Every tool calls them from the shell |
| **C. Tool-specific wiring** | Claude hooks and agent files; Codex/OpenCode/Cursor/Gemini role files and guard wiring; git hooks | Per host (`bin/emit/<host>.sh`) |

| | Claude Code | Codex | OpenCode | Cursor | Gemini CLI |
|---|---|---|---|---|---|
| Instructions | `.claude/CLAUDE.md` + skills | `AGENTS.md` + `.agents/skills/` | `AGENTS.md` + `.agents/skills/` | `AGENTS.md` + `.agents/skills/` | `AGENTS.md` (`.gemini/settings.json` `context.fileName`) + `.agents/skills/` |
| Roles | `agents/*.md` (plugin) / `.claude/agents/` | `.codex/agents/*.toml` + `config.toml` | `.opencode/agents/*.md` | `.cursor/agents/*.md` | `.gemini/agents/*.md` |
| Read-only enforcement | `guard-readonly` hook | sandbox `read-only` | `permission:` allow-list | `readonly: true` | `tools:` list |
| Guards | hooks (the model cannot skip them) | git hooks | JS plugin + git hooks | `hooks.json` → `adapt.sh cursor` + git hooks | `settings.json` hooks → `adapt.sh gemini` + git hooks |
| Kit scripts | plugin root or `<project-dir>/scripts/` | `<project-dir>/scripts/` | same | same | same |
| Install | `init.sh --host claude` | `--host codex` | `--host opencode` | `--host cursor` | `--host gemini` |
| Invoking the skill | `/spec-driven-dev` | `$spec-driven-dev` or `/skills` | per host | per host | per host |

`--host` takes a comma-separated list (`claude,codex,...`). On every host other than Claude, `init` copies the skills to `.agents/skills/`, the kit scripts, role texts and hooks to `<project-dir>/{scripts,roles,hooks}`, and the git hooks to `.githooks/`. Unvalidated points are in section 13.

Host notes:
- Codex: `.codex/config.toml` is project-side; an existing file is not overwritten, `adapters/codex/config.toml.snippet` is merged by hand. Role TOMLs contain `model_reasoning_effort`, `sandbox_mode` and `developer_instructions`; `model` is written only if `CODEX_MODEL_*` is set in `core/tiers.env`.
- OpenCode: the shell permission key is `OPENCODE_SHELL_KEY` in `core/hosts.env` (`bash` in old versions).
- Cursor/Gemini: if `.cursor/hooks.json` or `.gemini/settings.json` already exists, merge by hand. Where `ask` is not supported, the guard decision falls back to `deny`.
- The project dir is `.sdkit/` for every host. At run time `sdkit.env` (`project.env` in old installs) is looked up in `.sdkit`, `.agentkit`, `.claude`, `.codex`, in that order; pre-1.0 projects work as they are.
- Once per clone: `git config core.hooksPath .githooks` (`doctor.sh` warns).

**Separate process and independent provider:** `scripts/run-role.sh <role> --handoff F --host H` runs a role as a separate headless CLI process (`claude -p`, `codex exec`, `opencode run`, `cursor-agent -p`, `gemini -p`). If the verifier is given to a different provider with `VERIFIER_HOST`, the independence is real (the same model family misses its own mistakes).

On a host without subagent support the same plan runs sequentially; independent verification uses a fresh session or `run-role.sh`.

---

## 17. Parallel work

The default is **sequential**; parallel runs multiply tokens. Work runs in parallel only if the risk is `medium`/`high`, at least two tasks have disjoint write sets, and the host can run subagents.

Task format (`tasks.md` and plan section 5):
```
- [ ] T3 add retry to the importer | role: developer | size: medium | writes: services/importer/ | after: T1
```
`size:` is optional (model tier, section 6); `plan-waves.sh` shows it in the output as `T3(developer,medium)`, it does not affect grouping.
Example output of `scripts/plan-waves.sh tasks.md`:
```
wave 1: T1(developer)  ||  T3(devsecops)  ||  T5(developer)
wave 2: T2(developer)
wave 3: T4(test-writer)      # write path overlaps with T2, moved later
```

Safe parallel pairs: `test-writer ‖ developer` (if the test and interface are fixed in the plan; the developer cannot change the test) · two `developer`s with disjoint `writes:` · `developer ‖ devsecops` ·
`verifier ‖ reviewer ‖ security-auditor` (`high`, all read-only, none sees another's output) · `analyst ‖ scout` at intake. **Never:** `verifier` with the implementer, two writers on the same file, work that depends on an unmerged result.

Isolation **belongs to the kit**, it does not depend on the host's native worktree feature (so it works the same on every host): every writing task runs in its own worktree (`worktree.sh add T3`), its path is taken with `worktree.sh path T3` and written into the handoff as `WORKTREE:`, and the role reads/writes only under that path; if the host cannot pin the role to a directory, `run-role.sh --cwd` is used. The orchestrator merges wave by wave: `worktree.sh merge T3 tasks.md` first checks with `check-writes.sh` whether the task went outside its `writes:` set (if it did, it does not merge), then merges; after every merge it runs `verify --fast` and only then moves on to the next wave.
At `high` risk reviewer and security-auditor start in the same message as the verifier (plus host skills if `EXTRA_REVIEW_SKILLS` is set). A merge conflict means the write sets were wrong: stop, tell the user, fix the plan. At most `MAX_PARALLEL` (default 3) subagents at the same time: `plan-waves.sh` splits a larger wave, and tasks that do not fit move to the next wave.

---

## 18. Token economy

Goal: spend where judgement is needed; do not spend on searching, rewriting and rereading. The rules are in `core/rules/token-economy.md` (copied into the project); in summary:

| Lever | How |
|---|---|
| Right-sized role | Search `scout` (light), planning check `analyst`, design and `high` verification (`verifier-deep`) strong, the rest standard. Roles declare a tier, not a model name |
| Cheap first | `verify.sh` before the LLM review; if red, no expensive reading |
| Do not repeat | Green verification cache: the Stop hook, the verifier and the PR step do not repeat work for the same tree (skipped with `--no-cache`) |
| Script, not LLM | Plan parity (`check-plan-parity.sh`), verdict validation (`parse-verdict.sh`), write set (`check-writes.sh`), retry limit (`state.sh retry`) are deterministic scripts |
| Artifact handoff | A sub-role gets a short handoff with paths (`handoff.md`), not the conversation. Independent roles already do not get the implementer's reasoning, which also keeps this context small |
| Trim the output | The command's summary line + failing lines (`tail -40`); roles return a structured block + at most 15 lines |
| Read narrowly | Grep for the symbol, open the lines you need; do not read the whole file unless you are changing most of it |
| On-demand loading | `SKILL.md` is short; `references/` is read only at the relevant step |
| Depth by risk | `low`: no engineer run, no independent verifier and no parallel wave; the analyst runs at `low` too (cheap, consistent). A single `scout` run via `NEEDS-LOOKUP` instead of role chains |
| Parallel only when it pays | Disjoint write sets or read-only reviews, at most `MAX_PARALLEL` (3) concurrent |
| One retry, then ask | A second automatic retry burns tokens and rarely helps |
| Spawn when needed | One- or two-file work is done in place; roles do not spawn roles. Decision table: `references/delegation.md` |
| Short result, long form in a file | A role returns at most 15 lines + a structured block; the long form goes under `work/<slug>/out/`. The same scout question is not paid for twice, thanks to `lookup-cache.sh` |
| Budget | `MAX_SPAWNS`, `TOKEN_BUDGET_TASK`: asks when exceeded; verification is not cut short to fit the budget |
| Cache-friendly handoff | Fixed lines first, lines that change on every spawn last; the same model within a wave; spawns together |
| Checkpoint | `state.sh set step` + `notes.md` at step boundaries; resume without loss after `/clear` or compaction |
| Re-deriving | Things already settled in the plan's decision log and in the session are not asked/done again |

### Measurement: token ledger
With `USAGE_LOG=1` (`sdkit.env`) every agent run writes one JSON line to `<project-dir>/work/<slug>/usage.jsonl`: role, tier, host, model, input/output and cache tokens. On Claude `hooks/usage-log.sh` (SubagentStop and Stop) collects them from the transcript; `run-role.sh` records them where the host CLI writes its usage info (Claude yes; Cursor has no usage in its json output; best effort on the others). When off, all of this is a silent no-op. `USAGE_LINE=1` additionally prints one summary line per finished subagent (see the settings list).
`scripts/usage.sh report [slug]` gives the run counts and token totals per role and tier, plus the cache hit rate.

### Measurement: event log and benchmark
With `TELEMETRY=1` (`sdkit.local.env`) phase transitions, gate rejections, test results, agent runs (duration, tokens, tool calls), retries, failures and verification results are written as structured events to `work/<slug>/events.jsonl`; it is not a new ledger, the token counts come from the same source as `usage.sh`. Every measurement carries an `actual`, `estimated` or `unavailable` label; a number the host does not give is not written. Prompts and file contents are not recorded. `scripts/telemetry.sh summary [slug] [--json]` gives the report; run `telemetry.sh archive <slug>` before closeout (`work/<slug>` is deleted). No cost is shown unless a price table (`pricing.json`) is given. `bench/run.sh` runs four representative workflows simulated (free, deterministic) or, with `--real`, on real hosts. Details: [design-telemetry.md](design-telemetry.md).

Contracts (F02) write a `contract.check` event to the same log (valid/invalid, category, version, role, id, bytes; no text). The overhead was measured with simulated fixtures (`bench/run.sh overhead`): 202 fixed bytes per handoff, ~119 bytes per answer, 2 script calls per agent, no extra agent call; **token savings or cost were not measured**. Details: [design-contracts.md](design-contracts.md) §7.

### Budget and subagent management
All are off by default; the kit imposes no numbers, each team writes its own limit in `sdkit.env`.

| Setting | What it does |
|---|---|
| `TOKEN_BUDGET_TASK` **(personal)** | `usage.sh budget` compares the `in + out + cache-write` total in the ledger with the limit. Warns at `TOKEN_BUDGET_WARN_PCT` (70), stops at 100%. Needs `USAGE_LOG=1` |
| `MAX_SPAWNS` **(personal)** | `state.sh <slug> spawn` counts every spawn; once the limit is exceeded, the next spawn is put to the user. No token measurement needed |
| `SDD_MODE` | `strict` asks before the spawn that goes over the limit, `guided` only warns, `off` ignores both |
| `SUBAGENT_RESULT_MAX_LINES` **(personal)** | The `result-size` hook warns on a long answer (does not block) |
| `NOISY_CMD_PATTERNS` | The `guard-noisy` hook asks to run a matching command through `scripts/capped.sh`. Cost nudge, never a block. See `references/delegation.md`, "Keep this session thin" |

In Claude Code the counting is done by the `guard-budget` hook on every `Agent` call. On other hosts the spawn point is `run-role.sh`: at the limit it stops with exit 3, and after the user approves it is rerun with `--ignore-budget`. If the host gives no token info, the ledger stays empty and the token budget stays silent; the kit does not guess. For the same reason, on Codex the token budget works only when a record comes from the `run-role.sh` CLI output; `MAX_SPAWNS` works on every host.

Decision and result rules for the orchestrator (`references/delegation.md`): one- or two-file work is done in place, roles do not spawn roles, scout questions are asked in batches and `lookup-cache.sh get` is checked first. Read-only roles cannot write files; the orchestrator writes their long answer with `run-role.sh --out` or itself under `work/<slug>/out/<role>-<n>.md`. Writing roles (`engineer`, `developer`, `test-writer`, `devsecops`) put their long form at the handoff's `OUT:` path.

Cache: the model cache works for the same prefix and the same model, and its lifetime is short. In the handoff the fixed lines (ROLE, RISK, PROJECT-DIR, standard READ) come first and the changing ones (TASK, DIFF-BASE, TESTS) last; within a wave, tasks of the same tier use the same model; a wave's spawns are made together; `project.md` and the rules are not changed mid-task.

How to measure: make a **baseline run** with a fixed task, keep the `usage.sh report` output, then change **a single variable** (a role's tier, `verifier` instead of `verifier-deep`, cache on/off, parallel/sequential) and repeat the same task; compare the reports. Decide by the ledger, not by guesses.

Limit: the rules are at design level; the ledger fills only where the host gives token info (section 13).

---

## 19. Project memory

Goal: keep the knowledge the agent rediscovers on every task, and that is not visible in the code, in one place; but without loading all of it into context in every session. Since 1.0 it is **on by default** in new installs (`MEMORY=1` in `sdkit.env`; turned off with `sdkit init --no-memory`). In an old repo `sdkit upgrade` adds missing settings with their defaults, so it turns memory on too; if you do not want it, set `MEMORY=`.

| Layer | Where | Lifetime |
|---|---|---|
| Working | Conversation context | One session |
| Task | `work/<slug>/` (`state.json`, `plan.md`, `notes.md`, `out/`, `lookups/`) | Until closeout; survives `/clear` and compaction, deleted at closeout; personal, not in git |
| Project | `.sdkit/memory/` (`MEMORY_DIR`) | Lasting and in git; `memory.sh stale` flags stale entries |
| Personal | The host's own memory (Claude's user-level auto memory, `.claude/memory/`) | Decided by the host; the kit does not touch it. A path such as `.claude/memory.md` is not read by Claude Code anyway, so the kit generates no redirect file: the agent goes to `.sdkit/memory/INDEX.md` through the `CLAUDE.md`/`AGENTS.md` block and the session hook |

**Project memory.** `memory/INDEX.md` keeps one line per entry; only this file enters the context at session start (on Claude the `session-context` hook, on other hosts the "read the INDEX first" pointer in the `AGENTS.md` block). An entry's body is read when its line looks relevant. `INDEX.md` also links to `known-pitfalls.md` and `adr/`; both stay as they are (the verifier and `incident-to-rule` depend on them). Entry types: `fact` (a fact not derivable from the code), `howto` (a discovered command sequence), `decision` (a small decision; big ones go to an ADR).

An entry file is `<slug>.md`, and its header has the fields `type`, `title`, `updated`, `verify-by`, `refs`. An entry is a claim made on its `updated` date: if it contradicts the code, trust the code and tell the user the entry needs fixing.

**Writing.** During a task the agent appends what it learned to `work/<slug>/notes.md` as `MEMORY: fact|howto|decision | <slug> | <title> | <one or two sentences>` lines. At closeout (`MEMORY_PROMOTE=ask`) the orchestrator shows the `memory.sh candidates <slug>` list, the user picks, and `memory.sh promote <slug> <n...|all>` adds them. Nothing is written to lasting memory without user approval (`auto` deliberately removes this). Text that looks like a secret is rejected; when `MEMORY_INDEX_MAX` is reached no new entry is added, clean up first with `memory.sh stale`.

**Commands.** `memory.sh status|init|add|index|search|stale|autoload|candidates|promote` (script details in section 9). `doctor` reports the memory's state and stale entries. Details and orchestrator steps: `skills/spec-driven-dev/references/memory.md`.

**Git.** Since memory is inside `.sdkit/`, by default it is in git and shared by the team (`MEMORY_VCS=commit`). If you want it personal, `MEMORY_VCS=ignore` (`init --memory-vcs ignore` writes the line to `.sdkit/.gitignore`) or set `MEMORY_DIR` outside `.sdkit/`. Changing it later is fine.

Limit: memory is not a security boundary; the secret scan is a simple pattern check.
