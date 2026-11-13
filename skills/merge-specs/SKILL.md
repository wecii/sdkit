---
name: merge-specs
description: Analyst environment. Merges sibling spec changes (open changes written on the same approved base, specs/<id>/changes/<slug>/) into the next revision of the spec - mechanical preparation by spec.sh, then a fresh-subagent judgement of how the deltas relate (same AC, contradiction, broken citation, collapsed precondition), a sweep of the merged capability, at most four decisions per round put to the analyst, spec.sh apply, an independent EGM review of the merged revision, and publish. Use when spec.sh drift/check/apply reports siblings or a moved base.
license: MIT
metadata:
  author: spec-driven-kit
  version: "1.0"
---

Merges what git cannot: two changes can edit one acceptance criterion (AC) in different words, or edit different ACs that contradict each other. Design: `docs/design-spec-merge.md` (§6). Mechanics are `<kit>/scripts/spec.sh` and `<kit>/scripts/spec-change.sh`; review evidence is `<kit>/scripts/review.sh`. Never write `spec.meta.json`, review state or `change.json` fields other than `resolutions` by hand. `<kit>`, asking the user, and fresh subagents: `spec-driven-dev/references/hosts.md`.

**Rules that never bend.** (1) The person running the merge decides; you propose with reasons. (2) Never pick a winner silently: every AC touched by two changes, and every contradiction, becomes a recorded resolution. (3) Analyst text is authoritative; merge only what the deltas and the decisions say. (4) EGM PASS is not approval: the Tech Lead merges. (5) Never force-push, never commit to `main`. (6) A host without fresh subagents records `NOT_RUN` for stages 2-3 and the review, never PASS; stop and say so. (7) The analyst passes no sha or version to anything.

Language: as in `generate-specs` (`ANALYST_LANGUAGE`): questions, summaries and the PR body in it; AC ids, verdicts, file names and step banners stay English.

## Steps

Print `[sdkit] merge-specs - Step <n>/6: <name> - started|done` per step.

1. **Prepare.** `spec.sh drift <id>` names the siblings. Stay on (or switch to) one sibling's branch `spec/<id>--<slug>` and `git merge --no-edit origin/spec/<id>--<other>` for each other sibling (clean: each only added its own `changes/<slug>/`; on a conflict stop and show it). Then `spec.sh apply <id>`: exit 3 writes `<project-dir>/work/spec-merge/<id>/plan.json` (stage 1 facts) and changes nothing. Any other result: report it and stop.
2. **Judge** (fresh subagent, `references/judge.md`): per pair of changes, the relation, a proposed resolution and the alternatives.
3. **Sweep** (same pass): the merged AC list of every touched capability read once; report each base AC now inconsistent with the new ones.
4. **Decide** (`references/decide.md`): batches of at most 4 questions, safe default first, each naming the item it closes. A "needs a business answer" outcome uses the OQ mechanism and the merge goes on.
5. **Record and apply.** Write the decisions into each change's `change.json` `resolutions` (`[{item, decision, why, by}]`, empty array when nothing needed deciding) and the merged text into the deltas (a later MODIFIED of the same AC wins when applied, so the delta must hold the decided text and cite every kept AC). `spec.sh apply <id>` again: it renumbers id collisions (earlier `createdAt` keeps the id), applies the deltas as the next revision and runs the coverage check; on failure nothing is changed, read the problems and fix the deltas.
6. **Review and publish.** `review.sh begin <id>` (target the whole spec), fresh reviewers as in `../generate-specs/references/review.md` with the resolutions as context, `record`; then `spec.sh publish <id> --title ... --body-file ...` (body: the decisions, the sibling PR links). Close each other sibling PR with a note pointing at the merged one: `<kit>/scripts/open-pr.sh --close spec/<id>--<slug> x <note-file>`. Present: revision, decisions taken, renumbered ids, review verdict.
