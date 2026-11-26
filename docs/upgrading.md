# Upgrading projects

The kit lives in three places, and each is updated separately.

| Part | Where | How it is updated |
|---|---|---|
| **The `sdkit` binary** | Your machine (on `PATH`) | macOS/Linux: `brew upgrade sdkit`. Windows: `scoop update sdkit`, or unpack the release zip over the old one. |
| **Plugin side** (skills, roles, hook wiring) | Claude Code's plugin cache | The version is bumped in the kit repo and reaches the marketplace source; refresh it with `/plugin` |
| **Project side** (`<project-dir>`: `project.md`, `sdkit.env`, `rules/`, ...) | The project's own repo | `sdkit upgrade` in each repo: adds new files, does not touch your files |

## Steps (2.0 and later)

1. **Update the binary:** `brew upgrade sdkit` (macOS, Linux), `scoop update sdkit` (Windows), or download the zip of the release and replace `sdkit.exe`. `sdkit version` prints the version.
2. **Refresh the plugin in Claude Code:** `/plugin`, update the `spec-driven-kit` marketplace, then the plugin; restart the session. Other hosts have no plugin; step 3 is enough.
3. **Upgrade each repo:** `cd` into it and run
   ```bash
   sdkit upgrade
   ```
   It finds the host, mode and stack by itself, adds new files (e.g. a new rule), adds missing lines to `.gitignore`, rewrites the wiring (see "2.0.0" below) and ends with `sdkit doctor`. Several repos: run it once in each.
4. Read "2.0.0" and the later "Manual steps per version" sections, review with `git diff`, commit.

To see whether you are up to date: `<project-dir>/.scaffold-version` is the kit version the repo was last upgraded to; the plugin version is shown in the `/plugin` menu.

There is no `<kit>/bin/upgrade.sh` any more: the kit is one binary and a checkout of it is not needed.

## 3.0.1 -> 3.0.2: a management page in the VS Code extension

No manual step. The extension's middle page is now a place to work from, not only to watch: the specs as cards, a spec's page with its flow, the actions its stage allows and its files, and the run with a stepper, a status card, and a second tab with the agent's whole conversation (reasoning, every tool call and its output, folded). A run can be stopped and continued (or restarted fresh) from the page. "Spec'i güncelle" asks what to change (or takes the edited files / the PR comments when left empty), and works before the PR as well as after it; before the spec goes to the Tech Lead, `generate-specs` now asks once whether to send it, edit it first or have the agent change it. The design question is its own, visible last step (`Step n/10`), and "Tasarım üret" is a button on a spec. `sdkit ext run` takes `--note <text>`. Use this `sdkit` with this extension (`brew upgrade sdkit`). Also in: `tasks.md` split by role and Jira tasks drafted from it, and `business-requirements.md` ([guide.md](guide.md)).

## 3.0.0 -> 3.0.1: one pull request for spec and design

No manual step. `generate-design` run right after `generate-specs` now puts `designs/<id>/` on the spec's own branch, so the spec's pull request carries both and the Tech Lead reviews one PR; made alone or after the spec is merged it still opens `design/<id>` with its own PR. In the VS Code extension the run page shows what the agent is doing and for how long between its messages, and a spec's Dosyalar can be opened from the Specs list and in the spec's own folder (see [design-vscode.md](design-vscode.md)); `sdkit spec branch` says where a spec's folder is when its branch is open in another one.

## 2.3.1 -> 3.0.0: the VS Code extension

No manual step. New: the **Spec-Driven Kit** extension for VS Code (`editors/vscode`, id `sdkit.sdkit`; [design-vscode.md](design-vscode.md)) does what the `sdkit ui` panel does with native parts instead of a web page: a Readiness view and a welcome walkthrough that check what is set up (agent, OpenSpec, Jira, Bitbucket) and fix it with one button, the Connect form, the specs list by who acts next, new pre-spec, a run shown as a live page with the agent's questions as pick lists, editing a spec in the editor and sending it, and a copy kept current with the server by fast-forward only (no git commands for the person). It needs this version of `sdkit` (`brew upgrade sdkit` / `scoop update sdkit`): the extension talks to the new `sdkit ext` command and says so when the installed `sdkit` does not have it. Install the `.vsix` from the release page. Also new since 2.3.1 (2.4.0 was never tagged): `generate-design`, a BPMN process flow for the designer.

Things to know: running a spec with Codex is not built yet (setup and checks are); the extension sets a project up with `sdkit init --mode copy`, so the skills are copied into the repo (git-ignored) instead of coming from the Claude Code plugin; `sdkit ext` reads and writes only what the panel did and is not a stable interface for other tools.

## 2.3.0 -> 2.3.1: the panel grows up

No manual step. `sdkit ui` is much more than the three screens of 2.3.0: a sidebar layout in a dark console look; a page per spec with a six-stage flow bar, what was done, what can be done now, and its files in a browser editor (hand edits, the pre-spec included); starting a change on an approved spec and continuing after hand edits; the tasks screen with the plan gate (Jira parent checked in Jira, the version listed from `main`); update and merge entries; Reports (tokens and estimated cost per session and per spec); "continue" resumes the earlier host session; several specs run at once, each in its own git worktree (`../<repo>-wt/spec/<id>`, up to 3 runs; see [design-ui.md](design-ui.md)); and questions that used to go missing (an apostrophe breaking the command, the host's two-minute command limit, a question with no owner) now reach the page.

New in the kit: `SDKIT_TASK=<id>` in a session's environment files its token usage under that task, so `sdkit report task <id>` is one spec's report across all its sessions (the panel sets it to the spec id; unset, nothing changes). Things to know: the panel's sessions run the panel's own `sdkit`; a spec worktree keeps its copies of the host skills until it is removed (`Çalışma alanını temizle` on an approved spec) and made again; run one panel per repo.

## 2.2.0 -> 2.3.0: a local panel for non-technical roles

No manual step. `sdkit ui` starts a local web panel in the repo it is run from: Connect (Jira and Bitbucket settings, written to `sdkit.local.env` and checked on save), Health (`sdkit doctor` in plain words), and Start (new spec from a pasted pre-spec, the list of specs with their state, a `generate-specs` run with its questions and review findings as cards). It drives a headless Claude Code session on the analyst's machine and needs `sdkit` on `PATH`; see [design-ui.md](design-ui.md). Also new: `sdkit scan secrets`, `sdkit pr` accepts SSH origins for Bitbucket, and `sdkit spec publish` lets `git push` ask for credentials on the terminal.

## 2.1.2 -> 2.2.0: tasks split by role

No manual step. A spec made with `generate-specs` now carries `roles.json` (the roles the analyst picked) and a `## Roles` section in `design.md`; `generate-tasks` splits each task into one subtask per role (`area`), the task itself becoming a group created as `JIRA_TASK_TYPE` (default `Task`, added to `sdkit.env` by `sdkit upgrade`) under the parent, its role subtasks under it. Check that your Jira project allows a Sub-task under that issue type. Specs and tasks made before have no `roles.json` and work as they did. `sdkit preflight tasks` only warns when the Jira parent cannot be fetched or has no `sdkit-task` block.

## 2.1.1 -> 2.1.2: task `scope` is optional

No manual step. `generate-tasks` no longer asks the analyst for paths and writes no `scope`; the developer finds the files in the repo at `spec-driven-dev`. The task contract accepts a task without `scope` (one that has it still works, and its `externalId` is unchanged). A new task without `scope` is keyed on its acceptance criteria (and `slug`) alone.

## 2.1.0 -> 2.1.1: `spec promote` opens the PR

No manual step. `sdkit spec promote <id>` now commits the approval, pushes the branch and opens the promote PR itself (it checks that the PR host is ready first, and rolls the commit back when the push fails). It used to stop after the local commit.

## 2.0.0 -> 2.1.0: fewer review rounds, smaller task plans

No manual step; `sdkit upgrade` appends the new settings to `sdkit.env`. A repo whose `sdkit.env` does not set them takes the shipped defaults, and three of those are **on**:

- `REVIEW_BEGIN_IDEMPOTENT=1`: `sdkit review begin` on unchanged content uses no round. Set `0` for the old counting.
- `REVIEW_REQUIRE_LINT=1`: `begin` refuses while `sdkit review lint` has errors. Without `LINT_*` settings only the AC checks run (duplicate, undefined, gapped ids, `tasks.md` coverage); set `LINT_REF_PREFIXES`, `LINT_GATE_PREFIX`, `LINT_MARKER_WORDS`, `LINT_CLOSED_WORDS`, `LINT_WITHDRAWN_WORDS` to name your own conventions. Set `0` to turn the gate off.
- `SPEC_REVIEW_MAX_NEW_ACS=5`: `begin` warns (never refuses) when a round added more AC ids than that. `0` is off.

New: `sdkit review lint|status|changed|settle|settled|raise-cap`, `plan --round`, `record --set cheap|full --roles`, `sdkit preflight`, `sdkit spec next`, `sdkit tasks plan-check|regroup`, `acs --gates`, `ids --list`, `sdkit jira supersede`, `sdkit prespec gaps` and the `prespec-gaps` role (12 role files per host now). `tasks acs` and `trace` skip ACs the spec marks `(withdrawn)` (`--include-withdrawn` keeps them). `sdkit spec publish` reads `BITBUCKET_TOKEN`/`BITBUCKET_EMAIL` from `sdkit.local.env`. In `SDD_MANAGED=on` repos the task is no longer re-planned or re-proposed: `sdd start` seeds the Definition of Done from the approved spec's scenarios. A cheap-set review PASS never lets `spec publish` through.

## 2.0.0: one Go binary, no bash, Windows support

2.0.0 replaces every bash script, hook and git hook with the `sdkit` binary (`sdkit hook <event>`, `sdkit sdd ...`, `sdkit run-role`, ...). The files, the formats and the verifier's `DOD / FINDINGS / VERIFY / VERDICT` block are unchanged. Windows (amd64, arm64) is supported next to macOS and Linux.

### What to do

| Step | Where | Why |
|---|---|---|
| Install or update `sdkit` and keep it on `PATH` | each machine | hooks, git hooks and CI call `sdkit`, not a path |
| `sdkit upgrade` | each repo | removes the 1.x copies, rewrites the wiring |
| `git config core.hooksPath .githooks` | each clone | the shims are committed, the setting is per clone |
| Refresh the plugin with `/plugin` | Claude Code | `hooks.json` now calls `sdkit hook` |
| Re-init or copy the CI job from `templates/ci/` | each repo with the gate | pinned version and checksum, see below |
| Re-verify tasks that were open before the upgrade | open tasks | see "Fingerprint" |

### `spec-driven-dev` no longer uses OpenSpec

The skill writes no spec and calls no `openspec-*` skill: the spec comes from `generate-specs` (analyst repo, approved through the PR) or, standalone, is the approved `plan.md`. Standalone, the orchestrator now writes `proposal.md`, `tasks.md` and `design.md` from the plan into `<project-dir>/work/<slug>/` instead of `openspec/changes/<change>/`; pass that `proposal.md` to `sdkit sdd start --proposal`. Closeout no longer runs `openspec-sync-specs` / `openspec-archive-change`.

Only an analyst repo needs the `openspec` CLI and `openspec/` now. `sdkit init` and `sdkit doctor` set up and check them for `SDKIT_ENV=analyst` only, and `check-tools` asks for the CLI only when `openspec/` exists. In a developer or standalone repo an existing `openspec/` and the `openspec-*` skills are harmless; delete them if you do not use them. Nothing is removed for you.

### What `sdkit upgrade` removes, rewrites and keeps

| Action | Files |
|---|---|
| **Removes** (only when unedited, i.e. identical to the 1.x copy it installed) | `.sdkit/scripts/`, `.sdkit/hooks/`, `.sdkit/adapters.d/`, `.claude/hooks/` |
| **Rewrites** | the kit's own hook entries in `.claude/settings.local.json` / `settings.json`, Cursor `.cursor/hooks.json` and Gemini CLI `.gemini/settings.json`: an old 1.x entry (`.../hooks/<name>.sh`, `adapt.sh`) is replaced by `sdkit hook <event>`; your own entries stay. The managed copies (the `.githooks/` shims, the OpenCode guard plugin) are updated by the sync step when you have not edited them; an edited one is reported as a CONFLICT and kept (`sdkit sync --force` takes the kit's) |
| **Codex** | has no hook wiring (`.codex/config.toml` only holds the role definitions); its backstop is the git hooks, so set `core.hooksPath` below |
| **Keeps and reports** | a retired copy you edited: it is listed as `kept` so you can port the change, then delete it yourself |
| **Edits settings files** | `sdkit init` (run by upgrade) appends settings that are missing from `sdkit.env` and `sdkit.local.env` and never overwrites a value. For a repo last upgraded before 1.3.2, upgrade also turns an empty `TELEMETRY=` into `TELEMETRY=1` and `ROUTING=off` into `ROUTING=on` in both files, once |
| **Never touches** | `project.md`, `rules/`, `settings.json` (the project's own files) |

Upgrade does not scan for old wiring. It prints `removed` / `kept` for the retired files and ends with `sdkit doctor`, which checks that the Claude settings are valid JSON and enable the plugin (or, in copy mode, that the copied hooks are executable and wired), that the git hooks are active (`core.hooksPath`), and that CI runs the gate. A leftover 1.x hook entry you wrote yourself is not reported: search your settings for `.sh`.

### Git hooks path

The shims in `.githooks/` are committed; the path is a per-clone git setting. Every developer runs once per clone:

```bash
git config core.hooksPath .githooks
```

`sdkit install` is dropped (D3): it registered the kit's home so a git hook could find the scripts. The hook now runs `sdkit` from `PATH`, and `sdkit where` prints the data directory when you need it.

### CI template change

The shipped CI job no longer vendors scripts from the base branch. It downloads a **pinned** `sdkit` release and checks its **checksum** before running `sdkit sdd ci-check`. The pinned version is read from the **base branch's** committed file, so a pull request cannot change the gate it is judged by. Re-run `sdkit init --ci <host>` or copy the job from `templates/ci/`, and set the pin to the version you installed. Keep CODEOWNERS on `.sdkit/` and the CI file.

### jq is not needed

The kit no longer needs `jq`; it stays optional for your own `VERIFY_CMD`.

### Pre-1.0 layouts (D2)

`bin/migrate.sh` is gone. A repo on `.agentkit`, `.claude` or `.codex` with `project.env` must first run the **last 1.x** `<kit-1.x>/bin/upgrade.sh --migrate` (it moves the files to `.sdkit/`, `project.env` to `sdkit.env`), commit, and only then run `sdkit upgrade` with 2.0. `sdkit` 2.0 stops on a pre-1.0 layout and says so.

### Windows

Hooks exit only 0 or 2 and guards normalise backslashes, so Claude Code works with or without Git Bash. `VERIFY_CMD` and the other command settings run through `sh` when Git for Windows is present, else `cmd /C`; PowerShell and cmd are supported, write the command for the shell you have. **Caveat per host:** the Windows hook wiring for Codex, Gemini CLI and OpenCode is unverified until the first Windows CI run; Report what you see.

### Behaviour changes

| Area | Change |
|---|---|
| Settings files | `$NAME` expands only from settings read earlier; process variables such as `$HOME` no longer expand. |
| State lock | A lock wait gives up after 30 s with an error; 1.x waited forever. |
| Verify policies | `.sh` policies in `verify.d/` run through `sh` without the executable bit, so `chmod -x` no longer disables one: rename it to start with `_`. Passing steps no longer echo their output. |
| Fingerprint, `audit.jsonl` | `<project-dir>/audit.jsonl` is no longer part of the diff fingerprint, so a Jira or litellm call no longer makes evidence stale (it did in 1.x). |
| Fingerprint, sort order | Same algorithm (D11), but file names sort by byte (C locale). 1.x used the locale's `sort`: for mixed-case paths under a non-C locale the fingerprint differs once, so re-verify an open task after the upgrade. |
| Usage | Prices resolve by model id from `pricing.json` only; provider- and date-windowed rates and the flat v1 table are gone. `usage live pull` (Codex rollout) is not ported. Invalid JSON lines are skipped instead of failing the report. |
| Hook output | The Claude Code hook JSON is compact, not pretty-printed. |
| Managed mode | `SDD_JIRA_CMD` is gone; Jira calls use the built-in client (`JIRA_BASE_URL` can point at a bridge). |
| Guards | `guard-phase` and `guard-pr` do nothing in a repo without `.sdkit/sdkit.env`; 1.x denied there. |

### Kept on purpose, fixed after 2.0

- `guard-readonly` denies `sed -n`, strips only one `env`/`sudo` prefix; `guard-secrets` matches the raw path. `advance red` only needs a non-zero exit.
- **Known bug (also in 1.x):** `sdkit upgrade` re-runs `init`, which records the hash of a locally edited managed copy, so the next `sdkit sync` overwrites that edit. Until it is fixed, commit or copy aside a local edit of a managed file before `upgrade`.

### Cut from 2.0

- `scripts/test-select.sh` and `tests/test-map.conf`: `go test ./...` runs the whole suite.
- The `bench/` harness (costbase, tbench, history) is kept as is under `attic/bench/`, unmaintained and out of the build.

The "2.0.0 (bash era notes)" section below was written during the bash era and describes the settings parser, risk floor and gate hardening that shipped in 2.0.0; its script names (`scripts/env.sh`, `sdd.sh`, ...) are now `sdkit` subcommands.

## Jira and pull-request defaults (1.8.0)

For the `analyst` and `developer` envs, `init` and `upgrade` now set what a Jira + Bitbucket (or GitHub/GitLab) setup needs, and `sdkit doctor` ends with a **setup checklist** that names what is still empty, most important first:

1. `JIRA_BASE_URL`, `JIRA_PROJECT` (shared `sdkit.env`; added empty, you fill them in)
2. `JIRA_USER`, then the token `JIRA_API_TOKEN` (personal `sdkit.local.env`, git-ignored, or exported in your shell)
3. `JIRA_EGRESS=allow` (set for you in `sdkit.local.env`; remove it to turn the network off)
4. The PR host: for Bitbucket `BITBUCKET_TOKEN` (an `ATCTT...` access token is sent as Bearer; an Atlassian API token also needs `BITBUCKET_EMAIL`)

Changed by the upgrade, once and only from the old default: `TRACKER=none` becomes `TRACKER=jira`. Added if missing: `JIRA_SUBTASK_TYPE=Sub-task`, `JIRA_API_VERSION=3` (Jira Cloud; descriptions go out as Atlassian Document Format; use 2 for Data Center). Nothing you set is overwritten. When every value is present, doctor also checks the Jira credentials against the site and the Bitbucket token against the API.

## Manual steps per version

### 0.3 → 0.4
`upgrade.sh` does the following by itself: adds new files (new scripts and hooks, the `verifier-deep` role file, new stack scripts), adds missing lines to `.gitignore`, updates the managed copies with `sync.sh` (copy mode and non-Claude hosts). What is left to you:

- **Claude projects in copy mode:** merge the new hooks into your own `.claude/settings.json` (it is a project file and is not overwritten; example: `templates/settings.copy.json` in the kit). `guard-readonly`: `PreToolUse`, matcher `Bash|Edit|Write|NotebookEdit`. `usage-log`: `Stop` and `SubagentStop`. In plugin mode these come with the plugin.
- **`.verify-cache/`:** verify now caches a green result for the same tree. `.verify-cache/` is added to `<project-dir>/.gitignore` (`upgrade.sh` adds the lines missing from the template); if not, add it by hand.
- **New `project.env` keys are optional** (`USAGE_LOG`, `RUN_ROLE_HOST`, `VERIFIER_HOST`, `RUN_ROLE_MODEL_*`, `NODE_PM`, `VERIFY_BUILD`, `JAVA_BUILD_TOOL`, `EXTRA_REVIEW_SKILLS`). Empty = off. The file is yours and is not overwritten; see `templates/project.env` for descriptions.
- **DoD line format:** `check-plan-parity.sh` checks plan, `proposal.md` and `tasks.md` parity with a script. Write DoD items in the form `D<n>: text | Verified by: type`; in old free-form items the script finds no items (exit 2).
- **At `high` risk** the verifier is now `verifier-deep` (strong tier, generated on the kit side); no extra setting needed. To have another provider verify, set `VERIFIER_HOST` (`scripts/run-role.sh`).
- **Stack scripts:** `verify.sh` is now a thin entry point; the logic is in `steps.sh` (stack) and `scripts/verify-core.sh` (shared). All are managed files, `sync.sh` updates them. If you customized a copied `verify.sh`, `sync.sh` shows a CONFLICT: move the customization into a `verify.d/` policy or `VERIFY_CMD` and take the new file.
- **Usage logging is off:** for the token ledger write `USAGE_LOG=1` in `project.env`; report with `scripts/usage.sh report`.
- **New behaviour:** task state is kept in `work/<slug>/state.json` (resuming, single automatic retry); verifier output is validated with `parse-verdict.sh`; in parallel tasks the `writes:` scope is checked with `check-writes.sh`; `WORKTREE:` is added to the handoff. The read-only restriction on roles is now enforced on every host.
- **Kit maintainers:** run `bin/build-adapters.sh --check` and `tests/smoke.test.sh`; not needed for projects.
- **If you want to add a new host:** `<kit>/bin/init.sh --host <host> /path/to/project` (e.g. `opencode`, `cursor`, `gemini`); the project dir name does not change (the existing one is kept).

### 0.2.x → 0.3.0
`upgrade.sh` does the following by itself: adds `rules/test-first.md` and `rules/token-economy.md`, adds `work/` to `.gitignore`. What is left to you:

- **The `CLAUDE.md` map** (`.claude/CLAUDE.md`): it is a project file and is not overwritten. For the current text describing the new roles and the plan gate, look at `templates/CLAUDE.md` and merge as you like. Not mandatory; the skills carry their own flow.
- **The rubric in `project.md`** stays mandatory; there is no new field. Fill in the test layout section: the plan gate looks there for "Verified by".
- **Behaviour changes:** `spec-driven-dev` now questions you in detail at the plan gate before `propose`; the `analyst` role reviews the task; at `medium`/`high` DoD items must carry "Verified by". Your existing open `openspec` changes are not affected.
- **New roles** (`analyst`, `scout`, `engineer`, `developer`, `devsecops`) come with the plugin; no extra setting needed. Model tiers are defined in `core/tiers.env` (on the kit side).
- **The project dir name** stays `.claude` in old projects; the kit finds it by name. You do not have to move it.
- **If you want to switch to Codex:** `<kit>/bin/init.sh --host claude,codex /path/to/project` adds the new files (`AGENTS.md`, `.agents/`, `.codex/`, `.githooks/`); the project dir stays `.claude` (the existing one is kept). In each clone, `git config core.hooksPath .githooks`.

## Shared files (AGENTS.md, CLAUDE.md, settings.json, hooks.json, config.toml)

From this version the kit writes only its own part of these files (a `spec-driven-kit:begin/end` block in text files, only kit-owned keys and entries in JSON) and `sync.sh`/`upgrade.sh` refresh just that part. The first `upgrade.sh` on an existing repo appends the block to an unmarked `AGENTS.md`/`CLAUDE.md`; if an older kit generated text there, delete that text once. New: `<project-dir>/roles.d/<role>.md` (project addendum for a role), `OPENCODE_SHELL_KEY` in `project.env`.

## Server-side gate, machine install and drift check (0.4.0, phase gate)

- Run `<kit>/bin/install.sh` once per machine so the git hooks find the kit in repos that carry no copy of the scripts.
- `init.sh` now also copies `sdd.sh` and `resolve-base.sh` into `<project-dir>/scripts/` in every mode (CI runs them). `upgrade.sh` adds them and keeps them in sync.
- Add the CI gate with `init.sh --ci bitbucket|github|gitlab` (merge it into an existing pipeline file by hand), mark the check required, and protect `<project-dir>/attestations/` with code review.
- Tasks that finish `verified` now write `<project-dir>/attestations/<task>.json`; commit it with the change.
- `sync.sh --check` fails on drift between the managed copies and the kit; `doctor.sh` reports drift, the CI gate and the machine registration.

## Memory, token budgets and a hook fix (0.5.0)

- **Everything new is off by default.** Add the keys you want to `project.env` (existing files are never overwritten; copy them from `templates/project.env`): `MEMORY*` (project memory), `TOKEN_BUDGET_TASK`, `TOKEN_BUDGET_WARN_PCT`, `MAX_SPAWNS`, `SUBAGENT_RESULT_MAX_LINES`. `upgrade.sh` adds the new scripts (`memory.sh`, `lookup-cache.sh`) and hooks (`guard-budget.sh`, `result-size.sh`) and changes nothing else.
- **Project memory is opt-in:** `sdkit init --memory [--memory-vcs commit|ignore]` creates `<project-dir>/knowledge/INDEX.md`, sets `MEMORY=1` in `project.env` and, for `ignore`, adds the directory to `<project-dir>/.gitignore`. Use `MEMORY_VCS` to say whether the team shares the entries.
- **Fix, worth a look:** `hooks/hooks.json` (and `templates/settings.copy.json`) declared `SubagentStop` twice, so only `record-verdict` ever ran and per-subagent token usage was never logged on Claude Code. It is one list now. Copy-mode projects: `upgrade.sh` merges the missing entries into `.claude/settings.json`; check that `SubagentStop` there lists `record-verdict.sh`, `usage-log.sh` and `result-size.sh`, and that `PreToolUse` has the `Agent|Task` entry for `guard-budget.sh`.
- Roles now keep answers to 15 lines plus their block and may be handed an `OUT:` path; run `sdkit sync` to refresh the role files.

## 1.0.0: one shared `.sdkit/` directory and a personal `sdkit.env`

What changes for a repo set up with 0.x (everything keeps working until you migrate):

- **New layout.** The project directory is `.sdkit/` for every host. It is committed and identical for everyone, except `sdkit.env` (personal settings: limits, memory, hosts), `work/` and generated files, which `.sdkit/.gitignore` keeps out. `project.env` is now `sdkit.env`; the old file name is still read.
- **Migrate when you are ready:** `sdkit upgrade --migrate` shows a dry run; add `--apply` to do it (backup first in `.git/sdkit-migrate-*.tgz`). It `git mv`s the kit-owned files (`project.md`, `rules/`, `known-pitfalls.md`, `adr/`, `verify.d/`, `roles.d/`, `attestations/`, `knowledge/` -> `memory/`), takes `sdkit.env` out of git (it stays on disk), removes the kit's generated copies from the old directory and the kit's plugin/hook keys from `.claude/settings.json`, then rebuilds the rest. Your own skills, commands, agents and `.claude/memory/` are not touched. Commit the result; teammates run `sdkit init` once on their machine.
- **Host files are per machine now.** On Claude the kit writes `.claude/settings.local.json` instead of `settings.json`; roles, hooks, `.agents/`, `.githooks/` are generated and hidden in `.git/info/exclude`. Only `AGENTS.md` and the kit block in `.claude/CLAUDE.md` are meant to be committed.
- **Defaults arrive by themselves.** `sdkit init` and `sdkit upgrade` append every setting that is new in the template to your `sdkit.env` / `project.env` with its default and comment; your lines and values are never changed. That includes `MEMORY=1` and `USAGE_LOG=1` (on by default from 1.0): set them empty to turn them off. The limits (`TOKEN_BUDGET_TASK`, `MAX_SPAWNS`, `SUBAGENT_RESULT_MAX_LINES`) stay empty.
- **Memory moved:** the directory is `memory/` (was `knowledge/` in 0.5) and is shared through git; `--memory-vcs ignore` keeps it personal.
- **CI gate** (`init --ci`, `attestations/`) stays optional. CI runs without your `sdkit.env`, so the defaults apply; set `SDD_FREE_GLOBS` and the like as CI environment variables if you need them there. `.sdkit/scripts/sdd.sh` and `resolve-base.sh` are committed for that reason.
- **Old kits** (0.5.x and earlier) do not find `.sdkit/sdkit.env`; upgrade the machine's kit first (`brew upgrade sdkit`). The legacy lookup (`.claude`, `.codex`, `.agentkit` with `project.env`) stays in 1.x and is planned to go in the next major release.

## 1.0.1: marketplace address with a Homebrew install

With 0.5.0 and 1.0.0, `sdkit init` run from a Homebrew install wrote the wrong plugin address (`https://github.com/Homebrew/brew`) into the Claude settings, because the kit's folder sits inside Homebrew's own git repository. From 1.0.1 a packaged kit uses the `repository` field of `.claude-plugin/plugin.json`. If you ran `init` or `upgrade` with an affected version, check `extraKnownMarketplaces` in `.claude/settings.json` / `settings.local.json`; `sdkit upgrade --migrate` removes the old entry and writes the right one, or pass `--marketplace-url` to `init`.

## 1.1.0: team settings in a shared `sdkit.env`, personal ones in `sdkit.local.env`

In 1.0.0 the settings file was personal and git-ignored, which left the team's own rules (release flow, protected paths and branches, production cluster, secret patterns, stack) on one developer's machine. From 1.1.0:

- **`.sdkit/sdkit.env` is committed** and holds the team's policy. **`.sdkit/sdkit.local.env` is personal** (git-ignored, read after `sdkit.env`, so it wins): token budget and limits, `USAGE_LOG`, `MAX_PARALLEL`, memory behaviour, hosts and models.
- **Nothing to do by hand.** `sdkit upgrade` (or `sdkit init`) on a 1.0.0 repo moves the personal keys with their values into `sdkit.local.env`, removes them (and the comments the kit wrote above them) from `sdkit.env`, flips `.sdkit/.gitignore` and adds `!sdkit.env` so a root `*.env` rule cannot hide the shared file. Then **commit `sdkit.env`**; teammates get the same policy and run `sdkit init` once for their personal file.
- `sdkit upgrade --migrate` from a pre-1.0 repo does the same split while moving `project.env` to `sdkit.env` (the file stays in git, renamed).
- A pre-1.0 layout keeps a single `project.env` with every setting; both templates' new settings are appended to it.

## 2.0.0 (bash era notes): settings files are parsed, not run; optional risk floor

This is a breaking change, so it shipped in 2.0.0. Settings files are parsed (below); everything else in this section needs no action.

### Settings files are parsed, not run

`sdkit.env`, `sdkit.local.env` and a pre-1.0 `project.env` used to be `source`d, so any line in them ran as shell at every hook, git hook and script. They are now read by `scripts/env.sh`, which only assigns values. Most repos need nothing.

**Still works, with the same meaning:** `KEY=value`, `KEY="value"`, `KEY='value'` (literal), `export KEY=value`, `: "${KEY:=default}"`, blank lines, `# comments` and a trailing ` # comment` after an unquoted value. A value may use `$NAME` or `${NAME}` (a setting read earlier, `sdkit.local.env` after `sdkit.env`). Commands in `VERIFY_CMD`, `DIFF_BASE_CMD` and the like are values: they are still run, when the kit calls them, not when it reads the file.

**Ignored (reported on stderr and by `sdkit doctor` as `file:line`, never with the content):** command substitution (`$(...)`, backticks), `;` `&&` `|` `>`, an unquoted space (`KEY=a b`: quote it), `${NAME:-x}` and other expansions, multi-line values, bare commands (`source other.env`, `cd`, `if ...`), and keys that change how the shell runs (`PATH`, `IFS`, `HOME`, `BASH_*`, `LD_*`, `DYLD_*`, `TMPDIR`, `KIT_DIR`, ...).

**What to do**
1. `sdkit upgrade`, not only `sdkit sync`: it adds the new managed `scripts/env.sh` next to the scripts you vendored (copy mode, non-Claude hosts, the CI gate). A script that finds no `env.sh` stops and says so; hooks stay silent and read no settings.
2. `sdkit doctor` lists every line the kit now ignores. Fix each one: write the value out, or move the logic into a script and point `VERIFY_CMD` (or another command setting) at it.
3. `STACK` empty or missing still means `go` (the documented default, unchanged for repos from before stacks existed). Every script now takes that default from one place, and `doctor` warns when `STACK` is not set. One behaviour changes: `sdd.sh advance verified` for `low` risk used to fall back to the `generic` stack in that case and now uses `go`, like the hooks and git hooks did.

### Risk floor (optional, off by default)
`RISK_FLOOR_GLOBS` in `sdkit.env` (empty after `sdkit upgrade` appends it, so nothing changes until you set it): `level:glob,level:glob`, e.g. `high:services/payments/*,medium:migrations/*.sql,medium:*/auth/*`. A task whose diff touches a matching file may not carry a lower risk label than the strictest matching level. The label stays the user's choice; the floor only stops it from being too low for what the diff really touches.
- Checked by `sdd.sh advance green` and `advance verified` (strict refuses, guided warns, off ignores), on the files that really changed (the same set the fingerprint covers, untracked files included), and by `sdd.sh ci-check`, which recomputes the floor itself, ignores the attestation's `floor` field, and rejects an attestation whose `risk` is below it. A raised `risk` written by hand into an attestation still needs `verdict: PASS`.
- CI reads every setting, `RISK_FLOOR_GLOBS` and `SDD_MODE` included, from the **base branch's** committed `sdkit.env`: a pull request that empties the floor or sets `SDD_MODE=off` is still held to the base. A file matching a floor entry needs an attestation even where `SDD_FREE_GLOBS` or the docs globs would free it.
- A malformed value fails closed: `sdd.sh start`, `ci-check` and `sdkit doctor` refuse it (`sdd.sh floor --validate` checks it). `sdd.sh floor` prints the floor of the current diff.
- Limits: it constrains the label, it does not choose it, and a reviewer must still protect `sdkit.env` and `attestations/` (CODEOWNERS); an attestation whose JSON is forged outright (a `high` label with `PASS`) is the documented attestation limit. A personal `sdkit.local.env` can relax the local check, never CI. Putting a path under a floor changes the diff fingerprint (it edits `sdkit.env`), so attestations made before that need to be re-verified. Existing attestations without the `floor` field are still accepted.

### Gate hardening (review findings)

**Action:** re-run `sdkit init --ci <host>` (or copy the new job from `templates/ci/`) so CI runs the base branch's gate, and re-verify any task that was verified before the upgrade (the fingerprint format changed). Add CODEOWNERS for `.sdkit/` and the CI file.
- **CI runs a trusted gate.** The shipped CI jobs take `sdd.sh`, `env.sh` and `resolve-base.sh` from the base branch, and `ci-check` reads **every** setting from the base branch's `sdkit.env` (a PR can add a stricter `RISK_FLOOR_GLOBS`, never loosen anything). `DIFF_BASE_CMD` is never run in CI, and `VERIFY_BASE` must come from the CI job's environment; a `VERIFY_BASE` in a settings file no longer counts there.
- **`ci-check` fails closed.** An unknown base (shallow clone, wrong name), a diff that cannot be listed, or a missing hash tool is a FAIL, not "nothing to attest". An attestation with an empty or broken fingerprint never matches.
- **Fingerprint.** Covers each path's mode as well as its content (a `chmod` counts), submodule commits, symlink targets and any file name (non-ASCII, quotes, spaces). It uses `shasum`, `sha256sum` or `openssl`, whichever exists. Existing attestations no longer match: re-verify open tasks.
- **GREEN re-runs the RED command.** `advance green` always runs the command stored at `red`; a different `--test-cmd` is refused (`red --test-cmd false` then `green --test-cmd true` no longer passes).
- **Paths are normalised** before the edit gate, `frozen-tests` and `guard-protected` match them: `docs/../src/x`, `./x` and `a//b` are judged as the file they name. Task slugs may only use letters, digits, `.`, `_` and `-`.
- **guard-pr** refuses the hook-only subcommands anywhere in a command that runs the kit (`S=_evidence; sdd.sh $S ...`), skipping the git hooks (`--no-verify`, `core.hooksPath`, `SDD_SKIP=`, `GUARD_SKIP_VERIFY=`), `git` with options before `push` (`git -C . push`, `/usr/bin/git push`, `(git push)`) and `gh api .../pulls`. Still a speed bump, not a boundary.
- The git pre-commit hook gates deletions too. `parse-verdict.sh` reads `*` and numbered bullets like `-` ones, and refuses `VERDICT: PASS` when a VERIFY command is red.

### Also in this release (no action needed)
- Claude Code: the `SubagentStop` hook now validates the verifier's block with `parse-verdict.sh` and records only a well-formed one; a malformed or contradictory block is reported to the orchestrator and records nothing. The skill no longer tells Claude to pass `--record` (the `guard-pr` hook denied it there); other hosts still do, and `guard-pr` allows it for them.
- Spawn counts, task state, the usage ledger and the SDD state are written under a lock, so parallel agents no longer lose updates. Budget and ledger follow the task the phase machine has open (`sdd.sh task`), falling back to the newest `work/*/state.json` as before.
- `lookup-cache.sh` answers are dropped when an untracked file is added or edited.
- New, off by default: `TELEMETRY=1` in `sdkit.local.env` records structured run events in `work/<slug>/events.jsonl` (`scripts/telemetry.sh summary`), and `bench/` holds a benchmark runner. Nothing changes while the setting is empty; `sdkit upgrade` adds the empty line. Details: [design-telemetry.md](design-telemetry.md).
- `sdkit_lock` no longer waits on a directory nobody can write to.
- New, off by default: `CONTRACTS=1` in `sdkit.env` (a team setting) turns on agent contracts. A handoff with a `CONTRACT:` line is validated and its answer's `HANDOFF-RESULT/1` line is checked by `scripts/contract.sh` (Claude Code hook `check-contract`, and `run-role.sh` on every host, which then also exits 4/5 on a broken or non-done contract). Handoffs without that line behave exactly as before; nothing to migrate. Copy-mode installs get the hook through `templates/settings.copy.json` after `sdkit sync`. Details and host limits: [design-contracts.md](design-contracts.md).
- New, opt-in per task: `sdd.sh start --profile small|standard|high-assurance` (default `standard`, i.e. unchanged). `high-assurance` requires an independent verifier PASS at every risk and agent contracts for writing and deciding roles; `small` is low risk only. `sdd.sh transitions` and `sdd.sh policy` print the rules. Behaviour changes that apply to everyone: a refused move now records a `reason` (telemetry), two simultaneous `advance`/`start` calls no longer both succeed, and `sdd.sh advance verified` is accepted again after a late edit (it used to be refused from `verified`, so the "re-verify" hint could not be followed). Tasks opened before this have no profile and read as `standard`. See docs/design-workflow.md.
- **High risk now enforces independent evidence (F04, [design-evidence.md](design-evidence.md)).** `sdd.sh advance verified|pr|done` on a `--risk high` task refuse unless verifier, reviewer and security-auditor each have a PASS from a *registered* agent run on the current diff. **Action:** on Claude Code nothing, the hooks (`guard-budget.sh` registers the spawn, `record-verdict.sh` records) already do it; on Codex, OpenCode, Cursor and Gemini run all three roles with `run-role.sh` (a verdict recorded by hand with `parse-verdict.sh --record` is kept but refused at `high`). `reviewer` and `security-auditor` now end with `SUMMARY` and `VERDICT: PASS|BLOCK` (`sdkit sync` regenerates the role files). `ci-check` requires the same three PASSes in a `high` attestation, so an attestation written before this release no longer satisfies a new `high` diff: verify it again. Low and medium risk are unchanged. Also: a refused or lost `advance` never leaves a partial change or an attestation behind, and `sdd.sh evidence` shows each role's evidence state.

## 1.2.0: routing and orchestration (opt-in), GitHub distribution

Nothing changes until you opt in. `ROUTING=off` stays the default, so `run-role.sh`, budgets and the benchmarks behave as in 1.1.0.

- **Move the install to GitHub** (the kit left Bitbucket): `brew untap <the old tap>` (uninstall `sdkit` first, by its full `<tap>/sdkit` name if two taps provide it), `brew tap wecii/sdkit https://github.com/wecii/sdkit.git`, `brew trust wecii/sdkit`, `brew install wecii/sdkit/sdkit`.
  Claude Code: `claude plugin marketplace remove spec-driven-kit`, `claude plugin marketplace add wecii/sdkit`, reinstall `spec-driven-kit@spec-driven-kit` in each project. `brew uninstall` may also remove `jq` and `node` if nothing else needs them: reinstall them.
- **Per repo:** `sdkit upgrade <repo>` appends the new `ROUTING` / `ROUTE_*` settings to `sdkit.env` (all optional, `ROUTING=off`) and the personal limits to `sdkit.local.env`. It never rewrites your values. Do it on a clean branch.
- **Exit codes of `run-role.sh` with `ROUTING=on`:** 7 = valid evidence already exists (nothing to run, do not retry), 8 = routing declined to run and there is no valid result (never a pass). Scripts that call `run-role.sh` must handle both.
- **Turning it on:** set `RUN_ROLE_HOST` (and `VERIFIER_HOST` for independent roles), then `ROUTING=on`; look at a decision first with `route.sh explain --role <role>`. Details and limits: [design-routing.md](design-routing.md).

## 1.3.6: context economy (capped command output, thin orchestrator, `usage.sh context`)

Why: the orchestrator session is most of a task's cost, and it comes from carrying content, not from producing it: each token that enters the session is re-read on every later turn.

- **New settings, added by `sdkit upgrade`:** `NOISY_CMD_PATTERNS` (`sdkit.env`, empty = off), `CAPPED_LINES=40` and `CONTEXT_HINT=1` (`sdkit.local.env`). Nothing blocks and nothing changes until you list commands in `NOISY_CMD_PATTERNS`, e.g. `"npm test*,go test*,pytest*"`; the new `guard-noisy` hook then asks to run them through `scripts/capped.sh`.
- **New:** `scripts/capped.sh -- <command>` (keeps the exit code, the failure lines and the tail; the full log goes to `work/<slug>/out/`), `usage.sh context` (which tool results a Claude Code session carried and what carrying them cost), a stderr note at the `proposed` and `green` boundaries of `sdd.sh advance` (`CONTEXT_HINT=1`).
- **Skill rules:** the orchestrator no longer reads files over ~150 lines whole, and writes only a one-file-plus-test `low` change itself; everything else goes to the roles (`references/delegation.md`, "Keep this session thin").
- **Copy-mode and Cursor/Gemini projects:** run `sdkit sync` so the new hook is registered; the Claude Code plugin and the OpenCode plugin pick it up with the update.

## 1.3.5: role tiers in `sdkit.env`, task sizes required with ROUTING=on

- **New settings, added by `sdkit upgrade` with the roles' own tiers:** `AGENT_ANALYST_TIER`, `AGENT_DEVELOPER_TIER`, `AGENT_DEVSECOPS_TIER`, `AGENT_ENGINEER_TIER`, `AGENT_REVIEWER_TIER`, `AGENT_SCOUT_TIER`, `AGENT_SECURITY_AUDITOR_TIER`, `AGENT_TEST_WRITER_TIER`, `AGENT_VERIFIER_TIER` (`light` / `standard` / `strong`). Change one to move that role; nothing changes until you do. Claude Code roles pick the model of the tier (`haiku` / `sonnet` / `opus`).
- **`ROUTE_REQUIRE_SIZE=1`:** with `ROUTING=on` (the default since 1.3.2) and `ROUTE_POLICY=tiered`, `sdd.sh advance proposed` now refuses a `tasks.md` that has a `role:` task without `size: small|medium|large` (the orchestrator used to be able to skip `references/model-routing.md`). Give the tasks a size, or set `ROUTE_REQUIRE_SIZE=0` to keep the old behaviour. The `engineer` role now writes `size:` with `role:`, `writes:` and `after:`.

## 1.3.4: test fixes only

No manual step, no change to the scripts. The first full run (`tests/fast.sh --all`) found four test problems, none in the kit: `install.test.sh` counted `claude` lines and did not expect the routing line that `ROUTING=on` (the default since 1.3.2) prints, `recover.test.sh` gave `advance green` a different command than the one `red` was bound to, `reservation.test.sh` signalled `run-role.sh` after a fixed 3 s instead of waiting until it had reserved, and `report.test.sh` timed the machine under load. All four are fixed.

## 1.3.3: slow tests out of the everyday run, publishability scan

No manual step. For people working on the kit: `tests/slow/` (the smoke tests `run.sh`, `sdd.test.sh`, `workflow.test.sh`, `reservation.test.sh`, `evidence`, `contract`, `route`, ...) no longer runs by default: `tests/fast.sh` and `scripts/test-select.sh run` leave it out and say how many suites they skipped; `--all` (or the T3 / milestone tier) runs them. `packaging/scan-publishable.sh --history` no longer reports the made-up keys of the redaction test as hard findings (they are listed in `packaging/scan-allow.txt`, with the reason). Projects that upgrade from 1.3.2 are not touched: the one-time move of `TELEMETRY` / `ROUTING` to their new defaults happens only when crossing 1.3.2.

## 1.3.2: measurement on by default, a price table, task-scoped token counts

- **New setups measure:** `TELEMETRY=1` (`sdkit.local.env`) and `ROUTING=on` (`sdkit.env`) are now the template defaults next to `USAGE_LOG=1` and `VALUE_REPORT=on`. `sdkit upgrade` still only appends settings that are missing and never rewrites your values, with **one exception, once**: an upgrade from a kit older than 1.3.2 changes exactly the old defaults, `TELEMETRY=` (empty) to `TELEMETRY=1` and `ROUTING=off` to `ROUTING=on`, and prints what it set. Any other value (`shadow`, `0`, ...) is left alone, and once the project is at 1.3.2 a later `off` is never touched again. To keep one off, set it back after that upgrade; `sdkit doctor` warns while one is off.
- **`pricing.json`:** `sdkit init` / `sdkit upgrade` copy a starting table (public AWS Bedrock list, global inference) when the project has none; an existing file is never touched. `sdkit doctor` reports a missing or stale table and an unset or unknown `REPORT_BASELINE_MODEL`; `sdkit doctor --update-pricing` refreshes a table the kit wrote. Set `REPORT_BASELINE_MODEL=<an id in pricing.json>` in `sdkit.env` to get routing savings.
- **Value Report accuracy:** the orchestrator's tokens are counted from the start of the open task (before, a session that served several tasks was charged to each task in full, and the same session appeared in several tasks' totals). Ledger lines written by older versions are not rewritten. Unmeasured subagent runs are filled in from their transcript when a report is built; the role of a subagent is read from its `.meta.json` when the hook payload has none. An open task shows its quality gate as `Pending`; long texts are cut at a word boundary.

## 1.3.2 (React Native): skill recommendations

No manual step. On `react-native` repos `init` now recommends the Expo, Vercel and Callstack skill sets (installed by you, never vendored), and `doctor` warns when `.agents/skills` or `.claude/skills` still holds `building-native-ui` or `expo-tailwind-setup`, which upstream removed. See [guide.md](guide.md), section Stacks.

## 1.3.2 (React Native): Expo checks

Only `react-native` repos are affected; nothing new runs until you enable it.

- **New `verify.d` example** `40-expo.sh.example`: `expo install --check` when a `package.json` changes (FAIL on SDK-misaligned versions, WARN when it cannot run), a prebuild reminder when `app.json` / `app.config.*` plugins or `ios` / `android` settings change, and a WARN on NativeWind transform/shadow/transition/ring classes inside a conditional `className`. To use it: `cp "$(sdkit where)/stacks/react-native/verify.d.example/40-expo.sh.example" .sdkit/verify.d/40-expo.sh && chmod +x .sdkit/verify.d/40-expo.sh`.
- **Lint without eslint:** if a package has no `lint` script and no local eslint but a local prettier, verify runs `prettier --check` on the changed files instead of skipping lint. A formatting difference is a failure; `prettier --write` fixes it.
- **Tools:** `doctor` and the `check-tools` hook show `xcrun` (macOS) / `adb` hints, as warnings only, when `ios/` / `android/` exist. `tools.sh` and `steps.sh` are managed copies: `sdkit upgrade` refreshes them (plugin mode uses the updated plugin).

## 1.3.2 (React Native): Expo rules and pitfalls

Only `react-native` repos are affected. Rules and `known-pitfalls.md` are project-owned, so `sdkit upgrade` does not add or change them in an existing repo.

- **New rule file** `stacks/react-native/rules/expo-idioms.md` (Expo Router headers, form sheets, edge-to-edge Android, Hermes `Intl`, NativeWind, `expo-image`, prebuild). To take it: `cp "$(sdkit where)/stacks/react-native/rules/expo-idioms.md" .sdkit/rules/`.
- **`rn-idioms.md` changed:** styling no longer assumes `StyleSheet.create` (utility classes such as NativeWind keep static `className` strings and put only dynamic values in `style`), Expo uses `process.env.EXPO_OS` for platform branches, and there are new styling, animation and screen-state rules. Compare with `diff .sdkit/rules/rn-idioms.md "$(sdkit where)/stacks/react-native/rules/rn-idioms.md"` and merge what you want.
- **Pitfalls seed:** new repos get `stacks/react-native/known-pitfalls.md` (FlashList v2 pagination, FlatList offsets, Android ScrollView offset, Yoga alignment, `setTimeout` navigation). Copy the entries you want into your own `.sdkit/known-pitfalls.md`.
- **`verify.d` example `10-forbidden-patterns`:** the inline-style warning fires only on a `style={{ }}` inside a list's `renderItem`. If you enabled the policy, copy the new version over yours.

## 1.3.2 (React Native): fewer false failures on Expo setups

No manual step is required.

- **Stack detection:** an Expo app with a prebuilt `android/` is now detected as `react-native`. If an earlier `init` gave such a repo another stack, set `STACK=react-native` in `sdkit.env`.
- **`known-pitfalls.md`:** the template no longer ships a Go entry; Go repos get it from `stacks/go/known-pitfalls.md`. An existing file is yours and is not touched: delete the `typed-nil interface` entry if your repo is not Go.
- **`doctor`:** third-party skills in `.agents/skills/` no longer trigger the non-Claude host checks, a tool installed in `node_modules/.bin` counts as installed, and the `project.md` check ignores the template's explanatory `` `TODO` `` line.

## 1.3.0: usage and cost accounting, Value Report, F08-F20 scripts, GitHub/GitLab PR hosts

Nothing changes until you opt in; every new setting is off or empty by default.

- **Per repo:** `sdkit upgrade <repo>` appends the new settings to `sdkit.env` / `sdkit.local.env` (`VALUE_REPORT`, `REPORT_BASELINE_MODEL`, `PARALLEL`, `ROUTE_COST_ENFORCE` and related limits) and installs the new runtime scripts. It never rewrites your values.
- **Value Report:** `VALUE_REPORT=on` (personal) prints a compact report when a task ends and saves it under `work/_reports/`; `sdkit report task|session|latest|history` reads it at any time. Read-only, no model call. See [design-report.md](design-report.md).
- **Pricing:** `pricing.json` may now be the versioned v2 format (model, provider, effective date); the old flat format still works. See [design-usage.md](design-usage.md).
- **`parse-verdict.sh`** now distinguishes `MALFORMED[format]` (asked again once) from `MALFORMED[semantic]`; a hand-written parser of its messages should look for both.
- **Docs are English** from this version on (`docs/`, `CONTRIBUTING.md`).
- **CI gates:** `init --ci` now writes templates that run the base branch's own gate, and `init --ci gitlab` installs a GitLab merge-request gate. Re-run `sdkit init --ci <host>` only if you want the new template; existing CI files are not overwritten.

## 1.4.0: a fast test suite that runs in a container

No manual step for projects. `recover.sh` now reads file times correctly on Linux (GNU `stat`), so `sdkit recover` works there too.
For people working on the kit: the whole suite takes about 15 s. `tests/slow/` is gone (the long versions are kept in `tests/old/` as a reference and never run); every area has a short test in `tests/`. `tests/fast.sh` runs inside a Debian container by default (`tests/docker/Dockerfile`), `tests/fast.sh --no-docker` runs on the machine, and `--all` no longer exists. The kit's jq programs need jq 1.8 or newer, and `redact.sh` needs an `awk` that supports `{n}` repetition (gawk, not mawk).

## 1.4.1: who logs a step, and its token usage

No manual step. With `USAGE_LINE=1` (personal setting) the step lines name the orchestrator and carry its and the task's running token usage (in, cache read, cache write, out, hit ratio); `USAGE_LINE=1` now also switches the usage ledger on, so `USAGE_LOG` is not needed for it. Subagent lines show cache read and write too. On Codex the orchestrator's share is read from its rollout file; hosts that give no token data show `not measured`.

## 1.5.0: analyst and developer environments

No manual step; nothing changes until you opt in. `SDKIT_ENV` defaults to `standalone` (the existing OpenSpec workflow, unchanged). `bin/init.sh --env analyst` prepares a `project-specs` repo (git-ignored `prespec/`, skills `generate-specs`, `update-specs`, `generate-tasks`); `--env developer` prepares a source repo for Jira subtask execution (`SDD_MANAGED=on`, approved specs as the `specs/` submodule, `sdd.sh start --ticket KEY`). New settings are appended to `sdkit.env` and are empty or off by default; the Jira keys and `JIRA_EGRESS` (personal) are commented out. Spec review uses the EGM plugin (`egm@egm`); live EGM, Jira and GitHub flows are not yet verified. See `docs/role-aware.md`. `bin/init.sh|doctor.sh|upgrade.sh` and `bin/sdkit` changes now select focused tests instead of the whole suite.

## 1.6.0: generate-specs outputs an OpenSpec change

Analyst repos only. `generate-specs` now drafts in `work/spec-draft/`, asks you the decisions the review finds (instead of listing findings), then outputs an OpenSpec change (`proposal.md`, `design.md`, `tasks.md`, `specs/`) into `specs/<id>/` through `openspec-propose`. The analyst env now installs OpenSpec: run `sdkit init --env analyst --install-openspec` (or `openspec init`) once if `openspec/` is missing. New setting `ANALYST_LANGUAGE` (default `tr`) is appended to `sdkit.env` by `sdkit upgrade`. The default `SPEC_REVIEW_MAX_ROUNDS` is now 4; an existing file keeps its own value (`2`), so raise it by hand. Specs already published under `specs/<id>/` keep their layout and are changed with `update-specs`.

## 1.6.1: permissions for the work directory

No manual step. `sdkit upgrade` adds Claude Code allow entries (when missing) so agents can run `spec.sh`, `review.sh`, `sdkit prespec` and create or move files under `<project-dir>/work/` and the OpenSpec change into `specs/` without a prompt. A `work` directory that is a symlink outside the repo still prompts: Claude Code always asks for writes outside the project.

## 1.6.2: the round cap walks findings one by one

No manual step. At the spec-review round cap, `generate-specs` now goes through the open findings with you one at a time (proposed edit, then apply / answer / accept / reject) instead of listing them. `review.sh begin <id> --final` opens one verification round outside the cap (once per review id), and `review.sh accept` records `JIRA_USER` as who accepted when `--who` is not given. `JIRA_USER` moved out of the shared `sdkit.env` template: set it in your own `sdkit.local.env` (your Jira account, e-mail on Jira Cloud). An existing `JIRA_USER` in `sdkit.env` keeps working, but belongs in `sdkit.local.env`.

## 1.7.0: PR host and Bitbucket token in sdkit.local.env

No manual step. `sdkit upgrade` appends `PR_HOST`, `BITBUCKET_EMAIL`, `BITBUCKET_TOKEN` and `PR_TOKEN_REPO` to your `sdkit.local.env` (empty, or `auto` for `PR_HOST`). If `open-pr.sh` fails with "no token", put your Bitbucket token in `BITBUCKET_TOKEN` there (git-ignored); never in the shared `sdkit.env`. A `PR_HOST` set in `sdkit.env` or the environment still wins.
