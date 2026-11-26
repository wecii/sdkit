---
name: update-specs
description: Analyst environment. Updates an already published spec after analyst edits or Tech Lead change requests on its PR - detects the files that really changed, edits only the affected dependent documents, resolves cross-document inconsistencies, re-runs the independent EGM review on the modified artifacts, bumps the version exactly once and updates the existing PR. Use when specs/<id> was published and needs changes.
license: MIT
metadata:
  author: spec-driven-kit
  version: "1.0"
---

Keeps a published spec consistent after changes. Mechanics are `sdkit spec` and `sdkit review` (see `generate-specs`; same host wording: `spec-driven-dev/references/hosts.md`). Never write `spec.meta.json` or review state by hand.

**Rules that never bend.** (1) EGM PASS is not approval: the Tech Lead approves by merging. (2) Analyst edits are authoritative: never regenerate a whole document, never overwrite or reword text the analyst wrote; touch only what a change makes inconsistent. (3) Never silently overwrite an approved decision (an approved ADR, an AC id, a version-1.x behaviour): surface it to the user and get an explicit yes, or record a new ADR that supersedes it. (4) Never force-push; never commit to `main`.

## Two modes

- **Before approval** (`sdkit spec status <id>` says status draft, version 0.N): the first spec's PR is still open. Edit in place, as below; each publish bumps 0.N; no change record.
- **After approval** (status approved, the base is on `main`): every change is a **change** under `specs/<id>/changes/<slug>/`, never an edit of the base. Branch `spec/<id>--<slug>`, label = base +0.1. Siblings (open changes of the same base) are reconciled later by `merge-specs`. The analyst never types a sha or a version. Detail: `references/change.md`.

## Steps

Print `[sdkit] update-specs - Step <n>/6: <name> - started|done` per step.

1. **Detect.** Read the mode (above). Before approval: `sdkit spec branch <id>`, then `sdkit spec changed <id>`. After approval: `sdkit spec change new <id> <slug> --kind fix|feature --title "<title>"` (slug from the request, short kebab-case; ask only when it is unclear), then `sdkit spec drift <id>` and tell the analyst which siblings exist (exit 3 = there are). No changes and no change request: stop. A Tech Lead change request is read from the PR (the host's PR tooling) and listed with the file changes.
2. **Impact.** List the dependents (PRD <-> ADR <-> feature specs <-> ACs). Before approval the changed files are the source of truth; after approval the request is, and the base text it touches is read-only.
3. **Edit and reconcile** (`references/change.md`): minimal edits in a subagent that gets the request and the files, AC ids stable. After approval the edit is an OpenSpec delta in `changes/<slug>/specs/<capability>/spec.md` plus `intent.md` and the change's own `tasks.md`; then `sdkit spec change refresh <id> <slug>`. If a change contradicts an approved decision, stop and ask. **business-requirements.md** (a derived view of the spec, `../generate-specs/references/business-requirements.md`) follows the spec: before approval, when `specs/<id>/business-requirements.md` exists, refresh it after the edits and before the review with the `requirements-writer` role (fresh subagent, mode refresh: the existing file and what changed; ids kept). After approval a change branch never touches it, because it is a base file: it is refreshed once the change is applied (step 5). A spec published before the file existed does not get one unless the analyst asks.
4. **Review**: same internal loop as `generate-specs` (`../generate-specs/references/review.md`), for the modified artifacts, in fresh subagents, bounded by the round cap. For a change the review id is `<id>--<slug>` and the target is the change directory (`sdkit review begin <id>--<slug> --target <specs-dir>/<id>/changes/<slug>`). Unresolved BLOCKERs go to the human; NOT_RUN on a host without fresh subagents stops here.
5. **Publish.** `sdkit spec publish <id> --title "<title>" --body-file <file>`. Before approval it bumps the version once and updates the existing PR (`--breaking` only when the user says so). On a change branch it publishes only the change directory, never bumps the base, and puts the status block (siblings or "applied against base") into the PR body. A lone change is then applied with `sdkit spec apply <id>` (exit 0, label +0.1); right after the apply, when the spec has a `business-requirements.md`, refresh it with the `requirements-writer` (mode refresh, the applied change's `intent.md` and delta say what changed) and run `sdkit review lint <id> --target specs/<id>`; the revision is then reviewed and published again; with siblings, stop and hand over to `merge-specs`.
6. **Present**: what changed, which dependents were edited, the label or version, review verdict, the siblings if any, how each Tech Lead request was answered, open questions. Review PASS is not approval; the Tech Lead decides.
