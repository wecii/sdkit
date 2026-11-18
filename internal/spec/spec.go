package spec

// The mechanics of a published spec (was scripts/spec.sh): branch, PR, version and metadata kept honest. The writing and the review are done by skills.
// Exit: 0 ok, 1 refused / not satisfied / a step failed, 2 usage, 3 drift or an apply that needs resolutions.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/wecii/sdkit/internal/envfile"
	"github.com/wecii/sdkit/internal/gitx"
	"github.com/wecii/sdkit/internal/pr"
	"github.com/wecii/sdkit/internal/proc"
	"github.com/wecii/sdkit/internal/project"
	"github.com/wecii/sdkit/internal/redact"
	"github.com/wecii/sdkit/internal/review"
)

const specUsage = "usage: sdkit spec change new|refresh|status <id> ... | drift <id> [slug] | check <id> | apply <id> [slug...] | init-meta <id> | hash <id> | status <id> | changed <id> | branch <id> | next <id> | publish <id> --title T --body-file F [--breaking] | promote <id> | approved-sha <id> --sha S"

// env is one invocation: the project, its settings and the two streams.
type env struct {
	root, specs, prespec, base, kit string
	protected                       []string
	get                             func(string) string
	out, err                        io.Writer
}

type exit int // a die: the code to end with

func newEnv(out, errw io.Writer) *env {
	wd, _ := os.Getwd()
	root := os.Getenv("CLAUDE_PROJECT_DIR")
	if root == "" {
		if t, err := gitx.Top(wd); err == nil {
			root = t
		} else {
			root = wd
		}
	}
	return envAt(root, out, errw)
}

func envAt(root string, out, errw io.Writer) *env {
	s, p, _ := project.Load(root)
	val := func(k, d string) string {
		if v := s.String(k); v != "" && !strings.HasPrefix(v, "__") {
			return v
		}
		return d
	}
	// The Bitbucket credentials come from the process environment, else from the personal sdkit.local.env;
	// never from the shared sdkit.env (a committed token is a leak).
	local := envfile.New()
	local.Quiet = true
	_ = local.LoadFile(filepath.Join(p.Dir(), "sdkit.local.env"))
	return &env{root: root, specs: val("SPECS_DIR", "specs"), prespec: strings.TrimRight(val("PRESPEC_DIR", "prespec"), "/"), base: val("BASE_BRANCH", "main"),
		kit: p.KitDir, protected: strings.Fields(strings.ReplaceAll(s.String("PROTECTED_BRANCHES"), ",", " ")), out: out, err: errw,
		get: func(k string) string {
			if v := os.Getenv(k); v != "" {
				return v
			}
			if k == "BITBUCKET_TOKEN" || k == "BITBUCKET_EMAIL" {
				return local.String(k)
			}
			return s.String(k)
		}}
}

func (e *env) die(f string, a ...any) exit { fmt.Fprintf(e.err, "spec: "+f+"\n", a...); return 1 }
func (e *env) say(f string, a ...any)      { fmt.Fprintf(e.out, f+"\n", a...) }
func now() string                          { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }

var reOK = regexp.MustCompile(`^[A-Za-z0-9_-][A-Za-z0-9._-]*$`)

func okname(s string) bool { return reOK.MatchString(s) }

func (e *env) g(a ...string) (string, error) { return gitx.Run(e.root, a...) }
func (e *env) gok(a ...string) bool          { _, err := gitx.Run(e.root, a...); return err == nil }
func (e *env) fetch(a ...string)             { _, _ = e.g(append([]string{"fetch", "-q", "origin"}, a...)...) }
func (e *env) branch() string                { b, _ := e.g("rev-parse", "--abbrev-ref", "HEAD"); return b }

// show is `git show ref:path` byte for byte (a trimmed file would change its hash).
func (e *env) show(ref, path string) (string, bool) {
	r, err := proc.Run(context.Background(), e.root, nil, "git", "show", ref+":"+path)
	return r.Stdout, err == nil && r.Code == 0
}

func (e *env) dir(id string) string { return e.specs + "/" + id }
func (e *env) abs(id string) string { return filepath.Join(e.root, filepath.FromSlash(e.dir(id))) }
func (e *env) metaPath(id string) string {
	return filepath.Join(e.abs(id), "spec.meta.json")
}
func (e *env) cdir(id, slug string) string { return e.dir(id) + "/changes/" + slug }
func (e *env) cabs(id, slug string) string {
	return filepath.Join(e.root, filepath.FromSlash(e.cdir(id, slug)))
}

type meta struct {
	ID, Version, Status, ContentHash string
	Review                           struct{ Verdict string }
	History                          []struct{ Version, Sha, At, ContentHash string }
}

func (e *env) meta(id string) meta {
	var m meta
	b, _ := os.ReadFile(e.metaPath(id))
	_ = json.Unmarshal(b, &m)
	return m
}

func (e *env) hasMeta(id string) bool { _, err := os.Stat(e.metaPath(id)); return err == nil }

func jstr(s string) json.RawMessage { b, _ := json.Marshal(s); return b }

func raw(v any) json.RawMessage {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
	return bytes.TrimSpace(b.Bytes())
}

// set replaces the value of key k in place, or appends it (jq's `.k = v`).
func set(ps []pair, k string, v json.RawMessage) []pair {
	for i := range ps {
		if ps[i].K == k {
			ps[i].V = v
			return ps
		}
	}
	return append(ps, pair{k, v})
}

func marshal(ps []pair) []byte {
	var b, ind bytes.Buffer
	b.WriteByte('{')
	for i, p := range ps {
		if i > 0 {
			b.WriteByte(',')
		}
		b.Write(jstr(p.K))
		b.WriteByte(':')
		b.Write(p.V)
	}
	b.WriteByte('}')
	if json.Indent(&ind, b.Bytes(), "", "  ") != nil {
		return append(b.Bytes(), '\n')
	}
	ind.WriteByte('\n')
	return ind.Bytes()
}

// writeAtomic writes next to path and renames over it.
func writeAtomic(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".tmp.")
	if err != nil {
		return err
	}
	_, werr := f.Write(data)
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		os.Remove(f.Name())
		return werr
	}
	if err := os.Rename(f.Name(), path); err != nil {
		os.Remove(f.Name())
		return err
	}
	return nil
}

func (e *env) wmeta(id string, ps []pair) error { return writeAtomic(e.metaPath(id), marshal(ps)) }

func (e *env) curHash(id string) string {
	t, err := review.Load(e.root).Target(id, "")
	if err != nil {
		return ""
	}
	h, _ := review.Hash(t)
	return h
}

func vcmp(a, b string) int {
	pa, pb := strings.SplitN(a, ".", 2), strings.SplitN(b, ".", 2)
	for i := 0; i < 2; i++ {
		x, y := 0, 0
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			return x - y
		}
	}
	return 0
}

func bump(v string, breaking bool) string {
	mj, mn, _ := strings.Cut(v, ".")
	a, _ := strconv.Atoi(mj)
	b, _ := strconv.Atoi(mn)
	if breaking {
		return fmt.Sprintf("%d.0", a+1)
	}
	return fmt.Sprintf("%d.%d", a, b+1)
}

var reURLUser = regexp.MustCompile(`(://)[^/@\s]+@`)

// maskGit hides credentials in what git printed: user:token@ in URLs, the Bitbucket token itself, token-looking assignments.
func (e *env) maskGit(s string) string {
	s = reURLUser.ReplaceAllString(s, "${1}***@")
	if t := e.get("BITBUCKET_TOKEN"); len(t) >= 6 {
		s = strings.ReplaceAll(s, t, "***")
	}
	return redact.Text(s)
}

// push runs `git push -u origin <branch>`; on failure it prints git's own message (masked) so the cause is visible.
func (e *env) push(branch string) bool {
	// interactive: with a plain https origin and no stored credential git must be able to ask.
	err := gitx.RunInteractive(e.root, os.Stdin, "push", "-q", "-u", "origin", branch)
	if err == nil {
		return true
	}
	var xe *gitx.ExitError
	if errors.As(err, &xe) && xe.Stderr != "" {
		fmt.Fprintf(e.err, "spec: git push said:\n%s\n", e.maskGit(xe.Stderr))
	}
	return false
}

// CaseClash returns an existing ref name that differs from branch only in letter case ("" when none). On a case-insensitive
// file system (macOS, Windows) such refs share one file and a push fails with "cannot be resolved to branch".
func CaseClash(existing []string, branch string) string {
	for _, n := range existing {
		if n != branch && strings.EqualFold(n, branch) {
			return n
		}
	}
	return ""
}

func (e *env) isProtected(b string) bool {
	if b == e.base || strings.HasPrefix(b, "release/") || strings.HasPrefix(b, "hotfix/") {
		return true
	}
	for _, p := range append([]string{"main", "master", "develop", "trunk"}, e.protected...) {
		if b == p {
			return true
		}
	}
	return false
}

func (e *env) ensureBranch(id string) bool {
	b := "spec/" + id
	switch {
	case e.branch() == b:
		return true
	case e.gok("show-ref", "--verify", "-q", "refs/heads/"+b):
		return e.gok("checkout", "-q", b)
	case e.gok("show-ref", "--verify", "-q", "refs/remotes/origin/"+b):
		return e.gok("checkout", "-q", "-b", b, "--track", "origin/"+b)
	case e.gok("show-ref", "--verify", "-q", "refs/remotes/origin/"+e.base):
		return e.gok("checkout", "-q", "-b", b, "origin/"+e.base)
	}
	return e.gok("checkout", "-q", "-b", b)
}

type refChange struct{ ref, slug string }

// refChanges: every change branch of the spec, remote ones first (a slug appears once).
func (e *env) refChanges(id string) []refChange {
	out, _ := e.g("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/spec/"+id+"--*", "refs/heads/spec/"+id+"--*")
	var l []refChange
	seen := map[string]bool{}
	for _, r := range gitx.Lines(out) {
		_, sl, _ := strings.Cut(r, "spec/"+id+"--")
		if !seen[sl] {
			seen[sl] = true
			l = append(l, refChange{r, sl})
		}
	}
	return l
}

func (e *env) refStatus(ref, id, slug string) string {
	s, ok := e.show(ref, e.cdir(id, slug)+"/change.json")
	if !ok {
		return ""
	}
	return jsonStr(s, "status")
}

func jsonStr(doc, key string) string {
	ps, err := okv([]byte(doc))
	if err != nil {
		return ""
	}
	return strOf(field(ps, key))
}

func fileStr(path, key string) string {
	b, _ := os.ReadFile(path)
	return jsonStr(string(b), key)
}

func (e *env) ownSlug(id string) string {
	if s, ok := strings.CutPrefix(e.branch(), "spec/"+id+"--"); ok {
		return s
	}
	return ""
}

func openChanges(root string) []string {
	var l []string
	ents, _ := os.ReadDir(filepath.Join(root, "changes"))
	for _, c := range ents {
		if fileStr(filepath.Join(root, "changes", c.Name(), "change.json"), "status") == "open" {
			l = append(l, c.Name())
		}
	}
	return l
}

func (e *env) sibsNotHere(id, root string) []string {
	var l []string
	for _, rc := range e.refChanges(id) {
		if _, err := os.Stat(filepath.Join(root, "changes", rc.slug)); err != nil && e.refStatus(rc.ref, id, rc.slug) == "open" {
			l = append(l, rc.slug)
		}
	}
	return l
}

// drift: sibling open changes on other branches and whether the base moved under the change; rc 3 on drift.
func (e *env) drift(id, own string) ([]string, int) {
	if own == "" {
		own = e.ownSlug(id)
	}
	e.fetch()
	var sib, lines []string
	for _, rc := range e.refChanges(id) {
		if rc.slug != own && e.refStatus(rc.ref, id, rc.slug) == "open" {
			sib = append(sib, rc.slug)
		}
	}
	rc := 0
	if len(sib) > 0 {
		lines, rc = append(lines, "SIBLINGS: "+strings.Join(sib, ", ")), 3
	}
	if own != "" && e.hasMeta(id) {
		oh := fileStr(filepath.Join(e.cabs(id, own), "change.json"), "base")
		if ps, err := okv([]byte(oh)); err == nil {
			oh = strOf(field(ps, "contentHash"))
		} else {
			oh = ""
		}
		if e.gok("rev-parse", "--verify", "-q", "origin/"+e.base) {
			if nv, ok := e.show("origin/"+e.base, e.dir(id)+"/spec.meta.json"); ok && oh != "" && jsonStr(nv, "contentHash") != oh {
				lines, rc = append(lines, fmt.Sprintf("BASE: moved to v%s since '%s' was written", jsonStr(nv, "version"), own)), 3
			}
		}
	}
	if rc == 0 {
		lines = append(lines, "drift: none")
	}
	return lines, rc
}

// prBody: a copy of the body with the status block (gate b); returns the path.
func (e *env) prBody(id, bf string) (string, error) {
	b, err := os.ReadFile(bf)
	if err != nil {
		return "", err
	}
	if sl := e.ownSlug(id); sl != "" {
		d, _ := e.drift(id, sl)
		sib := ""
		for _, l := range d {
			if strings.HasPrefix(l, "SIBLINGS:") {
				sib = l
			}
		}
		cj := filepath.Join(e.cabs(id, sl), "change.json")
		switch {
		case sib != "":
			b = append(b, fmt.Sprintf("\n\n%s: do not merge alone, merge-specs first\n", sib)...)
		case fileStr(cj, "status") == "applied":
			h := ""
			if ps, err := readObj(cj); err == nil {
				if bs, err := okv(field(ps, "base")); err == nil {
					h = strOf(field(bs, "contentHash"))
				}
			}
			if len(h) > 12 {
				h = h[:12]
			}
			b = append(b, fmt.Sprintf("\n\napplied against base %s\n", h)...)
		default:
			b = append(b, "\n\nno siblings at publish time\n"...)
		}
	}
	f, err := os.CreateTemp("", "sdkit-prbody.")
	if err != nil {
		return "", err
	}
	defer f.Close()
	_, err = f.Write(b)
	return f.Name(), err
}

func (e *env) request(mode, title, file, dest string, reuse bool, out io.Writer) *pr.Request {
	r := &pr.Request{Dir: e.root, Mode: mode, Title: title, DescFile: file, Dest: dest, Reuse: reuse, Getenv: e.get, Out: out, Err: e.err}
	r.Host = e.get("PR_HOST")
	return r
}

// openPR is `pr open --reuse`; it returns the last output line (the URL).
func (e *env) openPR(title, file string) (string, error) {
	var b bytes.Buffer
	err := e.request("create", title, file, e.base, true, &b).Run(context.Background())
	l := gitx.Lines(b.String())
	if len(l) == 0 {
		return "", err
	}
	return l[len(l)-1], err
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		t := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(t, 0o755)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(t, b, 0o644)
	})
}

// RunSpec dispatches `sdkit spec <verb> ...`; the change and apply verbs shared with the low-level facts go to them.
func RunSpec(args []string, out, errw io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(errw, specUsage)
		return 2
	}
	verb, a := args[0], args[1:]
	switch {
	case verb == "change" && (len(a) == 0 || (a[0] != "new" && a[0] != "refresh" && a[0] != "status")):
		return RunChange(a, out, errw)
	case verb == "apply" && len(a) >= 3 && (a[0] == "renumber" || a[0] == "delta"):
		if st, err := os.Stat(a[1]); err == nil && st.IsDir() {
			return RunApply(a, out, errw)
		}
	}
	e := newEnv(out, errw)
	return e.dispatch(verb, a)
}

func (e *env) usage() exit { fmt.Fprintln(e.err, specUsage); return 2 }

func (e *env) dispatch(verb string, a []string) (rc int) {
	defer func() {
		if r := recover(); r != nil {
			x, ok := r.(exit)
			if !ok {
				panic(r)
			}
			rc = int(x)
		}
	}()
	if verb == "change" && len(a) > 0 {
		return e.changeCmd(a[0], a[1:])
	}
	if len(a) == 0 || !okname(a[0]) {
		return int(e.usage())
	}
	id, a := a[0], a[1:]
	if !map[string]bool{"drift": true, "check": true, "apply": true, "init-meta": true, "hash": true, "status": true, "changed": true, "branch": true, "publish": true, "promote": true, "approved-sha": true}[verb] {
		return int(e.usage())
	}
	switch verb {
	case "drift":
		own := ""
		if len(a) > 0 {
			own = a[0]
		}
		l, rc := e.drift(id, own)
		for _, s := range l {
			e.say("%s", s)
		}
		return rc
	case "check":
		return e.check(id)
	case "apply":
		return e.apply(id, a)
	case "init-meta":
		return e.initMeta(id)
	case "hash":
		e.needDir(id)
		h := e.curHash(id)
		if h == "" {
			return 1
		}
		e.say("%s", h)
		return 0
	case "status":
		return e.status(id)
	case "changed":
		return e.changed(id)
	case "branch":
		e.needDir(id)
		if !e.ensureBranch(id) {
			return int(e.die("cannot switch to spec/%s (never forced: resolve by hand)", id))
		}
		e.say("spec/%s", id)
		return 0
	case "next":
		if len(a) != 1 || !okname(a[0]) {
			return int(e.usage())
		}
		st := Next(e.root, a[0])
		who := "agent"
		if st.Human {
			who = "person"
		}
		e.say("next (%s): %s", who, st.Action)
		if st.Why != "" {
			e.say("why: %s", st.Why)
		}
		return 0
	case "publish":
		return e.publish(id, a)
	case "promote":
		return e.promote(id)
	}
	return e.approvedSha(id, a)
}

func (e *env) needDir(id string) {
	if st, err := os.Stat(e.abs(id)); err != nil || !st.IsDir() {
		panic(e.die("no spec directory %s", e.dir(id)))
	}
}

func (e *env) must(err error, f string, a ...any) {
	if err != nil {
		panic(e.die(f, a...))
	}
}

func (e *env) changeCmd(sub string, a []string) int {
	if len(a) == 0 || !okname(a[0]) {
		return int(e.usage())
	}
	id, a := a[0], a[1:]
	root := e.abs(id)
	switch sub {
	case "new":
		if len(a) == 0 || !okname(a[0]) {
			return int(e.usage())
		}
		slug, title, kind := a[0], "", "feature"
		for i := 1; i < len(a); i += 2 {
			v := ""
			if i+1 < len(a) {
				v = a[i+1]
			}
			switch a[i] {
			case "--title":
				title = v
			case "--kind":
				kind = v
			default:
				return int(e.usage())
			}
		}
		if strings.Contains(slug, "--") {
			return int(e.die("a slug cannot contain '--' (it separates the id from the slug in the branch name)"))
		}
		if kind != "fix" && kind != "feature" {
			return int(e.usage())
		}
		if title == "" {
			title = slug
		}
		e.fetch()
		src := "HEAD"
		if e.gok("rev-parse", "--verify", "-q", "origin/"+e.base) {
			src = "origin/" + e.base
		}
		m, ok := e.show(src, e.dir(id)+"/spec.meta.json")
		if !ok {
			return int(e.die("no spec '%s' on %s", id, src))
		}
		if jsonStr(m, "status") != "approved" {
			return int(e.die("'%s' is not approved on %s: a change needs an approved base (before approval, edit the spec in place)", id, src))
		}
		b := "spec/" + id + "--" + slug
		if e.gok("show-ref", "--verify", "-q", "refs/heads/"+b) {
			return int(e.die("branch %s exists (the slug is taken)", b))
		}
		if e.gok("show-ref", "--verify", "-q", "refs/remotes/origin/"+b) {
			return int(e.die("branch origin/%s exists (the slug is taken)", b))
		}
		if !e.gok("checkout", "-q", "-b", b, src) {
			return int(e.die("cannot create %s from %s (commit or stash your edits)", b, src))
		}
		ver, cd := e.meta(id).Version, e.cabs(id, slug)
		e.must(os.MkdirAll(filepath.Join(cd, "specs"), 0o755), "cannot create %s", cd)
		cj := []pair{{"slug", jstr(slug)}, {"title", jstr(title)}, {"kind", jstr(kind)}, {"label", jstr(bump(ver, false))}, {"status", jstr("open")}, {"createdAt", jstr(now())},
			{"base", raw(struct {
				Version     string `json:"version"`
				ContentHash string `json:"contentHash"`
			}{ver, e.curHash(id)})}, {"expects", json.RawMessage("{}")}, {"touches", json.RawMessage("[]")}}
		e.must(os.WriteFile(filepath.Join(cd, "change.json"), marshal(cj), 0o644), "cannot write change.json")
		_ = os.WriteFile(filepath.Join(cd, "intent.md"), []byte(fmt.Sprintf("# %s\n\nWhy this change exists and what the author meant (read by merge-specs).\n", title)), 0o644)
		e.say("spec: change '%s' on '%s' v%s, label %s, branch %s. Write the delta under %s/specs/", slug, id, ver, bump(ver, false), b, e.cdir(id, slug))
	case "refresh":
		if len(a) == 0 || !okname(a[0]) {
			return int(e.usage())
		}
		cd := e.cabs(id, a[0])
		ps, err := readObj(filepath.Join(cd, "change.json"))
		if err != nil {
			return int(e.die("no change '%s' in %s", a[0], id))
		}
		f, err := Compute(cd, root)
		if err != nil || len(f.Problems) > 0 {
			if f != nil {
				for _, p := range f.Problems {
					fmt.Fprintln(e.err, p)
				}
			}
			return int(e.die("the delta has problems (above)"))
		}
		ps = set(set(ps, "expects", raw(f.Expects)), "touches", raw(f.Touches))
		e.must(writeAtomic(filepath.Join(cd, "change.json"), marshal(ps)), "cannot write change.json")
		e.say("spec: '%s' touches %d AC(s)", a[0], len(f.Touches))
	case "status":
		one := ""
		if len(a) > 0 {
			one = a[0]
		}
		ents, _ := os.ReadDir(filepath.Join(root, "changes"))
		for _, c := range ents {
			cd := filepath.Join(root, "changes", c.Name())
			ps, err := readObj(filepath.Join(cd, "change.json"))
			if err != nil || (one != "" && one != c.Name()) {
				continue
			}
			mv := "no"
			if ids, err := Moved(cd, root, ""); err != nil || len(ids) > 0 {
				mv = "yes"
			}
			bs, _ := okv(field(ps, "base"))
			e.say("change=%s label=%s status=%s base=%s base_moved=%s", c.Name(), strOf(field(ps, "label")), strOf(field(ps, "status")), strOf(field(bs, "version")), mv)
		}
	default:
		return int(e.usage())
	}
	return 0
}

// Check is `spec check` as a report: err is non-nil when the spec is not mergeable.
func Check(root, id string) (string, error) {
	var b bytes.Buffer
	e := envAt(root, &b, &b)
	if e.check(id) != 0 {
		return b.String(), fmt.Errorf("spec check failed for %s", id)
	}
	return b.String(), nil
}

func (e *env) check(id string) int {
	e.needDir(id)
	root := e.abs(id)
	e.fetch()
	var probs []string
	for _, s := range openChanges(root) {
		probs = append(probs, "- not applied: "+s)
	}
	for _, rc := range e.refChanges(id) {
		if _, err := os.Stat(filepath.Join(root, "changes", rc.slug)); err != nil && e.refStatus(rc.ref, id, rc.slug) == "open" {
			probs = append(probs, fmt.Sprintf("- sibling not merged in: %s (%s): run merge-specs", rc.slug, rc.ref))
		}
	}
	cov, err := Coverage(root, "")
	if err != nil {
		cov = []string{err.Error()}
	}
	for _, c := range cov {
		probs = append(probs, "- "+c)
	}
	if len(probs) == 0 {
		e.say("spec: check OK for '%s'", id)
		return 0
	}
	e.say("spec: check FAILED for %s:\n%s", id, strings.Join(probs, "\n"))
	return 1
}

func (e *env) initMeta(id string) int {
	e.needDir(id)
	if e.hasMeta(id) {
		m := e.meta(id)
		e.say("spec: meta exists for '%s' (version %s, %s)", id, m.Version, m.Status)
		return 0
	}
	ps := []pair{{"id", jstr(id)}, {"version", jstr("0.0")}, {"status", jstr("draft")}, {"contentHash", jstr("")}, {"review", json.RawMessage("{}")}, {"history", json.RawMessage("[]")}}
	e.must(e.wmeta(id, ps), "cannot write %s", e.metaPath(id))
	e.say("spec: created %s (version 0.0: never published)", e.metaPath(id))
	return 0
}

func (e *env) status(id string) int {
	e.needDir(id)
	if !e.hasMeta(id) {
		return int(e.die("no spec.meta.json for '%s': run spec.sh init-meta %s", id, id))
	}
	h, m := e.curHash(id), e.meta(id)
	pub, rv := "no", "fail"
	if h != "" && h == m.ContentHash {
		pub = "yes"
	}
	if review.Status(e.root, id).OK() {
		rv = "pass"
	}
	e.say("id=%s version=%s status=%s branch=%s hash=%s published_hash=%s review_verdict=%s review_check=%s", id, m.Version, m.Status, e.branch(), h, pub, m.Review.Verdict, rv)
	return 0
}

func (e *env) changed(id string) int {
	e.needDir(id)
	d, m := e.dir(id), e.meta(id)
	var files []string
	if len(m.History) == 0 || m.History[len(m.History)-1].Sha == "" {
		_ = filepath.WalkDir(e.abs(id), func(p string, de fs.DirEntry, err error) error {
			if err == nil && !de.IsDir() {
				rel, _ := filepath.Rel(e.root, p)
				files = append(files, filepath.ToSlash(rel))
			}
			return nil
		})
	} else {
		last := m.History[len(m.History)-1].Sha
		if !e.gok("cat-file", "-e", last+"^{commit}") {
			return int(e.die("published SHA %s is not in this clone (git fetch)", last))
		}
		a, _ := e.g("diff", "--name-only", last, "--", d)
		b, _ := e.g("ls-files", "--others", "--exclude-standard", "--", d)
		files = append(gitx.Lines(a), gitx.Lines(b)...)
	}
	sort.Strings(files)
	prev := ""
	for _, f := range files {
		if f != prev && !strings.HasSuffix(f, "/spec.meta.json") && !strings.HasSuffix(f, "/acceptances.jsonl") {
			e.say("%s", f)
		}
		prev = f
	}
	return 0
}

func (e *env) apply(id string, slugs []string) int {
	e.needDir(id)
	root := e.abs(id)
	if len(slugs) == 0 {
		slugs = openChanges(root)
	}
	if len(slugs) == 0 {
		return int(e.die("no open change to apply in %s", e.dir(id)))
	}
	for _, s := range slugs {
		if fileStr(filepath.Join(root, "changes", s, "change.json"), "status") != "open" {
			return int(e.die("'%s' is not an open change of '%s'", s, id))
		}
	}
	W, err := os.MkdirTemp("", "sdkit-apply.")
	e.must(err, "no scratch directory")
	defer os.RemoveAll(W)
	sp := filepath.Join(W, "spec")
	p, err := Parse(root)
	if err == nil {
		err = copyTree(root, sp)
	}
	e.must(err, "cannot read the spec")
	var ids strings.Builder
	for _, a := range p.ACs {
		ids.WriteString(a.ID + "\n")
	}
	idsFile := filepath.Join(W, "ids")
	_ = os.WriteFile(idsFile, []byte(ids.String()), 0o644)
	if sibs := e.sibsNotHere(id, root); len(sibs) > 0 {
		e.say("SIBLINGS: %s. Merge their branches into this one with git, then run merge-specs; nothing was changed", strings.Join(sibs, ", "))
		return 3
	}
	needs, h := len(slugs) > 1, e.curHash(id)
	for _, s := range slugs {
		cd := filepath.Join(root, "changes", s)
		bs, _ := readObj(filepath.Join(cd, "change.json"))
		b2, _ := okv(field(bs, "base"))
		if strOf(field(b2, "contentHash")) != h {
			needs = true
		}
		if ids, err := Moved(cd, root, ""); err != nil || len(ids) > 0 {
			needs = true
		}
	}
	if needs {
		pf := filepath.Join(e.root, e.kit, "work", "spec-merge", id, "plan.json")
		e.must(os.MkdirAll(filepath.Dir(pf), 0o755), "cannot create %s", filepath.Dir(pf))
		plan, err := PlanOf(root, slugs)
		var b bytes.Buffer
		if err == nil {
			writeJSON(&b, plan)
			err = writeAtomic(pf, b.Bytes())
		}
		e.must(err, "cannot write the plan")
		var un []string
		for _, c := range plan.Changes {
			if len(c.Resolutions) == 0 || string(c.Resolutions) == "null" {
				un = append(un, strOf(c.Slug))
			}
		}
		if len(un) > 0 {
			e.say("spec: '%s' needs a semantic merge (siblings or a moved base): plan at %s; no resolutions recorded for: %s. Run merge-specs; nothing was changed", id, pf, strings.Join(un, ", "))
			return 3
		}
		e.must(Renumber(sp, slugs, e.out), "renumbering failed; nothing was changed")
	}
	for _, s := range slugs {
		cj := filepath.Join(sp, "changes", s, "change.json")
		f, err := Compute(filepath.Join(sp, "changes", s), sp)
		if err != nil || len(f.Problems) > 0 {
			if f != nil {
				for _, p := range f.Problems {
					fmt.Fprintln(e.err, p)
				}
			}
			return int(e.die("%s: the delta has problems (above); nothing was changed", s))
		}
		// touches is derived from the delta; expects keeps what was recorded
		ps, _ := readObj(cj)
		have, _ := okv(field(ps, "expects"))
		var ex []pair
		for _, kv := range f.Expects {
			ex = set(ex, kv[0], jstr(kv[1]))
		}
		for _, h := range have {
			ex = set(ex, h.K, h.V)
		}
		ps = set(set(ps, "touches", raw(f.Touches)), "expects", marshalCompact(ex))
		e.must(writeAtomic(cj, marshal(ps)), "cannot update change.json")
	}
	var keyed []string
	for _, s := range slugs {
		keyed = append(keyed, fileStr(filepath.Join(sp, "changes", s, "change.json"), "createdAt")+"\t"+s)
	}
	sort.Strings(keyed)
	top := e.meta(id).Version
	if needs {
		for _, s := range slugs {
			if l := fileStr(filepath.Join(root, "changes", s, "change.json"), "label"); vcmp(l, top) > 0 {
				top = l
			}
		}
	}
	newv, sha := bump(top, false), "unknown"
	if s, err := e.g("rev-parse", "HEAD"); err == nil {
		sha = s
	}
	for _, k := range keyed {
		s := k[strings.Index(k, "\t")+1:]
		e.must(Delta(sp, s), "%s: applying the delta failed; nothing was changed", s)
		if tb, _ := os.ReadFile(filepath.Join(sp, "changes", s, "tasks.md")); len(tb) > 0 {
			tf := filepath.Join(sp, "tasks.md")
			add := fmt.Sprintf("## Change: %s\n\n%s", s, tb)
			if _, err := os.Stat(tf); err == nil {
				add = "\n" + add
			}
			old, _ := os.ReadFile(tf)
			e.must(os.WriteFile(tf, append(old, add...), 0o644), "cannot write tasks.md")
		}
		cj := filepath.Join(sp, "changes", s, "change.json")
		ps, _ := readObj(cj)
		ap := []pair{{"version", jstr(newv)}, {"at", jstr(now())}, {"sha", jstr(sha)}}
		ps = set(set(ps, "status", jstr("applied")), "applied", marshalCompact(ap))
		e.must(writeAtomic(cj, marshal(ps)), "cannot update change.json")
	}
	mp := filepath.Join(sp, "spec.meta.json")
	ps, err := readObj(mp)
	e.must(err, "cannot update the meta")
	e.must(writeAtomic(mp, marshal(set(set(ps, "version", jstr(newv)), "status", jstr("draft")))), "cannot update the meta")
	if cov, err := Coverage(sp, idsFile); err != nil || len(cov) > 0 {
		for _, c := range cov {
			fmt.Fprintln(e.err, c)
		}
		return int(e.die("the coverage check failed (above); nothing was changed"))
	}
	e.must(copyTree(sp, root), "cannot write back")
	e.say("spec: applied %s to '%s' as revision %s (coverage OK). Next: review, publish, then promote", strings.Join(slugs, " "), id, newv)
	return 0
}

func marshalCompact(ps []pair) json.RawMessage {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, p := range ps {
		if i > 0 {
			b.WriteByte(',')
		}
		b.Write(jstr(p.K))
		b.WriteByte(':')
		b.Write(p.V)
	}
	b.WriteByte('}')
	return b.Bytes()
}

func (e *env) publish(id string, a []string) int {
	title, bf, brk := "", "", false
	for i := 0; i < len(a); i++ {
		v := ""
		if i+1 < len(a) {
			v = a[i+1]
		}
		switch a[i] {
		case "--title":
			title, i = v, i+1
		case "--body-file":
			bf, i = v, i+1
		case "--breaking":
			brk = true
		default:
			return int(e.usage())
		}
	}
	if f, err := os.Open(bf); title == "" || bf == "" || err != nil {
		return int(e.usage())
	} else {
		f.Close()
	}
	e.needDir(id)
	d := e.dir(id)
	if n, err := e.request("create", "", "", "", false, nil).Check(context.Background()); err != nil || n > 0 {
		if err != nil {
			fmt.Fprintln(e.err, err)
		}
		return int(e.die("the PR host is not ready (list above): fill it in and run publish again; nothing was committed or pushed"))
	}
	slug := e.ownSlug(id)
	cst := ""
	if slug != "" {
		cst = fileStr(filepath.Join(e.cabs(id, slug), "change.json"), "status")
	}
	rkey := id
	if cst != "" {
		rkey = id + "--" + slug
		if cst == "applied" {
			ncs, ents := 0, []fs.DirEntry(nil)
			ents, _ = os.ReadDir(filepath.Join(e.abs(id), "changes"))
			for _, c := range ents {
				ps, _ := readObj(filepath.Join(e.abs(id), "changes", c.Name(), "change.json"))
				ap, _ := okv(field(ps, "applied"))
				if strOf(field(ap, "version")) == e.meta(id).Version {
					ncs++
				}
			}
			if ncs > 1 {
				rkey = id
			}
		}
	}
	if r := review.Status(e.root, rkey); !r.OK() {
		e.say("review: %s", r.Reason)
		return int(e.die("publish needs a fresh PASS review of the current content (review.sh check %s)", rkey))
	}
	staged, _ := e.g("diff", "--cached", "--name-only")
	var bad []string
	reP := regexp.MustCompile("^(" + e.prespec + ")(/|$)")
	for _, l := range gitx.Lines(staged) {
		if reP.MatchString(l) {
			bad = append(bad, l)
		}
	}
	if len(bad) > 0 {
		return int(e.die("refusing: staged paths inside the pre-spec directory '%s' (never committed):\n%s", e.prespec, strings.Join(bad, "\n")))
	}
	if cst == "open" { // an open change: its directory only, the base and its version are untouched
		cp := e.cdir(id, slug)
		if !e.gok("add", "--", cp) {
			return int(e.die("git add failed"))
		}
		if !e.gok("diff", "--cached", "--quiet", "--", cp) {
			if !e.gok("commit", "-q", "-m", fmt.Sprintf("docs(spec): %s change %s", id, slug), "--", cp) {
				return int(e.die("commit failed"))
			}
		}
		if !e.push(e.branch()) {
			return int(e.die("push failed; fix the remote and run publish again"))
		}
		return e.finishPR(id, slug, title, bf)
	}
	if !e.hasMeta(id) {
		if e.initMeta(id) != 0 {
			return int(e.die("cannot create meta"))
		}
	}
	h := e.curHash(id)
	if h == "" {
		return int(e.die("cannot hash %s", d))
	}
	m := e.meta(id)
	b := "spec/" + id
	if cst != "" {
		b = e.branch()
	}
	if len(m.History) > 0 && h == m.ContentHash {
		// Same content as the recorded version: no new version. The PR may still be missing, so when this branch is ahead of the base, push it and open or reuse the PR.
		if e.branch() == b && e.gok("rev-parse", "--verify", "-q", "origin/"+e.base) {
			if n, _ := e.g("rev-list", "--count", "origin/"+e.base+"..HEAD"); n != "" && n != "0" {
				if !e.push(b) {
					return int(e.die("push failed; fix the remote and run publish again"))
				}
				url, err := e.openPR(title, bf)
				if err != nil {
					return int(e.die("opening the pull request failed; the version is already recorded, run publish again (it only opens the PR)"))
				}
				e.say("spec: '%s' unchanged since version %s: pull request %s", id, m.Version, url)
				return 0
			}
		}
		e.say("spec: '%s' unchanged since version %s: nothing to publish", id, m.Version)
		return 0
	}
	var newv string
	switch {
	case len(m.History) == 0:
		newv = "0.1"
	case cst == "applied" && m.History[len(m.History)-1].Version != m.Version:
		newv = m.Version // apply already set the revision
	default:
		newv = bump(m.Version, brk)
	}
	if cst == "" {
		refs, _ := e.g("for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/spec", "refs/remotes/origin/spec")
		var names []string
		for _, r := range gitx.Lines(refs) {
			names = append(names, strings.TrimPrefix(r, "origin/"))
		}
		if c := CaseClash(names, b); c != "" {
			return int(e.die("branch %s clashes with the existing %s: they differ only in letter case, so a case-insensitive file system (macOS, Windows) treats them as one ref and the push fails. Use the existing spelling of the id (or delete the stale branch); nothing was committed", b, c))
		}
	}
	if cst == "" && !e.ensureBranch(id) {
		return int(e.die("cannot switch to spec/%s (never forced)", id))
	}
	if e.isProtected(b) {
		return int(e.die("branch %s is protected", b))
	}
	if !e.gok("add", "--", d) {
		return int(e.die("git add failed"))
	}
	if !e.gok("diff", "--cached", "--quiet", "--", d) {
		if !e.gok("commit", "-q", "-m", fmt.Sprintf("docs(spec): %s v%s", id, newv), "--", d) {
			return int(e.die("commit failed"))
		}
	}
	// The version is recorded in a commit BEFORE the push and the PR: the PR then always has a diff and the meta travels with the spec. A failed push rolls it back.
	sha, _ := e.g("rev-parse", "HEAD")
	old, _ := os.ReadFile(e.metaPath(id))
	ps, err := okv(old)
	e.must(err, "cannot compute the new meta")
	hist := []json.RawMessage{}
	_ = json.Unmarshal(field(ps, "history"), &hist)
	hist = append(hist, raw(struct {
		Version     string `json:"version"`
		Sha         string `json:"sha"`
		At          string `json:"at"`
		ContentHash string `json:"contentHash"`
	}{newv, sha, now(), h}))
	for _, kv := range []pair{{"id", jstr(id)}, {"version", jstr(newv)}, {"status", jstr("draft")}, {"contentHash", jstr(h)}, {"review", e.reviewEvidence(id)}, {"history", raw(hist)}} {
		ps = set(ps, kv.K, kv.V)
	}
	e.must(e.wmeta(id, ps), "cannot write the meta")
	mrel := d + "/spec.meta.json"
	restore := func() {
		_ = os.WriteFile(e.metaPath(id), old, 0o644)
		_ = e.gok("reset", "-q", "HEAD", "--", mrel)
	}
	if !e.gok("add", "--", mrel) || !e.gok("commit", "-q", "-m", fmt.Sprintf("chore(spec): record %s v%s", id, newv), "--", mrel) {
		restore()
		return int(e.die("recording the version failed; meta restored, run publish again"))
	}
	if !e.push(b) {
		if e.gok("reset", "-q", "--soft", "HEAD~1") {
			restore()
		}
		return int(e.die("push failed; meta and version untouched, fix the remote and run publish again"))
	}
	url, err := e.openPR(title, bf)
	if err != nil {
		return int(e.die("pushed and recorded %s v%s, but opening the pull request failed: fix the cause and run publish again (it only opens the PR)", id, newv))
	}
	e.updatePR(id, title, bf)
	e.say("spec: published '%s' v%s at %s on %s -> %s", id, newv, sha, b, url)
	if strings.HasPrefix(newv, "0.") {
		e.say("spec: next: the Tech Lead reviews this PR; a v0.x is not approved yet, so after it merges run `sdkit spec promote %s` on a new branch (it commits, pushes and opens the promote PR; its merge is the approval). Only the merged SHA of that PR goes to generate-tasks (a SHA of the v0.x merge is refused).", id)
	} else {
		e.say("spec: next: the Tech Lead reviews and merges this PR; the merge is the approval. generate-tasks takes the merged SHA.")
	}
	return 0
}

func (e *env) updatePR(id, title, bf string) {
	pb, err := e.prBody(id, bf)
	if err == nil {
		defer os.Remove(pb)
		err = e.request("update", title, pb, e.base, false, io.Discard).Run(context.Background())
	}
	if err != nil {
		fmt.Fprintln(e.err, "spec: warning: could not update the PR title/body")
	}
}

func (e *env) finishPR(id, slug, title, bf string) int {
	pb, err := e.prBody(id, bf)
	if err != nil {
		return int(e.die("opening the pull request failed: run publish again"))
	}
	defer os.Remove(pb)
	url, err := e.openPR(title, pb)
	if err != nil {
		return int(e.die("opening the pull request failed: run publish again"))
	}
	e.updatePR(id, title, bf)
	e.say("spec: published change '%s' of '%s' (label %s) -> %s", slug, id, fileStr(filepath.Join(e.cabs(id, slug), "change.json"), "label"), url)
	return 0
}

// reviewEvidence is {verdict, contentHash, round, at} of the review state, {} when there is none.
func (e *env) reviewEvidence(id string) json.RawMessage {
	b, err := os.ReadFile(filepath.Join(e.root, e.kit, "work", "review", id, "state.json"))
	if err != nil {
		return json.RawMessage("{}")
	}
	var st struct{ Evidence map[string]json.RawMessage }
	if json.Unmarshal(b, &st) != nil {
		return json.RawMessage("{}")
	}
	var ps []pair
	for _, k := range []string{"verdict", "contentHash", "round", "at"} {
		v := st.Evidence[k]
		if v == nil {
			v = json.RawMessage("null")
		}
		ps = append(ps, pair{k, v})
	}
	return marshalCompact(ps)
}

func (e *env) promote(id string) int {
	e.needDir(id)
	b := e.branch()
	if e.isProtected(b) {
		return int(e.die("refusing on '%s': promote commits on the approval PR branch, nobody commits to a protected branch", b))
	}
	if !e.hasMeta(id) {
		return int(e.die("no spec.meta.json for '%s'", id))
	}
	m := e.meta(id)
	switch {
	case m.Status == "approved":
		return int(e.die("'%s' is already approved at %s", id, m.Version))
	case len(m.History) == 0:
		return int(e.die("'%s' was never published", id))
	case e.curHash(id) != m.ContentHash:
		return int(e.die("the content changed since the last publish: review and publish first"))
	}
	if st, _ := e.g("status", "--porcelain", "--", e.dir(id)); st != "" {
		return int(e.die("uncommitted changes under %s", e.dir(id)))
	}
	if n, err := e.request("create", "", "", "", false, nil).Check(context.Background()); err != nil || n > 0 {
		if err != nil {
			fmt.Fprintln(e.err, err)
		}
		return int(e.die("the PR host is not ready (list above): fill it in and run promote again; nothing was committed or pushed"))
	}
	v := m.Version
	if strings.HasPrefix(v, "0.") {
		v = "1.0"
	}
	sha, _ := e.g("rev-parse", "HEAD")
	oldMeta, _ := os.ReadFile(e.metaPath(id))
	ps, err := readObj(e.metaPath(id))
	e.must(err, "cannot write the meta")
	hist := []json.RawMessage{}
	_ = json.Unmarshal(field(ps, "history"), &hist)
	hist = append(hist, raw(struct {
		Version     string `json:"version"`
		Sha         string `json:"sha"`
		At          string `json:"at"`
		ContentHash string `json:"contentHash"`
	}{v, sha, now(), m.ContentHash}))
	ps = set(set(set(ps, "version", jstr(v)), "status", jstr("approved")), "history", raw(hist))
	e.must(e.wmeta(id, ps), "cannot write the meta")
	mrel := e.dir(id) + "/spec.meta.json"
	if !e.gok("add", "--", mrel) || !e.gok("commit", "-q", "-m", fmt.Sprintf("chore(spec): promote %s to v%s", id, v), "--", mrel) {
		_ = os.WriteFile(e.metaPath(id), oldMeta, 0o644)
		_ = e.gok("reset", "-q", "HEAD", "--", mrel)
		return int(e.die("commit failed; meta restored, run promote again"))
	}
	// Like publish: a failed push rolls the commit back so promote can simply be run again.
	if !e.push(b) {
		if e.gok("reset", "-q", "--soft", "HEAD~1") {
			_ = os.WriteFile(e.metaPath(id), oldMeta, 0o644)
			_ = e.gok("reset", "-q", "HEAD", "--", mrel)
		}
		return int(e.die("push failed; nothing recorded, fix the remote and run promote again"))
	}
	title := fmt.Sprintf("chore(spec): promote %s to v%s", id, v)
	bf, err := writeTemp(fmt.Sprintf("Promotes spec `%s` to v%s (approved).\n\nThe merge of this PR is the approval; generate-tasks takes the merged SHA.\n", id, v))
	if err != nil {
		return int(e.die("pushed %s, but could not write the PR body: run `sdkit pr open` by hand", b))
	}
	defer os.Remove(bf)
	url, err := e.openPR(title, bf)
	if err != nil {
		return int(e.die("pushed '%s' on %s, but opening the pull request failed: fix the cause and run `sdkit pr open`", id, b))
	}
	e.say("spec: promoted '%s' to approved v%s on %s and opened %s. The Tech Lead's merge is the approval; only the merged SHA goes to generate-tasks", id, v, b, url)
	return 0
}

func writeTemp(body string) (string, error) {
	f, err := os.CreateTemp("", "sdkit-promote-*.md")
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := f.WriteString(body); err != nil {
		os.Remove(f.Name())
		return "", err
	}
	return f.Name(), nil
}

// ApprovedSHA is gate (a): sha is on origin/<base>, the spec meta at sha says approved, and a spec with changes/ is whole there (gate d).
func (e *env) approvedSha(id string, a []string) int {
	sha := ""
	for i := 0; i < len(a); i++ {
		if a[i] != "--sha" {
			return int(e.usage())
		}
		if i++; i < len(a) {
			sha = a[i]
		}
	}
	if sha == "" {
		return int(e.usage())
	}
	e.fetch(e.base)
	full, err := e.g("rev-parse", "--verify", "-q", sha+"^{commit}")
	if err != nil {
		return int(e.die("unknown commit %s", sha))
	}
	if !e.gok("show-ref", "--verify", "-q", "refs/remotes/origin/"+e.base) {
		return int(e.die("no origin/%s to check against", e.base))
	}
	if !e.gok("merge-base", "--is-ancestor", full, "origin/"+e.base) {
		return int(e.die("%s is not reachable from origin/%s: the approval PR is not merged", sha, e.base))
	}
	m, ok := e.show(full, e.dir(id)+"/spec.meta.json")
	if !ok {
		return int(e.die("no spec meta for '%s' at %s", id, sha))
	}
	if jsonStr(m, "status") != "approved" {
		return int(e.die("'%s' is not approved at %s", id, sha))
	}
	if e.gok("cat-file", "-e", full+":"+e.dir(id)+"/changes") {
		tmp, err := os.MkdirTemp("", "sdkit-approved.")
		e.must(err, "cannot read '%s' at %s", id, sha)
		defer os.RemoveAll(tmp)
		files, _ := e.g("ls-tree", "-r", "--name-only", full, "--", e.dir(id))
		for _, f := range gitx.Lines(files) {
			c, ok := e.show(full, f)
			if !ok {
				return int(e.die("cannot read '%s' at %s", id, sha))
			}
			p := filepath.Join(tmp, filepath.FromSlash(f))
			_ = os.MkdirAll(filepath.Dir(p), 0o755)
			e.must(os.WriteFile(p, []byte(c), 0o644), "cannot read '%s' at %s", id, sha)
		}
		root, ver, probs := filepath.Join(tmp, filepath.FromSlash(e.dir(id))), jsonStr(m, "version"), ""
		for _, s := range openChanges(root) {
			probs += " open change " + s + " is in this revision but not applied;"
		}
		for _, rc := range e.refChanges(id) {
			if _, err := os.Stat(filepath.Join(root, "changes", rc.slug)); err == nil || e.refStatus(rc.ref, id, rc.slug) != "open" {
				continue
			}
			cj, _ := e.show(rc.ref, e.cdir(id, rc.slug)+"/change.json")
			bs, _ := okv([]byte(jsonField(cj, "base")))
			if bv := strOf(field(bs, "version")); vcmp(bv, ver) <= 0 {
				probs += fmt.Sprintf(" sibling %s (written on base %s) is not merged into this revision;", rc.slug, bv)
			}
		}
		if cov, err := Coverage(root, ""); err != nil || len(cov) > 0 {
			first := ""
			if len(cov) > 0 {
				first = cov[0]
			} else {
				first = err.Error()
			}
			probs += fmt.Sprintf(" the base does not cover its applied changes (%s);", first)
		}
		if h, _ := review.Hash(root); h != jsonStr(m, "contentHash") {
			probs += " the base content does not match its recorded hash;"
		}
		if probs != "" {
			return int(e.die("'%s' at %s is not a consistent revision:%s no task is generated from it (run spec.sh check %s)", id, sha, probs, id))
		}
	}
	e.say("spec: '%s' approved v%s at %s", id, jsonStr(m, "version"), full)
	return 0
}

func jsonField(doc, key string) string {
	ps, err := okv([]byte(doc))
	if err != nil {
		return ""
	}
	return string(field(ps, key))
}

// SpecsDir is SPECS_DIR of the settings, "specs" when unset.
func SpecsDir(s interface{ String(string) string }) string {
	if v := s.String("SPECS_DIR"); v != "" && !strings.HasPrefix(v, "__") {
		return v
	}
	return "specs"
}
