package tasks

import (
	"fmt"
	"strings"
	"testing"

	"github.com/wecii/sdkit/internal/lint"
	"github.com/wecii/sdkit/internal/testutil"
)

func TestCore(t *testing.T) {
	d, _ := Parse([]byte(`{"specId":"s1","tasks":[{"ref":"A","acceptanceCriteria":["AC-2","AC-1"],"scope":["src/b/","src/a/"],"dependsOn":["B"]},{"ref":"B","acceptanceCriteria":["AC-3"],"scope":["x"],"slug":"cs","change":"c1","dependsOn":["A"]}]}`))
	if err := d.Keys(); err != nil || d.Tasks[0].ExternalID != "s1:t739b2ae1f7" || d.Tasks[1].ExternalID != "s1:t399fafc96b" {
		t.Fatalf("ids %v %v", d.Tasks, err) // oracle hashes, incl. the collapsed empty slug of A
	}
	if _, cyc := d.Cycles(); cyc != "A -> B -> A" {
		t.Fatalf("cycle %q", cyc)
	}
	if _, p := d.Trace([]string{"AC-1", "AC-4"}); len(p) != 2 {
		t.Fatalf("trace %v", p)
	}
}

func TestWithdrawnIDs(t *testing.T) {
	text := "#### Scenario: AC-X-18 (withdrawn)\n- **WHEN** AC-X-18 is evaluated\n" +
		"#### Scenario: AC-X-22 (withdrawn) - old title\n" +
		"#### Scenario: AC-X-1\n- THEN replaces AC-X-18 and mentions (withdrawn)\n" +
		"#### Scenario: AC-X-5 (koşullu Q3)\n"
	got := withdrawnIDs(text)
	if len(got) != 2 || !got["AC-X-18"] || !got["AC-X-22"] {
		t.Fatalf("withdrawn = %v, want AC-X-18 and AC-X-22 only (prose mentions and other markers do not count)", got)
	}
}

func TestPlanCheck(t *testing.T) {
	// 39 tasks, 7 of them single-AC, the rest 2-14 ACs: the shape of the LOGIN-V2 plan that should have been 12-20 tasks
	sizes := []int{1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 12, 14}
	var b strings.Builder
	b.WriteString(`{"specId":"s","tasks":[`)
	n := 0
	for i, sz := range sizes {
		var acs []string
		for k := 0; k < sz; k++ {
			n++
			acs = append(acs, fmt.Sprintf("%q", fmt.Sprintf("AC-S-%d", n)))
		}
		dep := ""
		if i > 0 {
			dep = fmt.Sprintf(`,"dependsOn":["T%d"]`, i-1)
		}
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `{"ref":"T%d","risk":"medium","acceptanceCriteria":[%s],"scope":["app/form/"]%s}`, i, strings.Join(acs, ","), dep)
	}
	b.WriteString("]}")
	d, err := Parse([]byte(b.String()))
	if err != nil {
		t.Fatal(err)
	}
	text := func(ps []Advice) string {
		var s []string
		for _, a := range ps {
			s = append(s, a.Text)
		}
		return strings.Join(s, "\n")
	}
	got := text(d.PlanCheck(DefaultPlanCfg(), nil, "## Risk rubric\n| `high` | TODO |\n", nil))
	// 124 ACs at 4-12 per task allow 11-31 tasks; the configured 12-20 narrows it
	if !strings.Contains(got, "aim for 12-20") || !strings.Contains(got, "7 tasks carry a single AC") || !strings.Contains(got, "risk rubric") ||
		!strings.Contains(got, "merge:") || !strings.Contains(got, "chain:") {
		t.Fatalf("missing advice:\n%s", got)
	}
	if !d.PlanCheck(DefaultPlanCfg(), nil, "## Risk rubric\nTODO", nil)[0].Error {
		t.Fatal("an unfilled rubric is an error, not a warning")
	}
	g := GateMarkers("#### Scenario: AC-S-1 (pending Q1, conditional Q3)\n#### Scenario: AC-S-2 (withdrawn)\n#### Scenario: AC-S-3 (note)\n", []string{"pending", "conditional"})
	if len(g) != 1 || strings.Join(g["AC-S-1"], ",") != "Q1,Q3" {
		t.Fatalf("gates %v", g)
	}
}

func TestMerge(t *testing.T) {
	d, _ := Parse([]byte(`{"specId":"s","specSha":"x","tasks":[
	 {"ref":"A","risk":"low","acceptanceCriteria":["AC-1"],"scope":["a/"],"summary":"sa"},
	 {"ref":"B","risk":"high","acceptanceCriteria":["AC-2"],"scope":["a/"],"dependsOn":["A"],"summary":"sb"},
	 {"ref":"C","risk":"low","acceptanceCriteria":["AC-3"],"dependsOn":["B"]}]}`))
	if err := d.Merge([]string{"A", "B"}); err != nil {
		t.Fatal(err)
	}
	m := d.Tasks[0]
	if len(d.Tasks) != 2 || strings.Join(m.ACs, ",") != "AC-1,AC-2" || Str(m.Risk) != "high" || len(m.DependsOn) != 0 || Str(m.Summary) != "sa\n\nsb" || d.Tasks[1].DependsOn[0] != "A" {
		t.Fatalf("%+v", d.Tasks)
	}
	// A and C cannot merge when B (between them) stays outside: C depends on B depends on A
	d2, _ := Parse([]byte(`{"specId":"s","tasks":[{"ref":"A","acceptanceCriteria":["AC-1"]},{"ref":"B","acceptanceCriteria":["AC-2"],"dependsOn":["A"]},{"ref":"C","acceptanceCriteria":["AC-3"],"dependsOn":["B"]}]}`))
	if err := d2.Merge([]string{"A", "C"}); err == nil || len(d2.Tasks) != 3 {
		t.Fatalf("a merge that makes a cycle must be refused and leave the plan alone: %v", err)
	}
}

func TestRoles(t *testing.T) {
	plan := func(tasks string) *Doc {
		d, err := Parse([]byte(`{"specId":"s","tasks":[` + tasks + `]}`))
		if err != nil {
			t.Fatal(err)
		}
		return d
	}
	grp := `{"ref":"X","risk":"low","acceptanceCriteria":["AC-1","AC-2"]}`
	cases := []struct {
		name, tasks string
		roles       []string
		want        string // substring of the advice ("" = none), "error:" prefix = must be an error
	}{
		{"legacy plan without roles is not judged", grp, nil, ""},
		{"complete split", grp + `,{"ref":"X1","of":"X","area":"backend","acceptanceCriteria":["AC-1"]},{"ref":"X2","of":"X","area":"qa","acceptanceCriteria":["AC-1"],"dependsOn":["X1"]}`, []string{"backend", "qa"}, ""},
		{"group without subtasks", grp, []string{"backend"}, "has no role subtask"},
		{"role the spec did not pick", grp + `,{"ref":"X1","of":"X","area":"mobil","acceptanceCriteria":["AC-1"]}`, []string{"backend"}, "error:area: task X1 has role"},
		{"subtask without area", grp + `,{"ref":"X1","of":"X","acceptanceCriteria":["AC-1"]}`, []string{"backend"}, "error:area: role subtask X1"},
		{"subtask AC outside its group", grp + `,{"ref":"X1","of":"X","area":"backend","acceptanceCriteria":["AC-9"]}`, []string{"backend"}, "error:ac: X1 lists AC-9"},
		{"qa must come last", grp + `,{"ref":"X1","of":"X","area":"backend","acceptanceCriteria":["AC-1"]},{"ref":"X2","of":"X","area":"qa","acceptanceCriteria":["AC-1"]}`, []string{"backend", "qa"}, "missing X1"},
		{"picked role with no work", grp + `,{"ref":"X1","of":"X","area":"backend","acceptanceCriteria":["AC-1"]}`, []string{"backend", "ux"}, "picked ux"},
	}
	for _, c := range cases {
		var got string
		for _, a := range plan(c.tasks).roleAdvice(c.roles) {
			if a.Error {
				got += "error:"
			}
			got += a.Text + "\n"
		}
		if c.want == "" && got != "" || c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("%s: want %q in:\n%s", c.name, c.want, got)
		}
	}
	// the hash of a task without an area is unchanged; a subtask with the same ACs gets its own id
	d := plan(grp + `,{"ref":"X1","of":"X","area":"backend","acceptanceCriteria":["AC-1","AC-2"]}`)
	if err := d.Keys(); err != nil || d.Tasks[0].ExternalID == d.Tasks[1].ExternalID {
		t.Fatalf("ids %v %v", d.Tasks, err)
	}
	// a subtask is created after its group, and renders under the group's Jira key
	if o := d.Order(); strings.Join(o, "") != "XX1" {
		t.Fatalf("order %v", o)
	}
	u, _ := d.Render("X1", map[string]string{d.Tasks[0].ExternalID: "TFF-7"})
	if u.Parent != "TFF-7" || u.Area != "backend" || !strings.HasPrefix(u.Summary, "[backend]") {
		t.Fatalf("%+v", u)
	}
	if g, _ := d.Render("X", nil); !g.Group {
		t.Fatal("a task with role subtasks is a group")
	}
}

// The draft of generate-tasks from the role structure of tasks.md: group per feature, subtask per role, after: as dependencies.
func TestOutline(t *testing.T) {
	md := "## 1. Login\n### UI\n- [ ] 1.1 Design the form (AC-login-1)\n### Frontend\n- [ ] 1.2 Build the form (AC-login-1) | after: 1.1\n" +
		"### QA\n- [ ] 1.3 Test the form (AC-login-1, AC-login-2)\n### Backend\n- [ ] 1.4 Check the credentials (AC-login-2)\n" +
		"## 2. Lockout\n### Backend\n- [ ] 2.1 Count failures (AC-login-3) | after: 1.4\n" +
		"## Change: reset\n\n## 1. Reset\n### Backend\n- [ ] 1.1 Send the link (AC-login-5)\n"
	got := Outline(lint.ParseTasks(md), nil)
	by := map[string]OutTask{}
	for _, o := range got {
		by[o.Ref] = o
	}
	for _, c := range []struct {
		ref, deps, acs string
	}{
		{"G1", "", "AC-login-1,AC-login-2"},
		{"G1-frontend", "G1-ui", "AC-login-1"},
		{"G1-qa", "G1-ui,G1-frontend,G1-backend", "AC-login-1,AC-login-2"}, // qa last: after every other subtask of its group
		{"G2", "G1", "AC-login-3"},                                         // an after: across features is a group dependency
		{"G2-backend", "G1-backend", "AC-login-3"},
	} {
		o, ok := by[c.ref]
		if !ok || strings.Join(o.DependsOn, ",") != c.deps || strings.Join(o.ACs, ",") != c.acs {
			t.Errorf("%s: %+v", c.ref, o)
		}
	}
	if _, ok := by["G3"]; ok || len(got) != 7 {
		t.Errorf("the base outline leaves a change's tasks out: %d tasks", len(got))
	}
	ch := Outline(lint.ParseTasks(md), []string{"reset"})
	if len(ch) != 2 || ch[0].Change != "reset" || ch[1].Area != "backend" || ch[0].Risk == nil {
		t.Errorf("revision outline: %+v", ch)
	}
}

// The Jira description: short by default, more only where the task asks for it, and every quoted word comes from the spec.
func TestDescribe(t *testing.T) {
	spec := "#### Scenario: AC-login-1 Giriş formu\n- **WHEN** kullanıcı e-posta ve parolayı girer\n- **THEN** form gönderilir\n\n" +
		"#### Scenario: AC-login-2 Doğrulama (pending Q1)\n- **THEN** servis sonucu döner\n- **THEN** ikinci cümle\n"
	md := "## 1. Giriş\n### UI\n- [ ] 1.1 Giriş formunu tasarla (AC-login-1)\n### Frontend\n- [ ] 1.2 Giriş formunu kodla (AC-login-1) | after: 1.1\n- [ ] 1.3 Hata mesajını göster (AC-login-2)\n"
	sp := &SpecText{Path: "specs/login", Version: "1.0", Sha: "4e11e82219307441aaa6627210cf97509336eda8", ACs: ParseACTexts(spec), Steps: StepTexts(md)}
	d, _ := Parse([]byte(`{"specId":"login","specVersion":"1.0","tasks":[
 {"ref":"U","of":"G","area":"ui","title":"Giriş formunu tasarla","acceptanceCriteria":["AC-login-1"],"steps":["1.1"]},
 {"ref":"F","of":"G","area":"frontend","title":"Giriş formu ve hata mesajı","summary":"Kullanıcı giriş yapabilmeli.","acceptanceCriteria":["AC-login-1","AC-login-2"],"steps":["1.2","1.3"],"dependsOn":["U"]},
 {"ref":"G","title":"Giriş","acceptanceCriteria":["AC-login-1","AC-login-2"]}]}`))
	_ = d.Keys()
	render := func(ref string, mut func(*Task)) string {
		for i := range d.Tasks {
			if d.Tasks[i].Ref == ref {
				c := d.Tasks[i]
				if mut != nil {
					mut(&c)
				}
				d2 := *d
				d2.Tasks = append([]Task{}, d.Tasks...)
				d2.Tasks[i] = c
				u, _, err := d2.RenderWith(ref, map[string]string{d.Tasks[0].ExternalID: "PROJ-14"}, sp, "tr")
				if err != nil {
					return "ERR " + err.Error()
				}
				return u.Description
			}
		}
		return ""
	}
	for _, c := range []struct {
		name, got, want string
	}{
		{"default: only the steps", render("U", nil), "Yapılacaklar:\n- Giriş formunu tasarla"},
		{"summary sentence first, steps without AC ids", render("F", nil), "Kullanıcı giriş yapabilmeli.\n\nYapılacaklar:\n- Giriş formunu kodla\n- Hata mesajını göster"},
		{"acs quote the first THEN of the spec", render("F", func(x *Task) { x.Include = []string{"acs"} }), "Bitti sayılır:\n- AC-login-1 · Giriş formu: form gönderilir\n- AC-login-2 · Doğrulama: servis sonucu döner"},
		{"after names the dependency with its Jira key", render("F", func(x *Task) { x.Include = []string{"after"} }), "Önce bitmesi gerekenler:\n- PROJ-14 · [ui] Giriş formunu tasarla"},
		{"source", render("U", func(x *Task) { x.Include = []string{"source"} }), "Kaynak: specs/login v1.0 (4e11e82)"},
		{"a step the spec does not have", render("U", func(x *Task) { x.Steps = []string{"9.9"} }), "ERR task U: step 9.9"},
		{"an include nobody knows", render("U", func(x *Task) { x.Include = []string{"all"} }), "ERR task U: include \"all\""},
		{"a group with no steps is its sentence", render("G", func(x *Task) { x.Summary = "Giriş akışı." }), "Giriş akışı."},
	} {
		if !strings.Contains(c.got, c.want) {
			t.Errorf("%s: want %q in:\n%s", c.name, c.want, c.got)
		}
	}
	rk, _ := Parse([]byte(`{"tasks":[{"ref":"G","risk":"medium"},{"ref":"S","of":"G","area":"backend"},{"ref":"T","of":"G","area":"qa","risk":"low"}]}`))
	if r := riskOf(rk, &rk.Tasks[1]); r != "medium" {
		t.Errorf("a subtask without a risk takes its group's: %v", r)
	}
	if r := riskOf(rk, &rk.Tasks[2]); r != "low" {
		t.Errorf("a subtask's own risk stays: %v", r)
	}
	if strings.Contains(render("U", nil), "AC-login") {
		t.Error("the default description must not carry AC ids")
	}
}

func TestDescribeAdvice(t *testing.T) {
	sp := &SpecText{Steps: map[string]string{"\x001.1": "x"}}
	d, _ := Parse([]byte(`{"tasks":[{"ref":"A","steps":["1.1","7.7"],"include":["acs","nope"],"summary":"` + strings.Repeat("x", 301) + `"}]}`))
	got := ""
	for _, a := range d.DescribeAdvice(sp) {
		got += a.Text + "\n"
	}
	for _, w := range []string{"step 7.7", `"nope"`, "301 characters"} {
		if !strings.Contains(got, w) {
			t.Errorf("want %q in:\n%s", w, got)
		}
	}
}

// The example task-format.md quotes: a role subtask with all three optional sections.
func TestDescribeGolden(t *testing.T) {
	spec := "#### Scenario: AC-login-1 Giriş formu\n- **THEN** form gönderilir\n#### Scenario: AC-login-3 Hesap kilidi\n- **THEN** 5 hatalı denemeden sonra hesap 15 dakika kilitlenir\n"
	md := "## 1. Giriş\n### UI\n- [ ] 1.1 Giriş formunu tasarla (AC-login-1)\n### Frontend\n- [ ] 1.2 Giriş formunu ve kilit mesajını kodla (AC-login-1, AC-login-3) | after: 1.1\n"
	d, _ := Parse([]byte(`{"specId":"login","specVersion":"1.0","tasks":[
 {"ref":"U","of":"G","area":"ui","title":"Giriş formunu tasarla","acceptanceCriteria":["AC-login-1"],"steps":["1.1"]},
 {"ref":"F","of":"G","area":"frontend","title":"Giriş formunu kodla","summary":"Kullanıcılar e-posta ve parola ile giriş yapabilmeli.","acceptanceCriteria":["AC-login-1","AC-login-3"],"steps":["1.2"],"dependsOn":["U"],"include":["acs","after","source"]},
 {"ref":"G","title":"Giriş","acceptanceCriteria":["AC-login-1","AC-login-3"]}]}`))
	_ = d.Keys()
	sp := &SpecText{Path: "specs/login", Version: "1.0", Sha: "4e11e82219307441aaa6627210cf97509336eda8", ACs: ParseACTexts(spec), Steps: StepTexts(md)}
	u, _, err := d.RenderWith("F", map[string]string{d.Tasks[0].ExternalID: "PROJ-14"}, sp, "tr")
	if err != nil {
		t.Fatal(err)
	}
	testutil.Golden(t, "tasks/description", u.Summary+"\n\n"+u.Description+"\n")
}
