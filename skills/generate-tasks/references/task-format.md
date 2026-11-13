# tasks.json and task keys

```json
{"specId":"checkout","specVersion":"1.0","specSha":"<40 hex>","parent":"PROJ-12",
 "tasks":[{"ref":"A","title":"...","summary":"why and what, one paragraph","slug":"optional","risk":"low|medium|high",
           "acceptanceCriteria":["AC-1"],"dependsOn":["B"],"scope":["src/x/"]}]}
```

- `ref` is a local label for this draft; `dependsOn` uses refs. `render` maps them to `externalId`, then to Jira keys (`--keys map.json`), because the contract's `dependencies[]` holds Jira keys. Create in `tasks.sh order` so a dependency's key exists first.
- `externalId = <specId>:t<hash>`; the hash covers the sorted ACs, sorted scope and optional `slug`, never the title or the position. A rerun with the same ACs and scope keeps the key; changing a task's ACs or scope is a new task. Two tasks with identical ACs and scope need distinct `slug`s (tasks.sh says so).
- Atomic: one change a reviewer can hold in their head, one risk, a scope that does not overlap a sibling's unless ordered by `dependsOn`.
- AC ids are the spec's own (`AC-<n>`); never rename them. Every AC maps to at least one task; a task without an AC is an orphan and is rejected.
- Required by the contract: externalId, specId, specVersion, specSha, acceptanceCriteria, risk, dependencies, scope, parent. Missing or empty means intake rejects it.

## `change` (tasks of a merged revision)

Optional string, the slug of the spec change the task belongs to (`specs/<id>/changes/<slug>/`). It is part of the task key (`tasks.sh ids`), so the same ACs in a later change get a new `externalId` instead of updating a possibly done subtask. Leave it out for the first base. Completion is never recorded in the spec; Jira is the only truth.
