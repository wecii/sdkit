---
name: update-specs
description: Analyst environment. Updates an already published spec after analyst edits or Tech Lead change requests on its PR - detects the files that really changed, edits only the affected dependent documents, resolves cross-document inconsistencies, re-runs the independent EGM review on the modified artifacts, bumps the version exactly once and updates the existing PR. Use when specs/<id> was published and needs changes.
license: MIT
metadata:
  author: spec-driven-kit
  version: "1.0"
---

Keeps a published spec consistent after changes. Mechanics are `<kit>/scripts/spec.sh` and `<kit>/scripts/review.sh` (see `generate-specs`; same host wording: `spec-driven-dev/references/hosts.md`). Never write `spec.meta.json` or review state by hand.

**Rules that never bend.** (1) EGM PASS is not approval: the Tech Lead approves by merging. (2) Analyst edits are authoritative: never regenerate a whole document, never overwrite or reword text the analyst wrote; touch only what a change makes inconsistent. (3) Never silently overwrite an approved decision (an approved ADR, an AC id, a version-1.x behaviour): surface it to the user and get an explicit yes, or record a new ADR that supersedes it. (4) Never force-push; never commit to `main`.

## Steps

Print `[sdkit] update-specs - Step <n>/6: <name> - started|done` per step.

1. **Detect.** `spec.sh branch <id>`, then `spec.sh changed <id>`: the files that differ from the last published SHA. No changes and no change request: stop. If there is a Tech Lead change request, read it from the PR (the host's PR tooling) and list it with the file changes (`references/change.md`).
2. **Impact.** From the changed files and requests, list the dependents (PRD <-> ADR <-> feature specs <-> ACs). The changed files are the source of truth; dependents follow them.
3. **Edit and reconcile** (`references/change.md`): edit only the affected dependents, in a subagent that gets the diff and the files, keep AC ids stable, resolve contradictions between documents toward what the analyst changed. If a change contradicts an approved decision, stop and ask.
4. **Review**: same internal loop as `generate-specs` (`../generate-specs/references/review.md`), only for the modified artifacts, in fresh subagents, bounded by the round cap. Unresolved BLOCKERs go to the human; NOT_RUN on a host without fresh subagents stops here.
5. **Publish.** `spec.sh publish <id> --title "<title>" --body-file <file>` bumps the version exactly once (0.N before approval, 1.N after; add `--breaking` for N.0 only when the user says the change breaks compatibility) and updates the existing PR (never a second one). Unchanged content is a no-op.
6. **Present**: what changed, which dependents were edited, new version, review verdict, how each Tech Lead request was answered, open questions. Review PASS is not approval; the Tech Lead decides.
