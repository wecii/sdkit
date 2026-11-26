package ui

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/wecii/sdkit/internal/gitx"
	"github.com/wecii/sdkit/internal/project"
	"github.com/wecii/sdkit/internal/spec"
)

// SpecItem is one row of the home screen.
type SpecItem struct {
	ID       string     `json:"id"`
	State    string     `json:"state"`
	Label    string     `json:"label"`
	Waiting  bool       `json:"waiting"`  // someone other than the agent must act (the analyst's answer, the Tech Lead's merge)
	Continue bool       `json:"continue"` // the agent can take it from here
	Update   bool       `json:"update"`   // published: the Tech Lead's comments (or the analyst's edits) can be worked in
	Merge    bool       `json:"merge"`    // approved: sibling changes can be merged into the next revision
	Tasks    bool       `json:"tasks"`    // approved: Jira tasks can be made
	Flow     []FlowStep `json:"flow"`
}

// stateText is the plain-words state; whether the agent can continue it follows from the state.
var stateText = map[string]struct {
	label string
	cont  bool
}{
	spec.StateNoInput:     {"Ön-spec yok", false},
	spec.StateNew:         {"Ön-spec hazır, spec üretimi başlamadı", true},
	spec.StateDraft:       {"Taslak hazırlanıyor", true},
	spec.StateOutput:      {"Spec gözden geçiriliyor", true},
	spec.StateUnpublished: {"Gözden geçirildi, yayına hazır", true},
	spec.StateAwaiting:    {"Tech Lead onayı bekliyor", false},
	spec.StateApproved:    {"Onaylandı", false},
}

// specItem is the row of one spec entry.
func specItem(e spec.Entry) SpecItem {
	t, ok := stateText[e.State]
	if !ok {
		t.label = e.State
	}
	return SpecItem{ID: e.ID, State: e.State, Label: t.label, Continue: t.cont, Waiting: e.State == spec.StateAwaiting,
		Update: e.State == spec.StateAwaiting || e.State == spec.StateApproved, Merge: e.State == spec.StateApproved, Tasks: e.State == spec.StateApproved, Flow: Flow(e.State, false)}
}

// listLocal is every spec of one tree with where it stands, from the same facts `sdkit spec next` reads.
func listLocal(root string) []SpecItem {
	var out []SpecItem
	for _, e := range spec.List(root) {
		out = append(out, specItem(e))
	}
	return out
}

// sortItems puts what the analyst can still move first, then what waits for others, then what is done; by id inside each group.
func sortItems(items []SpecItem) {
	rank := map[string]int{spec.StateAwaiting: 1, spec.StateApproved: 2}
	sort.Slice(items, func(i, j int) bool {
		if ri, rj := rank[items[i].State], rank[items[j].State]; ri != rj {
			return ri < rj
		}
		return items[i].ID < items[j].ID
	})
}

// reID is stricter than the kit's own name rule: it becomes a file name, a branch name and part of a Jira link, and a person typed it.
var reID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,59}$`)

// ValidID reports whether id may name a new pre-spec from the panel.
func ValidID(id string) bool { return reID.MatchString(id) }

const maxPrespec = 200 << 10

// ErrPrespecExists is what WritePrespec wraps when the pre-spec is there and was not to be replaced, so a caller can ask the person.
var ErrPrespecExists = errors.New("pre-spec exists")

// WritePrespec saves the person's text as the pre-spec <id> in the project's pre-spec directory. The pre-spec is working input and
// is never committed, so it refuses when git would not ignore the file. An existing pre-spec is only replaced on request.
func WritePrespec(root, id, text string, overwrite bool) error {
	switch {
	case !ValidID(id):
		return errors.New("Ad harf, rakam, tire ve alt çizgiden oluşmalı (en fazla 60 karakter), örneğin odeme-akisi")
	case strings.TrimSpace(text) == "":
		return errors.New("Ön-spec boş olamaz")
	case len(text) > maxPrespec:
		return errors.New("Ön-spec çok uzun")
	}
	s, _, _ := project.Load(root)
	dir := strings.Trim(s.String("PRESPEC_DIR"), "/")
	if dir == "" || strings.HasPrefix(dir, "__") {
		dir = "prespec"
	}
	if filepath.IsAbs(dir) || strings.Contains(dir, "..") {
		return errors.New("PRESPEC_DIR bu deponun içinde olmalı")
	}
	path := filepath.Join(root, filepath.FromSlash(dir), id+".md")
	if gitx.Tracked(root, path) || !gitx.IsIgnored(root, path) {
		return fmt.Errorf("%s git tarafından yok sayılmıyor; ön-spec yanlışlıkla paylaşılmasın diye kaydedilmedi", dir)
	}
	if _, err := os.Stat(path); err == nil && !overwrite {
		return fmt.Errorf("%q adında bir ön-spec zaten var: %w", id, ErrPrespecExists)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(text), 0o644)
}

// Task is what a run is told to do. The browser names an action and an id; the wording is ours, so a page cannot hand the agent
// arbitrary instructions.
func Task(root, action, id string, in TaskInput) (string, error) {
	if !ValidID(id) && !reKitID.MatchString(id) {
		return "", errors.New("geçersiz ad")
	}
	switch action {
	case "generate-specs":
		return fmt.Sprintf("Use the generate-specs skill for the spec id %q (the pre-spec has the same name). If work on it already exists, continue from where `sdkit spec next %s` says it stands.", id, id), nil
	case "update-specs", "update-manual", "refine-specs":
		if action == "refine-specs" {
			t := fmt.Sprintf("Use the generate-specs skill for the spec id %q. Its output passed review but is not published yet, and the analyst wants a change first. ", id)
			if n := strings.TrimSpace(in.Note); n != "" {
				t += fmt.Sprintf("What they want changed, in their words (authoritative; do not ask again what to change): %q. ", n)
			} else {
				t += "Ask what to change with `sdkit ui ask` (free text). "
			}
			return t + "Make the smallest edit that does it (AC ids stay), run the review round for what changed, and ask the send-or-edit question again before publishing. Do not publish without that answer.", nil
		}
		t := fmt.Sprintf("Use the update-specs skill for the spec id %q.", id)
		if action == "update-manual" {
			t += fmt.Sprintf(" The analyst already edited the files by hand in the panel: start from `sdkit spec changed %s` and the git diff, treat the diff as the instruction and their text as authoritative, and re-derive nothing. Then review, publish and open or update the PR as the skill says.", id)
		} else {
			t += " Read the Tech Lead's change requests from its pull request, and the analyst's own edits, as the skill says. A Tech Lead request is not required: when there is neither a request nor an edit, ask the analyst what to change with `sdkit ui ask` (free text) and work from that."
			if n := strings.TrimSpace(in.Note); n != "" {
				t += fmt.Sprintf(" The analyst wrote what they want changed, in their words (authoritative; do not ask again what to change): %q.", n)
			}
		}
		if reSlug.MatchString(in.Slug) {
			t += fmt.Sprintf(" The change %q is already open on the current branch: continue it and do not create another. If you do not yet know what the analyst wants to change, ask them with `sdkit ui ask` first.", in.Slug)
		}
		return t, nil
	case "generate-design":
		return fmt.Sprintf("Use the generate-design skill for the spec id %q. The analyst chose to make the design now: do not ask whether the feature needs a user interface.", id), nil
	case "merge-specs":
		return fmt.Sprintf("Use the merge-specs skill for the spec id %q. If `sdkit spec drift` and `sdkit spec check` find nothing to merge, say so in one sentence and stop.", id), nil
	case "generate-tasks":
		_, pj, _ := project.Load(root)
		return generateTasksTask(id, in, pj.KitDir)
	}
	return "", errors.New("bilinmeyen işlem")
}

var reSlug = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,40}$`)

// reKitID admits the ids that already exist in a project (they may carry a dot), for continuing them.
var reKitID = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]{0,79}$`)
