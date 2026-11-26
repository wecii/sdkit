package tasks

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"sort"
	"strings"

	"github.com/wecii/sdkit/internal/gitx"
	"github.com/wecii/sdkit/internal/lint"
)

// Exit codes: 0 ok, 1 check failed, 2 usage, 3 not approved / spec unreadable, 4 task contract invalid.
const (
	exitFail     = 1
	exitUsage    = 2
	exitApproval = 3
	exitContract = 4
)

// Env is what the verbs need from outside. Approve says whether the spec at the SHA is an
// approved SHA (spec approved-sha); Validate checks a rendered task against the Jira contract
// (jira validate-task) and returns its message.
type Env struct {
	Repo     string // git repo holding the specs
	SpecPath string // directory of the specs, default "specs"
	Approve  func(id, sha string) bool
	Validate func(text string) (string, bool)
	Plan     PlanCfg // size rules for plan-check
	Project  string  // text of project.md (the risk rubric)
	Lang     string  // ANALYST_LANGUAGE: the language of the labels in a Jira description (tr, en)
	Stdin    io.Reader
	Out, Err io.Writer
}

type runner struct {
	Env
	doc *Doc
}

var sha40 = regexp.MustCompile(`^[0-9a-f]{40}$`)

const usage = "usage: sdkit tasks acs|changes|roles|outline|trace|cycles|ids|order|plan-check|regroup|render|report <tasks.json> ..."

// Run executes `sdkit tasks <verb> <tasks.json> ...` and returns the exit code.
func Run(env Env, args []string) int {
	r := &runner{Env: env}
	if r.SpecPath == "" {
		r.SpecPath = "specs"
	}
	die := func(code int, format string, a ...any) int {
		fmt.Fprintf(r.Err, "tasks: "+format+"\n", a...)
		return code
	}
	if len(args) < 2 || args[0] == "" {
		fmt.Fprintln(r.Err, usage)
		return exitUsage
	}
	verb, file, rest := args[0], args[1], args[2:]
	data, err := os.ReadFile(file)
	if err != nil {
		fmt.Fprintln(r.Err, usage)
		return exitUsage
	}
	if r.doc, err = Parse(data); err != nil {
		return die(exitUsage, "%v", err)
	}
	d := r.doc
	if !strings.Contains(" acs changes roles outline trace cycles ids order plan-check regroup render report ", " "+verb+" ") {
		return die(exitUsage, "unknown verb %s", verb)
	}
	if verb != "cycles" && verb != "regroup" {
		if code := r.gate(); code != 0 {
			return code
		}
	}
	switch verb {
	case "cycles":
		return r.cycles(true)
	case "roles":
		fmt.Fprint(r.Out, lines(r.roles()))
	case "outline":
		// outline <tasks.json> [--revision] [--out FILE]: draft the group tasks and role subtasks from the role structure of tasks.md at the SHA
		rev, out := false, ""
		for i := 0; i < len(rest); i++ {
			switch {
			case rest[i] == "--revision":
				rev = true
			case rest[i] == "--out" && i+1 < len(rest):
				out, i = rest[i+1], i+1
			default:
				fmt.Fprintln(r.Err, "tasks: usage: outline <tasks.json> [--revision] [--out FILE]")
				return exitUsage
			}
		}
		text := r.show(r.dir() + "/tasks.md")
		td := lint.ParseTasks(text)
		if strings.TrimSpace(text) == "" || !hasRoleSection(td) {
			return die(exitFail, "tasks.md at %s has no role headings (a spec made before roles): derive the tasks by hand", d.SpecSha)
		}
		var changes []string
		if rev {
			if changes = r.revChanges(); len(changes) == 0 {
				return die(exitFail, "no change was applied in this revision: outline without --revision")
			}
		}
		ot := Outline(td, changes)
		if len(ot) == 0 {
			return die(exitFail, "tasks.md has no feature to outline")
		}
		if out == "" {
			fmt.Fprint(r.Out, string(outlineJSON(d, ot)))
		} else if err := os.WriteFile(out, outlineJSON(d, ot), 0o644); err != nil {
			return die(exitFail, "cannot write %s", out)
		}
	case "changes":
		fmt.Fprint(r.Out, lines(r.revChanges()))
	case "acs":
		rev, inc := false, false
		for _, f := range rest {
			switch f {
			case "--revision":
				rev = true
			case "--include-withdrawn":
				inc = true
			default:
				fmt.Fprintln(r.Err, "tasks: usage: acs <tasks.json> [--revision] [--include-withdrawn]")
				return exitUsage
			}
		}
		if rev {
			fmt.Fprint(r.Out, lines(r.revisionACs()))
		} else {
			fmt.Fprint(r.Out, lines(r.allACs(inc)))
		}
	case "trace":
		if len(rest) == 0 || rest[0] == "" {
			fmt.Fprintln(r.Err, "tasks: usage: trace <tasks.json> <ac-list|->")
			return exitUsage
		}
		var in []byte
		if rest[0] == "-" {
			in, _ = io.ReadAll(r.Stdin)
		} else if in, err = os.ReadFile(rest[0]); err != nil {
			return die(exitUsage, "no such file: %s", rest[0])
		}
		set := map[string]bool{}
		for _, a := range strings.FieldsFunc(string(in), func(c rune) bool { return c == ',' || c == ' ' || c == '\t' || c == '\n' }) {
			set[a] = true
		}
		if len(set) == 0 {
			return die(exitFail, "empty AC list")
		}
		// A withdrawn AC is not tested, so it needs no task; --include-withdrawn keeps the old, stricter list.
		if len(rest) < 2 || rest[1] != "--include-withdrawn" {
			for w := range withdrawnIDs(r.text(true)) {
				delete(set, w)
			}
		}
		ok, problems := d.Trace(keys(set))
		for _, p := range problems {
			fmt.Fprintln(r.Err, p)
		}
		if len(problems) > 0 {
			return exitFail
		}
		fmt.Fprintln(r.Out, ok)
	case "ids":
		if len(rest) > 0 && rest[0] == "--list" { // ref<TAB>externalId, one per line: what the name promises
			if err := d.Keys(); err != nil {
				fmt.Fprintln(r.Err, err)
				return exitFail
			}
			for _, t := range d.Tasks {
				fmt.Fprintf(r.Out, "%s\t%s\n", t.Ref, t.ExternalID)
			}
			return 0
		}
		out, err := d.IDs()
		if err != nil {
			fmt.Fprintln(r.Err, err)
			return exitFail
		}
		fmt.Fprintln(r.Out, string(out))
	case "order":
		if code := r.cycles(false); code != 0 {
			return code
		}
		fmt.Fprint(r.Out, lines(d.Order()))
	case "regroup":
		// regroup <tasks.json> --merge A,B,C [--merge D,E] [--out FILE]: merge tasks of the plan (local file only; nothing is sent anywhere)
		out := ""
		for i := 0; i < len(rest); i++ {
			switch {
			case rest[i] == "--merge" && i+1 < len(rest):
				if err := d.Merge(strings.Split(rest[i+1], ",")); err != nil {
					return die(exitFail, "%v", err)
				}
				i++
			case rest[i] == "--out" && i+1 < len(rest):
				out, i = rest[i+1], i+1
			default:
				fmt.Fprintln(r.Err, "tasks: usage: regroup <tasks.json> --merge A,B,C [--merge D,E] [--out FILE]")
				return exitUsage
			}
		}
		if out == "" {
			fmt.Fprintln(r.Out, d.PlanJSON())
		} else if err := os.WriteFile(out, []byte(d.PlanJSON()+"\n"), 0o644); err != nil {
			return die(exitFail, "cannot write %s", out)
		}
	case "plan-check":
		adv := d.PlanCheck(r.Plan, GateMarkers(r.text(false), r.Plan.MarkerWords), r.Project, r.roles())
		adv = append(adv, d.DescribeAdvice(r.specText())...)
		code := 0
		for _, a := range adv {
			tag := "warn"
			if a.Error {
				tag, code = "error", exitFail
			}
			fmt.Fprintf(r.Out, "plan-check: %s: %s\n", tag, a.Text)
		}
		if len(adv) == 0 {
			fmt.Fprintln(r.Out, "plan-check: ok")
		}
		return code
	case "render":
		return r.render(rest)
	case "report":
		return r.report(rest)
	}
	return 0
}

func lines(s []string) string {
	if len(s) == 0 {
		return ""
	}
	return strings.Join(s, "\n") + "\n"
}

func keys(m map[string]bool) []string {
	var o []string
	for k := range m {
		o = append(o, k)
	}
	sort.Strings(o)
	return o
}

func (r *runner) cycles(say bool) int {
	unknown, cycle := r.doc.Cycles()
	switch {
	case unknown != "":
		fmt.Fprintln(r.Err, "tasks: unknown dependency: "+unknown)
	case cycle != "":
		fmt.Fprintln(r.Err, "tasks: dependency cycle: "+cycle)
	default:
		if say {
			fmt.Fprintln(r.Out, "no cycles")
		}
		return 0
	}
	return exitFail
}

// gate: approval first, then the spec version at that exact commit must match tasks.json.
func (r *runner) gate() int {
	d := r.doc
	refuse := func(format string, a ...any) int {
		fmt.Fprintf(r.Err, "tasks: "+format+"\n", a...)
		return exitApproval
	}
	if d.SpecID == "" || !sha40.MatchString(d.SpecSha) {
		return refuse("tasks.json needs specId and a 40-hex specSha")
	}
	if r.Approve == nil || !r.Approve(d.SpecID, d.SpecSha) {
		return refuse("specSha %s of %s is not an approved SHA on origin/main: refusing", d.SpecSha, d.SpecID)
	}
	var meta struct {
		Version string `json:"version"`
	}
	_ = json.Unmarshal([]byte(r.show(path.Join(r.dir(), "spec.meta.json"))), &meta)
	have := "null"
	if d.SpecVersion != nil {
		have = Str(d.SpecVersion)
	}
	if meta.Version != "" && meta.Version != have {
		return refuse("specVersion in tasks.json differs from %s at %s", meta.Version, d.SpecSha)
	}
	return 0
}

// roles are the roles the spec picked: specs/<id>/roles.json at the SHA, {"roles":["backend",...]}; none when the file is absent.
func (r *runner) roles() []string {
	var f struct {
		Roles []string `json:"roles"`
	}
	_ = json.Unmarshal([]byte(r.show(r.dir()+"/roles.json")), &f)
	return f.Roles
}

func (r *runner) dir() string { return r.SpecPath + "/" + r.doc.SpecID }

func (r *runner) show(file string) string {
	out, _ := gitx.Run(r.Repo, "show", r.doc.SpecSha+":"+file)
	return out
}

func (r *runner) files() []string {
	out, _ := gitx.Run(r.Repo, "ls-tree", "-r", "--name-only", r.doc.SpecSha, "--", r.dir())
	return gitx.Lines(out)
}

// text is every file of the spec directory at the SHA, optionally without changes/.
func (r *runner) text(withChanges bool) string {
	var parts []string
	for _, f := range r.files() {
		if withChanges || !strings.Contains(f, "/changes/") {
			parts = append(parts, r.show(f))
		}
	}
	return strings.Join(parts, "\n")
}

var acToken = regexp.MustCompile(`\bAC-[A-Za-z0-9_]+(-[A-Za-z0-9_]+)*(\.[A-Za-z0-9_]+)*`)

// withdrawnRe matches a scenario title that withdraws an AC: `#### Scenario: AC-x-1 (withdrawn)` (optionally `- title`).
var withdrawnRe = regexp.MustCompile(`(?m)^####[ \t]+Scenario:[ \t]*(` + acToken.String() + `)[ \t]*\([ \t]*withdrawn\b[^)]*\)`)

// withdrawnIDs are the AC ids the spec text marks withdrawn in a scenario title; prose that merely mentions an id does not count.
func withdrawnIDs(text string) map[string]bool {
	out := map[string]bool{}
	for _, m := range withdrawnRe.FindAllStringSubmatch(text, -1) {
		out[m[1]] = true
	}
	return out
}

// allACs: every AC id in the spec text, without the withdrawn ones unless include.
func (r *runner) allACs(include bool) []string {
	text := r.text(true)
	w := map[string]bool{}
	if !include {
		w = withdrawnIDs(text)
	}
	set := map[string]bool{}
	for _, a := range acToken.FindAllString(text, -1) {
		if !w[a] {
			set[a] = true
		}
	}
	return keys(set)
}

// revChanges: slugs of the changes applied in the revision of the spec at the SHA.
func (r *runner) revChanges() []string {
	var meta struct {
		Version string `json:"version"`
	}
	_ = json.Unmarshal([]byte(r.show(r.dir()+"/spec.meta.json")), &meta)
	var out []string
	for _, f := range r.files() {
		if !strings.HasPrefix(f, r.dir()+"/changes/") || !strings.HasSuffix(f, "/change.json") {
			continue
		}
		var c struct {
			Slug    string `json:"slug"`
			Status  string `json:"status"`
			Applied struct {
				Version string `json:"version"`
			} `json:"applied"`
		}
		if json.Unmarshal([]byte(r.show(f)), &c) == nil && c.Status == "applied" && c.Applied.Version == meta.Version {
			out = append(out, c.Slug)
		}
	}
	return out
}

// revisionACs: the active ACs (a `(withdrawn)` title never matches the scenario pattern below) that the changes of this revision added or modified.
func (r *runner) revisionACs() []string {
	slugs := r.revChanges()
	if len(slugs) == 0 {
		return nil
	}
	spec := r.text(false)
	touched := map[string]bool{}
	for _, s := range slugs {
		var c struct {
			Touches []string `json:"touches"`
		}
		_ = json.Unmarshal([]byte(r.show(r.dir()+"/changes/"+s+"/change.json")), &c)
		for _, t := range c.Touches {
			touched[t] = true
		}
	}
	var out []string
	for _, ac := range keys(touched) {
		if regexp.MustCompile(`(?m)^####[ \t]+Scenario:[ \t]*` + regexp.QuoteMeta(ac) + `([ \t]+-|[ \t]*$)`).MatchString(spec) {
			out = append(out, ac)
		}
	}
	return out
}

func (r *runner) render(rest []string) int {
	if len(rest) == 0 || rest[0] == "" {
		fmt.Fprintln(r.Err, "tasks: usage: render <tasks.json> <ref> [--keys MAP] [--json]")
		return exitUsage
	}
	ref, m, asJSON := rest[0], map[string]string{}, false
	for rest = rest[1:]; len(rest) > 0; {
		switch rest[0] {
		case "--keys":
			var b []byte
			var err error
			if len(rest) > 1 {
				b, err = os.ReadFile(rest[1])
			}
			if len(rest) < 2 || err != nil || json.Unmarshal(b, &m) != nil {
				fmt.Fprintln(r.Err, "tasks: --keys needs a file")
				return exitUsage
			}
			rest = rest[2:]
		case "--json":
			asJSON, rest = true, rest[1:]
		default:
			fmt.Fprintf(r.Err, "tasks: unknown option %s\n", rest[0])
			return exitUsage
		}
	}
	if err := r.doc.Keys(); err != nil {
		fmt.Fprintln(r.Err, err)
		return exitFail
	}
	u, ok, err := r.doc.RenderWith(ref, m, r.specText(), r.Lang)
	if !ok {
		fmt.Fprintf(r.Err, "tasks: no task with ref %s\n", ref)
		return exitUsage
	}
	if err != nil {
		fmt.Fprintf(r.Err, "tasks: %v\n", err)
		return exitFail
	}
	text := strings.TrimRight(u.Text(), "\n") // the bash held it in $(...), which drops the trailing newline
	if r.Validate != nil {
		if msg, ok := r.Validate(text); !ok {
			fmt.Fprint(r.Err, msg)
			fmt.Fprintf(r.Err, "tasks: rendered task %s fails jira.sh validate-task\n", ref)
			return exitContract
		}
	}
	if asJSON {
		fmt.Fprintln(r.Out, u.JSON())
	} else {
		fmt.Fprint(r.Out, text)
	}
	return 0
}

func (r *runner) report(rest []string) int {
	if len(rest) == 0 {
		fmt.Fprintln(r.Err, "tasks: usage: report <tasks.json> <results.jsonl> [--out FILE]")
		return exitUsage
	}
	b, err := os.ReadFile(rest[0])
	if err != nil {
		fmt.Fprintln(r.Err, "tasks: usage: report <tasks.json> <results.jsonl> [--out FILE]")
		return exitUsage
	}
	out := ""
	if len(rest) > 2 && rest[1] == "--out" {
		out = rest[2]
	}
	if err := r.doc.Keys(); err != nil {
		fmt.Fprintln(r.Err, err)
		return exitFail
	}
	res := map[string]map[string]any{}
	for dec := json.NewDecoder(bytes.NewReader(b)); ; {
		var o any
		if dec.Decode(&o) != nil {
			break
		}
		if m, ok := o.(map[string]any); ok {
			if id, _ := m["externalId"].(string); id != "" {
				res[id] = m
			}
		}
	}
	md, ok := r.doc.Report(res)
	if out != "" {
		_ = os.WriteFile(out, []byte(md+"\n"), 0o644)
	} else {
		fmt.Fprintln(r.Out, md)
	}
	if !ok {
		return exitFail
	}
	return 0
}

func hasRoleSection(d *lint.TasksDoc) bool {
	for _, f := range d.Features {
		if len(f.Sections) > 0 {
			return true
		}
	}
	return false
}

// specText is what a description quotes from the spec at the pinned SHA: the AC titles and THEN lines, the lines of tasks.md.
func (r *runner) specText() *SpecText {
	meta := struct {
		Version string `json:"version"`
	}{}
	_ = json.Unmarshal([]byte(r.show(r.dir()+"/spec.meta.json")), &meta)
	return &SpecText{Path: r.dir(), Version: meta.Version, Sha: r.doc.SpecSha,
		ACs: ParseACTexts(r.text(false)), Steps: StepTexts(r.show(r.dir() + "/tasks.md"))}
}
