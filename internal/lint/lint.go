// Package lint is the mechanical half of a spec review: the consistency errors a model reviewer keeps
// rediscovering round after round (AC ids, gate markers against the question table, cross-references,
// tasks.md coverage). It is deterministic and knows only the kit's own conventions (AC-<feature>-<n>,
// "(withdrawn)"); every other convention (reference prefixes, marker words) comes from Config.
package lint

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Config is what a project may tune (sdkit.env: LINT_*). The zero value runs only the AC checks.
type Config struct {
	RefPrefixes []string // reference letters whose uses must have a definition, e.g. D Q R
	GatePrefix  string   // the letter of open questions that gate ACs ("Q"); "" disables the marker check
	Withdrawn   []string // words that mark a definition withdrawn (lower case); empty means "withdrawn"
	MarkerWords []string // words that mark an AC as gated in its title, e.g. pending conditional (lower case)
	ClosedWords []string // words that mark a question row as closed, e.g. closed (lower case)
}

// Problem is one finding. Severity is "error" (blocks a review round) or "warn".
type Problem struct {
	Severity, Code, File string
	Line                 int
	Msg                  string
}

func (p Problem) String() string {
	return fmt.Sprintf("lint: %s %s %s:%d %s", p.Severity, p.Code, p.File, p.Line, p.Msg)
}

// Errors counts the blocking problems.
func Errors(ps []Problem) int {
	n := 0
	for _, p := range ps {
		if p.Severity == "error" {
			n++
		}
	}
	return n
}

type file struct {
	rel   string
	lines []string
}

// Run lints the markdown files of a directory (or one file) and returns the problems, errors first by file order.
func Run(target string, cfg Config) ([]Problem, error) {
	files, err := load(target)
	if err != nil {
		return nil, err
	}
	var ps []Problem
	defs := acDefs(files, cfg)
	ps = append(ps, checkACs(files, defs)...)
	ps = append(ps, checkTasksCoverage(files, defs)...)
	ps = append(ps, checkTaskRoles(files, target)...)
	ps = append(ps, checkBusinessRequirements(files, defs)...)
	if cfg.GatePrefix != "" {
		ps = append(ps, checkGates(files, defs, cfg)...)
	}
	if len(cfg.RefPrefixes) > 0 {
		ps = append(ps, checkRefs(files, cfg.RefPrefixes)...)
	}
	return ps, nil
}

func load(target string) ([]file, error) {
	st, err := os.Stat(target)
	if err != nil {
		return nil, err
	}
	var out []file
	read := func(p, rel string) error {
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		out = append(out, file{rel, strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")})
		return nil
	}
	if !st.IsDir() {
		return out, read(target, filepath.Base(target))
	}
	err = filepath.WalkDir(target, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(target, p)
		rel = filepath.ToSlash(rel)
		if d.IsDir() && (rel == "changes" || strings.HasPrefix(d.Name(), ".")) && rel != "." {
			return fs.SkipDir
		}
		if d.Type().IsRegular() && strings.HasSuffix(d.Name(), ".md") {
			return read(p, rel)
		}
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].rel < out[j].rel })
	return out, err
}

// acID: AC-<feature>-<n>; a following ", 47, 71" is shorthand for more ids of the same feature.
var (
	acRe    = regexp.MustCompile(`\bAC-[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*(?:[ \t]*,[ \t]*\d+\b)*`)
	acOneRe = regexp.MustCompile(`^(AC-(?:[A-Za-z0-9_]+-)*?)(\d+)$`)
	// the id at the start of a definition: a scenario title, a heading or the first cell of a table row (a bullet only mentions)
	defLead = regexp.MustCompile(`^[ \t]*(?:#{2,6}[ \t]+(?:Scenario:[ \t]*)?|\|[ \t]*)\**(AC-[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*)`)
	paren   = regexp.MustCompile(`\(([^)]*)\)`)
)

// expand turns "AC-X-21, 47, 71" into AC-X-21 AC-X-47 AC-X-71.
func expand(tok string) []string {
	parts := strings.Split(tok, ",")
	first := strings.TrimSpace(parts[0])
	out := []string{first}
	m := acOneRe.FindStringSubmatch(first)
	if m == nil {
		return out
	}
	for _, p := range parts[1:] {
		out = append(out, m[1]+strings.TrimSpace(p))
	}
	return out
}

type acDef struct {
	file      string
	line      int
	withdrawn bool
	words     string // lower-cased text of the parentheses after the id
}

func acDefs(files []file, cfg Config) map[string][]acDef {
	wd := cfg.Withdrawn
	if len(wd) == 0 {
		wd = []string{"withdrawn"}
	}
	defs := map[string][]acDef{}
	for _, f := range files {
		for i, l := range f.lines {
			m := defLead.FindStringSubmatchIndex(l)
			if m == nil {
				continue
			}
			id := l[m[2]:m[3]]
			rest := l[m[3]:]
			if j := strings.Index(rest, "|"); j >= 0 {
				rest = rest[:j]
			}
			d := acDef{file: f.rel, line: i + 1}
			if pm := paren.FindStringSubmatch(rest); pm != nil {
				d.words = strings.ToLower(pm[1])
			}
			low := strings.ToLower(l)
			for _, w := range wd {
				d.withdrawn = d.withdrawn || strings.Contains(low, w)
			}
			defs[id] = append(defs[id], d)
		}
	}
	return defs
}

func checkACs(files []file, defs map[string][]acDef) []Problem {
	var ps []Problem
	ids := sortedKeys(defs)
	for _, id := range ids {
		if d := defs[id]; len(d) > 1 {
			ps = append(ps, Problem{"error", "ac-duplicate", d[1].file, d[1].line, fmt.Sprintf("%s is defined %d times (first at %s:%d)", id, len(d), d[0].file, d[0].line)})
		}
	}
	// ids used somewhere but defined nowhere
	seen := map[string]bool{}
	for _, f := range files {
		for i, l := range f.lines {
			for _, tok := range acRe.FindAllString(l, -1) {
				for _, id := range expand(tok) {
					if _, ok := defs[id]; !ok && !seen[id] {
						seen[id] = true
						ps = append(ps, Problem{"error", "ac-undefined", f.rel, i + 1, id + " is used but never defined"})
					}
				}
			}
		}
	}
	// a hole in a feature's numbering that is neither defined nor withdrawn: ids are never renumbered, so a gap is a silent removal
	byFeat := map[string][]int{}
	for _, id := range ids {
		if m := acOneRe.FindStringSubmatch(id); m != nil {
			n, _ := strconv.Atoi(m[2])
			byFeat[m[1]] = append(byFeat[m[1]], n)
		}
	}
	for _, feat := range sortedKeys(byFeat) {
		ns := byFeat[feat]
		sort.Ints(ns)
		var gaps []string
		for i := 1; i < len(ns); i++ {
			for g := ns[i-1] + 1; g < ns[i] && len(gaps) < 8; g++ {
				gaps = append(gaps, strconv.Itoa(g))
			}
		}
		if len(gaps) > 0 {
			ps = append(ps, Problem{"warn", "ac-gap", defs[feat+strconv.Itoa(ns[0])][0].file, defs[feat+strconv.Itoa(ns[0])][0].line, fmt.Sprintf("%s numbering skips %s (a removed AC stays as '(withdrawn)')", feat+"n", strings.Join(gaps, ", "))})
		}
	}
	return ps
}

// checkTasksCoverage: tasks.md must cover every active AC (a rule of the propose step).
func checkTasksCoverage(files []file, defs map[string][]acDef) []Problem {
	var tf *file
	for i := range files {
		if filepath.Base(files[i].rel) == "tasks.md" {
			tf = &files[i]
		}
	}
	if tf == nil {
		return nil
	}
	mentioned := map[string]bool{}
	for _, l := range tf.lines {
		for _, tok := range acRe.FindAllString(l, -1) {
			for _, id := range expand(tok) {
				mentioned[id] = true
			}
		}
	}
	var miss []string
	for _, id := range sortedKeys(defs) {
		if !mentioned[id] && !defs[id][0].withdrawn {
			miss = append(miss, id)
		}
	}
	if len(miss) == 0 {
		return nil
	}
	more := ""
	if len(miss) > 10 {
		more, miss = fmt.Sprintf(" (+%d more)", len(miss)-10), miss[:10]
	}
	return []Problem{{"error", "tasks-coverage", tf.rel, 1, "tasks.md does not cover: " + strings.Join(miss, " ") + more}}
}

// checkGates: an AC marked as gated by a question needs that question's row, open, and the row must list the AC. The reverse is
// not checked: a row lists every AC it affects, the marker only those whose outcome is conditional.
func checkGates(files []file, defs map[string][]acDef, cfg Config) []Problem {
	qid := regexp.MustCompile(`(?i)\b` + regexp.QuoteMeta(cfg.GatePrefix) + `-?\d+[a-z]?\b`)
	row := regexp.MustCompile(`^\|[ \t]*\**(` + regexp.QuoteMeta(cfg.GatePrefix) + `-?\d+[a-z]?)\**[ \t]*\|`)
	type q struct {
		closed bool
		acs    map[string]bool
		file   string
		line   int
	}
	qs := map[string]*q{}
	norm := func(s string) string { return strings.ToUpper(strings.ReplaceAll(s, "-", "")) }
	for _, f := range files {
		for i, l := range f.lines {
			m := row.FindStringSubmatch(l)
			if m == nil {
				continue
			}
			r := &q{acs: map[string]bool{}, file: f.rel, line: i + 1}
			low := strings.ToLower(l)
			for _, w := range cfg.ClosedWords {
				r.closed = r.closed || strings.Contains(low, w)
			}
			for _, tok := range acRe.FindAllString(l, -1) {
				for _, id := range expand(tok) {
					r.acs[id] = true
				}
			}
			qs[norm(m[1])] = r
		}
	}
	marks := map[string]map[string]bool{} // ac -> gate ids named by its marker
	for id, ds := range defs {
		for _, d := range ds {
			for _, w := range cfg.MarkerWords {
				if strings.Contains(d.words, w) {
					if marks[id] == nil {
						marks[id] = map[string]bool{}
					}
					for _, g := range qid.FindAllString(d.words, -1) {
						marks[id][norm(g)] = true
					}
				}
			}
		}
	}
	var ps []Problem
	for _, ac := range sortedKeys(marks) {
		for _, g := range sortedKeys(marks[ac]) {
			r := qs[g]
			switch {
			case r == nil:
				ps = append(ps, Problem{"error", "gate-undefined", defs[ac][0].file, defs[ac][0].line, fmt.Sprintf("%s is marked for %s, which has no row in a question table", ac, g)})
			case r.closed:
				ps = append(ps, Problem{"error", "gate-closed", defs[ac][0].file, defs[ac][0].line, fmt.Sprintf("%s still carries a marker for %s, which is closed (%s:%d)", ac, g, r.file, r.line)})
			case !r.acs[ac] && len(r.acs) > 0:
				ps = append(ps, Problem{"error", "gate-unlisted", defs[ac][0].file, defs[ac][0].line, fmt.Sprintf("%s is marked for %s but %s's row (%s:%d) does not list it", ac, g, g, r.file, r.line)})
			}
		}
	}
	return ps
}

// checkRefs: every use of a configured reference (D3, R-2, Q1 ...) needs a definition at the start of a line.
func checkRefs(files []file, prefixes []string) []Problem {
	alt := make([]string, len(prefixes))
	for i, p := range prefixes {
		alt[i] = regexp.QuoteMeta(p)
	}
	idp := `(?:` + strings.Join(alt, "|") + `)-?\d+[a-z]?`
	use := regexp.MustCompile(`\b` + idp + `\b`)
	lead := regexp.MustCompile(`^[ \t]*(?:#{1,6}[ \t]+|[-*+][ \t]+|\|[ \t]*)?\**(` + idp + `(?:[ \t]*[,/][ \t]*` + idp + `)*)\b`)
	norm := func(s string) string { return strings.ReplaceAll(s, "-", "") }
	defined := map[string]bool{}
	for _, f := range files {
		for _, l := range f.lines {
			if m := lead.FindStringSubmatch(l); m != nil {
				for _, id := range use.FindAllString(m[1], -1) {
					defined[norm(id)] = true
				}
			}
		}
	}
	var ps []Problem
	seen := map[string]bool{}
	for _, f := range files {
		for i, l := range f.lines {
			if strings.Contains(l, "AC-") {
				l = acRe.ReplaceAllString(l, "") // ids inside AC ids are not references
			}
			for _, id := range use.FindAllString(l, -1) {
				if n := norm(id); !defined[n] && !seen[n] {
					seen[n] = true
					ps = append(ps, Problem{"error", "ref-undefined", f.rel, i + 1, id + " is referenced but never defined"})
				}
			}
		}
	}
	return ps
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// ACIDs lists the AC ids a document defines (withdrawn ones included: an id once issued stays issued), sorted.
func ACIDs(target string) []string {
	files, err := load(target)
	if err != nil {
		return nil
	}
	return sortedKeys(acDefs(files, Config{}))
}

// ActiveACIDs lists the AC ids a document defines that are not withdrawn, sorted: the ones a design must account for.
func ActiveACIDs(target string) []string {
	files, err := load(target)
	if err != nil {
		return nil
	}
	var out []string
	for id, ds := range acDefs(files, Config{}) {
		if len(ds) > 0 && !ds[0].withdrawn {
			out = append(out, id)
		}
	}
	sort.Strings(out)
	return out
}

// BRMarker is what business-requirements.md carries on its first line: it says the file is a view of the spec, not a source.
const BRMarker = "sdkit: derived view"

// checkBusinessRequirements: a business-requirements.md (when the spec has one) must say it is a derived view and must account for
// every active AC, so a reader of that one page misses nothing the spec requires. An AC it cites that the spec does not define is
// already an ac-undefined error: every markdown file of the spec is read for that.
func checkBusinessRequirements(files []file, defs map[string][]acDef) []Problem {
	var f *file
	for i := range files {
		if files[i].rel == "business-requirements.md" {
			f = &files[i]
		}
	}
	if f == nil {
		return nil
	}
	var ps []Problem
	if !strings.Contains(strings.Join(f.lines[:min(3, len(f.lines))], "\n"), BRMarker) {
		ps = append(ps, Problem{"error", "br-marker", f.rel, 1, "the first line must be the derived-view marker (" + BRMarker + " ...): this file is a view of the spec, the spec files win"})
	}
	mentioned := map[string]bool{}
	for _, l := range f.lines {
		for _, tok := range acRe.FindAllString(l, -1) {
			for _, id := range expand(tok) {
				mentioned[id] = true
			}
		}
	}
	var miss []string
	for _, id := range sortedKeys(defs) {
		if !mentioned[id] && !defs[id][0].withdrawn {
			miss = append(miss, id)
		}
	}
	if len(miss) > 0 {
		more := ""
		if len(miss) > 10 {
			more, miss = fmt.Sprintf(" (+%d more)", len(miss)-10), miss[:10]
		}
		ps = append(ps, Problem{"error", "br-coverage", f.rel, 1, "business-requirements.md does not account for: " + strings.Join(miss, " ") + more})
	}
	return ps
}
