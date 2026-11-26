// Package tasks is the deterministic core of generate-tasks: AC trace, dependency
// cycles, stable task keys, render and report. No model, no network.
package tasks

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Task is one entry of tasks.json (docs/go-port/contracts-inventory.md 7.5).
type Task struct {
	Ref        string   `json:"ref"`
	Title      any      `json:"title"`
	Summary    any      `json:"summary"`
	Slug       any      `json:"slug"`
	Change     any      `json:"change"`
	Risk       any      `json:"risk"`
	ACs        []string `json:"acceptanceCriteria"`
	DependsOn  []string `json:"dependsOn"`
	Scope      []string `json:"scope"`
	Area       string   `json:"area"`      // role subtask: the one role that does it (one of Roles)
	Of         string   `json:"of"`        // role subtask: ref of the group task it belongs to; a group task and a legacy task have none
	BlockedBy  []string `json:"blockedBy"` // gates (open questions) the task waits for; shown as "Blocked: ..." in its summary
	Steps      []string `json:"steps"`     // ids of the tasks.md lines this task does; their text is read from the spec at the SHA
	Include    []string `json:"include"`   // optional description sections: acs, after, source (default none)
	ExternalID string   `json:"-"`
	Key        string   `json:"-"`
}

// Doc is a parsed tasks.json; Raw keeps the original key order for `ids`.
type Doc struct {
	SpecID      string
	SpecVersion any
	SpecSha     string
	Parent      any
	Tasks       []Task
	raw         *obj
}

// Roles are the roles a spec's tasks are split by. The list is fixed in the kit; a spec picks the subset that works on it
// (specs/<id>/roles.json, written by generate-specs).
var Roles = []string{"solution-architect", "backend", "frontend", "devops", "qa", "mobil", "ui", "ux"}

// ValidRole reports whether v is one of Roles.
func ValidRole(v any) bool {
	s, ok := v.(string)
	for _, r := range Roles {
		if ok && r == s {
			return true
		}
	}
	return false
}

// Parse reads tasks.json and checks the shape (a tasks array, each with a ref).
func Parse(data []byte) (*Doc, error) {
	var top struct {
		SpecID      string          `json:"specId"`
		SpecVersion any             `json:"specVersion"`
		SpecSha     string          `json:"specSha"`
		Parent      any             `json:"parent"`
		Tasks       json.RawMessage `json:"tasks"`
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&top); err != nil || len(top.Tasks) == 0 || top.Tasks[0] != '[' {
		return nil, fmt.Errorf("tasks.json: needs a tasks array, each with a ref")
	}
	d := &Doc{SpecID: top.SpecID, SpecVersion: top.SpecVersion, SpecSha: top.SpecSha, Parent: top.Parent}
	td := json.NewDecoder(bytes.NewReader(top.Tasks))
	td.UseNumber()
	if err := td.Decode(&d.Tasks); err != nil {
		return nil, fmt.Errorf("tasks.json: needs a tasks array, each with a ref")
	}
	for _, t := range d.Tasks {
		if t.Ref == "" {
			return nil, fmt.Errorf("tasks.json: needs a tasks array, each with a ref")
		}
	}
	d.raw, _ = parseObj(data)
	return d, nil
}

// Str is jq's `tostring` after `// ""`: null and false are empty.
func Str(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case bool:
		if !x {
			return ""
		}
	case string:
		return x
	}
	b, _ := marshal(v)
	return string(b)
}

func marshal(v any) ([]byte, error) {
	var buf bytes.Buffer
	e := json.NewEncoder(&buf)
	e.SetEscapeHTML(false)
	err := e.Encode(v)
	return bytes.TrimRight(buf.Bytes(), "\n"), err
}

func sorted(s []string) []string {
	c := append([]string(nil), s...)
	sort.Strings(c)
	return c
}

// tsvFields reproduces the bash `IFS=$'\t' read -r r s a c ch` on a jq @tsv line:
// tab is IFS whitespace, so an empty field collapses and the later ones shift left.
// The 1.x ids depend on it, so it is kept.
func tsvFields(cols []string) (r, s, a, c, ch string) {
	esc := strings.NewReplacer(`\`, `\\`, "\t", `\t`, "\n", `\n`, "\r", `\r`)
	var f []string
	for _, col := range cols {
		if col = esc.Replace(col); col != "" {
			f = append(f, col)
		}
	}
	get := func(i int) string {
		if i < len(f) {
			return f[i]
		}
		return ""
	}
	if len(f) > 4 {
		ch = strings.Join(f[4:], "\t")
	}
	return get(0), get(1), get(2), get(3), ch
}

// Keys fills Key and ExternalID (<specId>:t<hash>). The hash covers the sorted ACs,
// the sorted scope, the optional slug and the change, never the title or position.
func (d *Doc) Keys() error {
	hashes := map[string]string{}
	var order []string
	for _, t := range d.Tasks {
		r, s, a, c, ch := tsvFields([]string{t.Ref, Str(t.Slug), strings.Join(sorted(t.ACs), ","), strings.Join(sorted(t.Scope), ","), Str(t.Change)})
		in := a + "|" + c + "|" + s
		if ch != "" {
			in += "|" + ch
		}
		if t.Area != "" { // only role subtasks: the ids of tasks without an area stay as they were
			in += "|area:" + t.Area
		}
		sum := sha256.Sum256([]byte(in))
		hashes[r] = hex.EncodeToString(sum[:])[:10]
		order = append(order, r)
	}
	var dups []string
	seen := map[string]int{}
	for _, r := range order {
		seen[hashes[r]]++
	}
	for h, n := range seen {
		if n > 1 {
			dups = append(dups, h)
		}
	}
	if len(order) > 0 && len(dups) > 0 {
		sort.Strings(dups)
		var refs string
		for _, r := range order {
			if hashes[r] == dups[0] {
				refs += r + " "
			}
		}
		return fmt.Errorf("tasks: two tasks share the same ACs and scope (add a distinct slug): %s", refs)
	}
	for i := range d.Tasks {
		d.Tasks[i].Key = "t" + hashes[d.Tasks[i].Ref]
		d.Tasks[i].ExternalID = d.SpecID + ":" + d.Tasks[i].Key
	}
	return nil
}

// IDs is tasks.json with key and externalId added to every task, original order kept.
func (d *Doc) IDs() ([]byte, error) {
	if err := d.Keys(); err != nil {
		return nil, err
	}
	var items []json.RawMessage
	_ = json.Unmarshal(d.raw.v["tasks"], &items)
	for i, it := range items {
		o, err := parseObj(it)
		if err != nil || i >= len(d.Tasks) {
			continue
		}
		o.set("key", d.Tasks[i].Key)
		o.set("externalId", d.Tasks[i].ExternalID)
		items[i], _ = o.MarshalJSON()
	}
	d.raw.setRaw("tasks", mustJSON(items))
	b, _ := d.raw.MarshalJSON()
	var out bytes.Buffer
	_ = json.Indent(&out, b, "", "  ")
	return out.Bytes(), nil
}

func mustJSON(v any) json.RawMessage { b, _ := marshal(v); return b }

// Trace checks the AC list against the tasks. problems are the stderr lines; ok is the success line.
func (d *Doc) Trace(acs []string) (ok string, problems []string) {
	set := func(s []string) map[string]bool {
		m := map[string]bool{}
		for _, x := range s {
			m[x] = true
		}
		return m
	}
	var mapped []string
	for _, t := range d.Tasks {
		mapped = append(mapped, t.ACs...)
	}
	al, mp := set(acs), set(mapped)
	diff := func(a, b map[string]bool) string {
		var o []string
		for k := range a {
			if !b[k] {
				o = append(o, k)
			}
		}
		sort.Strings(o)
		return strings.Join(o, " ")
	}
	if m := diff(al, mp); m != "" {
		problems = append(problems, "tasks: AC without a task: "+m)
	}
	if u := diff(mp, al); u != "" {
		problems = append(problems, "tasks: task references AC not in the spec: "+u)
	}
	var orph []string
	for _, t := range d.Tasks {
		if len(t.ACs) == 0 {
			orph = append(orph, t.Ref)
		}
	}
	if len(orph) > 0 {
		problems = append(problems, "tasks: orphan task (no AC): "+strings.Join(orph, " "))
	}
	return fmt.Sprintf("trace ok: %d ACs, %d tasks", len(al), len(d.Tasks)), problems
}

// Cycles returns the first unknown dependency ("A -> Z") or the first cycle found
// by a depth-first walk in task order ("A -> B -> A"); both empty means none.
func (d *Doc) Cycles() (unknown, cycle string) {
	known := map[string]bool{}
	adj := map[string][]string{}
	for _, t := range d.Tasks {
		known[t.Ref] = true
		adj[t.Ref] = append(adj[t.Ref], t.DependsOn...)
		if t.Of != "" { // a role subtask needs its group task to exist first
			adj[t.Ref] = append(adj[t.Ref], t.Of)
		}
	}
	for _, t := range d.Tasks {
		for _, dep := range adj[t.Ref] {
			if !known[dep] {
				return t.Ref + " -> " + dep, ""
			}
		}
	}
	state := map[string]int{}
	var stack []string
	var dfs func(u string) bool
	dfs = func(u string) bool {
		state[u] = 1
		stack = append(stack, u)
		for _, v := range adj[u] {
			if state[v] == 1 {
				i := 0
				for stack[i] != v {
					i++
				}
				cycle = strings.Join(stack[i:], " -> ") + " -> " + v
				return true
			}
			if state[v] == 0 && dfs(v) {
				return true
			}
		}
		state[u] = 2
		stack = stack[:len(stack)-1]
		return false
	}
	for _, t := range d.Tasks {
		if state[t.Ref] == 0 && dfs(t.Ref) {
			return "", cycle
		}
	}
	return "", ""
}

// Order lists the refs dependencies first; among ready tasks the file order wins.
// The caller has already checked Cycles.
func (d *Doc) Order() []string {
	done := map[string]bool{}
	var out []string
	for len(out) < len(d.Tasks) {
		progressed := false
		for _, t := range d.Tasks {
			if done[t.Ref] {
				continue
			}
			ready := true
			for _, dep := range t.DependsOn {
				ready = ready && done[dep]
			}
			ready = ready && (t.Of == "" || done[t.Of])
			if ready {
				done[t.Ref] = true
				out = append(out, t.Ref)
				progressed = true
				break
			}
		}
		if !progressed {
			break
		}
	}
	return out
}
