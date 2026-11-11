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

Stop and escalate only when the round cap is reached or the user says to proceed with an item unresolved. Then show the remaining findings with the options (fix by hand and raise `SPEC_REVIEW_MAX_ROUNDS`, or accept as a visible exception with `review.sh accept`, which only the user runs).
