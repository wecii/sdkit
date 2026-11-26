// Package spec holds the deterministic facts of a spec change (spec merge,
// docs/design-spec-merge.md): AC parsing and hashing, the delta against a base,
// sibling overlap, change.json validation. It never writes a file; apply.go is
// the file-writing half. A "root" is a base specs/<id>/ or a change
// specs/<id>/changes/<slug>/: its requirements live in
// <root>/specs/<capability>/spec.md and anything under <root>/changes/ is not
// part of it.
package spec

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/wecii/sdkit/internal/lint"
)

func longest(expr string) *regexp.Regexp {
	r := regexp.MustCompile(expr)
	r.Longest()
	return r
}

var (
	idRe     = longest(`AC-[A-Za-z0-9._-]*-[0-9]+`)
	idAtRe   = longest(`^AC-[A-Za-z0-9._-]*-[0-9]+`)
	citeRe   = longest(`AC-[A-Za-z0-9._-]*-[0-9]+|ADR-[A-Za-z0-9-]*[0-9]`)
	spaceRe  = regexp.MustCompile(`[ \t]+`)
	sectionR = regexp.MustCompile(`^(ADDED|MODIFIED|REMOVED|RENAMED) +Requirements`)
	wdRe     = regexp.MustCompile(`^ *\([Ww]ithdrawn\)`)
)

// AC is one acceptance criterion: a `#### Scenario: AC-<capability>-<n> ...` block.
type AC struct {
	ID          string `json:"id"`
	Capability  string `json:"capability"`
	Section     string `json:"section"`
	Requirement string `json:"requirement"`
	Withdrawn   bool   `json:"withdrawn"`
	Hash        string `json:"hash"`
}

// Req is a `### Requirement:` heading with the AC ids under it.
type Req struct {
	Capability string   `json:"capability"`
	Section    string   `json:"section"`
	Title      string   `json:"title"`
	ACs        []string `json:"acs"`
}

// NoID is a scenario that carries no AC id.
type NoID struct {
	Capability  string `json:"capability"`
	Section     string `json:"section"`
	Requirement string `json:"requirement"`
}

// Parsed is the output of `spec change parse`.
type Parsed struct {
	ACs          []AC   `json:"acs"`
	NoID         []NoID `json:"noId"`
	Requirements []Req  `json:"requirements"`
}

func norm(s string) string {
	s = spaceRe.ReplaceAllString(strings.ReplaceAll(s, "\r", ""), " ")
	return strings.TrimSuffix(strings.TrimPrefix(s, " "), " ")
}

// Hash is the content hash of an AC: sha256 of its normalised lines (CR removed,
// blanks collapsed, lines trimmed, empty lines dropped) joined by "\n" plus a final "\n".
func Hash(lines []string) string {
	s := sha256.Sum256([]byte(strings.Join(lines, "\n") + "\n"))
	return hex.EncodeToString(s[:])
}

func fileLines(text string) []string {
	return strings.Split(strings.TrimSuffix(text, "\n"), "\n")
}

func parseFile(capab, text string, p *Parsed) {
	var sec, req, id string
	var blk []string
	var wd, inac bool
	end := func() {
		if inac {
			p.ACs = append(p.ACs, AC{id, capab, sec, req, wd, Hash(blk)})
			addReq(p, capab, sec, req, id)
		}
		inac, blk = false, nil
	}
	for _, line := range fileLines(text) {
		lvl := 0
		for lvl < len(line) && line[lvl] == '#' {
			lvl++
		}
		if lvl > 0 && lvl <= 6 && lvl < len(line) && (line[lvl] == ' ' || line[lvl] == '\t') {
			if lvl <= 4 {
				end()
			}
			t := norm(line[lvl:])
			switch {
			case lvl == 2:
				sec, req = "", ""
				if sectionR.MatchString(t) {
					sec = strings.SplitN(t, " ", 2)[0]
				}
			case lvl == 3 && strings.HasPrefix(t, "Requirement:"):
				req = norm(t[12:])
				p.Requirements = append(p.Requirements, Req{capab, sec, req, []string{}})
			case lvl == 4 && strings.HasPrefix(t, "Scenario:"):
				rest := norm(t[9:])
				if m := idAtRe.FindString(rest); m != "" {
					id, wd, inac, blk = m, wdRe.MatchString(rest[len(m):]), true, []string{norm(line)}
				} else {
					p.NoID = append(p.NoID, NoID{capab, sec, req})
				}
			}
			continue
		}
		if inac {
			if n := norm(line); n != "" {
				blk = append(blk, n)
			}
		}
	}
	end()
}

func addReq(p *Parsed, capab, sec, req, id string) {
	if n := len(p.Requirements); n > 0 && p.Requirements[n-1].Capability == capab && p.Requirements[n-1].Title == req {
		p.Requirements[n-1].ACs = append(p.Requirements[n-1].ACs, id)
		return
	}
	p.Requirements = append(p.Requirements, Req{capab, sec, req, []string{id}})
}

// Parse reads the requirements of a root.
func Parse(root string) (*Parsed, error) {
	if st, err := os.Stat(root); err != nil || !st.IsDir() {
		return nil, fmt.Errorf("no directory %s", root)
	}
	ents, _ := os.ReadDir(filepath.Join(root, "specs"))
	p, n := &Parsed{ACs: []AC{}, NoID: []NoID{}, Requirements: []Req{}}, 0
	for _, e := range ents {
		b, err := os.ReadFile(filepath.Join(root, "specs", e.Name(), "spec.md"))
		if err != nil {
			continue
		}
		n++
		parseFile(e.Name(), string(b), p)
	}
	if n == 0 {
		return nil, fmt.Errorf("no specs/<capability>/spec.md under %s", root)
	}
	return p, nil
}

func acMap(p *Parsed) map[string]AC {
	m := map[string]AC{}
	for _, a := range p.ACs {
		m[a.ID] = a
	}
	return m
}

func uniq(ss []string) []string {
	m, out := map[string]bool{}, []string{}
	for _, s := range ss {
		if !m[s] {
			m[s] = true
			out = append(out, s)
		}
	}
	sort.Strings(out)
	return out
}

func has(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

// Expects maps AC ids to the base hash the change expects, in insertion order.
type Expects [][2]string

// MarshalJSON writes the ordered object.
func (e Expects) MarshalJSON() ([]byte, error) {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, kv := range e {
		if i > 0 {
			b.WriteByte(',')
		}
		k, _ := json.Marshal(kv[0])
		v, _ := json.Marshal(kv[1])
		b.Write(k)
		b.WriteByte(':')
		b.Write(v)
	}
	b.WriteByte('}')
	return b.Bytes(), nil
}

// Facts is the delta of a change against its base.
type Facts struct {
	Added     []string `json:"added"`
	Modified  []string `json:"modified"`
	Removed   []string `json:"removed"`
	Unchanged []string `json:"unchanged"`
	Touches   []string `json:"touches"`
	Expects   Expects  `json:"expects"`
	Problems  []string `json:"problems"`
}

// Compute reports what the delta in changeDir adds, modifies and removes against base.
func Compute(changeDir, baseDir string) (*Facts, error) {
	d, err := Parse(changeDir)
	if err != nil {
		return nil, err
	}
	b, err := Parse(baseDir)
	if err != nil {
		return nil, err
	}
	bm, dm := acMap(b), acMap(d)
	var added, modified, removed, unchanged, pAdded, pRm, pRm2, pMods []string
	for _, a := range d.ACs {
		if x, ok := bm[a.ID]; a.Section == "ADDED" && !ok {
			added = append(added, a.ID)
		} else if a.Section == "ADDED" && x.Withdrawn {
			pAdded = append(pAdded, fmt.Sprintf("ADDED %s reuses a withdrawn id (withdrawn ids are never reused)", a.ID))
		} else if a.Section == "ADDED" {
			pAdded = append(pAdded, fmt.Sprintf("ADDED %s exists already in the base (use MODIFIED)", a.ID))
		}
	}
	for _, r := range d.Requirements {
		if r.Section != "MODIFIED" {
			continue
		}
		var inb, baseacs []string
		for _, id := range r.ACs {
			if _, ok := bm[id]; ok {
				inb = append(inb, id)
			}
		}
		if len(inb) == 0 {
			pMods = append(pMods, fmt.Sprintf("MODIFIED requirement %q (%s) matches no AC of the base", r.Title, r.Capability))
			continue
		}
		for _, br := range b.Requirements {
			for _, id := range br.ACs {
				if has(inb, id) {
					baseacs = append(baseacs, br.ACs...)
					break
				}
			}
		}
		for _, id := range r.ACs {
			if _, ok := bm[id]; !ok {
				added = append(added, id)
			}
		}
		for _, id := range inb {
			switch x, y := dm[id], bm[id]; {
			case !x.Withdrawn && x.Hash != y.Hash:
				modified = append(modified, id)
			case x.Withdrawn && !y.Withdrawn:
				removed = append(removed, id)
			case !x.Withdrawn && x.Hash == y.Hash:
				unchanged = append(unchanged, id)
			}
		}
		for _, id := range uniq(baseacs) {
			if !bm[id].Withdrawn && !has(r.ACs, id) {
				pMods = append(pMods, fmt.Sprintf("MODIFIED requirement %q drops %s (keep it, or withdraw it with a `(withdrawn)` marker)", r.Title, id))
			}
		}
	}
	for _, a := range d.ACs {
		if a.Section != "REMOVED" {
			continue
		}
		if x, ok := bm[a.ID]; !ok {
			pRm = append(pRm, fmt.Sprintf("REMOVED %s is not in the base", a.ID))
		} else if x.Withdrawn {
			pRm2 = append(pRm2, fmt.Sprintf("REMOVED %s is already withdrawn in the base", a.ID))
		} else {
			removed = append(removed, a.ID)
		}
	}
	pRm = append(pRm, pRm2...)
	for _, r := range d.Requirements {
		if r.Section != "REMOVED" || len(r.ACs) > 0 {
			continue
		}
		found := false
		for _, br := range b.Requirements {
			if br.Capability == r.Capability && br.Title == r.Title {
				found = true
				for _, id := range br.ACs {
					if !bm[id].Withdrawn {
						removed = append(removed, id)
					}
				}
			}
		}
		if !found {
			pRm = append(pRm, fmt.Sprintf("REMOVED requirement %q (%s) is not in the base", r.Title, r.Capability))
		}
	}
	f := &Facts{Added: uniq(added), Modified: uniq(modified), Removed: uniq(removed), Unchanged: uniq(unchanged), Expects: Expects{}}
	f.Touches = uniq(append(append(append([]string{}, f.Added...), f.Modified...), f.Removed...))
	for _, id := range append(append([]string{}, f.Modified...), f.Removed...) {
		f.Expects = append(f.Expects, [2]string{id, bm[id].Hash})
	}
	f.Problems = append(append(append([]string{}, pAdded...), pRm...), pMods...)
	counts := map[string]int{}
	var dups []string
	for _, a := range d.ACs {
		counts[a.ID]++
	}
	for id, n := range counts {
		if n > 1 {
			dups = append(dups, id)
		}
	}
	sort.Strings(dups)
	for _, id := range dups {
		f.Problems = append(f.Problems, id+" appears more than once in the delta")
	}
	for _, n := range d.NoID {
		f.Problems = append(f.Problems, fmt.Sprintf("a scenario without an AC id in %s (%s)", n.Capability, n.Requirement))
	}
	return f, nil
}

type pair struct {
	K string
	V json.RawMessage
}

// okv decodes the top level of a JSON object keeping the key order.
func okv(raw []byte) ([]pair, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return nil, fmt.Errorf("not a JSON object")
	}
	var out []pair
	for dec.More() {
		k, err := dec.Token()
		if err != nil {
			return nil, err
		}
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, err
		}
		out = append(out, pair{k.(string), v})
	}
	return out, nil
}

func field(ps []pair, k string) json.RawMessage {
	for i := len(ps) - 1; i >= 0; i-- {
		if ps[i].K == k {
			return ps[i].V
		}
	}
	return nil
}

func readObj(path string) ([]pair, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return okv(b)
}

func strOf(raw json.RawMessage) string {
	var s string
	_ = json.Unmarshal(raw, &s)
	return s
}

func strList(raw json.RawMessage) []string {
	var l []string
	_ = json.Unmarshal(raw, &l)
	return l
}

// Moved lists the ids whose text in base is no longer the one the change expects
// (from expectsFile, else changeDir/change.json).
func Moved(changeDir, baseDir, expectsFile string) ([]string, error) {
	if expectsFile == "" {
		expectsFile = filepath.Join(changeDir, "change.json")
	}
	if _, err := os.Stat(expectsFile); err != nil {
		return nil, fmt.Errorf("no %s (the change records what it expects)", expectsFile)
	}
	b, err := Parse(baseDir)
	if err != nil {
		return nil, err
	}
	ps, err := readObj(expectsFile)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s", expectsFile)
	}
	bm, out := acMap(b), []string{}
	exp, _ := okv(field(ps, "expects"))
	for _, p := range exp {
		if bm[p.K].Hash != strOf(p.V) || bm[p.K].ID == "" {
			out = append(out, p.K)
		}
	}
	return out, nil
}

// Collision is an AC id two siblings both add; Same is true when their text is the same.
type Collision struct {
	ID      string   `json:"id"`
	Same    bool     `json:"same"`
	Changes []string `json:"changes"`
}

// Shared is an AC id two siblings both modify or remove.
type Shared struct {
	ID      string   `json:"id"`
	Changes []string `json:"changes"`
}

// Overlap is the conflict report of sibling changes.
type Overlap struct {
	Collisions []Collision `json:"collisions"`
	Shared     []Shared    `json:"shared"`
}

type sibling struct {
	slug, createdAt string
	order           int
	added, touched  []string
	hashes          map[string]string
}

// OverlapOf compares sibling changes against base, ordered by createdAt (else argument order).
func OverlapOf(dirs []string, baseDir string) (*Overlap, error) {
	var its []sibling
	for i, c := range dirs {
		s := sibling{slug: filepath.Base(c), order: i + 1, hashes: map[string]string{}}
		if ps, err := readObj(filepath.Join(c, "change.json")); err == nil {
			s.createdAt = strOf(field(ps, "createdAt"))
		}
		f, err := Compute(c, baseDir)
		if err != nil {
			return nil, err
		}
		d, _ := Parse(c)
		s.added, s.touched = f.Added, append(append([]string{}, f.Modified...), f.Removed...)
		for _, a := range d.ACs {
			s.hashes[a.ID] = a.Hash
		}
		its = append(its, s)
	}
	sort.SliceStable(its, func(i, j int) bool {
		a, b := its[i], its[j]
		if (a.createdAt == "") != (b.createdAt == "") {
			return b.createdAt == ""
		}
		if a.createdAt != b.createdAt {
			return a.createdAt < b.createdAt
		}
		return a.order < b.order
	})
	o := &Overlap{Collisions: []Collision{}, Shared: []Shared{}}
	var addedAll, touchedAll []string
	for _, s := range its {
		addedAll, touchedAll = append(addedAll, s.added...), append(touchedAll, s.touched...)
	}
	who := func(id string, pick func(sibling) []string) (slugs []string, hs []string) {
		for _, s := range its {
			if has(pick(s), id) {
				slugs, hs = append(slugs, s.slug), append(hs, s.hashes[id])
			}
		}
		return
	}
	for _, id := range uniq(addedAll) {
		if sl, hs := who(id, func(s sibling) []string { return s.added }); len(sl) > 1 {
			o.Collisions = append(o.Collisions, Collision{id, len(uniq(hs)) == 1, sl})
		}
	}
	for _, id := range uniq(touchedAll) {
		if sl, _ := who(id, func(s sibling) []string { return s.touched }); len(sl) > 1 {
			o.Shared = append(o.Shared, Shared{id, sl})
		}
	}
	return o, nil
}

// Cites are the AC and ADR ids a change's markdown mentions.
type Cites struct {
	ACs  []string `json:"acs"`
	ADRs []string `json:"adrs"`
}

// PlanChange is one open change in the merge-specs stage 1 plan.
type PlanChange struct {
	Slug         json.RawMessage `json:"slug"`
	Title        json.RawMessage `json:"title"`
	Kind         json.RawMessage `json:"kind"`
	Label        json.RawMessage `json:"label"`
	CreatedAt    json.RawMessage `json:"createdAt"`
	Base         json.RawMessage `json:"base"`
	Resolutions  json.RawMessage `json:"resolutions"`
	Added        []string        `json:"added"`
	Modified     []string        `json:"modified"`
	Removed      []string        `json:"removed"`
	Problems     []string        `json:"problems"`
	ExpectsMoved []string        `json:"expectsMoved"`
	Cites        Cites           `json:"cites"`
	Capabilities []string        `json:"capabilities"`
}

// Plan is the JSON for merge-specs stage 1.
type Plan struct {
	BaseACs    int          `json:"baseAcs"`
	Changes    []PlanChange `json:"changes"`
	Collisions []Collision  `json:"collisions"`
	Shared     []Shared     `json:"shared"`
}

func changeStatus(dir string) string {
	ps, err := readObj(filepath.Join(dir, "change.json"))
	if err != nil {
		return ""
	}
	return strOf(field(ps, "status"))
}

func citesOf(dir string) Cites {
	var all []string
	_ = filepath.WalkDir(dir, func(p string, e os.DirEntry, err error) error {
		if err == nil && !e.IsDir() && strings.HasSuffix(p, ".md") {
			b, _ := os.ReadFile(p)
			all = append(all, citeRe.FindAllString(string(b), -1)...)
		}
		return nil
	})
	c := Cites{ACs: []string{}, ADRs: []string{}}
	for _, s := range uniq(all) {
		if strings.HasPrefix(s, "AC-") {
			c.ACs = append(c.ACs, s)
		} else {
			c.ADRs = append(c.ADRs, s)
		}
	}
	return c
}

// PlanOf builds the plan of the named open changes (default: all in root/changes).
func PlanOf(root string, slugs []string) (*Plan, error) {
	if len(slugs) == 0 {
		ents, _ := os.ReadDir(filepath.Join(root, "changes"))
		for _, e := range ents {
			if e.IsDir() && changeStatus(filepath.Join(root, "changes", e.Name())) == "open" {
				slugs = append(slugs, e.Name())
			}
		}
	}
	if len(slugs) == 0 {
		return nil, fmt.Errorf("no open change under %s/changes", root)
	}
	b, err := Parse(root)
	if err != nil {
		return nil, err
	}
	p, dirs := &Plan{BaseACs: len(b.ACs), Changes: []PlanChange{}}, []string{}
	for _, sl := range slugs {
		c := filepath.Join(root, "changes", sl)
		ps, err := readObj(filepath.Join(c, "change.json"))
		if err != nil {
			return nil, fmt.Errorf("no change.json in %s", c)
		}
		dirs = append(dirs, c)
		f, err := Compute(c, root)
		if err != nil {
			return nil, err
		}
		mv, _ := Moved(c, root, "")
		pc := PlanChange{field(ps, "slug"), field(ps, "title"), field(ps, "kind"), field(ps, "label"), field(ps, "createdAt"), field(ps, "base"), nil,
			f.Added, f.Modified, f.Removed, f.Problems, append([]string{}, mv...), citesOf(c), []string{}}
		if r := field(ps, "resolutions"); string(r) != "false" {
			pc.Resolutions = r
		}
		caps, _ := os.ReadDir(filepath.Join(c, "specs"))
		for _, e := range caps {
			if !strings.HasPrefix(e.Name(), ".") {
				pc.Capabilities = append(pc.Capabilities, e.Name())
			}
		}
		p.Changes = append(p.Changes, pc)
	}
	sort.SliceStable(p.Changes, func(i, j int) bool { return strOf(p.Changes[i].CreatedAt) < strOf(p.Changes[j].CreatedAt) })
	o, err := OverlapOf(dirs, root)
	if err != nil {
		return nil, err
	}
	p.Collisions, p.Shared = o.Collisions, o.Shared
	return p, nil
}

// Coverage checks, after an apply, that nothing of any applied change is lost;
// idsBefore is a file of the AC ids before the apply (optional).
func Coverage(root, idsBefore string) ([]string, error) {
	b, err := Parse(root)
	if err != nil {
		return nil, err
	}
	var applied []string
	ents, _ := os.ReadDir(filepath.Join(root, "changes"))
	for _, e := range ents {
		if e.IsDir() && changeStatus(filepath.Join(root, "changes", e.Name())) == "applied" {
			applied = append(applied, filepath.Join(root, "changes", e.Name()))
		}
	}
	if len(applied) == 0 {
		return nil, nil
	}
	bm, probs, res := acMap(b), []string{}, []string{}
	cjs := map[string][]pair{}
	for _, c := range applied {
		ps, _ := readObj(filepath.Join(c, "change.json"))
		cjs[c] = ps
		var rs []struct{ Item string }
		_ = json.Unmarshal(field(ps, "resolutions"), &rs)
		for _, r := range rs {
			res = append(res, r.Item)
		}
	}
	for _, c := range applied {
		d, err := Parse(c)
		if err != nil {
			return nil, err
		}
		sl, tc := filepath.Base(c), strList(field(cjs[c], "touches"))
		tk, _ := os.ReadFile(filepath.Join(c, "tasks.md"))
		for _, p := range lint.CheckTasksMD(sl+"/tasks.md", string(tk), lint.PickedRoles(root)) {
			probs = append(probs, fmt.Sprintf("%s: %s", sl, strings.TrimPrefix(p.String(), "lint: error ")))
		}
		for _, a := range d.ACs {
			if !has(tc, a.ID) {
				continue
			}
			x, ok := bm[a.ID]
			switch {
			case a.Section == "REMOVED":
				if !x.Withdrawn && !has(res, a.ID) {
					probs = append(probs, fmt.Sprintf("%s: %s was removed but is not withdrawn in the base", sl, a.ID))
				}
			case !ok:
				probs = append(probs, fmt.Sprintf("%s: %s is missing from the base", sl, a.ID))
			case x.Hash != a.Hash && !has(res, a.ID):
				probs = append(probs, fmt.Sprintf("%s: %s differs from the base and has no recorded resolution", sl, a.ID))
			}
		}
		for _, a := range d.ACs {
			if (a.Section == "ADDED" || a.Section == "MODIFIED") && !a.Withdrawn && has(tc, a.ID) &&
				!regexp.MustCompile(`(^|[^A-Za-z0-9_-])`+regexp.QuoteMeta(a.ID)+`([^0-9A-Za-z_]|$)`).Match(tk) {
				probs = append(probs, fmt.Sprintf("%s: its tasks.md does not cover %s", sl, a.ID))
			}
		}
	}
	counts, now := map[string]int{}, []string{}
	for _, a := range b.ACs {
		counts[a.ID]++
		now = append(now, a.ID)
	}
	var twice []string
	for id, n := range counts {
		if n > 1 {
			twice = append(twice, id)
		}
	}
	sort.Strings(twice)
	for _, id := range twice {
		probs = append(probs, fmt.Sprintf("AC id %s appears twice in the base", id))
	}
	if ids, err := os.ReadFile(idsBefore); idsBefore != "" && err == nil {
		for _, id := range strings.Split(string(ids), "\n") {
			if id != "" && !has(now, id) {
				probs = append(probs, fmt.Sprintf("AC id %s was lost by the apply", id))
			}
		}
	}
	files, _ := filepath.Glob(filepath.Join(root, "specs", "*", "spec.md"))
	for _, f := range append(files, filepath.Join(root, "tasks.md")) {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, t := range uniq(idRe.FindAllString(string(b), -1)) {
			if !has(now, t) {
				probs = append(probs, fmt.Sprintf("%s/%s: reference to %s does not resolve", filepath.Base(filepath.Dir(f)), filepath.Base(f), t))
			}
		}
	}
	return probs, nil
}

var (
	hexRe    = regexp.MustCompile(`^[0-9a-f]{64}$`)
	labelRe  = regexp.MustCompile(`^[0-9]+\.[0-9]+$`)
	createRe = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$`)
)

func isStr(raw json.RawMessage) (string, bool) {
	var s string
	return s, json.Unmarshal(raw, &s) == nil && raw != nil
}

func objOf(raw json.RawMessage) map[string]json.RawMessage {
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return nil
	}
	return m
}

// Validate checks change.json in changeDir; with baseDir also the delta against
// the base and touches == the delta's. It returns the reasons.
func Validate(changeDir, baseDir string) ([]string, error) {
	cj := filepath.Join(changeDir, "change.json")
	raw, err := os.ReadFile(cj)
	if err != nil {
		return nil, fmt.Errorf("no change.json in %s", changeDir)
	}
	if !json.Valid(raw) {
		return nil, fmt.Errorf("%s is not valid JSON", cj)
	}
	ps, _ := okv(raw)
	slug := filepath.Base(changeDir)
	str := func(k string) (string, bool) { s, ok := isStr(field(ps, k)); return s, ok && s != "" }
	var probs []string
	bad := func(ok bool, msg string) {
		if !ok {
			probs = append(probs, msg)
		}
	}
	s, ok := str("slug")
	bad(ok && s == slug, fmt.Sprintf("slug must be a non-empty string equal to the directory name (%s)", slug))
	_, ok = str("title")
	bad(ok, "title is missing")
	k, _ := str("kind")
	bad(k == "fix" || k == "feature", "kind must be fix or feature")
	l, _ := str("label")
	bad(labelRe.MatchString(l), "label must look like 1.1")
	st, _ := str("status")
	bad(st == "open" || st == "applied", "status must be open or applied")
	ca, _ := str("createdAt")
	bad(createRe.MatchString(ca), "createdAt must be an ISO UTC time")
	bs := objOf(field(ps, "base"))
	v, _ := isStr(bs["version"])
	h, _ := isStr(bs["contentHash"])
	bad(bs != nil && labelRe.MatchString(v) && hexRe.MatchString(h), "base needs a version and a sha256 contentHash")
	ex := objOf(field(ps, "expects"))
	okEx := ex != nil
	for k, raw := range ex {
		h, _ := isStr(raw)
		okEx = okEx && strings.HasPrefix(k, "AC-") && hexRe.MatchString(h)
	}
	bad(okEx, "expects must map AC ids to sha256 hashes")
	var tc []any
	okT := json.Unmarshal(field(ps, "touches"), &tc) == nil && string(field(ps, "touches")) != "null"
	for _, x := range tc {
		t, isS := x.(string)
		okT = okT && isS && strings.HasPrefix(t, "AC-")
	}
	bad(okT, "touches must be an array of AC ids")
	rn, okR := objOf(field(ps, "renames")), true
	if r := field(ps, "renames"); r != nil && string(r) != "null" {
		okR = rn != nil
		for k, raw := range rn {
			t, _ := isStr(raw)
			okR = okR && strings.HasPrefix(k, "AC-") && strings.HasPrefix(t, "AC-")
		}
	}
	bad(okR, "renames must map AC ids to AC ids")
	okRes := true
	if r := field(ps, "resolutions"); r != nil && string(r) != "null" {
		var rs []map[string]json.RawMessage
		okRes = json.Unmarshal(r, &rs) == nil
		for _, m := range rs {
			for _, f := range []string{"item", "decision", "why", "by"} {
				s, ok := isStr(m[f])
				okRes = okRes && ok && s != ""
			}
		}
	}
	bad(okRes, "each resolution needs item, decision, why and by")
	if st == "applied" {
		ap := objOf(field(ps, "applied"))
		okA := ap != nil
		for _, f := range []string{"version", "at", "sha"} {
			s, ok := isStr(ap[f])
			okA = okA && ok && s != ""
		}
		bad(okA, "an applied change needs applied {version, at, sha}")
	}
	if baseDir != "" && len(probs) == 0 {
		f, err := Compute(changeDir, baseDir)
		if err != nil {
			return nil, fmt.Errorf("cannot read the delta of %s or the base %s", changeDir, baseDir)
		}
		probs = append(probs, f.Problems...)
		have := append([]string{}, strList(field(ps, "touches"))...)
		sort.Strings(have)
		bad(strings.Join(have, ",") == strings.Join(f.Touches, ","), fmt.Sprintf("touches in change.json (%s) differ from the delta (%s)", strings.Join(have, ","), strings.Join(f.Touches, ",")))
		var ek []string
		for k := range ex {
			ek = append(ek, k)
		}
		var fk []string
		for _, e := range f.Expects {
			fk = append(fk, e[0])
		}
		bad(strings.Join(uniq(ek), ",") == strings.Join(uniq(fk), ","), "expects in change.json names other ACs than the delta modifies or removes")
	}
	return probs, nil
}

const changeUsage = "usage: sdkit spec change parse <root> | compute <change-dir> --base <root> | moved <change-dir> --base <root> [--expects FILE] | overlap <change-dir>... --base <root> | plan <spec-root> [<slug>...] | coverage <spec-root> [--ids-before FILE] | validate <change-dir> [--base <root>]"

func writeJSON(w io.Writer, v any) {
	var b, ind bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
	_ = json.Indent(&ind, bytes.TrimSpace(b.Bytes()), "", "  ")
	ind.WriteByte('\n')
	_, _ = w.Write(ind.Bytes())
}

// RunChange runs `sdkit spec change <verb> ...`: facts only, never a write. Exit 0 ok, 1 problems, 2 usage.
func RunChange(args []string, out, errw io.Writer) int {
	fail := func(err error) int { fmt.Fprintf(errw, "spec-change: %v\n", err); return 1 }
	usage := func() int { fmt.Fprintln(errw, changeUsage); return 2 }
	if len(args) == 0 {
		return usage()
	}
	verb, pos, base, expects := args[0], []string{}, "", ""
	for i := 1; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--base" || a == "--expects" || (verb == "coverage" && a == "--ids-before"):
			v := ""
			if i+1 < len(args) {
				i++
				v = args[i]
			}
			if a == "--base" {
				base = v
			} else {
				expects = v
			}
		case strings.HasPrefix(a, "--"):
			return usage()
		default:
			pos = append(pos, a)
		}
	}
	n := len(pos)
	switch {
	case verb == "parse" && n == 1 && base == "":
		p, err := Parse(pos[0])
		if err != nil {
			return fail(err)
		}
		writeJSON(out, p)
	case verb == "compute" && n == 1 && base != "":
		f, err := Compute(pos[0], base)
		if err != nil {
			return fail(err)
		}
		writeJSON(out, f)
		if len(f.Problems) > 0 {
			return 1
		}
	case verb == "moved" && n == 1 && base != "":
		ids, err := Moved(pos[0], base, expects)
		if err != nil {
			return fail(err)
		}
		for _, id := range ids {
			fmt.Fprintln(out, id)
		}
		if len(ids) > 0 {
			return 1
		}
	case verb == "overlap" && n >= 1 && base != "":
		o, err := OverlapOf(pos, base)
		if err != nil {
			return fail(err)
		}
		writeJSON(out, o)
	case verb == "plan" && n >= 1:
		p, err := PlanOf(pos[0], pos[1:])
		if err != nil {
			return fail(err)
		}
		writeJSON(out, p)
	case verb == "coverage" && n == 1:
		probs, err := Coverage(pos[0], expects)
		if err != nil {
			return fail(err)
		}
		for _, p := range probs {
			fmt.Fprintln(out, p)
		}
		if len(probs) > 0 {
			return 1
		}
	case verb == "validate" && n == 1:
		probs, err := Validate(pos[0], base)
		if err != nil {
			return fail(err)
		}
		for _, p := range probs {
			fmt.Fprintf(out, "spec-change: %s\n", p)
		}
		if len(probs) > 0 {
			return 1
		}
		fmt.Fprintf(out, "spec-change: %s ok\n", filepath.Base(pos[0]))
	default:
		return usage()
	}
	return 0
}
