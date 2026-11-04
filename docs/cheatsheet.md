# Quick reference

For details see [guide.md](guide.md).

## Daily use

```
/spec-driven-dev <ticket or description>    # new task (full name: /spec-driven-kit:spec-driven-dev)
/incident-to-rule                           # after a bug is fixed, add a lasting guard
/scaffold-init                              # new repo, once (by the person setting it up); host: claude, codex, opencode, cursor, gemini (several, comma-separated)
                                            # on Codex invoke it as: $spec-driven-dev
/scaffold-doctor                            # is the install sound?
```

## What the risk label does

| | low | medium | high |
|---|---|---|---|
| Explore + proposal + **DoD** | yes | yes | yes |
| Race/ordering scenario in `design.md` | | | **mandatory** |
| Test first (RED → GREEN) | yes | yes | yes (a separate agent writes and freezes the test) |
| Independent `verifier` | no | **mandatory** | **mandatory** + `code-review` + `security-review` |
| Claude opens the PR | yes | yes | yes |

The analyst proposes the label, **you confirm it**. Ticket priority does not set the label.

## Flow (short)

1. The **analyst** reviews the task; if something is missing it asks (at most 4 questions per round, the recommended default first)
2. Risk label confirmation → explore
3. **Plan gate**: scope, DoD (each item's "Verified by"), design, tasks/roles and risks are put to you in detailed questions. You can edit; changes propagate through the plan.
   Final approval: `Approve and propose` / `Edit a section` / `Stop here`
4. `propose` → test first → implementation by roles → independent verification → PR
5. You can say "update the plan" at any time; only the affected rounds are repeated

## Roles

`orchestrator` (main session) · `analyst` is anything missing? · `scout` cheap lookup · `engineer` design and test strategy · `developer` code · `test-writer` tests ·
`devsecops` pipeline/infrastructure · `reviewer` / `security-auditor` / `verifier` independent and read-only (`verifier-deep` at `high` risk, strong tier). The implementer never verifies.
Roles do not call each other; if a lookup is needed they write `NEEDS-LOOKUP:` and the orchestrator runs `scout`.

## Hosts and stacks

| | Options |
|---|---|
| Host (`init.sh --host a,b`) | `claude` (default), `codex`, `opencode`, `cursor`, `gemini`. The project dir is `.sdkit/` for every host (`.claude`/`.codex`/`.agentkit` in old installs); settings: shared `sdkit.env` + personal `sdkit.local.env` |
| Stack (`--stack`, otherwise automatic) | `go`, `spring-boot`, `react-native`, `jvm`, `nextjs`, `python`, `generic` fallback (this is the detection order; one stack per repo) |

On non-Claude hosts the guards run at commit/push time (`.githooks`), and also on tool calls if the host supports it; the adapters were not validated on a live install ([guide.md](guide.md) §13, §16).

## Parallel work

```bash
<kit>/scripts/plan-waves.sh tasks.md      # splits independent tasks into waves
<kit>/scripts/worktree.sh add T3          # isolated worktree for the task
<kit>/scripts/worktree.sh merge T3        # merge at the end of the wave, then verify --fast
```
Task: `- [ ] T3 description | role: developer | size: medium | writes: path/ | after: T1`. Sequential by default; parallel only with disjoint `writes:` and at most `MAX_PARALLEL` (3) subagents. `size:` (small/medium/large → light/standard/strong) is optional; without it the role's tier applies. On other hosts: `run-role.sh <role> --handoff F --tier light|standard|strong`.

## State, resume, cost

```bash
<kit>/scripts/state.sh <slug> show              # task state (work/<slug>/state.json); resume from here after /clear or a crash
sdkit report task|session|latest|history [--detailed|--json|--markdown]   # Value Report: who did what, what it cost, what it saved (automatic at task/session end with VALUE_REPORT=on)
<kit>/scripts/usage.sh report [slug] [--project] [--session ID|current] [--json]   # tokens, cache hit rate, estimated USD (API-equivalent) per role/model/session, coverage warnings (needs USAGE_LOG=1)
<kit>/scripts/usage.sh scan [--session ID]       # ledger a Claude Code session the hook did not see, from its transcript (origin observed)
<kit>/scripts/pricing.sh status                # price table: missing/stale/unpriced models/baseline (sdkit doctor --update-pricing refreshes it)
<kit>/scripts/usage.sh prices                    # which price table is in force (pricing.json v2: model, provider, effective date)
<kit>/scripts/usage.sh budget [slug]            # usage against TOKEN_BUDGET_TASK (exit 3 warning, 4 exceeded)
<kit>/scripts/usage.sh context [transcript]     # which tool results a session carried and what carrying them cost (Claude Code)
<kit>/scripts/capped.sh -- <command>            # run tests/builds; keep failures + tail in the session, full log in work/<slug>/out/
<kit>/scripts/telemetry.sh summary [slug] [--json]  # run summary: phase/agent durations, tokens (measured/total), retries, failures, verification (needs TELEMETRY=1)
<kit>/scripts/telemetry.sh archive <slug>         # before closeout: move the events under work/_archive/
<kit>/bench/run.sh run all                         # simulated benchmark (free); real: --real --host H --yes
<kit>/bench/run.sh run contracts | overhead        # F02: 5 contract fixtures | overhead with/without contracts (bytes, events, script calls, latency)
<kit>/scripts/contract.sh issue F | check-result F --id I --role R --record   # agent contract (CONTRACTS=1): validate the handoff / the answer (0 done, 1 partial|blocked|failed, 2 invalid; 0 does NOT mean "verified")
<kit>/scripts/sdd.sh start <slug> --risk R --profile small|standard|high-assurance --proposal P   # profile (default standard)
<kit>/scripts/sdd.sh transitions | policy [--json]   # valid phase transitions and entries | rules in force for the task (workflow.sh)
<kit>/scripts/sdd.sh evidence [--json]            # high risk: state of the verifier/reviewer/security-auditor evidence (valid|stale|untrusted|...)
<kit>/scripts/contract.sh pending | status      # unanswered handoffs | all ids of the task
<kit>/scripts/memory.sh candidates <slug>       # memory candidates at closeout (MEMORY=1); search | stale | add | promote
<kit>/scripts/lookup-cache.sh get <slug> "question" # scout answer cache; 1 on a miss
<kit>/scripts/run-role.sh verifier --handoff F --cwd D --host H   # run the role in a separate process; another provider with VERIFIER_HOST
AGENT_<ROLE>_TIER=light|standard|strong       # sdkit.env: the tier (and so the model) a role runs at; the roles are listed there with their own tier
<kit>/scripts/route.sh explain --role R [--risk L]   # routing decision (ROUTING=on): adapter, model, reason, budget; no model call, no record
<kit>/scripts/route.sh registry | capabilities | validate   # model registry | adapter capabilities | settings check
<kit>/scripts/check-plan-parity.sh plan.md proposal.md [tasks.md]  # DoD lines: D<n>: text | Verified by: type
```

## What to do when Claude stops

| Situation | Meaning | What to do |
|---|---|---|
| "No risk rubric" | No rubric is defined in `project.md` | Write the rubric yourself; Claude does not invent one |
| "Cannot be tested" options | The code cannot be tested without real infrastructure | Pick one of the options (narrow interface / leave out of scope and record it / integration infrastructure) |
| Release frozen | The release to branch from is tagged `freeze/` | You decide which branch to use |
| Verifier `BLOCK` | DoD `FAIL` or a `CONFIRMED` finding | One automatic retry if it is an implementation bug; if it is a spec gap it comes back to you |
| Second `BLOCK` | The automatic loop is over | Read the summary and decide; there is no third automatic retry |
| Hook `ask` | Protected path / prod `kubectl` / env branch push | Approve or deny |
| Hook `deny` | Secret file, frozen test, wrong branch source | The message gives the reason; fix the cause instead of working around the block |
| Git hook refused (non-Claude hosts) | `guard.sh`: secret, frozen test, protected path, protected branch | Fix the cause; if approved, `ALLOW_PROTECTED=1` / `ALLOW_PROTECTED_PUSH=1` |
| "verify failed" at Stop | An uncommitted change fails the stack's fast check (e.g. vet/build) | Claude fixes it; no infinite loop |

## Hooks at a glance

| Hook | Decision | Disabled by |
|---|---|---|
| `guard-secrets` | deny: `.env*`, `*credentials*`, `*.pem` | `SECRET_GLOBS` empty |
| `guard-protected` | ask: under `PROTECTED_PATHS` | `PROTECTED_PATHS` empty |
| `frozen-tests` | deny: the `<project-dir>/.frozen` list | file absent |
| `guard-prod` | ask: mutating `kubectl` against a prod cluster | `PROD_KUBE_CLUSTERS` empty |
| `guard-git` | deny/ask: release flow rules | `BASE_BRANCH_MODE` ≠ `release` |
| `post-edit-fmt` | the stack's formatter (e.g. `gofmt -w`) | no stack tool |
| `stop-verify` | block: "done" with a broken vet/build | no verify script |
| `guard-readonly` | deny: a read-only role changing files | off if the call has no role |
| `value-report` | Value Report session summary at session end/start (does not block, no stdout) | `VALUE_REPORT` ≠ `on` |
| `usage-log` | token ledger, (`TELEMETRY=1`) the `agent.end` event, and (`USAGE_LINE=1`) a one-line usage summary per finished subagent and the ledger rows the step line reads (does not block) | `USAGE_LOG`, `TELEMETRY` and `USAGE_LINE` ≠ `1` |
| `guard-budget` | ask/warning: `MAX_SPAWNS` or `TOKEN_BUDGET_TASK` exceeded | both empty |
| `guard-noisy` | ask: a long-output command (tests, build) outside `capped.sh` | `NOISY_CMD_PATTERNS` empty |
| `result-size` | warning: role answer too long | `SUBAGENT_RESULT_MAX_LINES` empty |
| `check-contract` | ask (strict, invalid handoff) / warning: the handoff or the `HANDOFF-RESULT` line does not match the contract; does not touch the verdict | `CONTRACTS` ≠ `1` or no `CONTRACT:` in the handoff |
| `session-context`, `check-tools` | info | |

Hooks are safety nets, not a security boundary (regex-based).

## Verification

```bash
<kit>/stacks/<stack>/scripts/verify.sh              # full: the stack's checks + verify.d (Go: gofmt, vet, build, test, lint)
<kit>/stacks/<stack>/scripts/verify.sh --fast       # cheap checks only (Go: vet + build)
<kit>/stacks/<stack>/scripts/verify.sh --since-head # uncommitted changes only
<kit>/stacks/<stack>/scripts/verify.sh --no-cache   # ignore the green-result cache for the same tree
<kit>/bin/doctor.sh <repo>                     # install check
<kit>/bin/upgrade.sh <repo>                    # upgrade to a new kit version (refresh the plugin with /plugin first)
<kit>/bin/build-adapters.sh --check            # (kit maintainer) are the roles and generated files in sync
<kit>/tests/smoke.test.sh                             # (kit maintainer) script/hook/init smoke test
```

`verify.d` script: `<project-dir>/verify.d/NN-name.sh`, `chmod +x`, `. "$VERIFY_LIB"`, prints `FAIL: ...` / `WARN: ...` for a problem.
Files starting with `_` are not run; the `.example` files `init` brings are off until the extension is removed.

## After a bug is fixed (`incident-to-rule`)

First match in order: lint rule → `verify.d` policy → regression test → hook → `known-pitfalls.md` entry.
A guard is not trusted until it **fails** on the diff that produced the bug and **passes** on the fix.

## Common problems

| Symptom | Cause / fix |
|---|---|
| No plugin prompt appeared | `/plugin marketplace add <kit-repo-url>`, then `/plugin install spec-driven-kit@spec-driven-kit` |
| Project permissions/plugin not active | Trust was not granted; project settings are not applied before that |
| A `verify.d` script does not run | Missing `chmod +x`, its name starts with `_`, or it has the `.example` extension |
| A guard does not run | The related setting is empty (table above), or check the install with `doctor.sh` |
| Kit updated, nothing changed in the project | Plugin mode: update with `/plugin`. Copy mode: `sync.sh` |
| Guard does not run on a non-Claude host | `git config core.hooksPath .githooks` was not run in this clone |
| "no known stack detected" | Pass `init.sh --stack go\|spring-boot\|nextjs\|react-native`; another stack needs a new one in the kit ([guide.md](guide.md) §14) |
| Verify said "cached" | The same tree was green before; use `--no-cache` to run it again |
| PR not opened, code 2 | `PR_HOST` is not bitbucket/github/gitlab/auto, or `gh`/`glab` is missing; [hosts.md](hosts.md) |
