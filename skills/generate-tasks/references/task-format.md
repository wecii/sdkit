# tasks.json and task keys

```json
{"specId":"checkout","specVersion":"1.0","specSha":"<40 hex>","parent":"PROJ-12",
 "tasks":[{"ref":"A","title":"...","summary":"why and what, one paragraph","slug":"optional","risk":"low|medium|high",
           "acceptanceCriteria":["AC-1"],"dependsOn":["B"]}]}
```

- **Role mode** (the spec has `roles.json`): a task with `"of":"<group ref>"` and `"area":"<role>"` is a role subtask; the task it points to is the group (it has no `area`, and Jira shows it as a `JIRA_TASK_TYPE` issue under the parent, its subtasks under it). Two levels only. The group is done when its subtasks are; only subtasks are implemented (`sdkit sdd start` refuses a group). A subtask's ACs are a subset of the group's, its `externalId` hash also covers `area` (so a subtask with the group's ACs still has its own id; two subtasks of one role under one group need distinct `slug`s), and its Jira summary is `[<role>] <title>`. Roles are fixed: `solution-architect`, `backend`, `frontend`, `devops`, `qa`, `mobil`, `ui`, `ux`.
```json
{"ref":"A","title":"Draft creation","risk":"medium","acceptanceCriteria":["AC-1","AC-2"]}
{"ref":"A-be","of":"A","area":"backend","title":"Draft API","summary":"POST /drafts ...","acceptanceCriteria":["AC-1","AC-2"]}
{"ref":"A-fe","of":"A","area":"frontend","title":"Draft form","summary":"uses POST /drafts from A-be","acceptanceCriteria":["AC-1"],"dependsOn":["A-be"]}
{"ref":"A-qa","of":"A","area":"qa","title":"Draft tests","acceptanceCriteria":["AC-1","AC-2"],"dependsOn":["A-be","A-fe"]}
```
- `sdkit tasks outline` drafts these from the spec's `tasks.md` (refs `G1`, `G1-frontend`, ...; the group `risk` is left empty for the analyst). A subtask gets `steps` (ids of its `tasks.md` lines) and, when it has one line, that line as its title.
- `ref` is a local label for this draft; `dependsOn` uses refs. `render` maps them to `externalId`, then to Jira keys (`--keys map.json`), because the contract's `dependencies[]` holds Jira keys. Create in `sdkit tasks order` so a dependency's key exists first.
- `externalId = <specId>:t<hash>`; the hash covers the sorted ACs and optional `slug`, never the title or the position. A rerun with the same ACs keeps the key; changing a task's ACs is a new task. Two tasks with identical ACs need distinct `slug`s (sdkit tasks says so).
- Size: aim for `TASKS_TARGET_MIN`-`TASKS_TARGET_MAX` tasks (default 12-20), typically 4-12 ACs each; one rule or behaviour family is one task (e-mail rules V-4..V-7 are one task, not four). Split only for (i) a different gate (an AC marked pending/conditional on an open question is its own task, `blockedBy: ["Q1"]` puts "Blocked: Q1" in its summary), (ii) a different risk, (iii) independent delivery. `sdkit tasks plan-check` measures this.
- Atomic: one change a reviewer can hold in their head, one risk.
- AC ids are the spec's own (`AC-<n>`); never rename them. Every AC maps to at least one task; a task without an AC is an orphan and is rejected.
- Required by the contract: externalId, specId, specVersion, specSha, acceptanceCriteria, risk, dependencies, parent. Optional: scope, `area` (a kit role), `group` (true on a group task; `render` sets both). Missing or empty means intake rejects it.

## `change` (tasks of a merged revision)

Optional string, the slug of the spec change the task belongs to (`specs/<id>/changes/<slug>/`). It is part of the task key (`sdkit tasks ids`), so the same ACs in a later change get a new `externalId` instead of updating a possibly done subtask. Leave it out for the first base. Completion is never recorded in the spec; Jira is the only truth.

## The Jira text

A person reads the title and the description in one glance, so both stay short. The machine-read `sdkit-task` block below them is unchanged.

- `title`: what to do, as an action, in the analyst's language. Role subtasks show it as `[role] <title>`.
- `summary`: optional, one sentence (a group's goal). `plan-check` warns above 300 characters.
- `steps`: ids of the `tasks.md` lines the task does (`["1.2","1.3"]`; for a change, the line ids of that change's section). Their text is quoted from the spec at the pinned SHA when the task is rendered, without the AC ids; an id that is not in `tasks.md` at the SHA is a `plan-check` error. Not retyped.
- `include`: optional sections, default none: `acs` (title and first THEN of each AC, at most six, the rest as "and N more"), `after` (each dependency with its Jira key and title), `source` (spec path, version, short SHA). Their text is read from the spec and the plan, not written by the agent.
- Labels follow `ANALYST_LANGUAGE` (`tr`, else English). In Jira API v3 the lists are bullet lists and the labels bold.

A frontend subtask with all three sections (the golden `testdata/golden/tasks/description.txt`):

```
Kullanıcılar e-posta ve parola ile giriş yapabilmeli.

Yapılacaklar:
- Giriş formunu ve kilit mesajını kodla

Bitti sayılır:
- AC-login-1 · Giriş formu: form gönderilir
- AC-login-3 · Hesap kilidi: 5 hatalı denemeden sonra hesap 15 dakika kilitlenir

Önce bitmesi gerekenler:
- PROJ-14 · [ui] Giriş formunu tasarla

Kaynak: specs/login v1.0 (4e11e82)
```

Without `include` only the first two blocks remain. Running `generate-tasks` again on the same spec refreshes the descriptions of tasks that already exist (the upsert is by `externalId`).
