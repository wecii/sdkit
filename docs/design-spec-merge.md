# Design: parallel spec changes and the semantic merge

Status: **implemented** (see "Implementation notes" at the end for where the code deviates or decides). §2 was agreed, §11 lists what is still open. Every spec in the example repo is still a draft, so there is nothing to migrate.

## 1. Problem

The spec, not the code, is the single source of truth. Code branches merge with git; spec branches must merge too, and a line merge is not enough: a bugfix and a feature can change the same acceptance criterion (AC) in different words, or change different ACs that contradict each other. Today:

- `specs/<id>/` is one OpenSpec change per id (`LOGIN`, `google_login`), versioned 0.N → 1.0 by promotion, on branch `spec/<id>`. There is no living "current spec": `openspec/specs/` stays empty.
- Two parallel pieces of work become two ids. Their relation exists only as prose (`google_login` says it overrides `AC-login-social-3` "for Google" and defers the edit to a follow-up). Nothing notices at merge time.
- AC ids are `AC-<capability>-<n>` with "next free number": two parallel branches pick the same number.

## 2. Decisions

1. **One base per spec.** `specs/<id>/` is the living spec and always holds the latest merged state. There are no sibling ids for follow-up work; `google_login` becomes a change on `LOGIN`.
2. **A change is a delta with its own state** under `specs/<id>/changes/<slug>/`: the base it was written against (recorded by the kit, never typed by the analyst), what it changes, why, which ACs it touches, and the new tasks it brings. Format: OpenSpec delta (`ADDED/MODIFIED/REMOVED Requirements`), which `generate-specs` already produces.
3. **Versions are labels.** A change gets the next label of its base when it is created (`1.1`). Changes written on the same base are **siblings** and share that label; nothing is relabelled. The merge of siblings is a new revision with the next label (`1.2`). There is no `--breaking` flag: every change is treated as potentially breaking, one step per revision.
4. **A change branch writes only under `changes/<slug>/` and never touches base files** while it is in review. Two sibling branches cannot conflict in git. A lone change is applied to the base on its own branch (`1.1`).
5. **Siblings are always a semantic merge**, even when they touch different ACs, because they can contradict each other.
6. **The flow for siblings** (§6): each sibling PR is reviewed on its own and the Tech Lead says OK. The analyst who merges then merges the siblings **locally** with `merge-specs`, which produces the new revision (`1.2`) and sends it to review once more. Only that merged revision reaches the base branch. The label does not shift under a reviewer.
7. **The person who runs the merge decides.** The model proposes, with reasons; that person (the team knows a merge is coming, as with code) answers, in batches, only the real decisions.
8. **Completion is never stored in the spec.** Jira is the only truth for done tasks (§8).
9. **History is permanent.** Applied and merged changes stay forever.
10. The analyst passes no sha or version to any command.

## 3. Layout

```
specs/LOGIN/                         the base (living spec)
├── spec.meta.json                   version, status, contentHash (base files only, not changes/), history
├── proposal.md  design.md  tasks.md
├── specs/<capability>/spec.md       requirements and ACs, current state
└── changes/
    └── <slug>/
        ├── change.json              machine state (below)
        ├── intent.md                why, what the author meant (read by merge-specs)
        ├── tasks.md                 only the NEW and CHANGED tasks of this change
        └── specs/<capability>/spec.md   the delta: ADDED / MODIFIED / REMOVED
```

`change.json`:

```json
{
  "slug": "apple-private-email", "title": "...", "kind": "fix|feature",
  "label": "1.1", "status": "open|applied", "createdAt": "...",
  "base": {"version": "1.0", "contentHash": "..."},
  "expects": {"AC-login-social-3": "<sha256 of its text in the base when the change was written>"},
  "touches": ["AC-login-social-3"],
  "renames": {"AC-login-social-10": "AC-login-social-11"},
  "resolutions": [{"item": "AC-login-social-3", "decision": "combine", "why": "...", "by": "..."}],
  "applied": {"version": "1.2", "at": "...", "sha": "..."}
}
```

`base`, `expects`, `touches` and `createdAt` are computed by `update-specs`/`spec.sh`, not typed. An applied change keeps `status: applied` and its delta is never edited again.

## 4. Identity and the "expects" check

- The merge key is the **AC id** (the scenario). A requirement is identified by the set of its ACs (header text alone breaks on a rename).
- `expects[ac]` = sha256 of the AC's normalised text in the base at write time. Different from the base at merge time = the base moved under it.
- **Id collision.** When siblings ADD the same id with different content, the change with the earlier `createdAt` keeps it; the other is renumbered to the next free number, the references inside its own files (`tasks.md`, `design.md`, cross-references) are rewritten and `renames` records it. Safe because tasks are generated only after approval; if a task already pins the old id, the merge refuses and says so.

Example. Base: highest is `AC-login-social-9`. Change A (fix) adds `AC-login-social-10` "provider timeout shows the error". Change B (feature, written later) adds `AC-login-social-10` "Apple hidden e-mail sign-in". Merging A and B: A keeps 10, B's AC becomes `AC-login-social-11`, B's `tasks.md` and cross-references are rewritten, `renames: {10: 11}` is recorded in B.

## 5. Where a merge need is detected

There is no pipeline, and the Tech Lead merges in the host UI where no kit code runs. So the guarantees are layered, and the last ones cannot be bypassed by a UI merge:

| Gate | Where | What |
|---|---|---|
| a | `update-specs` start and `spec.sh publish` | `spec.sh drift <id>` fetches `origin/spec/*` and finds the siblings: open changes of the same spec on the same base (and any revision merged since the change's base). It names them; for siblings `publish` still works (they are reviewed separately) but marks the PR. |
| b | The spec PR itself | `publish` writes a status block into the PR body: `SIBLINGS: <slugs>: do not merge alone, merge-specs first`, or `applied against base <hash>`. `spec.sh check <id>` is the one command the Tech Lead runs before merging; it prints OK or what is missing. |
| c | Local git hooks (`.githooks`) | A local merge or push of a spec branch runs the same check. Does not cover a merge in the host UI. |
| d | `generate-tasks` (via `spec.sh approved-sha`) | Refuses a spec revision with unmerged siblings or an inconsistent base. No task exists for an inconsistent spec, whoever merged it. |
| e | Developer side: `sdd.sh start` and the push/PR gate | The task's pinned `specSha` is older than the latest approved revision of the same spec and that revision touches an AC of the task: the task is blocked with the existing `block --spec-change` → `revalidate --sha` path. |

(e) is "the code is going to be merged, so the spec must be too" made automatic. The Tech Lead and analyst must know about (b); (d) and (e) protect when they forget.

## 6. Applying and merging

**One change, base unmoved.** `spec.sh apply <id> [<slug>]` writes the delta into the base on the change's own branch, sets label `1.1`, marks it `applied`, updates `spec.meta.json`, runs the coverage check (§7). Exit 0. No skill involved.

**Siblings (or a base that moved).** Locally, by the analyst who merges:

1. Review of each sibling PR proceeds as usual; the Tech Lead's OK on each is the signal that its content is accepted.
2. The analyst starts from one sibling's branch and merges the other sibling branches in with git. This is clean, because each only added its own `changes/<slug>/`. The branches may be all N siblings at once.
3. `merge-specs` does the mechanical preparation (renumbers id collisions, lists what each delta changed against the base, writes `work/spec-merge/<id>/plan.json`), then the semantic work (§6.1), then `spec.sh apply` writes all deltas into the base as the next revision (`1.2`).
4. The result is published as the update of that branch's PR and goes to review again; the merge decisions are what the reviewers look at. The other sibling PRs are closed by the kit with a note pointing at the merged one.
5. A late sibling (written on an older base, finished after the merge landed) is merged the same way against the new base, producing the next revision.

### 6.1 The semantic part (`merge-specs`)

The base is the common ancestor of the siblings. What a delta changed against it is objective; what both left unchanged in the base is the shared ground the model reasons from. The script therefore extracts no "shared values" (no message or number heuristics); it only lists the objective facts and leaves the comparison to the model.

Relations the model looks for, from cheap to subtle:

| Relation | Example | Question |
|---|---|---|
| Same AC edited by both | both change `AC-login-social-3` | which text, or a combination? |
| Same requirement/capability, different ACs | A: timeout error. B: new provider error flow | overlap or contradiction? |
| Cross-reference | B's AC cites an AC that A changed | is the citation still true? |
| Same unchanged base text depended on | both deltas build on one base message, state or rule that one of them also changes | still consistent? |
| Decision level | A supersedes an ADR that B relies on | does B's basis still stand? |
| Precondition collapse | B's `GIVEN` assumes behaviour A removed | is B's scenario still possible? |

Stages:

1. **Facts (script).** Per sibling: ACs added, modified, removed; ACs and ADRs cited; capabilities touched; `expects` against the current base. Pure lookups, no interpretation.
2. **Judgement (fresh subagent).** It reads the base text of every touched capability, both deltas and both `intent.md`. Per pair: independent / complementary / contradicting / overlapping / superseding, with a proposed resolution and the alternatives.
3. **Sweep.** The same pass reads the merged AC list of every touched capability once and reports any base AC now inconsistent with the new ones. Independent of the facts of stage 1, so a missed candidate is still found.
4. **Decisions.** Batches of at most 4 questions, a safe default first, each naming the item it closes (as `generate-specs/references/triage.md`). Outcomes: keep both / A wins / B wins / write a combined AC / supersede through a new ADR / needs a business answer. The last one uses the existing OQ mechanism: the AC is marked `blocked by OQ-n` and the merge goes on.
5. The decisions go into `change.json` (`resolutions`) and the merged text into the deltas; `spec.sh apply` runs and now applies. The merged revision gets its own EGM review (`review.sh`, fresh isolation, bound to the content hash).

When the deltas touch nothing in common, the skill still does stages 3 and 5 but usually asks nothing.

An approved AC that the merged result reverses or weakens follows the existing `update-specs` rule: raise it with the person and supersede through a new ADR instead of editing history. Since every change counts as breaking, this holds for every MODIFIED/REMOVED of an approved AC.

## 7. Verification

`apply` ends with a deterministic coverage check, repeated after `merge-specs`:

- every AC each sibling ADDED, MODIFIED or REMOVED (withdrawn) is in the base as intended, or has a recorded resolution (nothing from either change is lost);
- no AC id lost or duplicated; a withdrawn id is never reused;
- every reference to an AC id resolves;
- the changes' tasks cover every AC they add or modify (the `tasks.sh trace` logic).

A lone mechanical apply needs no new EGM round; a merge always gets one. A change's review evidence is bound to the change directory hash; the base `contentHash` covers base files only.

## 8. Tasks

The spec never records completion; Jira does. A change's own `tasks.md` carries only the tasks the change brings (new, or tied to a modified AC). That is how "new" is told from "already done": a task of an earlier, generated change is done or not in Jira; a task of a change not yet generated has no subtask.

- On apply, the change's tasks are appended to the base `tasks.md`, tagged with the change slug. Tasks are identified by their AC set, never by an ordinal like `3.12` (ordinals collide like AC numbers).
- **A modified AC always gets a new task**, never an update of an existing (possibly done) subtask. The task key therefore includes the change slug; the new task references the earlier task(s) covering the same ACs.
- `generate-tasks` runs per merged revision and creates only the tasks of the changes in it; existing subtasks are never touched.

## 9. Developer side

Unchanged contract: a task pins an **approved** `specSha` reachable from `origin/<base>`; approval is the Tech Lead's merge of the PR (an already applied base). New: gate (e), and `sdd.sh` can show which change introduced each AC of a task. The kit adds and removes no code in a merge: after it the developer `revalidate`s to the merged sha and the verifier checks the DoD against the merged ACs.

## 10. Impact on the kit

| Area | Change |
|---|---|
| `scripts/spec.sh` | new `drift`, `apply`, `check`; change-aware `status`/`changed`/`publish`; base `contentHash` excludes `changes/`; PR-body status block |
| `scripts/open-pr.sh` | update the PR body on Bitbucket (today only `gh pr edit` for GitHub is wired in `spec.sh publish`); close a sibling PR with a note |
| skills | `update-specs` writes a change instead of editing the base; new `merge-specs`; `generate-specs` creates the first base, and a feature on an existing base becomes a change |
| `scripts/tasks.sh`, `sdd.sh` | per-change task generation, key includes the slug; gate (e) |
| hooks | `.githooks`: spec-branch check (gate c) |
| docs | `README.md`, `docs/guide.md` (§2, §6, §7, §10, §15), `docs/cheatsheet.md`, `core/roles/README.md` counts and tables in the same change; version bump per `CLAUDE.md` |

## 11. Open points

1. Closing a sibling PR and refreshing the PR-body block through the Bitbucket REST API (`open-pr.sh` creates and reuses PRs there but does not edit or close them).
2. What the Tech Lead's first OK on a sibling means in the host when that PR is then closed unmerged; the merged revision carries a link to the sibling PRs and their reviews.
3. A merge of many siblings at once versus pairwise: the model reads all N deltas in one judgement pass (cost grows with N); a fallback to pairwise when the context gets too large.
4. Tuning the stage 2 and 3 prompts on the `LOGIN` / `google_login` pair as the first real input.

## 12. Implementation notes

Code: `scripts/spec-change.sh` (facts), `scripts/spec-apply.sh` (renumber, delta writes), `spec.sh` (`change`, `drift`, `check`, `apply`, change-aware `publish`/`approved-sha`), `open-pr.sh` (`--update`, `--close`), `skills/merge-specs`, `tasks.sh` (`changes`, `acs --revision`, change in the task key), `sdd.sh` (gate e), `guard.sh` (gate c, `SPEC_CHECK_ON_PUSH`). Tests: `spec-change.test.sh`, `spec-merge.test.sh`.

Decisions settled before the build: (1) change branches are `spec/<id>--<slug>` (git cannot hold `spec/<id>` and `spec/<id>/<slug>`); gate (a) lists `origin/spec/<id>--*`. (2) Edits before the base is approved stay in place (0.N, no change record); the change model starts once the base is approved on the base branch. (3) A change's label is the base version +0.1; no `--breaking` for a change.

Where the build decides something the design left open:
- **Merged revision label.** One change on an unmoved base: base +0.1 (its label). A merge: one step past the highest of the base version and the siblings' labels (siblings share 1.1, the merge is 1.2; a late sibling on a base that is already 1.2 gives 1.3).
- **Apply is sequential.** Deltas are applied in `createdAt` order, a later MODIFIED of the same requirement replaces the earlier text, and the coverage check rejects a result that lost an earlier change's text. So `merge-specs` must put the decided text into the deltas and record `resolutions`; `apply` exits 3 (plan written, nothing changed) until every change has a `resolutions` array.
- **Withdrawn ids** are written as `AC-x-n (withdrawn) - title` with a fixed body; a MODIFIED requirement may leave a withdrawn AC out (apply keeps it) but not an active one.
- **Renumbering** rewrites the later change's own `*.md` files and its `touches`, and records `renames`. The design's "refuse if a Jira task already pins the id" cannot occur: a task pins only ids that are already in an approved base, and then the later change collides with the base, not with a task; such an id is renumbered like any other.
- **Review binding.** `review.sh` hashes exclude the top-level `changes/` directory (base) and every `change.json` (machine state), so applying a change does not stale its own review. A lone apply is published on the change's review; a merge needs a review of the whole base (`review.sh begin <id>`).
- **Gate (d)** (`approved-sha`) checks, for a spec that has `changes/`: no open change inside the revision, no open sibling branch written on that base or older and absent from it, coverage, and the recorded hash.
- **Gate (e)** reads the specs checkout's HEAD: a later approved revision whose applied changes touch an AC of the task blocks `start`, the verified gate and the push gate, naming the AC and the change.
- Still open as listed in §11: what a Tech Lead's OK on a closed sibling PR means in the record, one pass over N siblings versus pairwise, and prompt tuning of stages 2-3 on the LOGIN / google_login pair.
