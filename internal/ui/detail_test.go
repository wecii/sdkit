package ui

import (
	"encoding/base64"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestFlow(t *testing.T) {
	cases := []struct {
		state string
		tasks bool
		want  string // one letter per stage: d done, c current, t todo
	}{
		{"no-input", false, "ctttt" + "t"},
		{"new", false, "dcttt" + "t"},
		{"draft", false, "ddcttt"},
		{"output", false, "ddcttt"},
		{"unpublished", false, "dddctt"},
		{"awaiting", false, "ddddct"},
		{"approved", false, "dddddc"},
		{"approved", true, "dddddd"},
		{"awaiting", true, "ddddct"},
		{"something-new", false, "tttttt"},
	}
	for _, c := range cases {
		got := ""
		for _, s := range Flow(c.state, c.tasks) {
			got += s.Status[:1]
		}
		if got != c.want {
			t.Errorf("Flow(%s, tasks=%v) = %s, want %s", c.state, c.tasks, got, c.want)
		}
	}
}

func TestActions(t *testing.T) {
	keys := func(state string, open bool) string {
		var k []string
		for _, a := range Actions(state, open) {
			k = append(k, a.Key)
		}
		return strings.Join(k, ",")
	}
	cases := []struct {
		state string
		open  bool
		want  string
	}{
		{"no-input", false, ""},
		{"draft", false, "generate-specs"},
		{"unpublished", false, "generate-specs,refine-specs"},
		{"awaiting", false, "update-specs,update-manual,generate-design"},
		{"approved", false, "start-change,edit-change,generate-design,generate-tasks,merge-specs"},
		{"approved", true, "start-change,edit-change,update-manual,generate-design,generate-tasks,merge-specs"},
	}
	for _, c := range cases {
		if got := keys(c.state, c.open); got != c.want {
			t.Errorf("Actions(%s, open=%v) = %q, want %q", c.state, c.open, got, c.want)
		}
	}
}

func TestChangeSlug(t *testing.T) {
	at := time.Date(2026, 11, 18, 22, 31, 0, 0, time.UTC)
	cases := []struct{ user, want string }{
		{"Ayse.Yilmaz@firma.com", "ayse-yilmaz-261118-2231"},
		{"", "panel-261118-2231"},
		{"--@x.com", "panel-261118-2231"},
		{"a_very_long_user_name_indeed@x.com", "a-very-long-user-nam-261118-2231"},
	}
	for _, c := range cases {
		got := ChangeSlug(c.user, at)
		if got != c.want || strings.Contains(got, "--") || !reSlug.MatchString(got) {
			t.Errorf("ChangeSlug(%q) = %q, want %q", c.user, got, c.want)
		}
	}
}

func TestUpdateTaskNamesTheOpenChange(t *testing.T) {
	got, _ := Task("", "update-manual", "odeme", TaskInput{Slug: "ayse-261118-2231"})
	if !strings.Contains(got, "sdkit spec changed odeme") || !strings.Contains(got, `"ayse-261118-2231"`) || !strings.Contains(got, "do not create another") {
		t.Errorf("manual continue on a change: %q", got)
	}
	if got, _ := Task("", "update-specs", "odeme", TaskInput{Slug: "x; rm -rf /"}); strings.Contains(got, "rm -rf") {
		t.Errorf("a slug that is not a slug must not reach the task: %q", got)
	}
}

func gitIn(t *testing.T, root string, args ...string) {
	t.Helper()
	c := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t"}, args...)...)
	c.Dir = root
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// a published spec (awaiting the Tech Lead) with a feature file, plus a link that points outside the spec
func publishedSpec(t *testing.T, status string) string {
	root := scratchRepo(t, "/prespec/\n/.sdkit/work/\n")
	d := filepath.Join(root, "specs", "odeme")
	os.MkdirAll(filepath.Join(d, "specs", "kart"), 0o755)
	os.WriteFile(filepath.Join(d, "proposal.md"), []byte("# Öneri\n"), 0o644)
	os.WriteFile(filepath.Join(d, "specs", "kart", "spec.md"), []byte("AC-1\n"), 0o644)
	os.WriteFile(filepath.Join(d, "spec.meta.json"), []byte(`{"id":"odeme","version":"0.1","status":"`+status+`","history":[{"version":"0.1","at":"2026-11-16T10:00:00Z"}]}`), 0o644)
	os.WriteFile(filepath.Join(root, "secret.md"), []byte("gizli\n"), 0o644)
	os.Symlink(filepath.Join(root, "secret.md"), filepath.Join(d, "link.md"))
	gitIn(t, root, "add", "-A")
	gitIn(t, root, "commit", "-q", "-m", "spec")
	return root
}

func TestEditingRules(t *testing.T) {
	root := publishedSpec(t, "draft")
	files := func() map[string]FileItem {
		d, err := GetDetail(root, "odeme")
		if err != nil {
			t.Fatal(err)
		}
		m := map[string]FileItem{}
		for _, f := range d.Files {
			m[f.Path] = f
		}
		return m
	}
	f := files()
	if _, ok := f["specs/odeme/spec.meta.json"]; ok {
		t.Error("the kit's own records are not for editing")
	}
	if _, ok := f["specs/odeme/link.md"]; ok {
		t.Error("a link out of the spec directory must not be listed")
	}
	if p := f["specs/odeme/proposal.md"]; p.Editable || !strings.Contains(p.Why, "dalına") {
		t.Errorf("a published spec is edited on its own branch: %+v", p)
	}
	if err := WriteFile(root, "odeme", "specs/odeme/proposal.md", "x", false); err == nil {
		t.Error("write on the wrong branch must be refused")
	}
	gitIn(t, root, "checkout", "-q", "-b", "spec/odeme")
	if !files()["specs/odeme/proposal.md"].Editable {
		t.Fatal("editable on spec/odeme")
	}
	for _, bad := range []string{"secret.md", "../secret.md", "specs/odeme/link.md", "specs/odeme/spec.meta.json", "specs/odeme/nope.md"} {
		if err := WriteFile(root, "odeme", bad, "x", false); err == nil {
			t.Errorf("write to %q must be refused", bad)
		}
		if _, _, err := ReadFile(root, "odeme", bad); err == nil {
			t.Errorf("read of %q must be refused", bad)
		}
	}
	if err := WriteFile(root, "odeme", "specs/odeme/proposal.md", "# Yeni\n", true); err == nil {
		t.Error("no writes while a run is going")
	}
	if err := WriteFile(root, "odeme", "specs/odeme/proposal.md", "# Yeni\n", false); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(root, "specs", "odeme", "proposal.md")); string(b) != "# Yeni\n" {
		t.Errorf("content = %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(root, "secret.md")); string(b) != "gizli\n" {
		t.Error("the file behind the link was touched")
	}
}

func TestApprovedSpecIsReadOnly(t *testing.T) {
	root := publishedSpec(t, "approved")
	gitIn(t, root, "checkout", "-q", "-b", "spec/odeme")
	err := WriteFile(root, "odeme", "specs/odeme/proposal.md", "x", false)
	if err == nil || !strings.Contains(err.Error(), "Onaylı") {
		t.Errorf("the approved base is never edited, a change is: %v", err)
	}
}

func TestGitAuthEnv(t *testing.T) {
	root := scratchRepo(t, "/.sdkit/sdkit.local.env\n")
	gitIn(t, root, "remote", "add", "origin", "https://user@bitbucket.org/ws/repo.git")
	local := filepath.Join(root, ".sdkit", "sdkit.local.env")
	if GitAuthEnv(root) != nil {
		t.Error("no token, no header")
	}
	os.WriteFile(local, []byte("BITBUCKET_EMAIL=a@b.c\nBITBUCKET_TOKEN=secret1\n"), 0o600)
	env := strings.Join(GitAuthEnv(root), "\n")
	want := base64.StdEncoding.EncodeToString([]byte("a@b.c:secret1"))
	if !strings.Contains(env, "GIT_TERMINAL_PROMPT=0") || !strings.Contains(env, "Basic "+want) || !strings.Contains(env, "http.https://bitbucket.org/.extraHeader") {
		t.Errorf("env = %s", env)
	}
	os.WriteFile(local, []byte("BITBUCKET_TOKEN=ATCTTabc\n"), 0o600)
	if e := strings.Join(GitAuthEnv(root), "\n"); !strings.Contains(e, base64.StdEncoding.EncodeToString([]byte("x-token-auth:ATCTTabc"))) {
		t.Errorf("an access token goes as x-token-auth: %s", e)
	}
	gitIn(t, root, "remote", "set-url", "origin", "git@bitbucket.org:ws/repo.git")
	if GitAuthEnv(root) != nil {
		t.Error("an SSH remote needs no header")
	}
	gitIn(t, root, "remote", "set-url", "origin", "https://example.com/ws/repo.git")
	if GitAuthEnv(root) != nil {
		t.Error("the token is sent to Bitbucket only")
	}
}

func TestStartChangeOnApprovedSpec(t *testing.T) {
	root := publishedSpec(t, "approved")
	remote := t.TempDir()
	gitIn(t, remote, "init", "-q", "--bare")
	gitIn(t, root, "remote", "add", "origin", remote)
	gitIn(t, root, "push", "-q", "origin", "HEAD:main")
	gitIn(t, root, "fetch", "-q", "origin")
	at := time.Date(2026, 11, 18, 22, 31, 0, 0, time.UTC)

	if _, err := StartChange(root, "yok", "a@b.c", at); err == nil {
		t.Error("a spec that does not exist has no change to start")
	}
	slug, err := StartChange(root, "odeme", "ayse@firma.com", at)
	if err != nil || slug != "ayse-261118-2231" {
		t.Fatalf("slug %q, err %v", slug, err)
	}
	if b := Branch(root); b != "spec/odeme--"+slug {
		t.Errorf("the change lives on its own branch: %s", b)
	}
	d, err := GetDetail(root, "odeme")
	if err != nil || len(d.Changes) != 1 || d.Changes[0].Status != "open" {
		t.Fatalf("open change expected: %+v %v", d.Changes, err)
	}
	var intent FileItem
	for _, f := range d.Files {
		if strings.HasSuffix(f.Path, "/intent.md") {
			intent = f
		}
		if strings.HasSuffix(f.Path, "proposal.md") && f.Editable {
			t.Errorf("the approved base stays read-only even next to an open change: %+v", f)
		}
	}
	if !intent.Editable {
		t.Errorf("the change's own files are editable on its branch: %+v", intent)
	}
	if _, err := StartChange(root, "odeme", "ayse@firma.com", at); err == nil {
		t.Error("the same slug twice must be refused by the kit, not silently reused")
	}
	var keys []string
	for _, a := range d.Actions {
		keys = append(keys, a.Key)
	}
	if !strings.Contains(strings.Join(keys, ","), "update-manual") {
		t.Errorf("with an open change the person can continue after editing by hand: %v", keys)
	}
}

func TestResumeFor(t *testing.T) {
	root := scratchRepo(t, "/.sdkit/work/\n")
	a, b, c := "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa", "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb", "cccccccc-3333-4333-8333-cccccccccccc"
	for _, r := range []RunRecord{
		{Session: a, Spec: "odeme", Action: "generate-specs", Start: "2026-11-17T08:00:00Z"},
		{Session: b, Spec: "odeme", Action: "generate-specs", Start: "2026-11-18T08:00:00Z"}, // newer, but the host no longer has it
		{Session: c, Spec: "baska", Action: "generate-specs", Start: "2026-11-19T08:00:00Z"},
	} {
		RecordRun(root, r)
	}
	has := func(id string) bool { return id != b }
	got := ResumeFor(root, "odeme", root, has)
	if got["generate-specs"].Session != a || len(got) != 1 {
		t.Errorf("the latest session the host still has, of this spec and this action: %+v", got)
	}
	if len(ResumeFor(root, "odeme", root, nil)) != 0 {
		t.Error("without a way to ask the host nothing is resumed")
	}
	RecordRun(root, RunRecord{Session: a, Spec: "odeme", Action: "generate-tasks", Start: "2026-11-20T08:00:00Z"})
	if _, ok := ResumeFor(root, "odeme", root, has)["generate-tasks"]; ok {
		t.Error("a tasks run is never resumed: its parent and version are chosen again")
	}
}

func TestResumeArgs(t *testing.T) {
	args := BuildArgs(RunSpec{Prompt: "p", Resume: "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"})
	if strings.Join(args, " ") != strings.Join(BuildArgs(RunSpec{Prompt: "p"}), " ")+" --resume aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa" {
		t.Errorf("args = %v", args)
	}
}

func TestPrespecIsInTheFileList(t *testing.T) {
	root := scratchRepo(t, "/prespec/\n")
	WritePrespec(root, "odeme", "# Ön-spec\n", false)
	find := func() FileItem {
		d, err := GetDetail(root, "odeme")
		if err != nil {
			t.Fatal(err)
		}
		for _, f := range d.Files {
			if f.Group == "Ön-spec" {
				return f
			}
		}
		t.Fatal("pre-spec not listed")
		return FileItem{}
	}
	if f := find(); !f.Editable || f.Path != "prespec/odeme.md" {
		t.Errorf("before a draft exists the pre-spec is the person's to change: %+v", f)
	}
	os.MkdirAll(filepath.Join(root, ".sdkit", "work", "spec-draft", "odeme"), 0o755)
	if f := find(); f.Editable || f.Why == "" {
		t.Errorf("once a draft exists the pre-spec is the source, read-only: %+v", f)
	}
	if text, _, err := ReadFile(root, "odeme", "prespec/odeme.md"); err != nil || !strings.Contains(text, "Ön-spec") {
		t.Errorf("readable at any stage: %q %v", text, err)
	}
}
