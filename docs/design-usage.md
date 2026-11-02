# Usage and cost accounting (F07)

The `usage.sh` ledger is now complete, deduplicated, model-aware and recomputable. There are no LLM calls; prices and usage are **never invented**. Verification: `tests/usage.test.sh`.

## 1. Root cause analysis

Found by reading the code and measuring real Claude Code transcripts (`~/.claude/projects`).

| # | Symptom | Root cause | Evidence |
|---|---|---|---|
| R1 | Sub-agent output tokens missing | `hooks/usage-log.sh` kept the **first** duplicate per message with `unique_by(.id)`; a streamed message repeats under the same `id` with a growing `output_tokens` | In 6177 duplicated message IDs, 853 have differing values; in sub-agent transcripts output is **31.4% short** (1,904,471 → 2,776,239). Example agent: 16,165 instead of 6,544 |
| R2 | Messages can be dropped | Messages without an ID were merged into one group (`unique_by` null key) | code reading; pinned by a test |
| R3 | Main-session usage can be written to a sub-agent | For `SubagentStop`, `agent_transcript_path // transcript_path`: with no path, the **main** transcript is read and the whole session is written to the sub-agent role (e.g. analyst) | code reading. Sub-agent transcripts live in a separate file: `<session>/subagents/agent-<id>.jsonl` (+ `.meta.json`) |
| R4 | Missing agent runs (e.g. analyst) | If the transcript could not be read, the hook exited silently; when the host failed (rc≠0, timeout), `run-role.sh` wrote no row at all. The gap was invisible | code reading |
| R5 | Orchestrator missing/partial | The orchestrator takes a snapshot only on `Stop` (end of turn); nothing is written in an interrupted session. There was no distinction between a snapshot and a final record: a late/small snapshot could overwrite a larger one | code reading |
| R6 | No per-model cost | One model per row (the last seen); if the session switches models, everything is priced at the last model. No provider, session or origin fields | ledger schema v1 |
| R7 | `cost_est` 0 / absent | `usage.sh report` did not compute cost. Prices lived only in `telemetry.sh`/`route.sh`, in a flat `{model:{in,out}}` form, with no date/provider, and silently "unavailable" when the table was missing | code reading |
| R8 | Cache ratio unverified | The formula is correct (`cache_read/(in+cache_read+cache_write)`) but untested, used a `floor` percentage, and did not exclude partial/duplicated rows | `tests/usage.test.sh`, hand-computed |
| R9 | No project total | `work/<slug>` is deleted on close; the report summed only open tasks | `telemetry.sh archive` already copies `_archive/<slug>.usage.jsonl`, but the report did not read it |

Effect of R1: in main-session transcripts the duplicates are mostly identical (in the measured example the old and new results are equal); the difference shows up in sub-agent transcripts (intermediate streaming values).

## 2. Ledger (`work/<slug>/usage.jsonl`) – schema v2

The old fields stay as they are; the new fields are additive (a row without them counts as an old row).

| Field | Meaning |
|---|---|
| `in` | input tokens, **excluding cache** |
| `out`, `cache_read`, `cache_write` | output, read from cache, written to cache |
| `model`, `provider` | model ID; provider only if visible from the source (`msg_bdrk_`→bedrock, `msg_vrtx_`→vertex, `msg_`→anthropic), otherwise empty |
| `role`, `tier`, `host`, `ts` | role, tier, host, UTC time |
| `session` | session ID |
| `id` | stable **run ID** (sub-agent: `agent_id`; orchestrator: `session-<session>`; `run-role`: `rr-…`) |
| `origin` | `sdk` (recorded by a hook / run-role) or `observed` (read from the transcript by `usage.sh scan`) |
| `kind` | `snapshot` (may grow) or `final` (finished) |
| `status` | `interrupted` (a run cut short) |
| `tq` | `unavailable`: tokens could not be read; zeros mean **unmeasured** |
| `cost_est_usd`, `cost_src` | the host's own estimate (not an invoice); separate from the kit's computation |

**Deduplication.** The key is `(id, model)`. On write: a snapshot does not overwrite a `final`, a smaller reading does not overwrite a larger one (counters only grow), and real numbers overwrite the `unavailable` marker. The report applies the same rule on read (order of evidence: final > measured > larger total > later), so out-of-order/duplicate rows are still counted once. Old rows without an ID cannot be matched: each is counted and a warning is given.

**Multiple models.** If a transcript uses more than one model, one row per model is written (same `id`); each is priced at its own rate, and the run count is the number of distinct `id`s.

**SDK and observed.** Hooks write `origin: sdk`. `usage.sh scan` reads, from the transcript, the Claude Code sessions the hook never saw (hook disabled, interrupted, external) and writes them as `observed` with the same `id`s; if the hook already wrote them, they are **not counted twice**. Default: the latest session; `--session`, `--since`, `--dir`.

## 3. Pricing

`<project-dir>/pricing.json` (or `TELEMETRY_PRICES`). `sdkit init` copies a starting table (`templates/pricing.json`): the public **AWS Bedrock** list for the Claude models (global cross-region inference, standard tier). It is a snapshot, not your contract: check it against your own prices. USD / million tokens.

`scripts/pricing.sh refresh` (or `sdkit doctor --update-pricing`) rebuilds it from the live list; `pricing.sh status` (run by `doctor`) reports a missing, unreadable or stale table (kit-written, over 90 days), models in your ledgers that it cannot price, and a `REPORT_BASELINE_MODEL` that is not in it. Only a table the script wrote (`"managed_by": "sdkit pricing"`) is ever replaced; delete that key to take the table over by hand. Not modelled: 1-hour cache writes, batch tiers and long-context surcharges (`cache_write` is the 5-minute rate); models without a global price (older ones) are left out of the snapshot.

```json
{ "version": 2, "currency": "USD",
  "models": [
    { "model": "<model-id>", "provider": "bedrock", "effective_from": "2026-01-01", "effective_to": null,
      "in": 0.0, "out": 0.0, "cache_read": 0.0, "cache_write": 0.0, "source": "<price page/contract>" } ] }
```

The old flat form (`{"<model>": {"in":…, "out":…}}`) keeps working (no version, no dates, no provider). `telemetry.sh` and `route.sh` read the v2 table by converting it with `sdkit_prices_flat` into a flat table valid today.

**Resolution path (deterministic, in this order):** (1) table: `TELEMETRY_PRICES` → `<project-dir>/pricing.json` → none; (2) model: exact match, otherwise the base ID with the `-YYYYMMDD` suffix stripped; (3) provider: if the record's provider is known, the entry must be of the same provider or have none; if unknown and there are ≥2 candidates with different providers, `ambiguous_provider`; (4) effective date: the record's day falls within `[effective_from, effective_to]`; (5) multiple candidates: the provider-specific one first, then the latest `effective_from`.

**If it cannot be resolved, cost is `null`, not zero:** `no_pricing_table`, `pricing_table_has_no_models`, `unknown_model` (including a missing model ID), `provider_mismatch`, `ambiguous_provider`, `not_effective_on_record_date`, `missing_rate:<kind>` (no rate for a kind that has tokens; a kind with 0 tokens needs no rate), `tokens_unavailable`. An unreadable table and a non-USD currency produce a warning.

## 4. Cost and report

Cost is **not written** to the ledger; every report computes it as tokens × the table in force. When a price is updated, all history is recomputed. Internal arithmetic is full precision (jq double precision); rounding to 4 decimals happens only in display. Token counts and cost stay separate.

Three separate amounts, never mixed: the **API-equivalent estimate** (tokens × `pricing.json`, this report), the **host estimate** (Claude Code `total_cost_usd`, not an invoice) and **billed** (`billed`, always "unavailable": no source reports it; a Claude Code subscription has no per-token invoice, and the estimate is only the cost of the same tokens at API prices).

```bash
usage.sh report [slug] [--project] [--session ID|current] [--json]
usage.sh prices [--json]
usage.sh scan [--session ID | --since YYYY-MM-DD] [--dir DIR] [--slug S]
usage.sh extract <transcript>
```

Report: role, model and session tables; cache hit rate (`cache_read / (in + cache_read + cache_write)`, 1 decimal) and API-equivalent savings; estimated cost; a coverage line. The **total becomes `PARTIAL`** (a lower bound) when: a run is unpriced, a run is unmeasured (`tq: unavailable`), the price table is missing/unreadable, a session has no orchestrator record (`scan` is suggested), there are fewer agent records than the recorded spawn count (`state.json .spawns`), or an old row has no ID. `--project` adds archived tasks (`work/_archive/*.usage.jsonl`, written by `telemetry.sh archive`); the default scope is open tasks as before.

## 5. Before / after

On a real Claude Code sub-agent transcript (`Explore`, claude-sonnet-5-5):

```
BEFORE                                                AFTER (usage.sh scan + report, with example prices)
role     tier runs in  out   cache_read cache_write   role          runs in  out    cache_read cache_write est_usd
Explore  -    1    60  6544  2549093    139803         Explore       1    60  16165  2549093    139803      $1.5316
TOTAL    -    1    60  6544  2549093    139803         orchestrator  1    202 65568  13210783   284495      $6.0142
cache hit rate: 94%                                    TOTAL         2    262 81733  15759876   424298      $7.5459
(no model, no cost, no coverage)                       model claude-sonnet-5-5 / bedrock; hit rate 97.4%; billed: unavailable
```

Output tokens went 6544 → 16165 (the final value, not a streaming intermediate); the orchestrator row is now written; there is a model/provider breakdown, cost and coverage warnings. (The prices are for display only.)

## 6. Remaining limits and accuracy guarantees

**Guarantees:** token counts are the `usage` values recorded in the transcript (once per message, the largest among streaming duplicates); the same `id` is never counted twice; cost is computed only with a resolved price entry, otherwise `null` and a warning; the total is `PARTIAL` on missing data; since cost is not stored, it is recomputed consistently when prices change; same ledger + same table = same result.

**Limits:**
- A run for which no record was ever written **cannot be proven**: coverage is warned about only through hints (spawn counter, a session without an orchestrator, the `unavailable` marker). A "complete" report is complete for the recorded data.
- Codex, OpenCode and Cursor do not report tokens (`unavailable`); Gemini does not report cache. Their cost cannot be computed.
- The assumption that `scan` and hook IDs are the same: sub-agent ID `agent_id` = the `agent-<id>.jsonl` file name. If this does not hold in a different Claude Code version, double counting is possible; it was not verified with a real hook payload (only the file naming and `.meta.json` were seen in real transcripts).
- `scan` writes a whole session into the task ledger; if the session also contains off-task work, the task looks larger.
- The provider is inferred only from the transcript message-ID prefix; behind a server/gateway (proxy) it may be wrong or empty (if empty, a provider-less price entry is used).
- Prices come from the user; a wrong table produces a wrong cost. Long-term/separate pricing (1-hour cache write, batch/priority tier, long-context threshold) is not modelled: `cache_write` is a single rate.
- The actual billed amount is unknown; for subscription usage this report is only API-equivalent.
- `work/<slug>` is deleted on close; for the project total, `telemetry.sh archive` (TELEMETRY=1) must have run first.
- Error bound: concurrent writes are protected by `sdkit_lock`; the lock break timeouts are the same (3 s / 10 s).
