package tasks

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
)

// PlanCfg holds the size rules of a task plan (TASKS_* in sdkit.env).
type PlanCfg struct {
	Min, Max    int // wanted number of tasks
	ACsMin      int // typical ACs per task, lower bound (4)
	ACsMax      int // upper bound (12)
	SingleMax   int // most tasks that may carry a single AC (3)
	ChainMax    int // longest dependsOn chain (3)
	MarkerWords []string
}

// DefaultPlanCfg is the shipped default (templates/sdkit.env repeats it).
func DefaultPlanCfg() PlanCfg {
	return PlanCfg{Min: 12, Max: 20, ACsMin: 4, ACsMax: 12, SingleMax: 3, ChainMax: 3}
}

// Advice is one plan-check line; Error lines make the command exit 1.
type Advice struct {
	Error bool
	Text  string
}

var reGateTitle = regexp.MustCompile(`(?m)^####[ \t]+Scenario:[ \t]*(AC-[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*)[ \t]*\(([^)]*)\)`)
var reGateID = regexp.MustCompile(`(?i)\b[A-Z]+-?\d+[a-z]?\b`)

// GateMarkers maps an AC to the gates (open questions) its scenario title names, e.g. "(pending Q1, conditional Q3)".
// Only parentheses that hold one of the marker words count; a withdrawn AC is skipped.
func GateMarkers(spec string, words []string) map[string][]string {
	out := map[string][]string{}
	for _, m := range reGateTitle.FindAllStringSubmatch(spec, -1) {
		low := strings.ToLower(m[2])
		if strings.Contains(low, "withdrawn") {
			continue
		}
		hit := false
		for _, w := range words {
			hit = hit || (w != "" && strings.Contains(low, strings.ToLower(w)))
		}
		if !hit {
			continue
		}
		set := map[string]bool{}
		for _, g := range reGateID.FindAllString(m[2], -1) {
			set[strings.ToUpper(g)] = true
		}
		out[m[1]] = keys(set)
	}
	return out
}

// RubricUnfilled reports whether the "Risk rubric" section of project.md still holds a TODO.
func RubricUnfilled(projectMD string) bool {
	in := false
	for _, l := range strings.Split(projectMD, "\n") {
		if strings.HasPrefix(l, "## ") {
			in = strings.Contains(strings.ToLower(l), "risk rubric")
			continue
		}
		if in && strings.Contains(l, "TODO") {
			return true
		}
	}
	return false
}

// PlanCheck judges the size and shape of a task plan. gates maps AC -> gates (GateMarkers); projectMD is project.md;
// roles are the roles the spec picked (specs/<id>/roles.json, empty when it has none).
// It advises, it never rewrites: a merge suggestion is a candidate for the analyst, not an order.
// The size, pack, chain and merge rules judge the group (top-level) tasks only: role subtasks multiply the count on purpose.
func (d *Doc) PlanCheck(cfg PlanCfg, gates map[string][]string, projectMD string, roles []string) []Advice {
	out := d.roleAdvice(roles)
	return append(out, d.groups().planSize(cfg, gates, projectMD)...)
}

// groups is the plan without its role subtasks (d itself when it has none).
func (d *Doc) groups() *Doc {
	top := &Doc{SpecID: d.SpecID, SpecVersion: d.SpecVersion, SpecSha: d.SpecSha, Parent: d.Parent}
	for _, t := range d.Tasks {
		if t.Of == "" {
			top.Tasks = append(top.Tasks, t)
		}
	}
	if len(top.Tasks) == len(d.Tasks) {
		return d
	}
	return top
}

// roleAdvice checks the split by role: every subtask has one valid role and a group task, the ACs stay inside the group's,
// each group has what its roles need (qa last, after the others) and each picked role has work.
func (d *Doc) roleAdvice(roles []string) []Advice {
	used := false
	for _, t := range d.Tasks {
		used = used || t.Area != "" || t.Of != ""
	}
	if len(roles) == 0 && !used {
		return nil
	}
	var out []Advice
	warn := func(f string, a ...any) { out = append(out, Advice{false, fmt.Sprintf(f, a...)}) }
	bad := func(f string, a ...any) { out = append(out, Advice{true, fmt.Sprintf(f, a...)}) }
	allowed := map[string]bool{}
	for _, r := range roles {
		if !ValidRole(r) {
			bad("roles: %q in roles.json is not a kit role (%s).", r, strings.Join(Roles, ", "))
		}
		allowed[r] = true
	}
	if len(roles) == 0 {
		warn("roles: the spec has no roles.json, so any role is accepted. Run generate-specs again or write specs/<id>/roles.json.")
		for _, r := range Roles {
			allowed[r] = true
		}
	}
	by := map[string]Task{}
	kids := map[string][]Task{}
	for _, t := range d.Tasks {
		by[t.Ref] = t
		if t.Of != "" {
			kids[t.Of] = append(kids[t.Of], t)
		}
	}
	work := map[string]bool{}
	for _, t := range d.Tasks {
		if t.Area != "" {
			work[t.Area] = true
			if !ValidRole(t.Area) || !allowed[t.Area] {
				bad("area: task %s has role %q, which the spec did not pick (%s).", t.Ref, t.Area, strings.Join(roles, ", "))
			}
		}
		if t.Of == "" {
			continue
		}
		g, ok := by[t.Of]
		switch {
		case t.Area == "":
			bad("area: role subtask %s (of %s) has no area.", t.Ref, t.Of)
		case !ok:
			bad("of: task %s belongs to %s, which is not in the plan.", t.Ref, t.Of)
		case g.Of != "":
			bad("of: task %s belongs to %s, which is itself a subtask; there are two levels only (group task, role subtask).", t.Ref, t.Of)
		case g.Area != "":
			bad("of: task %s belongs to %s, which has a role itself; a group task has no area.", t.Ref, t.Of)
		default:
			in := map[string]bool{}
			for _, a := range g.ACs {
				in[a] = true
			}
			for _, a := range t.ACs {
				if !in[a] {
					bad("ac: %s lists %s, which its group task %s does not carry.", t.Ref, a, g.Ref)
				}
			}
		}
	}
	for _, g := range d.Tasks {
		if g.Of != "" || g.Area != "" {
			continue
		}
		ks := kids[g.Ref]
		if len(ks) == 0 {
			warn("roles: task %s has no role subtask; nobody is named to implement it.", g.Ref)
			continue
		}
		var qa *Task
		var others []string
		for i, k := range ks {
			if k.Area == "qa" {
				qa = &ks[i]
			} else {
				others = append(others, k.Ref)
			}
		}
		if allowed["qa"] && qa == nil {
			warn("qa: task %s has role subtasks but none for qa; qa tests last.", g.Ref)
		}
		if qa != nil {
			dep := map[string]bool{}
			for _, x := range qa.DependsOn {
				dep[x] = true
			}
			var miss []string
			for _, o := range others {
				if !dep[o] {
					miss = append(miss, o)
				}
			}
			if len(miss) > 0 {
				warn("qa: %s (qa of %s) should depend on every other role subtask of %s; missing %s.", qa.Ref, g.Ref, g.Ref, strings.Join(miss, " "))
			}
		}
	}
	for _, r := range roles {
		if !work[r] {
			warn("roles: the spec picked %s but no task is for it.", r)
		}
	}
	return out
}

func (d *Doc) planSize(cfg PlanCfg, gates map[string][]string, projectMD string) []Advice {
	var out []Advice
	warn := func(f string, a ...any) { out = append(out, Advice{false, fmt.Sprintf(f, a...)}) }
	bad := func(f string, a ...any) { out = append(out, Advice{true, fmt.Sprintf(f, a...)}) }
	set := map[string]bool{}
	for _, t := range d.Tasks {
		for _, a := range t.ACs {
			set[a] = true
		}
	}
	nAC, n := len(set), len(d.Tasks)
	if RubricUnfilled(projectMD) {
		bad("risk rubric: project.md's \"Risk rubric\" still has TODO. Risk labels would be guesses (every task came out the same). Fill in what makes a change high / medium / low for this project (money or auth? a state-changing endpoint? read-only?), then run plan-check again.")
	}
	// the wanted range: the configured one, narrowed by the ACs-per-task bounds
	lo, hi := cfg.Min, cfg.Max
	if nAC > 0 && cfg.ACsMax > 0 && cfg.ACsMin > 0 {
		lo = max(lo, int(math.Ceil(float64(nAC)/float64(cfg.ACsMax))))
		hi = min(hi, int(math.Ceil(float64(nAC)/float64(cfg.ACsMin))))
	}
	if lo > hi {
		lo = hi
	}
	if hi > 0 && (n < lo || n > hi) {
		warn("size: %d tasks for %d ACs; aim for %d-%d (4-12 ACs per task, one behaviour family per task). Split only by a different gate, a different risk or independent delivery.", n, nAC, lo, hi)
	}
	var singles []string
	for _, t := range d.Tasks {
		if len(t.ACs) == 1 {
			singles = append(singles, t.Ref)
		}
	}
	if len(singles) > cfg.SingleMax {
		warn("size: %d tasks carry a single AC (%s); allowed %d. Merge them into the task of their behaviour family.", len(singles), strings.Join(singles, " "), cfg.SingleMax)
	}
	if l, chain := d.longestChain(); l > cfg.ChainMax {
		warn("chain: %d tasks in a row each depend on the previous (%s); allowed %d. A chain with the same scope usually is one task.", l, strings.Join(chain, " -> "), cfg.ChainMax)
	}
	// gates: a task mixes gated and ungated ACs, or different gates
	gateOf := func(t Task) string {
		var all []string
		for _, a := range t.ACs {
			all = append(all, strings.Join(gates[a], "+"))
		}
		sort.Strings(all)
		return strings.Join(all, "|")
	}
	byRef := map[string]Task{}
	for _, t := range d.Tasks {
		byRef[t.Ref] = t
		kinds := map[string]bool{}
		for _, a := range t.ACs {
			kinds[strings.Join(gates[a], "+")] = true
		}
		if len(kinds) > 1 {
			warn("gate: task %s mixes ACs with different gates (%s). Put each gate in its own task, with \"Blocked: <Q>\" in its summary, so ungated work is not held back.", t.Ref, strings.Join(describeGates(kinds), "; "))
		}
	}
	// merge candidates: B depends only on A, same risk, same gate, a common scope root, both small
	for _, b := range d.Tasks {
		if len(b.DependsOn) != 1 {
			continue
		}
		a, ok := byRef[b.DependsOn[0]]
		if !ok || Str(a.Risk) != Str(b.Risk) || gateOf(a) != gateOf(b) || len(a.ACs)+len(b.ACs) > cfg.ACsMax || !sharesScope(a.Scope, b.Scope) {
			continue
		}
		warn("merge: %s and %s (%s depends on %s) share risk, gate and scope; together %d ACs. Candidate for one task.", a.Ref, b.Ref, b.Ref, a.Ref, len(a.ACs)+len(b.ACs))
	}
	out = append(out, d.packAdvice(cfg, gateOf)...)
	if len(d.Tasks) > 5 {
		same := map[string]int{}
		for _, t := range d.Tasks {
			same[Str(t.Risk)]++
		}
		if len(same) == 1 && !RubricUnfilled(projectMD) {
			warn("risk: all %d tasks have the same risk label (%s); check the rubric was applied per task.", n, Str(d.Tasks[0].Risk))
		}
	}
	return out
}

func describeGates(kinds map[string]bool) []string {
	var o []string
	for k := range kinds {
		if k == "" {
			k = "none"
		}
		o = append(o, k)
	}
	sort.Strings(o)
	return o
}

// sharesScope: both have no scope, or some path of a and of b start with the same first two segments.
func sharesScope(a, b []string) bool {
	if len(a) == 0 && len(b) == 0 {
		return true
	}
	root := func(p string) string {
		seg := strings.Split(strings.Trim(p, "/"), "/")
		return strings.Join(seg[:min(2, len(seg))], "/")
	}
	ra := map[string]bool{}
	for _, p := range a {
		ra[root(p)] = true
	}
	for _, p := range b {
		if ra[root(p)] {
			return true
		}
	}
	return false
}

// longestChain is the longest path of dependsOn edges, counted in tasks (the cycle check has run).
func (d *Doc) longestChain() (int, []string) {
	by := map[string]Task{}
	for _, t := range d.Tasks {
		by[t.Ref] = t
	}
	memo := map[string][]string{}
	var walk func(r string, depth int) []string
	walk = func(r string, depth int) []string {
		if c, ok := memo[r]; ok {
			return c
		}
		if depth > len(d.Tasks) {
			return []string{r}
		}
		best := []string{}
		for _, dep := range by[r].DependsOn {
			if c := walk(dep, depth+1); len(c) > len(best) {
				best = c
			}
		}
		memo[r] = append(append([]string{}, best...), r)
		return memo[r]
	}
	var longest []string
	for _, t := range d.Tasks {
		if c := walk(t.Ref, 0); len(c) > len(longest) {
			longest = c
		}
	}
	return len(longest), longest
}

// packAdvice groups tasks by (risk, gate, scope root) and packs each group first-fit into tasks of at most ACsMax ACs.
// It says how many tasks that would leave; the analyst decides, and runs cycles again after merging.
func (d *Doc) packAdvice(cfg PlanCfg, gateOf func(Task) string) []Advice {
	if cfg.ACsMax <= 0 {
		return nil
	}
	type grp struct{ tasks []Task }
	groups := map[string]*grp{}
	var order []string
	for _, t := range d.Tasks {
		root := ""
		if len(t.Scope) > 0 {
			root = scopeRoot(t.Scope[0])
		}
		k := Str(t.Risk) + " / gate " + gateKey(gateOf(t)) + " / " + root
		if groups[k] == nil {
			groups[k] = &grp{}
			order = append(order, k)
		}
		groups[k].tasks = append(groups[k].tasks, t)
	}
	total := 0
	var lines []Advice
	for _, k := range order {
		ts := append([]Task(nil), groups[k].tasks...)
		sort.SliceStable(ts, func(i, j int) bool { return len(ts[i].ACs) > len(ts[j].ACs) })
		var bins [][]Task
		var load []int
		for _, t := range ts {
			placed := false
			for i := range bins {
				if load[i]+len(t.ACs) <= cfg.ACsMax {
					bins[i], load[i], placed = append(bins[i], t), load[i]+len(t.ACs), true
					break
				}
			}
			if !placed {
				bins, load = append(bins, []Task{t}), append(load, len(t.ACs))
			}
		}
		total += len(bins)
		if len(bins) < len(ts) {
			var parts []string
			for _, b := range bins {
				var refs []string
				for _, t := range b {
					refs = append(refs, t.Ref)
				}
				parts = append(parts, "["+strings.Join(refs, " ")+"]")
			}
			lines = append(lines, Advice{false, fmt.Sprintf("pack: %s: %d tasks fit %d (up to %d ACs each): %s", k, len(ts), len(bins), cfg.ACsMax, strings.Join(parts, " "))})
		}
	}
	if len(lines) > 0 {
		lines = append(lines, Advice{false, fmt.Sprintf("pack: merging as above leaves about %d tasks (run `tasks cycles` after merging).", total)})
	}
	return lines
}

func gateKey(g string) string {
	if strings.Trim(g, "|") == "" {
		return "none"
	}
	return g
}

func scopeRoot(p string) string {
	seg := strings.Split(strings.Trim(p, "/"), "/")
	return strings.Join(seg[:min(2, len(seg))], "/")
}

var riskRank = map[string]int{"low": 1, "medium": 2, "high": 3}

// Merge folds the tasks of refs into the first of them (or into), keeping its position: ACs, scope, dependencies and
// gates are the union, the risk the highest, the summary the members' summaries in order. References to a member become
// references to the merged task. Refused when it would create a cycle.
func (d *Doc) Merge(refs []string) error {
	if len(refs) < 2 {
		return fmt.Errorf("merge needs at least two refs")
	}
	member := map[string]bool{}
	for _, r := range refs {
		member[r] = true
	}
	idx := map[string]int{}
	for i, t := range d.Tasks {
		idx[t.Ref] = i
	}
	for _, r := range refs {
		if _, ok := idx[r]; !ok {
			return fmt.Errorf("no task with ref %s", r)
		}
	}
	for _, r := range refs {
		t := d.Tasks[idx[r]]
		if t.Of != "" || t.Area != "" {
			return fmt.Errorf("task %s is a role subtask: subtasks are not merged (merge their group tasks instead)", r)
		}
	}
	head := refs[0]
	union := func(a, b []string) []string {
		seen := map[string]bool{}
		var o []string
		for _, x := range append(append([]string{}, a...), b...) {
			if !seen[x] {
				seen[x] = true
				o = append(o, x)
			}
		}
		return o
	}
	m := d.Tasks[idx[head]]
	var sums []string
	if s := Str(m.Summary); s != "" {
		sums = append(sums, s)
	}
	for _, r := range refs[1:] {
		t := d.Tasks[idx[r]]
		m.ACs, m.Scope, m.DependsOn, m.BlockedBy = union(m.ACs, t.ACs), union(m.Scope, t.Scope), union(m.DependsOn, t.DependsOn), union(m.BlockedBy, t.BlockedBy)
		if riskRank[Str(t.Risk)] > riskRank[Str(m.Risk)] {
			m.Risk = t.Risk
		}
		if s := Str(t.Summary); s != "" {
			sums = append(sums, s)
		}
	}
	if len(sums) > 0 {
		m.Summary = strings.Join(sums, "\n\n")
	}
	var deps []string
	for _, x := range m.DependsOn {
		if !member[x] {
			deps = append(deps, x)
		}
	}
	m.DependsOn, m.ExternalID, m.Key = deps, "", ""
	var out []Task
	for _, t := range d.Tasks {
		switch {
		case t.Ref == head:
			out = append(out, m)
			continue
		case member[t.Ref]:
			continue
		}
		if member[t.Of] { // a role subtask of a merged group follows its group
			t.Of = head
		}
		var nd []string
		for _, x := range t.DependsOn {
			if member[x] {
				x = head
			}
			nd = append(nd, x)
		}
		t.DependsOn = union(nd, nil)
		out = append(out, t)
	}
	old := d.Tasks
	d.Tasks = out
	if u, c := d.Cycles(); u != "" || c != "" {
		d.Tasks = old
		return fmt.Errorf("merging %s would create a dependency cycle (%s%s)", strings.Join(refs, ","), u, c)
	}
	return nil
}

// PlanJSON is the plan document with the tasks as they are now (specId, specVersion, specSha, parent first).
func (d *Doc) PlanJSON() string {
	type tk struct {
		Ref       string   `json:"ref"`
		Title     any      `json:"title,omitempty"`
		Summary   any      `json:"summary,omitempty"`
		Slug      any      `json:"slug,omitempty"`
		Change    any      `json:"change,omitempty"`
		Risk      any      `json:"risk,omitempty"`
		ACs       []string `json:"acceptanceCriteria"`
		DependsOn []string `json:"dependsOn"`
		Scope     []string `json:"scope"`
		Area      string   `json:"area,omitempty"`
		Of        string   `json:"of,omitempty"`
		BlockedBy []string `json:"blockedBy,omitempty"`
		Steps     []string `json:"steps,omitempty"`
		Include   []string `json:"include,omitempty"`
	}
	doc := struct {
		SpecID      string `json:"specId"`
		SpecVersion any    `json:"specVersion"`
		SpecSha     string `json:"specSha"`
		Parent      any    `json:"parent"`
		Tasks       []tk   `json:"tasks"`
	}{SpecID: d.SpecID, SpecVersion: d.SpecVersion, SpecSha: d.SpecSha, Parent: d.Parent}
	for _, t := range d.Tasks {
		if t.DependsOn == nil {
			t.DependsOn = []string{}
		}
		doc.Tasks = append(doc.Tasks, tk{t.Ref, t.Title, t.Summary, t.Slug, t.Change, t.Risk, t.ACs, t.DependsOn, t.Scope, t.Area, t.Of, t.BlockedBy, t.Steps, t.Include})
	}
	b, _ := marshal(doc)
	var buf bytes.Buffer
	_ = json.Indent(&buf, b, "", "  ")
	return buf.String()
}
