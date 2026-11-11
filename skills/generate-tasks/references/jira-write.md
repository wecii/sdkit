# Writing to Jira

Two transports, one contract. `jira.sh validate-task` is the validator for both; `tasks.sh render` calls it before any write.

- **jira.sh (deterministic)**: `jira.sh upsert <externalId> <json>` needs `JIRA_EGRESS=allow` and credentials by env var name (see `adapters.d/jira.sh`). Idempotent by label `sdkit-ext-<externalId>`: finds the existing subtask and updates it, else creates it under the parent. Prints `{key, externalId, action}`; exit 3 egress/auth, 4 contract, 5 external failure.
- **Jira MCP tools (used by the agent)**: search for the label `sdkit-ext-<externalId>` first; update if found, create a subtask under the parent if not. Use the description from `tasks.sh render` verbatim (the fenced `sdkit-task` block), add labels `sdkit` and `sdkit-ext-<externalId>`. After the call, read the issue back and run `jira.sh validate-task` on its description; only then write the result line to `results.jsonl`.

Rules for both: never create a parent; never set an assignee; a non-zero exit, an error response or a missing key means no result line (so `report` fails). Do not retry blindly: search by label first, so a half-finished run cannot duplicate.
