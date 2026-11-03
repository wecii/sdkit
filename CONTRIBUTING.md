# Contributing to the kit

This file is for people who change **the kit itself**. To use the kit in a project see [README.md](README.md) and
[docs/README.md](docs/README.md).

## Core rule: the kit stays generic

**Nothing project-specific is baked into** skills, agents, hooks or scripts: no branch names, cluster names, service names, team jargon or risk criteria.
These come from the project's `<project-dir>/sdkit.env` and `project.md`. If you find yourself saying "this is only true in our project" about a change, it belongs
not in the kit but in that project's project dir (`<project-dir>` = `.sdkit/`; `.claude`, `.codex` or `.agentkit` in pre-1.0 installs). (A fix was made for exactly this reason in the past: `fix: keep project-specific wording out of the generic hooks and agents`.)

Second rule: **do not overwrite project-side files.** `init.sh` never overwrites existing `project.*`, `rules/`, `settings.json` files, not even with `--force`;
`--force` is only for the managed files of copy mode.

## What goes where

| I want to add | Where | Also |
|---|---|---|
| Skill | `skills/<name>/SKILL.md` (frontmatter: `name`, `description`, `license`, `metadata`) | `description` must say "when to use it"; `docs/guide.md` §5 and the README tables |
| Role (agent) | `core/roles/<name>.md` (frontmatter: `name`, `description`, `kind`, `access`, `tier`, `independent`, optional `deep`), then `bin/build-adapters.sh` | **`agents/` and `adapters/<host>/` are generated, do not edit them by hand.** Keep access as narrow as possible (independent roles `read-only`); fix the output format; `core/roles/README.md` and `guide.md` §6 |
| Hook | `hooks/<name>.sh` + wiring in `hooks/hooks.json` | Use `jget`/`decide` from `hooks/lib.sh`; document the setting that turns it off (`sdkit.env`); the table in `guide.md` §7; the copy-mode wiring in `init`/`doctor` |
| `sdkit.env` setting | `templates/sdkit.env` if it is team policy, `templates/sdkit.local.env` if it is personal (limit, budget, host/model, memory behaviour); default lines are appended to existing files automatically by `init`/`upgrade`. If you make a key personal, `split_personal_env` moves it too | Pick a safe default (empty = feature off); `guide.md` §10 |
| Generic rule | `core/rules/` | Must be language-independent; `init.sh` copies it into the project |
| Flow step / detail | `skills/spec-driven-dev/SKILL.md` stays short; details go under `references/` | Token economy: a reference is read only at the relevant step; do not bloat `SKILL.md` |
| New host | The "Adding a new host" list below | `guide.md` §14, §16 |
| Tool-independent guard | `scripts/guard.sh` + `adapters/git/` | The same rule as the Claude hooks, at commit/push time |
| Language/stack | `stacks/<name>/` | The "Adding a new stack" list below, `guide.md` §14 |
| Project template | `templates/` | `init.sh` writes it, `doctor.sh` checks it; update both |
| Example `verify.d` policy | `stacks/<stack>/verify.d.example/*.sh.example` | The `FAIL:`/`WARN:` protocol |

## Rules for writing hooks

- Input is JSON on stdin; read it with `jq`. The result is a `permissionDecision` (`deny` / `ask`) JSON or, for Stop, a block.
- **Make off the default**: if the setting is empty, exit silently (`exit 0`). A hook without a setting makes noise in every project.
- Block only on purpose: outside the case you need to decide on, the exit code is 0; the hook's own error must not lock up the session.
- The deny/ask message must state the reason and the way out ("see `project.md`", "the active release branch is X").
- Hooks are safety nets, not a security boundary; write the escape routes into `guide.md` §13.
- These hooks are for Claude Code; Gemini and Cursor call the same ones through the `hooks/adapt.sh` wrapper, OpenCode through a plugin. Their counterpart everywhere is `scripts/guard.sh` (git hook): if you add a new guard, think about all of them together.
- Stop hooks must check `stop_hook_active` (so there is no infinite loop) and set a timeout in `hooks.json`.

## Verification (before submitting)

Smoke test first: `tests/smoke.test.sh` exercises the scripts (verdict, plan parity, write scope, state, usage), the hooks, `run-role.sh --dry-run` and `init` with fixtures (stating for each case whether it should pass or fail); if you changed a script or hook, add a case there. Then by hand:

```bash
tests/smoke.test.sh                                                        # smoke test
tests/sdd.test.sh && tests/shared.test.sh                          # phase machine, shared files
tests/memory.test.sh && tests/budget.test.sh                       # project memory, token budget, hook wiring
tests/sdkit-dir.test.sh                                            # .sdkit layout, appending missing settings, old layout, --migrate
tests/risk-floor.test.sh                                            # risk floor (RISK_FLOOR_GLOBS): label floor, CI bypass attempts
tests/hardening.test.sh                                            # F00.5: verdict validation, concurrent writes, settings files not executed, task resolution, cache, STACK
tests/workflow.test.sh                                             # F03: profiles, transition table, refusal reasons, contract policy, concurrency, telemetry
tests/report.test.sh                                               # Value Report: task/session report, savings arithmetic, double counting, one-shot generation, no LLM call
tests/roletier.test.sh                                           # AGENT_<ROLE>_TIER (helper, route.sh, run-role.sh, Agent hook, session start, doctor) and the task-size gate
tests/pricing.test.sh                                             # price table: refresh from the Bedrock list, status, init and doctor
tests/usage.test.sh                                               # F07: usage/cost accounting, price resolution, deduplication, coverage warnings
tests/efficiency.test.sh                                           # F08: verdict normalisation, format/semantic split, PASS without evidence, early DoD check
tests/context.test.sh                                              # F09: bounded output, ENVELOPE/1, error lines preserved
tests/selection.test.sh                                            # F10: changed file → test mapping, pipe failure, cache
tests/costbase.test.sh                                             # F11: fixed-data baseline and comparison guards
tests/adapter.test.sh                                              # F12: adapter contract, fake external adapter
tests/litellm.test.sh                                              # F13: OpenAI-compatible adapter (fake curl): policy, egress permission, secrets
tests/costroute.test.sh                                            # F14: hard cost policy, reservation, unknown
tests/dispatch.test.sh                                             # F15: parallel dispatch rules
tests/knowledge.test.sh                                            # F16: content-hashed notes
tests/trace.test.sh                                                # F17: trace (content-free)
tests/recover.test.sh                                              # F18: recovery, idempotent
tests/security.test.sh                                             # F19: redaction, audit chain, static policy
tests/gate-security.test.sh                                        # review findings: trusted CI gate, fail-closed fingerprint, RED/GREEN binding, path normalisation, guard-pr bypasses
tests/ci.test.sh                                                   # F20: cheap PR check, regression history
tests/evidence.test.sh                                             # F04: high-risk evidence (3 roles), trust/identity, staleness, forgery, concurrency, adapter claims
tests/contract.test.sh                                             # F02: agent contracts (validation, recording, hook, run-role, verifier independence, backward compatibility, contract benchmarks)
tests/route.test.sh                                               # F06: routing decisions, registry, scheduling, retry/escalation, budget, run-role integration (fake CLI; no model call)
tests/tbench.test.sh                                               # F05-A: task benchmark (task registry, isolation, hidden test separation, metric ingestion, seal, report, real-run gate; no model call)
tests/telemetry.test.sh                                            # F01: event schema, correlation, concurrency, failure isolation, benchmark (simulated; no real LLM run)
bin/build-adapters.sh --check                                       # are the roles and generated files in sync
bash -n hooks/*.sh bin/*.sh bin/emit/*.sh scripts/*.sh stacks/*/scripts/*.sh adapters/git/*  # syntax
jq . hooks/hooks.json .claude-plugin/*.json templates/settings.*.json >/dev/null
shellcheck hooks/*.sh bin/*.sh scripts/*.sh                         # if installed
```

Speed: a file in `tests/` must stay under 30 s. `tests/fast.sh` runs them in parallel, prints each file's time and flags one over the budget (`-b SEC`); you never need the whole suite while developing: `scripts/test-select.sh run` runs only the suites your change maps to (`tests/test-map.conf`), several at a time (`--jobs N` or `TEST_SELECT_JOBS`, default a third of the cores, `1` = one after another; results always print in map order), and reuses a green result for an identical tree. `tests/fast.sh` runs the whole suite inside a small Debian container (`tests/docker/Dockerfile`: bash, git, jq >= 1.8, gawk, python3), so tools are the same everywhere and no endpoint-security scanner slows each spawned process; `--no-docker` runs on this machine instead (`scripts/test-select.sh` always runs locally). The suite takes about 15 s in the container with `-j 4`. Keep a test to a few cases that share one scratch repo (source `tests/lib/common.sh`): every kit script call costs a process or more, so the number of calls is the budget. `tests/old/` holds the long pre-slimming versions as a reference; nothing runs them. `tests/prof.sh <file>` shows where one file spends its time, section by section. A file whose sections build their own repositories can still run them at the same time through `tests/lib/psections.sh` (see `tests/costroute.test.sh`; `PSEC_DEBUG=1` says why a section is chained); check that the totals match a sequential run (`PSEC_ONLY=x bash <file>`).

Then try it end to end in a throwaway repo:

```bash
tmp="$(mktemp -d)" && git -C "$tmp" init -q && cd "$tmp"
<kit>/bin/init.sh --stack go "$tmp"              # plugin mode (the stack cannot be detected in an empty repo, --stack is required)
<kit>/bin/doctor.sh "$tmp"                          # expected FAILs: only project.md with TODOs and (if there is no commit) BASE_BRANCH
<kit>/bin/init.sh --mode copy --stack go "$tmp2"    # a separate throwaway repo for copy mode
<kit>/bin/init.sh --host claude,codex --stack go "$tmp3"   # Codex files: AGENTS.md, .agents/, .codex/, .githooks/
<kit>/bin/init.sh --host opencode,cursor,gemini --stack go "$tmp4"   # .sdkit/, .opencode/, .cursor/, .gemini/
```

For the parallel tools, try `scripts/plan-waves.sh` with a sample `tasks.md` (try waves, an unknown id and a cycle) and `scripts/worktree.sh add|merge|clean` in a temporary repo;
for `scripts/guard.sh`, stage a `.env` / protected path / frozen test in a temporary repo and try `git commit` (it must refuse); a clean file must pass.

If you changed a hook, run it by hand with an input that triggers it and one that **does not**:

```bash
echo '{"tool_name":"Read","tool_input":{"file_path":".env"}}' | CLAUDE_PROJECT_DIR="$tmp" <kit>/hooks/guard-secrets.sh
```

A guard is not trusted until it has been seen to "fail and then pass": try both the case it must block and the case it must allow.

## Adding a new host

1. `bin/emit/<host>.sh`: `emit_<host>_begin` and `emit_<host>_role`, output to `adapters/<host>/`; wire it into `bin/build-adapters.sh`, run it, commit the generated files.
2. `core/hosts.env` (tool and permission names, read-only shell allow-list) and `core/tiers.env` (`<HOST>_MODEL_LIGHT|STANDARD|STRONG`; empty = the session's model).
3. `bin/init.sh` (`--host` values, project dir name, host files), `bin/doctor.sh` (host checks, CLI note), `bin/upgrade.sh` (host detection).
4. Guard wiring: if the host does not resemble the Claude hook JSON, add a case to `hooks/adapt.sh` or write a plugin like OpenCode's; otherwise only the git hooks (`adapters/git/`) remain.
5. A `case` for the host in `scripts/run-role.sh` (headless run flags) and a check with `--dry-run`.
6. The table in `skills/spec-driven-dev/references/hosts.md`, `README.md`, `docs/guide.md` §13, §14, §16 and the table in `core/roles/README.md`.
7. Cases in `tests/smoke.test.sh`: `run-role.sh --dry-run`, `init.sh --host <host>` output, the `adapt.sh` input if any. If you did not try it on a live install, mark it as not validated in the README "Limits" and in guide.md §13.

## Adding a new stack

1. The `stacks/<name>/` contract is in [stacks/README.md](stacks/README.md): `detect.sh`, `scripts/verify.sh` (thin entry point), `scripts/steps.sh` (`STACK_SOURCE_RE`, `stack_run`), `scripts/fmt.sh`, `scripts/tools.sh`, `permissions.txt`, `rules/`, `verify.d.example/`, optional `known-pitfalls.md` (seed for the project file).
2. The detection order in `bin/init.sh` (`STACKS` variable: go, spring-boot, react-native, jvm, nextjs, python; first match wins): `detect.sh` must not give false positives.
3. `hooks/check-tools.sh` reads the `required|` / `optional|` lines in `scripts/tools.sh`; a missing tool is a `warn`, not a `fail`.
4. `permissions.txt`: patterns to add to the Claude `settings.json` "allow" list (their narrowest form).
5. Shared logic stays in `scripts/verify-core.sh`; a stack only writes `stack_run`. Node-based stacks share `stacks/_node/scripts/node-lib.sh`.
6. `templates/sdkit.env` (if there is a new stack setting), `README.md`, `docs/guide.md` §14 and `docs/cheatsheet.md`; a fixture can be added to `tests/smoke.test.sh`.

## Versioning and release

1. Make the change. If you changed roles in `core/roles/`, run `bin/build-adapters.sh` and commit the generated files too. Update the related tables in `docs/guide.md` and the README (including part counts: number of skills/roles/hooks/scripts; currently 4 skills, 10 roles, 19 hooks, 33 scripts).
2. Bump the version in `.claude-plugin/plugin.json` **and** `.claude-plugin/marketplace.json` together (both must match), and in the version badge at the top of `README.md`.
   - patch: fix, docs
   - minor: new skill/agent/hook/setting (off by default)
   - major: a change that requires existing projects to update files in their project dir by hand
3. If the release needs anything done by hand, add an "X → Y" section to `docs/upgrading.md` (`upgrade.sh` adds new files itself; everything else is written there).
4. Push and get it onto the branch the marketplace watches (the default branch); projects do not see the new version until the version is bumped and it lands on that branch. Repos using the plugin update with `/plugin`; those in copy mode run `sync.sh`, so changing the
   path of managed files affects projects in copy mode.

## Commits and branches

[core/rules/git.md](core/rules/git.md) applies: `<type>(<scope>): <description>`, imperative mood, subject ≤ 72 characters, branch `<type>/<short-name>`.
In this repo the scope is the kit part (`hooks`, `skills`, `verify`, `init` ...); a doc change is `docs:`.

## Docs

- `README.md` is kept in English and short: what it is, install, links.
- `docs/` is in English. Details live in `guide.md`; `cheatsheet.md` and the README only summarize and link to the guide, do not duplicate information.
- If a number or table appears in several files (hook count, settings list), update all of them in the same change.
