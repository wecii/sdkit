# Consuming a spec-change request

A developer who finds a spec defect stops, fills `templates/change-request.md` (or `jira.sh change-request <subtask> <json>` creates the blocking Jira item) and the subtask stays blocked. The analyst:

1. Reads the request: subtask key, specId, specSha it was pinned to, defective section/AC id, evidence, proposed change, impact. Check the SHA is the one the subtask carries; reject a request against a different one.
2. Decides: accept, amend or reject. A rejection goes back as a comment on the request with the reason; the developer continues on the same SHA.
3. If accepted: run `update-specs` for the spec (new draft version, review loop, PR, human merge). The merge produces a **new approved SHA** on `origin/main`; the old SHA stays valid history.
4. Run generate-tasks again against the new SHA. Tasks whose ACs and scope are unchanged keep their `externalId` (updated, with the new `specSha`/`specVersion`); changed ones are new tasks. Retire superseded subtasks by comment, never by deleting.
5. Tell the developer the new SHA on the request. The developer resumes only against it: they move the `specs/` submodule to the new SHA and run `sdd.sh revalidate` (re-runs intake checks); until that passes the work stays blocked.
