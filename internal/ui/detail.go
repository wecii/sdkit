package ui

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/wecii/sdkit/internal/gitx"
	"github.com/wecii/sdkit/internal/spec"
)

// FlowStep is one stage of a spec's life on the bar at the top of its page.
type FlowStep struct {
	Key    string `json:"key"`
	Label  string `json:"label"`
	Status string `json:"status"` // done | current | todo
}

var flowSteps = []struct{ key, label string }{
	{"prespec", "Ön-spec"},
	{"draft", "Sorular ve taslak"},
	{"review", "Gözden geçirme"},
	{"publish", "PR'a gönderme"},
	{"approval", "Tech Lead onayı"},
	{"tasks", "Task'lar"},
}

// stageOf is the index of the stage a state is in; -1 for a state the panel does not know.
func stageOf(state string) int {
	switch state {
	case spec.StateNoInput:
		return 0
	case spec.StateNew:
		return 1
	case spec.StateDraft, spec.StateOutput:
		return 2
	case spec.StateUnpublished:
		return 3
	case spec.StateAwaiting:
		return 4
	case spec.StateApproved:
		return 5
	}
	return -1
}

// Flow marks every stage done, current or still to come. Tasks made in Jira close the last stage too.
func Flow(state string, tasksDone bool) []FlowStep {
	cur := stageOf(state)
	out := make([]FlowStep, len(flowSteps))
	for i, s := range flowSteps {
		st := "todo"
		switch {
		case cur < 0:
		case i < cur || (tasksDone && state == spec.StateApproved):
			st = "done"
		case i == cur:
			st = "current"
		}
		out[i] = FlowStep{Key: s.key, Label: s.label, Status: st}
	}
	return out
}

// ActionItem is something the person can do at this stage. Key is what the page sends back as the action (or handles itself).
type ActionItem struct {
	Key     string `json:"key"`
	Label   string `json:"label"`
	Hint    string `json:"hint,omitempty"`
	Primary bool   `json:"primary,omitempty"`
}

// Actions is what can be done at a stage, and nothing else: the page never offers a step the flow is not at.
func Actions(state string, openChange bool) []ActionItem {
	switch state {
	case spec.StateNew, spec.StateDraft, spec.StateOutput:
		return []ActionItem{{"generate-specs", "Devam et", "Eksik noktaları soracağım, taslağı hazırlayıp gözden geçireceğim.", true}}
	case spec.StateUnpublished:
		return []ActionItem{
			{"generate-specs", "PR'a gönder", "Review geçti. Göndermeden önce son bir kez sorulur; elle düzelttiyseniz review'u yeniden çalışır.", true},
			{"refine-specs", "Spec'i güncelle", "Ne değişeceğini yazarsınız, ajan en küçük düzeltmeyi yapar ve review eder; sonra göndermeden önce tekrar sorar. Dosyaları kendiniz düzenlediyseniz doğrudan \"PR'a gönder\" yeterli.", false},
		}
	case spec.StateAwaiting:
		return []ActionItem{
			{"update-specs", "Spec'i güncelle", "Tech Lead'in PR yorumlarını okur ve/veya sizden ne değişeceğini sorar; ilgili yerleri düzeltir, review eder, aynı PR'ı günceller.", true},
			{"update-manual", "Elle düzelttim, devam et", "Dosyaları kendiniz düzelttiyseniz: farkı esas alır, review eder, PR'ı günceller.", false},
			{"generate-design", "Tasarım üret", "Spec'ten BPMN süreç akışı üretir ve aynı PR'a ekler.", false},
		}
	case spec.StateApproved:
		a := []ActionItem{
			{"start-change", "Değişiklik başlat", "Ne değişeceğini size sorar, değişikliği ayrı bir dalda yazar, review eder ve PR açar.", true},
			{"edit-change", "Elle düzenle", "Boş bir değişiklik açar; dosyaları kendiniz düzeltirsiniz.", false},
		}
		if openChange {
			a = append(a, ActionItem{"update-manual", "Elle düzelttim, devam et", "Açık değişikliğin farkını esas alır, review eder, PR açar.", false})
		}
		return append(a,
			ActionItem{"generate-design", "Tasarım üret", "Onaylı spec'ten BPMN süreç akışı üretir.", false},
			ActionItem{"generate-tasks", "Task üret", "Onaylı sürümden Jira task'ları üretir.", false},
			ActionItem{"merge-specs", "Birleştir", "Aynı sürüm üzerinde yazılmış değişiklikleri tek revizyonda birleştirir.", false})
	}
	return []ActionItem{}
}

// FileItem is a file of the spec the person may read, and whether they may change it.
type FileItem struct {
	Path     string `json:"path"` // relative to the repo, with slashes
	Group    string `json:"group"`
	Editable bool   `json:"editable"`
	Why      string `json:"why,omitempty"` // when not editable
}

// Detail is the spec page.
type Detail struct {
	ID         string                `json:"id"`
	State      string                `json:"state"`
	Label      string                `json:"label"`
	Flow       []FlowStep            `json:"flow"`
	Done       []string              `json:"done"`
	Actions    []ActionItem          `json:"actions"`
	Branch     string                `json:"branch"`
	WantBranch string                `json:"wantBranch,omitempty"` // the branch the editable files live on, when it is not the current one
	Files      []FileItem            `json:"files"`
	Running    bool                  `json:"running"`
	Worktree   bool                  `json:"worktree"` // the spec works in a worktree of its own
	Resume     map[string]ResumeInfo `json:"resume"`   // per action: the earlier session "Devam et" would continue
	Info       spec.Info             `json:"info"`
	Changes    []spec.ChangeInfo     `json:"changes"`
}

// ResumeInfo is an earlier host session of a spec that a run of the same action can continue.
type ResumeInfo struct {
	Session string `json:"session,omitempty"`
	At      string `json:"at"`
}

// resumable are the actions whose conversation is worth continuing: the same skill picks up where `sdkit spec next` says. A tasks run
// is not one: its parent and version are chosen again each time.
var resumable = []string{"generate-specs", "update-specs", "update-manual", "merge-specs"}

// ResumeFor finds, for each resumable action, the latest panel session of this spec that the host still has.
func ResumeFor(root, id, dir string, exists func(string) bool) map[string]ResumeInfo {
	out := map[string]ResumeInfo{}
	if exists == nil {
		return out
	}
	for _, r := range ReadRuns(root) {
		// a session belongs to the tree it ran in: the host files it per working directory
		if r.Spec != id || !exists(r.Session) || (r.Dir != "" && r.Dir != dir) || (r.Dir == "" && dir != root) {
			continue
		}
		for _, a := range resumable {
			if r.Action == a {
				out[a] = ResumeInfo{Session: r.Session, At: r.Start}
			}
		}
	}
	return out
}

// Branch is the branch the repo is on now.
func Branch(root string) string {
	b, _ := gitx.Run(root, "rev-parse", "--abbrev-ref", "HEAD")
	return b
}

// GetDetail gathers the page of one spec from the repo; nothing is written.
func GetDetail(root, id string) (Detail, error) {
	if !ValidID(id) && !reKitID.MatchString(id) {
		return Detail{}, errors.New("geçersiz ad")
	}
	var it *SpecItem
	for _, s := range listLocal(root) {
		if s.ID == id {
			s := s
			it = &s
		}
	}
	if it == nil {
		return Detail{}, errors.New("böyle bir spec yok")
	}
	info := spec.Inspect(root, id)
	branch := Branch(root)
	open := false
	for _, c := range info.Changes {
		open = open || c.Status == "open"
	}
	files, want := listFiles(root, id, it.State, info, branch)
	d := Detail{ID: id, State: it.State, Label: it.Label, Branch: branch, WantBranch: want, Info: info, Changes: info.Changes, Files: files,
		Actions: Actions(it.State, open)}
	d.Flow = Flow(it.State, ReadTaskResult(root, id, "").Done)
	d.Done = facts(it.State, info)
	return d, nil
}

func facts(state string, in spec.Info) []string {
	cur, out := stageOf(state), []string{}
	if cur >= 1 {
		out = append(out, "Ön-spec yazıldı")
	}
	if cur >= 2 {
		out = append(out, "Sorular cevaplandı, taslak hazırlandı")
	}
	if cur >= 3 {
		v := "Review geçti"
		if in.Verdict != "" {
			v += " (" + in.Verdict + ")"
		}
		out = append(out, v)
	}
	for _, h := range in.History {
		out = append(out, fmt.Sprintf("Sürüm %s PR'a gönderildi (%s)", h.Version, day(h.At)))
	}
	if cur >= 5 {
		out = append(out, "Tech Lead onayladı: sürüm "+in.Version)
	}
	for _, c := range in.Changes {
		out = append(out, fmt.Sprintf("Değişiklik %s: %s, etiket %s", c.Slug, map[string]string{"open": "açık", "applied": "uygulandı"}[c.Status], c.Label))
	}
	return out
}

func day(at string) string {
	if len(at) >= 10 {
		return at[:10]
	}
	return at
}

// listFiles is the allow-list of what the panel reads and writes: Markdown files of the spec (and of its draft), nothing the kit
// owns (meta, change records) and nothing outside those two directories. Whether one is editable follows the stage and the branch.
func listFiles(root, id, state string, info spec.Info, branch string) ([]FileItem, string) {
	var out []FileItem
	want := ""
	// the pre-spec is the input of everything below it: always readable, and editable only until a draft is made from it
	if st, err := os.Lstat(filepath.Join(root, filepath.FromSlash(info.Prespec))); err == nil && st.Mode().IsRegular() && strings.HasSuffix(info.Prespec, ".md") {
		it := FileItem{Path: info.Prespec, Group: "Ön-spec", Editable: state == spec.StateNew}
		if !it.Editable {
			it.Why = "Spec üretimi başladı; ön-spec artık kaynak olarak okunur."
		}
		out = append(out, it)
	}
	walk := func(dir, group string, skipChanges bool, edit func(rel string) (bool, string)) {
		base := filepath.Join(root, filepath.FromSlash(dir))
		var rels []string
		filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			rel, _ := filepath.Rel(root, p)
			rel = filepath.ToSlash(rel)
			switch {
			case d.IsDir() && skipChanges && rel == dir+"/changes":
				return filepath.SkipDir
			case d.IsDir() && strings.HasPrefix(d.Name(), ".") && p != base:
				return filepath.SkipDir
			case d.Type().IsRegular() && strings.HasSuffix(d.Name(), ".md"):
				rels = append(rels, rel)
			}
			return nil
		})
		sort.Strings(rels)
		for _, rel := range rels {
			ok, why := edit(rel)
			out = append(out, FileItem{Path: rel, Group: group, Editable: ok, Why: why})
		}
	}
	specBranch := "spec/" + id
	published := len(info.History) > 0
	walk(info.Dir, "Spec", true, func(string) (bool, string) {
		switch {
		case info.Status == "approved":
			return false, "Onaylı sürüm salt okunur. Değişiklik başlatın."
		case published && branch != specBranch:
			want = specBranch
			return false, "Düzenlemek için önce spec dalına geçin."
		}
		return true, ""
	})
	walk(info.Draft, "Taslak", false, func(string) (bool, string) {
		if state == spec.StateDraft || state == spec.StateNew {
			return true, ""
		}
		return false, "Taslak artık spec'e dönüştü; spec dosyalarını düzenleyin."
	})
	for _, c := range info.Changes {
		cb := specBranch + "--" + c.Slug
		walk(info.Dir+"/changes/"+c.Slug, "Değişiklik: "+c.Slug, false, func(string) (bool, string) {
			switch {
			case c.Status != "open":
				return false, "Bu değişiklik uygulandı."
			case branch != cb:
				want = cb
				return false, "Düzenlemek için önce bu değişikliğin dalına geçin."
			}
			return true, ""
		})
	}
	if out == nil {
		out = []FileItem{}
	}
	return out, want
}

const maxFile = 400 << 10

func findFile(root, id, rel string) (FileItem, error) {
	d, err := GetDetail(root, id)
	if err != nil {
		return FileItem{}, err
	}
	for _, f := range d.Files {
		if f.Path == rel {
			return f, nil
		}
	}
	return FileItem{}, errors.New("bu dosya paneldeki spec dosyaları arasında değil")
}

// ReadFile returns a listed file's text. A path that is not on the list (a traversal, a kit file, a symlink out) is refused.
func ReadFile(root, id, rel string) (string, FileItem, error) {
	f, err := findFile(root, id, rel)
	if err != nil {
		return "", f, err
	}
	p := filepath.Join(root, filepath.FromSlash(f.Path))
	if st, err := os.Lstat(p); err != nil || !st.Mode().IsRegular() || st.Size() > maxFile {
		return "", f, errors.New("dosya okunamadı veya çok büyük")
	}
	b, err := os.ReadFile(p)
	return string(b), f, err
}

// WriteFile replaces a listed, editable file. It never creates a file, and it will not write while a run is going: the agent and
// the person would be editing the same text.
func WriteFile(root, id, rel, text string, running bool) error {
	f, err := findFile(root, id, rel)
	switch {
	case err != nil:
		return err
	case running:
		return errors.New("Bir çalışma sürerken dosya düzenlenemez; bitmesini bekleyin veya durdurun")
	case !f.Editable:
		return errors.New(f.Why)
	case len(text) > maxFile || !utf8.ValidString(text) || strings.ContainsRune(text, 0):
		return errors.New("Metin çok büyük veya geçersiz karakter içeriyor")
	}
	p := filepath.Join(root, filepath.FromSlash(f.Path))
	st, err := os.Lstat(p)
	if err != nil || !st.Mode().IsRegular() {
		return errors.New("dosya yazılamadı")
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), ".sdkit-edit-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(text); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	os.Chmod(tmp.Name(), st.Mode().Perm())
	return os.Rename(tmp.Name(), p)
}

// ChangeSlug names a change the person did not name: who they are (the Atlassian e-mail they connected) and when. It satisfies the
// kit's name rule and never holds the `--` that separates the id from the slug in a branch name.
func ChangeSlug(user string, now time.Time) string {
	local, _, _ := strings.Cut(strings.ToLower(user), "@")
	var b strings.Builder
	for _, r := range local {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
		} else if b.Len() > 0 && !strings.HasSuffix(b.String(), "-") {
			b.WriteByte('-')
		}
	}
	who := strings.Trim(b.String(), "-")
	if len(who) > 20 {
		who = strings.Trim(who[:20], "-")
	}
	if who == "" {
		who = "panel"
	}
	return who + "-" + now.Format("060102-1504")
}

// StartChange opens a change on an approved spec, named by ChangeSlug, through the kit's own `sdkit spec change new`. That
// switches the repo to the change's branch; git refuses when there are unsaved edits, and the person is told so.
func StartChange(root, id, user string, now time.Time) (string, error) {
	for _, s := range listLocal(root) {
		if s.ID == id && s.State == spec.StateApproved {
			slug := ChangeSlug(user, now)
			var out, errb bytes.Buffer
			if spec.RunSpecAt(root, []string{"change", "new", id, slug, "--kind", "feature", "--title", "Panelden değişiklik (" + slug + ")"}, &out, &errb) != 0 {
				return "", gitFailure("Değişiklik açılamadı", errb.String())
			}
			return slug, nil
		}
	}
	return "", errors.New("Değişiklik yalnızca onaylı bir spec için başlatılır")
}

// SwitchBranch moves the repo to the spec's own branch (the kit's `sdkit spec branch`).
func SwitchBranch(root, id string) error {
	var out, errb bytes.Buffer
	if spec.RunSpecAt(root, []string{"branch", id}, &out, &errb) != 0 {
		return gitFailure("Dala geçilemedi", errb.String())
	}
	return nil
}

func gitFailure(what, stderr string) error {
	msg := strings.TrimSpace(stderr)
	if strings.Contains(msg, "commit or stash") || strings.Contains(msg, "would be overwritten") || strings.Contains(msg, "never forced") {
		return errors.New(what + ": çalışma ağacında kaydedilmemiş değişiklikler var. Önce bunları kaydedin veya teknik ekipten yardım isteyin")
	}
	return errors.New(what + ": " + clip(msg, 300))
}

// GitAuthEnv lets a session push to Bitbucket over HTTPS with the token the person saved, with no terminal to ask on. The header
// travels in the process environment of that one session (never on a command line, never in git's config on disk) and only for
// bitbucket.org. Nothing is returned for another host, an SSH remote or a missing token, and the session then uses what git has.
func GitAuthEnv(root string) []string {
	_, token := SavedTokens(root)
	origin := Origin(root)
	if token == "" || !strings.HasPrefix(origin, "https://") || !strings.Contains(origin, "bitbucket.org") {
		return nil
	}
	user := "x-token-auth" // repository and workspace access tokens
	if !strings.HasPrefix(token, "ATCTT") {
		user = ReadConnection(root).BitbucketEmail
	}
	if user == "" {
		return nil
	}
	return []string{
		"GIT_TERMINAL_PROMPT=0",
		"GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=http.https://bitbucket.org/.extraHeader",
		"GIT_CONFIG_VALUE_0=Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+token)),
	}
}
