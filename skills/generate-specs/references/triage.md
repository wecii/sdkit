# Triage after a review round

Goal: the human answers questions, not finding lists. After each review round, before editing anything:

1. List every finding with its severity (`BLOCKER` first). For each, decide the class:
   - `FIX`: the answer exists in the pre-spec, `project.md`, the code or the review standard. Examples: a section is missing and the pre-spec has the content; two open questions glued on one line; an AC merged away that must stay; a term used before it is defined and the pre-spec defines it.
   - `ASK`: only a person can supply it. Examples: what an acronym stands for when the pre-spec never says; which of several designs is the decision (and who owns it, by when); a security choice such as account matching on social login or unverified provider e-mail; a timeout value; a cost, date or metric; an API contract that does not exist yet.
   - `REJECT`: wrong or out of scope; write one line why.
2. Group the `ASK` items by topic. One question per decision, never one per finding: several findings often close with one answer. Offer 2-3 concrete options with a recommended safe default first (for example "no automatic account matching in v1; revisit later"). Say who the decision belongs to if the pre-spec names no owner, and offer "unknown, record as an open question with an owner" as an option. Put the question in `ANALYST_LANGUAGE`.
3. Ask (at most 4 questions per round, further rounds as needed). Wait for the answers.
4. Apply. Each answer becomes content, not a note: a requirement or `AC-` criterion, a decision with the rejected alternatives, or, only if the user chose "unknown", an open question carrying an owner. Mark ACs that depend on an unresolved decision as blocked, naming the decision. Do not leave a closed question in the open-questions list.
5. Re-run the review on the changed artifacts (`review.sh begin`, fresh reviewers, `record`). If the new findings are `ASK` again, repeat from step 1.

## At the round cap: walk the open findings one by one

Stop here only when the round cap is reached (`begin` exits 3) or the user says to proceed with an item unresolved. Never hand over a bare list of ids and files. Go through the open BLOCKER/MAJOR findings (BLOCKER first) yourself, one question at a time:

1. Show the finding: id, severity, where (file and line), the problem in one sentence, your class (`FIX` / `ASK` / `REJECT`) with the reason, and the exact edit you propose as a diff.
2. Ask one question with these options, the proposed edit first: **apply it**; **answer differently** (the user gives the text); **accept the risk** (visible exception, `--why` is the user's reason); **reject the finding** (one line why).
3. Group findings that one decision closes into a single question (as above); do not ask again for a finding the answer already closed.
4. Apply the answers as content. Accept runs `review.sh accept <review-id> <finding-id> --why "<reason>"` only after the user's explicit yes for that finding; `--who` is left out, so it records `JIRA_USER`. If `JIRA_USER` is empty, tell the user to set it in `sdkit.local.env` and stop; never invent a name.
5. Verify, do not trust: open the single final round `review.sh begin <review-id> --final` (outside the cap, once per review id), run fresh reviewers on the changed artifacts only, `record`. Text the person wrote or edited is not PASS until this round says so. If the final round still has open BLOCKER/MAJOR findings, a second `--final` is refused (exit 3): show them and let the user decide (rework by hand or raise `SPEC_REVIEW_MAX_ROUNDS`).
