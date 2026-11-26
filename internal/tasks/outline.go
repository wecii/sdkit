package tasks

import (
	"bytes"
	"encoding/json"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/wecii/sdkit/internal/lint"
)

// OutTask is a task of the draft Outline returns, in tasks.json's own key order. Risk is set (empty) on a group task only: it is
// the analyst's, read from the project's rubric, never derived here.
type OutTask struct {
	Ref       string   `json:"ref"`
	Of        string   `json:"of,omitempty"`
	Area      string   `json:"area,omitempty"`
	Title     string   `json:"title"`
	Summary   string   `json:"summary"`
	Steps     []string `json:"steps,omitempty"`
	Change    string   `json:"change,omitempty"`
	Risk      *string  `json:"risk,omitempty"`
	ACs       []string `json:"acceptanceCriteria"`
	DependsOn []string `json:"dependsOn"`
}

// Outline derives the group tasks and role subtasks from the role structure of tasks.md: a feature is a group task, each of its
// role sections one subtask of that role, and an `after:` becomes a dependency (between subtasks, and between the groups they sit
// in). qa comes last in its group, after every other subtask of it. changes nil takes the base features, otherwise the features
// of those `## Change:` sections. A subtask names its tasks.md lines in steps (their text is quoted from the spec when the task is rendered) and, with one line,
// takes it as its title. It is a draft for the analyst to refine, not a decision.
func Outline(d *lint.TasksDoc, changes []string) []OutTask {
	want := map[string]bool{}
	for _, c := range changes {
		want[c] = true
	}
	var feats []lint.Feature
	for _, f := range d.Features {
		if (changes == nil && f.Change == "") || (changes != nil && want[f.Change]) {
			feats = append(feats, f)
		}
	}
	type key struct{ change, id string }
	type loc struct{ group, sub string }
	where := map[key]loc{}
	groupRef := func(i int) string { return "G" + strconv.Itoa(i+1) }
	for i, f := range feats {
		for _, s := range f.Sections {
			for _, t := range s.Tasks {
				where[key{f.Change, t.ID}] = loc{groupRef(i), groupRef(i) + "-" + s.Role}
			}
		}
	}
	var out []OutTask
	for i, f := range feats {
		g := groupRef(i)
		var subs []OutTask
		var groupACs, groupDeps []string
		for _, s := range f.Sections {
			sub := OutTask{Ref: g + "-" + s.Role, Of: g, Area: s.Role, Title: titleCase(s.Role) + ": " + f.Title, Change: f.Change}
			for _, t := range s.Tasks {
				sub.Steps = append(sub.Steps, t.ID)
				sub.ACs = addAll(sub.ACs, t.ACs)
				for _, a := range t.After {
					if l, ok := where[key{f.Change, a}]; ok {
						if l.sub != sub.Ref {
							sub.DependsOn = addAll(sub.DependsOn, []string{l.sub})
						}
						if l.group != g {
							groupDeps = addAll(groupDeps, []string{l.group})
						}
					}
				}
			}
			if len(s.Tasks) == 1 { // one step: the title is the action itself
				sub.Title = actionTitle(s.Tasks[0].Text)
			}
			groupACs = addAll(groupACs, sub.ACs)
			subs = append(subs, sub)
		}
		for j := range subs {
			if subs[j].Area == "qa" {
				for k := range subs {
					if k != j {
						subs[j].DependsOn = addAll(subs[j].DependsOn, []string{subs[k].Ref})
					}
				}
			}
		}
		empty := ""
		sort.Strings(groupACs)
		out = append(out, OutTask{Ref: g, Title: f.Title, Change: f.Change, Risk: &empty, ACs: groupACs, DependsOn: nonNil(groupDeps)})
		for _, s := range subs {
			s.ACs, s.DependsOn = nonNil(s.ACs), nonNil(s.DependsOn)
			out = append(out, s)
		}
	}
	return out
}

// actionTitle is the text of a tasks.md line without its AC ids: "Build the form (AC-login-1)" -> "Build the form".
func actionTitle(text string) string {
	return strings.TrimSpace(regexp.MustCompile(`[ \t]*\((?:[^()]*\bAC-[^()]*)\)[ \t]*$`).ReplaceAllString(text, ""))
}

func addAll(to, from []string) []string {
	have := map[string]bool{}
	for _, s := range to {
		have[s] = true
	}
	for _, s := range from {
		if !have[s] {
			have[s] = true
			to = append(to, s)
		}
	}
	return to
}

func nonNil(l []string) []string {
	if l == nil {
		return []string{}
	}
	return l
}

func titleCase(role string) string {
	switch role {
	case "ui", "ux", "qa":
		return strings.ToUpper(role)
	}
	parts := strings.Split(role, "-")
	for i, p := range parts {
		if p != "" {
			parts[i] = strings.ToUpper(p[:1]) + p[1:]
		}
	}
	return strings.Join(parts, " ")
}

// outlineJSON is a whole tasks.json (header of the skeleton, the drafted tasks).
func outlineJSON(d *Doc, tasks []OutTask) []byte {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	e.SetIndent("", "  ")
	_ = e.Encode(struct {
		SpecID      string    `json:"specId"`
		SpecVersion any       `json:"specVersion"`
		SpecSha     string    `json:"specSha"`
		Parent      any       `json:"parent"`
		Tasks       []OutTask `json:"tasks"`
	}{d.SpecID, d.SpecVersion, d.SpecSha, d.Parent, tasks})
	return b.Bytes()
}
