package tasks

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/wecii/sdkit/internal/lint"
)

// A Jira task is read by a person in a glance: a title that says what to do, and a description with the steps and, only where the
// task is unclear without them, three optional sections. Everything quoted from the spec is read from the spec at the pinned SHA by
// this code, never retyped by a model, so the description cannot drift from the single source of truth.
//
// Default description: the one-sentence summary (if any) and "To do" (the task's own lines of tasks.md). A task opts into more with
// include: "acs" (the ACs that mean done, title and THEN), "after" (what must be done first), "source" (spec path, version, SHA).

// Include values a task may carry.
var includeAllowed = map[string]bool{"acs": true, "after": true, "source": true}

// maxACLines caps the "done when" list; the rest is a pointer to the spec.
const maxACLines = 6

// ACText is what the spec says about one acceptance criterion: the scenario title and the first THEN.
type ACText struct{ Title, Then string }

// SpecText is the part of the spec at the SHA that a description quotes.
type SpecText struct {
	Path, Version, Sha string
	ACs                map[string]ACText
	Steps              map[string]string // change slug + "\x00" + task id -> the line's text without its AC ids
}

var (
	reScenario = regexp.MustCompile(`^#{3,6}[ \t]+Scenario:[ \t]*(AC-[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*)[ \t]*[-:]?[ \t]*(.*)$`)
	reThen     = regexp.MustCompile(`\*\*THEN\*\*[ \t]*(.*)$`)
	reACTail   = regexp.MustCompile(`[ \t]*\((?:[^()]*\bAC-[^()]*)\)[ \t]*$`)
	reParen    = regexp.MustCompile(`[ \t]*\([^()]*\)[ \t]*$`)
)

// ParseACTexts reads the scenarios of a spec text: `#### Scenario: AC-x-1 Title` and the first `**THEN**` line under it.
func ParseACTexts(spec string) map[string]ACText {
	out := map[string]ACText{}
	cur := ""
	for _, l := range strings.Split(strings.ReplaceAll(spec, "\r\n", "\n"), "\n") {
		if m := reScenario.FindStringSubmatch(l); m != nil {
			cur = m[1]
			t := strings.TrimSpace(reParen.ReplaceAllString(strings.TrimSpace(m[2]), ""))
			out[cur] = ACText{Title: t}
			continue
		}
		if strings.HasPrefix(l, "#") {
			cur = ""
			continue
		}
		if cur == "" {
			continue
		}
		if m := reThen.FindStringSubmatch(l); m != nil {
			if a := out[cur]; a.Then == "" {
				a.Then = strings.TrimSpace(m[1])
				out[cur] = a
			}
		}
	}
	return out
}

// StepTexts maps every task line of a tasks.md to its text, AC ids removed, keyed by change slug and id.
func StepTexts(tasksMD string) map[string]string {
	out := map[string]string{}
	for _, f := range lint.ParseTasks(tasksMD).Features {
		add := func(ts []lint.TaskLine) {
			for _, t := range ts {
				out[f.Change+"\x00"+t.ID] = strings.TrimSpace(reACTail.ReplaceAllString(t.Text, ""))
			}
		}
		add(f.Loose)
		for _, s := range f.Sections {
			add(s.Tasks)
		}
	}
	return out
}

type labels struct{ todo, done, after, source, more string }

func labelsFor(lang string) labels {
	if strings.HasPrefix(strings.ToLower(lang), "tr") {
		return labels{"Yapılacaklar:", "Bitti sayılır:", "Önce bitmesi gerekenler:", "Kaynak:", "ve %d tane daha (spec'e bakın)"}
	}
	return labels{"To do:", "Done when:", "Do first:", "Source:", "and %d more (see the spec)"}
}

// summaryOf is the Jira summary of a task: its title (or its externalId), with the role in front for a role subtask.
func summaryOf(t Task) string {
	s := t.ExternalID
	if t.Title != nil && t.Title != false {
		s = Str(t.Title)
	}
	if t.Area != "" {
		s = "[" + t.Area + "] " + s
	}
	return s
}

// describe builds the description of t: the Blocked line, the summary sentence, "To do", then the sections t asked for.
func (d *Doc) describe(t Task, keys map[string]string, sp *SpecText, lang string) (string, error) {
	lb := labelsFor(lang)
	var parts []string
	if len(t.BlockedBy) > 0 {
		parts = append(parts, "Blocked: "+strings.Join(t.BlockedBy, ", "))
	}
	if s := strings.TrimSpace(Str(t.Summary)); s != "" {
		parts = append(parts, s)
	}
	if sp == nil && (len(t.Steps) > 0 || len(t.Include) > 0) {
		return "", fmt.Errorf("task %s has steps or include but no spec text was given", t.Ref)
	}
	change := Str(t.Change)
	if len(t.Steps) > 0 {
		sec := []string{lb.todo}
		for _, id := range t.Steps {
			txt, ok := sp.Steps[change+"\x00"+id]
			if !ok {
				return "", fmt.Errorf("task %s: step %s is not a task of tasks.md at the pinned SHA", t.Ref, id)
			}
			sec = append(sec, "- "+txt)
		}
		parts = append(parts, strings.Join(sec, "\n"))
	}
	for _, in := range t.Include {
		switch in {
		case "acs":
			sec := []string{lb.done}
			for i, ac := range t.ACs {
				if i == maxACLines {
					sec = append(sec, "- "+fmt.Sprintf(lb.more, len(t.ACs)-maxACLines))
					break
				}
				x, ok := sp.ACs[ac]
				if !ok {
					return "", fmt.Errorf("task %s: %s is not in the spec at the pinned SHA", t.Ref, ac)
				}
				line := ac
				if x.Title != "" {
					line += " · " + x.Title
				}
				if x.Then != "" {
					line += ": " + x.Then
				}
				sec = append(sec, "- "+line)
			}
			if len(sec) > 1 {
				parts = append(parts, strings.Join(sec, "\n"))
			}
		case "after":
			byRef := map[string]Task{}
			for _, o := range d.Tasks {
				byRef[o.Ref] = o
			}
			sec := []string{lb.after}
			for _, dep := range t.DependsOn {
				o, ok := byRef[dep]
				if !ok {
					continue
				}
				id := o.ExternalID
				if k := keys[o.ExternalID]; k != "" {
					id = k
				}
				sec = append(sec, "- "+id+" · "+summaryOf(o))
			}
			if len(sec) > 1 {
				parts = append(parts, strings.Join(sec, "\n"))
			}
		case "source":
			sha := sp.Sha
			if len(sha) > 7 {
				sha = sha[:7]
			}
			parts = append(parts, lb.source+" "+sp.Path+" v"+sp.Version+" ("+sha+")")
		default:
			return "", fmt.Errorf("task %s: include %q is not one of acs, after, source", t.Ref, in)
		}
	}
	return strings.Join(parts, "\n\n"), nil
}

// DescribeAdvice judges what describe needs of a plan: every step exists in tasks.md at the SHA, every include is known, and a
// summary stays one sentence long.
func (d *Doc) DescribeAdvice(sp *SpecText) []Advice {
	var out []Advice
	for _, t := range d.Tasks {
		change := Str(t.Change)
		for _, id := range t.Steps {
			if sp == nil {
				break
			}
			if _, ok := sp.Steps[change+"\x00"+id]; !ok {
				out = append(out, Advice{true, fmt.Sprintf("steps: task %s names step %s, which is not a task of tasks.md at the pinned SHA.", t.Ref, id)})
			}
		}
		for _, in := range t.Include {
			if !includeAllowed[in] {
				out = append(out, Advice{true, fmt.Sprintf("include: task %s has %q; use acs, after or source.", t.Ref, in)})
			}
		}
		if n := len([]rune(strings.TrimSpace(Str(t.Summary)))); n > 300 {
			out = append(out, Advice{false, fmt.Sprintf("summary: task %s has %d characters; keep it to one sentence, the description should be read at a glance.", t.Ref, n)})
		}
	}
	return out
}
