# Documentation map

Pick where to start by your role.

| I am... | Read | Then |
|---|---|---|
| A **developer** working in a repo that is already set up | [cheatsheet.md](cheatsheet.md) | [guide.md](guide.md) §4 (flow), §7 (why did a hook block me?) |
| About to **set up** a new repo | [../README.md](../README.md) "Quick start" | [guide.md](guide.md) §10 (settings), §11 (install), then `doctor.sh` |
| Someone who **fixed a bug** and wants to stop it recurring | [guide.md](guide.md) §5 (`incident-to-rule`) | §8 (`verify.d` protocol) |
| Trying to understand **why a hook or guard ran / did not run** | [guide.md](guide.md) §7 | §12 (permission model), §13 (limits) |
| Upgrading my project to a **new kit version** | [upgrading.md](upgrading.md) | `bin/upgrade.sh` |
| Opening the PR on **GitHub/GitLab** | [hosts.md](hosts.md) | |
| Going to use **Codex, OpenCode, Cursor or Gemini** (or mixed with Claude) | [guide.md](guide.md) §16 | §13 (host limits), [../skills/spec-driven-dev/references/hosts.md](../skills/spec-driven-dev/references/hosts.md) |
| Learning what a **stack** provides / adding a new stack | [../stacks/README.md](../stacks/README.md) | [../CONTRIBUTING.md](../CONTRIBUTING.md), [guide.md](guide.md) §14 |
| Working in **parallel** / tuning token spend and project memory | [guide.md](guide.md) §17, §18, §19 | [../core/rules/token-economy.md](../core/rules/token-economy.md) |
| Adding/changing a **role** | [../core/roles/README.md](../core/roles/README.md) | [guide.md](guide.md) §6, §14 |
| Measuring **how many tokens / how much time the kit spends**, running benchmarks | [design-telemetry.md](design-telemetry.md) | [guide.md](guide.md) §18 |
| Understanding and enabling agent **handoff/result contracts** (`CONTRACTS=1`) | [design-contracts.md](design-contracts.md) | [../skills/spec-driven-dev/references/contract.md](../skills/spec-driven-dev/references/contract.md) |
| Understanding workflow **profiles** (small/standard/high-assurance), phase transitions, the failure/retry policy | [design-workflow.md](design-workflow.md) | [../skills/spec-driven-dev/references/workflow.md](../skills/spec-driven-dev/references/workflow.md) |
| Understanding reviewer/security-auditor enforcement at **high risk**, evidence validity and the host capability matrix | [design-evidence.md](design-evidence.md) | [design-workflow.md](design-workflow.md) |
| Understanding which **agent/model** runs, the budget, retries and escalation (F06) | [design-routing.md](design-routing.md) | [design-evidence.md](design-evidence.md) |
| Understanding how **token usage and cost** are computed, the price table (`pricing.json`), `usage.sh report/scan` output and missing-data warnings (F07) | [design-usage.md](design-usage.md) | [design-telemetry.md](design-telemetry.md) |
| Understanding the correctness and cost comparison of the same task solved by **plain agentic development vs. SDKit** (benchmark infrastructure, F05-A) | [design-benchmark.md](design-benchmark.md) | [design-telemetry.md](design-telemetry.md) |
| Working as an **analyst** (specs, review, Jira tasks) or a **developer** on Jira-driven tasks (`SDKIT_ENV`) | [role-aware.md](role-aware.md) | [design-role-aware.md](design-role-aware.md), [guide.md](guide.md) §10 |
| Going to change **the kit itself** | [../CONTRIBUTING.md](../CONTRIBUTING.md) | [guide.md](guide.md) §14, §15 |

## Files

| File | Contents |
|---|---|
| [cheatsheet.md](cheatsheet.md) | One page: commands, risk table, "if X happened, do Y", common problems |
| [design-sdkit-dir.md](design-sdkit-dir.md) | Design record: single `.sdkit/` directory, personal `sdkit.env`, what goes into git, verifications and deviations (1.0.0) |
| [audit-architecture.md](audit-architecture.md) | Architecture and capability audit (F00): component map, capability inventory, lifecycles, findings, prioritized list, proposed ADRs |
| [design-routing.md](design-routing.md) | Smart orchestration (F06): decision engine, model registry, execution contract, retry/escalation, budget (hard/advisory), routing matrix, trust boundaries |
| [design-usage.md](design-usage.md) | Usage and cost accounting (F07): root causes, ledger schema v2, deduplication, price resolution, report, before/after, limits |
| [design-spec-merge.md](design-spec-merge.md) | Parallel spec changes: one living base, per-change deltas, apply and semantic `merge-specs`, gates, verification |
| [role-aware.md](role-aware.md) | Role-aware environments: analyst and developer flows, usage, Jira task contract, change requests, EGM, limits, open decisions |
| [design-role-aware.md](design-role-aware.md) | Design contract of the role-aware work packages |
| [design-adapters.md](design-adapters.md) | Execution adapter contract (F12) and optional LiteLLM (F13) |
| [design-security.md](design-security.md) | Security hardening (F19): redaction, audit trail, static policy |
| [design-benchmark.md](design-benchmark.md) | Task benchmark (F05-A): task registry, isolation and security boundary, strategies, metrics (per host), simulation, report, F05-B prerequisites |
| [design-telemetry.md](design-telemetry.md) | Baseline measurement and telemetry (F01): event schema, which metric is reliable, benchmark framework, simulated results, limits, F02 recommendations |
| [design-report.md](design-report.md) | Value Report: task/session report, measured vs estimated, savings methodology, one-shot generation, limits |
| [design-contracts.md](design-contracts.md) | Agent contracts (F02): handoff/result format, validation categories, host status, benchmark overhead, migration, limits |
| [design-evidence.md](design-evidence.md) | Evidence integrity (F04): high-risk enforcement, trust boundary, validity states, atomicity, host capability matrix, accepted limits |
| [guide.md](guide.md) | Full guide: every skill, agent, hook, engine, setting, install flow, limit |
| [upgrading.md](upgrading.md) | Upgrading projects to a new kit version, manual steps per version |
| [hosts.md](hosts.md) | PR hosts (Bitbucket, GitHub, GitLab) and CI gates |
| [../stacks/README.md](../stacks/README.md) | Stack contract: `detect.sh`, `steps.sh`, `tools.sh`, `permissions.txt` |
| [../tests/smoke.test.sh](../tests/smoke.test.sh) | Script/hook/init smoke test for kit maintainers |

## Glossary

| Term | Meaning |
|---|---|
| **DoD** | Definition of Done: the acceptance criteria in `proposal.md` that a test or the diff can mark PASS/FAIL |
| **Risk label** | `low` / `medium` / `high`. Proposed from the project's risk rubric, confirmed by the user; sets the depth of verification |
| **Verifier** | The agent that never saw the implementation and judges the DoD and the diff independently |
| **Diff base** | The ref the change is compared against (`resolve-base.sh`): the release branch or `origin/BASE_BRANCH` |
| **Frozen test** | A regression test written at `high` risk and added to `<project-dir>/.frozen`, which the implementer cannot change |
| **`verify.d`** | The project's own checks: executable scripts under `<project-dir>/verify.d/` that print `FAIL:`/`WARN:` |
| **Role** | An agent responsibility defined tool-independently under `core/roles/`; generated into a subagent file for each host |
| **Tier** | A role's cost class: `light` / `standard` / `strong`; `core/tiers.env` maps it to a model |
| **Plan gate** | The step before `propose` where you are questioned on the plan in detail and approve it |
| **Wave** | A group of independent tasks whose write paths do not overlap and that can run in parallel |
| **Host** | The agent tool the kit runs in: Claude Code, Codex, OpenCode, Cursor or Gemini CLI. (The PR host is separate: Bitbucket etc.) |
| **Stack** | The language/framework part: `go`, `spring-boot`, `nextjs`, `react-native`; one per repo |
| **`verifier-deep`** | The generated strong-tier twin of `verifier`; used at `high` risk |
| **`state.json`** | `work/<slug>/state.json`: task state, resuming and the single automatic retry |
| **Pitfall** | A past bug class in `known-pitfalls.md` that the verifier looks for in every diff |
| **Plugin / copy mode** | Whether the kit is used as a plugin or by being copied into the repo |
