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

## Two modes

- **Before approval** (`spec.sh status <id>` says status draft, version 0.N): the first spec's PR is still open. Edit in place, as below; each publish bumps 0.N; no change record.
- **After approval** (status approved, the base is on `main`): every change is a **change** under `specs/<id>/changes/<slug>/`, never an edit of the base. Branch `spec/<id>--<slug>`, label = base +0.1. Siblings (open changes of the same base) are reconciled later by `merge-specs`. The analyst never types a sha or a version. Detail: `references/change.md`.

## Steps

Print `[sdkit] update-specs - Step <n>/6: <name> - started|done` per step.

1. **Detect.** Read the mode (above). Before approval: `spec.sh branch <id>`, then `spec.sh changed <id>`. After approval: `spec.sh change new <id> <slug> --kind fix|feature --title "<title>"` (slug from the request, short kebab-case; ask only when it is unclear), then `spec.sh drift <id>` and tell the analyst which siblings exist (exit 3 = there are). No changes and no change request: stop. A Tech Lead change request is read from the PR (the host's PR tooling) and listed with the file changes.
2. **Impact.** List the dependents (PRD <-> ADR <-> feature specs <-> ACs). Before approval the changed files are the source of truth; after approval the request is, and the base text it touches is read-only.
3. **Edit and reconcile** (`references/change.md`): minimal edits in a subagent that gets the request and the files, AC ids stable. After approval the edit is an OpenSpec delta in `changes/<slug>/specs/<capability>/spec.md` plus `intent.md` and the change's own `tasks.md`; then `spec.sh change refresh <id> <slug>`. If a change contradicts an approved decision, stop and ask.
4. **Review**: same internal loop as `generate-specs` (`../generate-specs/references/review.md`), for the modified artifacts, in fresh subagents, bounded by the round cap. For a change the review id is `<id>--<slug>` and the target is the change directory (`review.sh begin <id>--<slug> --target <specs-dir>/<id>/changes/<slug>`). Unresolved BLOCKERs go to the human; NOT_RUN on a host without fresh subagents stops here.
5. **Publish.** `spec.sh publish <id> --title "<title>" --body-file <file>`. Before approval it bumps the version once and updates the existing PR (`--breaking` only when the user says so). On a change branch it publishes only the change directory, never bumps the base, and puts the status block (siblings or "applied against base") into the PR body. A lone change is then applied with `spec.sh apply <id>` (exit 0, label +0.1) and published again; with siblings, stop and hand over to `merge-specs`.
6. **Present**: what changed, which dependents were edited, the label or version, review verdict, the siblings if any, how each Tech Lead request was answered, open questions. Review PASS is not approval; the Tech Lead decides.
