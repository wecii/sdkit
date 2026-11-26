// Package preflight answers, before a long or irreversible step, "will it go through?" with every cause at once and in plain
// words (sdkit preflight spec-publish <id> | tasks <tasks.json>). It reads and checks; it never writes, commits or pushes.
package preflight

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/wecii/sdkit/internal/envfile"
	"github.com/wecii/sdkit/internal/gitx"
	"github.com/wecii/sdkit/internal/jira"
	"github.com/wecii/sdkit/internal/project"
	"github.com/wecii/sdkit/internal/review"
	"github.com/wecii/sdkit/internal/spec"
	"github.com/wecii/sdkit/internal/tasks"
)

// Line is one check result. Level is OK, WARN or FAIL.
type Line struct{ Level, Text string }

func (l Line) String() string { return fmt.Sprintf("%-4s %s", l.Level, l.Text) }

// Failed reports whether any line is a FAIL.
func Failed(ls []Line) bool {
	for _, l := range ls {
		if l.Level == "FAIL" {
			return true
		}
	}
	return false
}

// Opts is what a run needs from outside; Self runs `sdkit <args>` (the approval gate).
type Opts struct {
	Root    string
	Offline bool
	Getenv  func(string) string
	Self    func(args ...string) (string, bool)
}

type pf struct {
	Opts
	tr   bool
	set  *envfile.Settings
	proj project.Project
	out  []Line
}

// msg picks the Turkish or English text (ANALYST_LANGUAGE, default tr).
func (p *pf) msg(tr, en string) string {
	if p.tr {
		return tr
	}
	return en
}

func (p *pf) add(level, tr, en string, a ...any) {
	p.out = append(p.out, Line{level, fmt.Sprintf(p.msg(tr, en), a...)})
}

func newPF(o Opts) *pf {
	s, pr, _ := project.Load(o.Root)
	lang := strings.ToLower(s.String("ANALYST_LANGUAGE"))
	if o.Getenv == nil {
		o.Getenv = os.Getenv
	}
	return &pf{Opts: o, tr: lang == "" || lang == "tr" || lang == "turkish", set: s, proj: pr}
}

func (p *pf) git(a ...string) (string, error) { return gitx.Run(p.Root, a...) }

func (p *pf) gitOK(a ...string) bool { _, err := p.git(a...); return err == nil }

// localValue is a value from the process environment, else from the personal sdkit.local.env (never the shared sdkit.env).
func (p *pf) localValue(k string) (v, from string) {
	if v = p.Getenv(k); v != "" {
		return v, "env"
	}
	l := envfile.New()
	l.Quiet = true
	_ = l.LoadFile(filepath.Join(p.proj.Dir(), "sdkit.local.env"))
	if v, ok := l.Raw(k); ok && v != "" {
		return v, "sdkit.local.env"
	}
	return "", ""
}

func (p *pf) base() string {
	if b := p.set.String("BASE_BRANCH"); b != "" && !strings.HasPrefix(b, "__") {
		return b
	}
	return "main"
}

var reSHA = regexp.MustCompile(`^[0-9a-f]{40}$`)

// CheckSHA says what is wrong with a pasted commit id ("" when its shape is right).
func CheckSHA(sha string) (tr, en string) {
	switch {
	case len(sha) != 40 && regexp.MustCompile(`^[0-9a-fA-F]+$`).MatchString(sha):
		return fmt.Sprintf("SHA %d karakter, 40 olmalı: yapıştırırken baştan/sondan karakter kesilmiş olabilir (%s)", len(sha), sha),
			fmt.Sprintf("the SHA has %d characters, it needs 40: a character may have been lost when pasting (%s)", len(sha), sha)
	case !reSHA.MatchString(sha):
		return fmt.Sprintf("SHA geçerli bir tam commit kimliği değil (küçük harf onaltılık, 40 karakter): %q", sha), fmt.Sprintf("the SHA is not a full commit id (40 lower-case hex characters): %q", sha)
	}
	return "", ""
}

var reParent = regexp.MustCompile(`^[A-Z][A-Z0-9_]*-[0-9]+$`)

// SpecPublish checks what `sdkit spec publish <id>` needs.
func SpecPublish(o Opts, id string) []Line {
	p := newPF(o)
	if !review.OkName(id) {
		p.add("FAIL", "geçersiz spec kimliği %q", "invalid spec id %q", id)
		return p.out
	}
	// the Tech Lead's PR host
	url, _ := p.git("remote", "get-url", "origin")
	host := strings.ToLower(p.set.String("PR_HOST"))
	if tok, from := p.localValue("BITBUCKET_TOKEN"); tok != "" {
		p.add("OK", "BITBUCKET_TOKEN bulundu (%s)", "BITBUCKET_TOKEN found (%s)", from)
		if !strings.HasPrefix(tok, "ATCTT") {
			if em, from := p.localValue("BITBUCKET_EMAIL"); em != "" {
				p.add("OK", "BITBUCKET_EMAIL bulundu (%s)", "BITBUCKET_EMAIL found (%s)", from)
			} else if g := gitx.Config(p.Root, "user.email"); g != "" {
				p.add("OK", "e-posta git config user.email'den alınacak", "the e-mail comes from git config user.email")
			} else {
				p.add("FAIL", "BITBUCKET_EMAIL yok: .sdkit/sdkit.local.env içine Bitbucket hesap e-postanızı yazın", "BITBUCKET_EMAIL is missing: put your Bitbucket account e-mail in .sdkit/sdkit.local.env")
			}
		}
		lf := filepath.Join(p.proj.Dir(), "sdkit.local.env")
		if _, err := os.Stat(lf); err == nil && !gitx.IsIgnored(p.Root, lf) {
			p.add("WARN", "sdkit.local.env git tarafından yok sayılmıyor: token'ı commit etmeden önce .gitignore'a ekleyin", "sdkit.local.env is not git-ignored: add it to .gitignore before a token lands in a commit")
		}
	} else if strings.Contains(url, "bitbucket") || host == "bitbucket" {
		p.add("FAIL", "BITBUCKET_TOKEN bulunamadı (ne ortam değişkeninde ne .sdkit/sdkit.local.env içinde). sdkit.local.env'e BITBUCKET_TOKEN=... yazın; dosya git'e girmez", "BITBUCKET_TOKEN not found (neither in the environment nor in .sdkit/sdkit.local.env). Put BITBUCKET_TOKEN=... in sdkit.local.env; it is never committed")
	}
	// the spec and its review
	if st, err := os.Stat(filepath.Join(p.Root, spec.SpecsDir(p.set), id)); err != nil || !st.IsDir() {
		p.add("FAIL", "%s/%s yok: önce propose adımı çalışmalı", "%s/%s does not exist: the propose step has to run first", spec.SpecsDir(p.set), id)
	} else if p.firstPublishWithoutBR(id) {
		p.add("FAIL", "%s/%s/business-requirements.md yok: ilk yayından önce requirements-writer ile yazılmalı (generate-specs adım 7)", "%s/%s/business-requirements.md does not exist: a spec's first publish needs it, written by the requirements-writer (generate-specs step 7)", spec.SpecsDir(p.set), id)
	} else if r := review.Status(p.Root, id); !r.OK() {
		p.add("FAIL", "taze bir review PASS yok: %s", "there is no fresh review PASS: %s", r.Reason)
	} else {
		p.add("OK", "review PASS güncel (tur %d)", "the review PASS is current (round %d)", r.Round)
	}
	// the branch
	b := "spec/" + id
	if !p.Offline {
		if _, err := p.git("fetch", "-q", "origin"); err != nil {
			var xe *gitx.ExitError
			msg := err.Error()
			if x, ok := err.(*gitx.ExitError); ok {
				xe, msg = x, x.Stderr
			}
			_ = xe
			p.add("WARN", "git fetch başarısız (uzak branş durumu eski olabilir): %s", "git fetch failed (the remote branch state may be old): %s", mask(msg))
		}
	}
	refs, _ := p.git("for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/spec", "refs/remotes/origin/spec")
	var names []string
	for _, r := range gitx.Lines(refs) {
		names = append(names, strings.TrimPrefix(r, "origin/"))
	}
	if c := spec.CaseClash(names, b); c != "" {
		p.add("FAIL", "%s ile mevcut %s yalnızca büyük/küçük harfle ayrışıyor; macOS/Windows'ta aynı ref olur ve push 'cannot be resolved to branch' verir. Mevcut yazımı kullanın", "%s and the existing %s differ only in letter case; on macOS/Windows that is one ref and the push fails with 'cannot be resolved to branch'. Use the existing spelling", b, c)
	}
	base := p.base()
	if p.gitOK("show-ref", "--verify", "-q", "refs/remotes/origin/"+b) {
		if p.gitOK("merge-base", "--is-ancestor", "origin/"+b, "origin/"+base) {
			p.add("WARN", "uzak %s zaten origin/%s içine birleşmiş. Silinmeden aynı adla yeni push sunucu hook'una takılabilir: uzak branşı silin (ya da bu bir 'promote' turuysa yeni bir branşta sdkit spec promote çalıştırın)", "remote %s is already merged into origin/%s. Pushing the same name again can hit the server's pre-receive hook: delete the remote branch (or, for the promote step, run sdkit spec promote on a new branch)", b, base)
		} else {
			p.add("OK", "uzak %s var ve henüz birleşmemiş (aynı PR yeniden kullanılır)", "remote %s exists and is not merged yet (the same PR is reused)", b)
		}
	} else {
		p.add("OK", "%s için uzak branş yok, yenisi açılacak", "no remote branch %s yet, a new one is created", b)
	}
	// where the spec stands
	if mb, err := os.ReadFile(filepath.Join(p.Root, spec.SpecsDir(p.set), id, "spec.meta.json")); err == nil {
		var m struct{ Version, Status string }
		if json.Unmarshal(mb, &m) == nil && strings.HasPrefix(m.Version, "0.") && m.Status != "approved" {
			p.add("OK", "sürüm %s: birleştikten sonra 'sdkit spec promote %s' ile onay PR'ı gerekir; generate-tasks yalnızca onaylı SHA'yı kabul eder", "version %s: after it merges, a promote PR ('sdkit spec promote %s') is needed; generate-tasks takes only the approved SHA", m.Version, id)
		}
	}
	return p.out
}

// Tasks checks what generate-tasks needs before the first Jira write.
func Tasks(o Opts, file string) []Line {
	p := newPF(o)
	b, err := os.ReadFile(file)
	var d tasks.Doc
	var doc *tasks.Doc
	if err == nil {
		doc, err = tasks.Parse(b)
	}
	_ = d
	if err != nil {
		p.add("FAIL", "%s okunamadı veya geçerli bir tasks.json değil: %v", "%s is not readable or not a valid tasks.json: %v", file, err)
		return p.out
	}
	if tr, en := CheckSHA(doc.SpecSha); tr != "" {
		p.add("FAIL", "%s", "%s", p.msg(tr, en))
	} else if _, err := p.git("rev-parse", "--verify", "-q", doc.SpecSha+"^{commit}"); err != nil {
		p.add("FAIL", "SHA %s bu depoda yok (git fetch gerekebilir ya da yanlış kopyalanmış)", "SHA %s is not in this repository (git fetch may be needed, or it was copied wrong)", doc.SpecSha)
	} else if !p.gitOK("merge-base", "--is-ancestor", doc.SpecSha, "origin/"+p.base()) {
		p.add("FAIL", "SHA origin/%s üzerinde değil: onay PR'ı birleşmemiş. v0.x birleşimi yetmez; promote PR'ının birleşim SHA'sını kullanın", "the SHA is not on origin/%s: the approval PR is not merged. A v0.x merge is not enough; use the merge SHA of the promote PR", p.base())
	} else if out, ok := p.Self("spec", "approved-sha", doc.SpecID, "--sha", doc.SpecSha); !ok {
		p.add("FAIL", "spec bu SHA'da onaylı değil: %s", "the spec is not approved at this SHA: %s", strings.TrimSpace(out))
	} else {
		p.add("OK", "SHA onaylı ve origin/%s üzerinde", "the SHA is approved and on origin/%s", p.base())
	}
	parent, _ := doc.Parent.(string)
	if !reParent.MatchString(parent) {
		p.add("FAIL", "Jira parent anahtarı geçersiz: %q (örnek: PROJ-123)", "the Jira parent key is invalid: %q (e.g. PROJ-123)", parent)
	} else {
		c := jira.Load(p.Root, p.Getenv)
		switch {
		case c.TokenErr != nil:
			p.add("FAIL", "Jira token yüklenemedi: %v", "the Jira token could not be loaded: %v", c.TokenErr)
		case c.Egress != "allow":
			p.add("FAIL", "JIRA_EGRESS=allow ayarlı değil: görev metni makineden çıkmayacak, hiçbir şey gönderilmez", "JIRA_EGRESS=allow is not set: nothing is sent")
		case p.Offline:
			p.add("WARN", "--offline: parent %s'in varlığı denetlenmedi", "--offline: the parent %s was not checked", parent)
		default:
			// The parent is usually an epic or story with no sdkit-task block, so only
			// its existence matters (Get, not Fetch), and a miss warns instead of blocking.
			if _, err := c.Get(parent); err != nil {
				p.add("WARN", "Jira parent %s alınamadı, devam ediliyor: %v", "Jira parent %s could not be fetched, continuing: %v", parent, err)
			} else {
				p.add("OK", "Jira parent %s var, token geçerli", "Jira parent %s exists and the token works", parent)
			}
		}
	}
	if md, err := os.ReadFile(filepath.Join(p.proj.Dir(), "project.md")); err == nil && tasks.RubricUnfilled(string(md)) {
		p.add("FAIL", "project.md'deki risk rubric'i hâlâ TODO: risk etiketleri tahmin olur. Neyin high/medium/low olduğunu yazın", "the risk rubric in project.md still has TODO: risk labels would be guesses. Say what makes a change high/medium/low")
	}
	return p.out
}

var reCred = regexp.MustCompile(`(://)[^/@\s]+@`)

func mask(s string) string { return reCred.ReplaceAllString(s, "${1}***@") }

// firstPublishWithoutBR: a spec never published (no history in its meta) must carry business-requirements.md; one published before this
// file existed is not asked for it.
func (p *pf) firstPublishWithoutBR(id string) bool {
	dir := filepath.Join(p.Root, spec.SpecsDir(p.set), id)
	if _, err := os.Stat(filepath.Join(dir, "business-requirements.md")); err == nil {
		return false
	}
	var m struct {
		History []json.RawMessage `json:"history"`
	}
	if b, err := os.ReadFile(filepath.Join(dir, "spec.meta.json")); err == nil {
		_ = json.Unmarshal(b, &m)
	}
	return len(m.History) == 0
}
