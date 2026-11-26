package lint

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// A tasks.md written by generate-specs groups its tasks by feature and then by the role that does them:
//
//	## 1. Login Feature
//	### UI
//	- [ ] 1.1 Design the form (AC-login-1)
//	### Frontend
//	- [ ] 1.2 Build the form (AC-login-1) | after: 1.1
//
// A change appended by `sdkit spec apply` sits under `## Change: <slug>`; its features follow at the same level. The role of a
// section is its heading, lower-cased, spaces as hyphens; only roles the analyst picked (roles.json) are allowed.

// TaskLine is one checklist item.
type TaskLine struct {
	ID, Text string
	ACs      []string // as written, sorted, withdrawn ids included
	After    []string // task ids it waits for
	Line     int
}

// RoleSection is the tasks one role has in one feature.
type RoleSection struct {
	Role  string
	Line  int
	Tasks []TaskLine
}

// Feature is a `## n. Title` group; Change is the slug of the `## Change:` section it sits in ("" for the base).
type Feature struct {
	Title, Change string
	Line          int
	Sections      []RoleSection
	Loose         []TaskLine // tasks before any role heading
}

// TasksDoc is a parsed tasks.md.
type TasksDoc struct{ Features []Feature }

var (
	taskRe  = regexp.MustCompile(`^[ \t]*- \[[ xX]\] +(\S+)[ \t]*(.*)$`)
	numRe   = regexp.MustCompile(`^\d+(?:\.\d+)*\.?[ \t]+`)
	afterRe = regexp.MustCompile(`^after:[ \t]*(.*)$`)
)

// RoleSlug turns a heading ("Solution Architect") into a role name ("solution-architect").
func RoleSlug(h string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(h)), " ", "-")
}

// ParseTasks reads a tasks.md. Text that is neither a heading nor a checklist item is ignored.
func ParseTasks(text string) *TasksDoc {
	d := &TasksDoc{}
	change := ""
	for i, l := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		switch {
		case strings.HasPrefix(l, "### "):
			if n := len(d.Features); n > 0 {
				f := &d.Features[n-1]
				f.Sections = append(f.Sections, RoleSection{Role: RoleSlug(l[4:]), Line: i + 1})
			}
		case strings.HasPrefix(l, "## "):
			h := strings.TrimSpace(l[3:])
			if rest, ok := strings.CutPrefix(h, "Change:"); ok {
				change = strings.TrimSpace(rest)
				continue
			}
			d.Features = append(d.Features, Feature{Title: numRe.ReplaceAllString(h, ""), Change: change, Line: i + 1})
		default:
			m := taskRe.FindStringSubmatch(l)
			if m == nil || len(d.Features) == 0 {
				continue
			}
			t := TaskLine{ID: strings.TrimRight(m[1], "."), Line: i + 1}
			parts := strings.Split(m[2], "|")
			t.Text = strings.TrimSpace(parts[0])
			for _, p := range parts[1:] {
				if a := afterRe.FindStringSubmatch(strings.TrimSpace(p)); a != nil {
					for _, id := range strings.FieldsFunc(a[1], func(r rune) bool { return r == ',' || r == ' ' }) {
						t.After = append(t.After, strings.TrimRight(id, "."))
					}
				}
			}
			seen := map[string]bool{}
			for _, tok := range acRe.FindAllString(m[2], -1) {
				for _, id := range expand(tok) {
					if !seen[id] {
						seen[id] = true
						t.ACs = append(t.ACs, id)
					}
				}
			}
			sort.Strings(t.ACs)
			f := &d.Features[len(d.Features)-1]
			if n := len(f.Sections); n > 0 {
				f.Sections[n-1].Tasks = append(f.Sections[n-1].Tasks, t)
			} else {
				f.Loose = append(f.Loose, t)
			}
		}
	}
	return d
}

// CheckTasksMD judges the role structure of a tasks.md against the roles the analyst picked. picked empty (no roles.json) or a file
// with no role heading at all (written before roles) is not judged: nothing published earlier starts to fail.
func CheckTasksMD(file, text string, picked []string) []Problem {
	if len(picked) == 0 {
		return nil
	}
	d := ParseTasks(text)
	pk := map[string]bool{}
	for _, r := range picked {
		pk[r] = true
	}
	roleMode := false
	for _, f := range d.Features {
		for _, s := range f.Sections {
			roleMode = roleMode || pk[s.Role]
		}
	}
	if !roleMode {
		return nil
	}
	var ps []Problem
	bad := func(code string, line int, f string, a ...any) {
		ps = append(ps, Problem{"error", code, file, line, fmt.Sprintf(f, a...)})
	}
	type key struct{ change, id string }
	ids := map[key]TaskLine{}
	var all []struct {
		key
		t TaskLine
	}
	check := func(f Feature, t TaskLine) {
		k := key{f.Change, t.ID}
		if prev, dup := ids[k]; dup {
			bad("tasks-duplicate-id", t.Line, "task id %s is used twice (first at line %d)", t.ID, prev.Line)
		}
		ids[k] = t
		all = append(all, struct {
			key
			t TaskLine
		}{k, t})
		if len(t.ACs) == 0 {
			bad("tasks-no-ac", t.Line, "task %s names no acceptance criterion", t.ID)
		}
	}
	for _, f := range d.Features {
		for _, t := range f.Loose {
			bad("tasks-no-role", t.Line, "task %s in '%s' sits under no role heading (### <role>)", t.ID, f.Title)
			check(f, t)
		}
		seen := map[string]int{}
		for _, s := range f.Sections {
			if !pk[s.Role] {
				bad("tasks-role-unknown", s.Line, "'### %s' is not a role this spec picked (%s)", s.Role, strings.Join(picked, ", "))
			}
			if first, dup := seen[s.Role]; dup {
				bad("tasks-role-twice", s.Line, "role %s appears twice in '%s' (first at line %d): one section per role", s.Role, f.Title, first)
			}
			seen[s.Role] = s.Line
			if len(s.Tasks) == 0 {
				bad("tasks-role-empty", s.Line, "role %s in '%s' has no task: drop the heading", s.Role, f.Title)
			}
			for _, t := range s.Tasks {
				check(f, t)
			}
		}
	}
	graph := map[key][]key{}
	for _, a := range all {
		for _, id := range a.t.After {
			k := key{a.change, id}
			if _, ok := ids[k]; !ok {
				bad("tasks-after-undefined", a.t.Line, "task %s waits for %s, which is not a task here", a.t.ID, id)
				continue
			}
			graph[a.key] = append(graph[a.key], k)
		}
	}
	state := map[key]int{}
	var walk func(key) string
	walk = func(k key) string {
		state[k] = 1
		for _, n := range graph[k] {
			if state[n] == 1 {
				return n.id
			}
			if state[n] == 0 {
				if c := walk(n); c != "" {
					return c
				}
			}
		}
		state[k] = 2
		return ""
	}
	for _, a := range all {
		if state[a.key] == 0 {
			if c := walk(a.key); c != "" {
				bad("tasks-after-cycle", a.t.Line, "task %s is part of an after: cycle (through %s)", a.t.ID, c)
				break
			}
		}
	}
	return ps
}

// pickedRoles reads roles.json ({"roles":[...]}) of a spec directory; none when it is absent.
func pickedRoles(dir string) []string {
	b, err := os.ReadFile(filepath.Join(dir, "roles.json"))
	if err != nil {
		return nil
	}
	var f struct {
		Roles []string `json:"roles"`
	}
	_ = json.Unmarshal(b, &f)
	return f.Roles
}

// PickedRoles is the roles a spec directory picked (roles.json), for callers that judge a change's tasks.md.
func PickedRoles(dir string) []string { return pickedRoles(dir) }

func checkTaskRoles(files []file, target string) []Problem {
	st, err := os.Stat(target)
	if err != nil || !st.IsDir() {
		return nil
	}
	for _, f := range files {
		if f.rel == "tasks.md" {
			return CheckTasksMD(f.rel, strings.Join(f.lines, "\n"), pickedRoles(target))
		}
	}
	return nil
}
