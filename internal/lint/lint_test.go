package lint

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// One row per mechanical mistake the LOGIN-V2 review rediscovered round after round.
func TestRun(t *testing.T) {
	cfg := Config{GatePrefix: "Q", MarkerWords: []string{"pending", "conditional"}, ClosedWords: []string{"closed"}, RefPrefixes: []string{"D", "R"}}
	base := map[string]string{
		"spec.md":                  "#### Scenario: AC-X-1\n#### Scenario: AC-X-2 (pending Q1)\n#### Scenario: AC-X-3 (withdrawn)\n#### Scenario: AC-X-4\n",
		"prd.md":                   "| Q1 | what? | owner | AC-X-2, 4 |\n| Q2 | closed: done | - | - |\n- **R-1** rule. AC-X-1\n### D1 - decision\nSee D1 and R-1.\n",
		"tasks.md":                 "- [ ] 1.1 AC-X-1, 2, 4\n",
		"business-requirements.md": "<!-- sdkit: derived view of the spec -->\n| R1 | rule | AC-X-1, 2, 4 |\n",
	}
	cases := []struct{ name, file, from, to, want string }{
		{"clean", "", "", "", ""},
		{"duplicate AC", "spec.md", "AC-X-4\n", "AC-X-1\n", "ac-duplicate"},
		{"AC used, never defined", "prd.md", "See D1", "See AC-X-9 D1", "ac-undefined"},
		{"shorthand list expands", "tasks.md", "AC-X-1, 2, 4", "AC-X-1, 2, 7", "ac-undefined"},
		{"tasks.md misses an AC", "tasks.md", "AC-X-1, 2, 4", "AC-X-1, 2", "tasks-coverage"},
		{"withdrawn AC needs no task", "tasks.md", "AC-X-1, 2, 4", "AC-X-1, 2, 4", ""},
		{"marker names a closed question", "spec.md", "(pending Q1)", "(pending Q2)", "gate-closed"},
		{"marker names an unknown question", "spec.md", "(pending Q1)", "(pending Q9)", "gate-undefined"},
		{"row does not list the marked AC", "prd.md", "AC-X-2, 4", "AC-X-4", "gate-unlisted"},
		{"undefined reference", "prd.md", "See D1 and R-1.", "See D7 and R-1.", "ref-undefined"},
		{"business-requirements.md misses an AC", "business-requirements.md", "AC-X-1, 2, 4", "AC-X-1, 2", "br-coverage"},
		{"business-requirements.md without the marker", "business-requirements.md", "sdkit: derived view", "a view", "br-marker"},
		{"gap without withdrawn", "spec.md", "#### Scenario: AC-X-4", "#### Scenario: AC-X-6", "ac-gap"},
	}
	for _, c := range cases {
		dir := t.TempDir()
		for n, b := range base {
			if n == c.file {
				if !strings.Contains(b, c.from) {
					t.Fatalf("%s: fixture lacks %q", c.name, c.from)
				}
				b = strings.Replace(b, c.from, c.to, 1)
			}
			_ = os.WriteFile(filepath.Join(dir, n), []byte(b), 0o644)
		}
		ps, err := Run(dir, cfg)
		if err != nil {
			t.Fatal(err)
		}
		var codes []string
		for _, p := range ps {
			codes = append(codes, p.Code)
		}
		got := strings.Join(codes, " ")
		if c.want == "" && got != "" || c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("%s: got [%s], want %q", c.name, got, c.want)
		}
	}
}

// The role structure of tasks.md: one row per way a model-written file can miss the shape generate-specs asks for.
func TestTasksRoles(t *testing.T) {
	ok := "## 1. Login Feature\n### UI\n- [ ] 1.1 Design the form (AC-login-1)\n### Frontend\n- [ ] 1.2 Build the form (AC-login-1) | after: 1.1\n### Backend\n- [ ] 1.3 Check the credentials (AC-login-2)\n"
	picked := []string{"ui", "frontend", "backend"}
	cases := []struct {
		name, text string
		picked     []string
		want       string // "" = no problem
	}{
		{"valid", ok, picked, ""},
		{"flat list written before roles", "## 1. Login\n- [ ] 1.1 Form (AC-login-1)\n", picked, ""},
		{"no roles.json: not judged", strings.Replace(ok, "### UI", "### Whatever", 1), nil, ""},
		{"role the analyst did not pick", ok + "### Mobil\n- [ ] 1.4 App (AC-login-1)\n", picked, "tasks-role-unknown"},
		{"task before any role heading", strings.Replace(ok, "### UI\n", "- [ ] 1.0 Loose (AC-login-1)\n### UI\n", 1), picked, "tasks-no-role"},
		{"task without an AC", strings.Replace(ok, "(AC-login-2)", "", 1), picked, "tasks-no-ac"},
		{"after names a missing task", strings.Replace(ok, "after: 1.1", "after: 1.9", 1), picked, "tasks-after-undefined"},
		{"after cycle", strings.Replace(ok, "(AC-login-1)\n### Frontend", "(AC-login-1) | after: 1.2\n### Frontend", 1), picked, "tasks-after-cycle"},
		{"role listed twice in a feature", ok + "### UI\n- [ ] 1.4 Again (AC-login-1)\n", picked, "tasks-role-twice"},
		{"role heading with no task", ok + "### DevOps\n", append([]string{"devops"}, picked...), "tasks-role-empty"},
		{"duplicate task id", strings.Replace(ok, "1.3 Check", "1.2 Check", 1), picked, "tasks-duplicate-id"},
		{"same id in another change is fine", ok + "## Change: lock\n\n## 1. Lockout\n### Backend\n- [ ] 1.1 Count (AC-login-3)\n", picked, ""},
	}
	for _, c := range cases {
		got := ""
		for _, p := range CheckTasksMD("tasks.md", c.text, c.picked) {
			got += p.Code + " " + p.Msg + "\n"
		}
		if c.want == "" && got != "" || c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("%s: want %q, got:\n%s", c.name, c.want, got)
		}
	}
	d := ParseTasks(ok + "## Change: lock\n\n## 2. Lockout\n### Backend\n- [ ] 2.1 Count (AC-login-3, 4)\n")
	if len(d.Features) != 2 || d.Features[1].Change != "lock" || d.Features[1].Title != "Lockout" || len(d.Features[1].Sections[0].Tasks[0].ACs) != 2 {
		t.Errorf("parse: %+v", d.Features)
	}
}
