package spec

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/wecii/sdkit/internal/lint"
	"github.com/wecii/sdkit/internal/review"
)

// Step is what `sdkit spec next` tells the orchestrator: the next action, and whether a person must act.
type Step struct {
	Action string
	Human  bool
	Why    string
	State  string // where the spec is, one of the State* values; for a screen, not for the orchestrator
}

// Where a spec is in its life, from the pre-spec to the Tech Lead's approval. The names are a contract with the panel.
const (
	StateNoInput     = "no-input"    // no pre-spec, no draft, no output
	StateNew         = "new"         // a pre-spec exists, nothing is drafted
	StateDraft       = "draft"       // drafted, in review (or about to become the output)
	StateOutput      = "output"      // the OpenSpec output exists and is in review
	StateUnpublished = "unpublished" // the output passed review and has not gone to a PR
	StateAwaiting    = "awaiting"    // published, waiting for the Tech Lead's merge
	StateApproved    = "approved"    // merged
)

// Next reads the facts on disk (pre-spec, draft, review evidence, lint, spec dir, meta) and names the single next step of
// generate-specs. It decides nothing about content: it only stops the orchestrator from guessing where it is, and says when
// a real decision (not a model round) is the only thing left. Nothing is written.
func Next(root, id string) Step {
	e := envAt(root, nil, nil)
	rc := review.Load(root)
	exists := func(p string) bool { _, err := os.Stat(filepath.Join(root, p)); return err == nil }
	draft := filepath.ToSlash(filepath.Join(e.kit, "work", "spec-draft", id))
	out := e.dir(id)
	lintFirst := func(target string) *Step {
		ps, err := lint.Run(filepath.Join(root, target), rc.Lint)
		if err == nil && lint.Errors(ps) > 0 {
			return &Step{Action: fmt.Sprintf("fix the %d lint error(s) yourself (sdkit review lint %s --target %s); no reviewer is spent on them", lint.Errors(ps), id, target), Why: "mechanical"}
		}
		return nil
	}
	round := func(rid, target string) Step {
		if r := rc.Check(rid); r.OK() {
			return Step{}
		}
		if s := lintFirst(target); s != nil {
			return *s
		}
		st := rc.Status(rid)
		if len(st) > 0 && (strings.Contains(st, "CONVERGED") || strings.Contains(st, "round cap")) {
			return Step{Action: "show the open BLOCKER/MAJOR findings to the analyst in one screen (triage.md, \"At the round cap\"): apply / answer / accept / reject; raising the cap is theirs", Human: true, Why: "converged or capped: more rounds only sample"}
		}
		return Step{Action: fmt.Sprintf("review round on %s: sdkit review changed %s, plan --round N, begin, fresh reviewers on the changed files, record", target, rid), Why: "no fresh PASS"}
	}
	switch {
	case !exists(filepath.Join(e.prespec, id+".md")) && !exists(draft) && !exists(out):
		return Step{Action: fmt.Sprintf("sdkit prespec check %s: there is no pre-spec", id), Human: true, Why: "no input", State: StateNoInput}
	case !exists(draft) && !exists(out):
		return Step{Action: "collect every open point of the pre-spec as ONE batch of questions (decision / fact / default), settle the answers, then draft in a fresh subagent", Human: true, Why: "questions come first, once", State: StateNew}
	case exists(draft) && !exists(out):
		if s := round(id+"-draft", draft); s.Action != "" {
			s.State = StateDraft
			return s
		}
		return Step{Action: "propose: openspec-propose from the reviewed draft into " + out + " (copy work/decisions/" + id + ".md to " + out + "/decisions.md)", Why: "draft is PASS", State: StateDraft}
	}
	m := e.meta(id)
	// a spec that was never published gets its business-requirements.md right after the proposal and before the output is reviewed, so the
	// review and the hash cover it; a spec published earlier is not asked for it (update-specs refreshes one that exists)
	if (!e.hasMeta(id) || len(m.History) == 0) && !exists(out+"/business-requirements.md") {
		return Step{Action: "write " + out + "/business-requirements.md with the requirements-writer role (mode create; generate-specs references/business-requirements.md), then lint it", Why: "the output is complete only with it", State: StateOutput}
	}
	if s := round(id, out); s.Action != "" {
		s.State = StateOutput
		return s
	}
	switch {
	case !e.hasMeta(id) || len(m.History) == 0:
		return Step{Action: fmt.Sprintf("sdkit preflight spec-publish %s, then sdkit spec init-meta %s and sdkit spec publish %s --title ... --body-file ...", id, id, id), Why: "output is PASS, not published", State: StateUnpublished}
	case m.Status != "approved":
		return Step{Action: "wait for the Tech Lead's merge of the PR; the merge is the approval. For a v0.x, then promote (sdkit spec promote) on a new branch", Human: true, Why: "approval is not ours", State: StateAwaiting}
	}
	return Step{Action: "done: give generate-tasks the merged SHA", Why: "approved", State: StateApproved}
}
