# Execution adapters (F12) and optional LiteLLM (F13)

## Contract
Built-in hosts (`claude codex opencode cursor gemini`) run through `run-role.sh` **as before**; `core/adapters.json` declares their capabilities. An external adapter is an executable file `<project-dir>/adapters.d/<name>.sh` (or in the kit's `adapters.d/`); it is called with `run-role.sh --host ext:<name>`, so the risk baseline, spawn record, `parse-verdict --record`, usage ledger and routing path are **unchanged**. An adapter never records its own verdict.

| Verb | Call | Expected output |
|---|---|---|
| capabilities | `<f> capabilities` | JSON with exactly 8 keys (`noninteractive tool_use model_selection usage_reporting structured_output cancellation timeout cost_reporting`), values `help-verified\|declared\|estimated\|kit\|none` |
| execute | `<f> execute --role R --cwd D --tier T --ro 0\|1 [--model M] --prompt-file P` | `{"result": text, "usage": {input_tokens, output_tokens, cache_*?}}`; without `usage` it is **not measured** (not zero) |
| status / cancel | `<f> status\|cancel [id]` | exit 3 if unsupported; `adapter.sh` reports this as "unsupported" |
| usage | `adapter.sh usage <host>` | `none` / `declared`; never invents zeros |
| evidence | `run-role.sh` → `parse-verdict.sh --record` | independent of the adapter |

`scripts/adapter.sh capabilities|usage|cancel|status|validate`. Built-in hosts have no cancel (only a time limit if the `timeout` command exists); parity is not faked.

## Jira task adapter (role-aware, off by default)
`adapters.d/jira.sh` is the transport of `scripts/jira.sh` (REST via `curl`); it is not a text-generation adapter. Nothing leaves the machine without `JIRA_EGRESS=allow` (personal) and `TRACKER=jira`; the token is read from the environment variable named by `JIRA_TOKEN_ENV` and never written to a file. The task contract, exit codes and the Jira MCP alternative are in [design-role-aware.md](design-role-aware.md); usage in [role-aware.md](role-aware.md). Tests use a fake `curl` (`tests/stubs/jira-curl`); the REST paths were **not** tried against a live Jira.

## LiteLLM / OpenAI-compatible endpoint (F13, off by default)
`adapters.d/litellm.sh`: `POST <LITELLM_BASE_URL>/chat/completions`. **Text only**: no tools, no file access; for this reason `verifier/reviewer/security-auditor` and writing roles are refused (an independent decision cannot rest on pasted content). Nothing is sent without `LITELLM_EGRESS=allow` (the prompt may carry repo content); the server must be in the `LITELLM_ALLOW_HOSTS` list (default: localhost only). The key is read from an environment variable (`LITELLM_API_KEY_ENV`), passed to curl via **stdin**, and masked in error messages. Provider errors exit 5. Usage comes from the response's `usage`; if absent, it is not measured. Per-model attribution is written to the usage ledger via `--model`.
Claude subscription traffic does **not** go through LiteLLM. **There is no adapter for FusionCLI**: its command surface could not be verified from here; it must be written against the real `--help`. Tests use a fake `curl` (`tests/litellm.test.sh`); not tried against a live endpoint.
