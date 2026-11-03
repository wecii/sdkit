# Task benchmark (F05-A)

Infrastructure that has the same software task solved with different strategies (plain agentic development, SDKit standard, SDKit high-assurance) and measures **correctness and resource use**. F05-A is infrastructure only: there are no real model calls, and SDKit workflow behaviour did not change. Real measurement is F05-B's job (§9).

`bench/run.sh` (F01–F03) measures the cost of the kit's own workflow in scenarios. `bench/tbench.sh` answers "was the job done right, for how many tokens, with which strategy". The two are separate; telemetry (`scripts/telemetry.sh`) is reused, and there is no second ledger.

## 1. Architecture

```
bench/tbench.sh              driver: tasks strategies validate seal fixtures run preflight ingest verify report
bench/tasks/<ID>-<slug>/     task.json (manifest), task.md (the text the agent sees), starter/ (the repo the agent sees + visible tests)
bench/tasks/registry.json    id@version -> manifest summary (a sealed version never changes)
bench/evaluator/<ID>-<slug>/ evaluator ONLY: hidden/ (hidden acceptance tests), variants/{reference,partial}/
bench/strategies/*.json      baseline, sdkit-standard, sdkit-high-assurance
bench/sim/sim.json           simulation fixture (hand-written numbers; labelled)
bench/lib/                   runlimited.py (timeout, output limit, process group), ingest.jq, from-telemetry.jq, report.jq, report-md.jq, sim-agent.sh
tests/tbench.test.sh         automated tests
```

Reused: the `telemetry.sh summary --json` format (imported with `from-telemetry.jq`), the same quality labels as `usage.sh`/`run-role.sh` (measured/estimated/unavailable), and the `bench/run.sh` rule "simulated by default, real with `--real` + `--yes`".

Result directory (`--out DIR`, must be **outside** the kit tree):
`DIR/runs/<run-id>/{result.json, result.sha256, agent.log, public.log, hidden.log, diagnostics/}` and a temporary `DIR/work/`.

## 2. Task registry

Each task has: ID+version, description, risk, difficulty, starter repo (local fixture, git tree ID, origin), visible test command, hidden test command and minimum test count, requirements (R1…Rn), editable paths, limits (agent time, test time, output bytes), environment, and two content digests (`visible_sha256`: task.md + starter; `evaluator_sha256`: hidden + variants). `seal` writes the digests; `validate` recomputes them. The same `id@version` cannot be resealed with different content (exit 5): bump the version.

| ID | Difficulty / risk | Task | Deliberate defect |
|---|---|---|---|
| T01 | low / low | null handling and error propagation | crashes on a `None` profile, all errors are swallowed as `""` |
| T02 | low / low | input validation, edge cases | `int()` accepts `+5`, `1_000`, Unicode digits and unbounded values; SKU is not validated |
| T03 | medium / medium | paginated REST API | no pagination, order not guaranteed |
| T04 | medium / medium | concurrent cache race | the loader runs N times for the same key; `invalidate` race |
| T05 | high / high | authorization bypass | no ownership/sharing check, `owner_id` can be overwritten, an inactive user gets through |
| T06 | high / high | multi-component transaction consistency | stock/payment/order not atomic, no refund, no idempotency |

All use only the Python 3 standard library (unittest, threading, sqlite3), no network, and run in seconds. Fixture validation (`tbench.sh fixtures`, also run by the tests) proves four states for each task:

| State | Visible tests | Hidden tests |
|---|---|---|
| starter (defective) | pass | **fail** |
| `partial` (half solution) | pass | **fail** |
| `reference` (reference solution, evaluator only) | pass | **pass** |
| emptying the tests (`tamper`) | pass | **fail** (the evaluator takes only `app/`) |

## 3. Isolation and evaluation

Each run gets: its own work directory, a new git repo from the pristine starter (fixed identity and date; exit 5 if the tree ID does not match the manifest), a unique run ID (`mkdir` is atomic; an existing ID exits 4), a separate result directory, and on failure the work directory is kept under `diagnostics/`. No git command is applied to the kit's own repo; deletion happens only under `work/<id>` and in a marked directory.

Evaluation happens **outside** the agent's environment, after the agent finishes: a fresh tree = pristine starter + **only** the agent's `editable` paths (refused if there is a symlink) + hidden tests. Tests the agent wrote or changed are ignored; the visible tests run in their pristine form as a regression check. Hidden tests must run at least `min_tests` and cannot be skipped; results are recorded per requirement (`test_R<n>_*`). There is no LLM judge.

The environment given to the agent contains only the allowed variables, via `env -i` (PATH, HOME, work path, prompt file); the evaluator path is in no variable. Before the run, the work directory is searched for digests of the evaluator files; if any are found, the run stops.

### Security boundary (stated openly)

**A git worktree or temp directory is not a sandbox.** A process with shell access as the same user can read the `bench/evaluator/` directory. Therefore:

- The simulation does **not claim** hidden-test isolation (`hidden_test_isolation: "not claimed"` in the result); the fake agent is harness code.
- A real run (`--real --yes`) needs an isolation mechanism (`SDKIT_TBENCH_ISOLATION_CMD`, e.g. a container or a `sandbox-exec` wrapper). `tbench.sh preflight` checks that it really hides the evaluator assets (it tries to `cat` the hidden test file, `ls` the directory and `cat` the reference; all must fail, and it must be able to run a simple program). If the mechanism is missing or does not hide them, it **fails closed** (exit 3). The check only probes the evaluator assets; it is not a full sandbox proof.
- Network access is not restricted; the agent can look for a solution outside (in F05-B the isolation mechanism should cover this too).

## 4. Strategies

| Strategy | Workflow | Profile | Independent verification | Risk floor |
|---|---|---|---|---|
| `baseline` | none: a single coding agent, the task text, the repo, tools | - | none | n/a |
| `sdkit-standard` | `sdd.sh start --profile standard` | standard | by risk (medium, high) | inherited |
| `sdkit-high-assurance` | `--profile high-assurance` | high-assurance | at every risk; at high risk reviewer + security-auditor too | inherited |

Model, provider, tools, task text, starting revision and limits are the same in all strategies (`same_as_other_strategies`); the difference is recorded in the `result.strategy.differs_from_baseline` field. The SDKit lifecycle is not imposed on `baseline`. SDKit strategies cannot change the `SDD_MODE`, `RISK_FLOOR*`, `HOOK*` or `SDKIT_*` settings through `env`; `risk_floor` must be `inherit` (`tbench.sh strategies` validates this). On the high-risk T05/T06, the kit's mandatory three-role evidence applies as is.

## 5. Metrics

Per run (`result.json`): tokens (input, output, cache read/write, total and what the total is based on), **provider cost** (measured, separate) and **estimated API-equivalent cost** (from the price table only, separate), LLM call count, agent call count, duration, retries, profile, task risk, model/provider/billing type (`metered|subscription|unknown`), exit status, visible/hidden test result, code change (files, lines, test files touched), phase durations, tokens per role. Every field is `measured | estimated | unavailable`; a missing or invalid number becomes **null**, never 0; an unlabelled number counts as "estimated". With subscription billing, the reported USD is stored as an estimate, not as "measured spend".

Support per host (based on today's `run-role.sh` readers; not verified against live CLIs):

| Host | Tokens (input/output) | Cache | Provider cost | LLM call count | Note |
|---|---|---|---|---|---|
| Claude Code | measured (JSON output `usage`) | read/write measured | `total_cost_usd` is in the JSON, `run-role.sh` does not read it yet | none | on a subscription this value is the API equivalent |
| Gemini CLI | measured | none (null) | none | none | the total is a lower bound |
| Codex, OpenCode, Cursor | **none** (null) | none | none | none | only duration, agent count, retries |

No host provides the LLM call count; this field is filled only if the harness counts calls through a proxy/trace (F05-B). Telemetry also reports per-agent tokens as "partial": `ingest` flags this with a "lower bound" warning.

## 6. Simulation

`tbench.sh run --simulate`: no model. A fake agent (`lib/sim-agent.sh`) stands in for the strategy and plays out an outcome: `reference`, `partial`, `starter`, `tests-only`, `crash`, `hang`, `flood` (`--sim-force`). The numbers are hand-written in `bench/sim/sim.json`; the result file carries `simulated: true` and a label, the report says "SIMULATED / NO REAL MEASUREMENTS" in its header when there is no real measurement, simulated runs are **never mixed** with real figures, and `conclusions_allowed=false`. The simulation exercises loading, the work directory, strategy selection, metric ingestion (baseline `agent-metrics/1`, SDKit strategies in the `telemetry.sh summary` format, one with no usage at all), evaluation, persistence, the report and error recovery (crash, timeout, output overflow, interruption).

## 7. Reporting

`tbench.sh report --results DIR` produces JSON and Markdown (`DIR/reports/`, never overwrites). Contents: runs/successes/success rate per strategy, failure categories, tokens (median; total only if present in **every** run), cost, latency, retries, agent/LLM calls, a task × strategy table, data completeness (counts of measured/estimated/unavailable), comparison with baseline (only on matching tasks, percentage-point difference, median token ratio, flags), measurement limits. **Cost per successful task** = the sum over ALL of the strategy's runs (failures included) / the number of successes; it is computed only if n ≥ `--min-n` (default 5), there is at least one success and the metric is present in all runs, otherwise the reason is written. Failures stay in every denominator. The report does not rank strategies; it produces "cheaper but less correct" and "less correct than baseline" flags. Tampered (digest mismatch) and incomplete (interrupted/crashed) runs are excluded and listed by name.

## 8. Integrity

Each run records: the task version and digests, the starting commit and tree ID, the runner version/commit/dirty flag/code digest (`evaluator.code_sha256`), the strategy configuration, the model, the environment (operating system, architecture, bash/jq/python/git versions; no host name or user) and a timestamp. After `result.json` is written, its digest is sealed into `result.sha256` and it is made read-only; `tbench.sh verify` detects changes (exit 6). A run ID cannot be reused. Interruption (SIGTERM): the process group is killed, the result is sealed as `interrupted`, exit 130. On a hard crash such as SIGKILL, the `RUNNING` marker remains and the run is listed as "incomplete" in the report.

Exit codes: 0 ok, 1 error, 2 usage, 3 refused (fail closed), 4 run ID exists, 5 task integrity, 6 sealed result changed, 130 interrupted.

## 9. Remaining prerequisites for F05-B

1. **Real isolation**: a mechanism (container/VM) that hides the evaluator assets and restricts the network, and passing `preflight` with it.
2. **Real strategy adapters**: a single-agent run for baseline; for SDKit, `init` in the repo, `sdd.sh start --profile`, `TELEMETRY=1`, and `telemetry.sh summary --json` at the end (the harness collects it as `telemetry-summary.json`). For now `run --real` stops after the gate.
3. Pinning the **same model/tools** and recording `--model/--provider/--billing`.
4. **Provider cost**: reading Claude's `total_cost_usd` (`run-role.sh` does not capture it yet) and a usage source for Codex/OpenCode/Cursor; without one, only duration/correctness can be compared on these hosts.
5. A proxy or host log for the **LLM call count**.
6. **Sample**: ≥ 5 repetitions per task (`--reps`), models without a fixed seed for variance; a confidence interval calculation should be added.
7. Telemetry `agent.end` events are missing for the host's own subagents (Codex etc.): per-agent tokens are a lower bound (the report warns).
8. Hidden tests are only so thorough: as the task set grows, the `partial` variants should be tested with new defect classes.
9. A budget and approval (`--yes`) policy for paid runs.
