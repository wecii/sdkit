package spec

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wecii/sdkit/internal/review"
	"github.com/wecii/sdkit/internal/testutil"
)

func TestPublishNeedsFreshPass(t *testing.T) {
	f := filepath.Join(testutil.TempRepo(t), "specs", "x", "spec.md")
	t.Setenv("CLAUDE_PROJECT_DIR", filepath.Dir(filepath.Dir(filepath.Dir(f))))
	t.Setenv("PR_HOST", "github")
	testutil.FakeCLI(t, "gh", "exit 0")
	_ = os.MkdirAll(filepath.Dir(f), 0o755)
	for i, c := range []string{"[]", "[ ]"} { // an empty findings array is also a valid document
		_ = os.WriteFile(f, []byte(c), 0o644)
		if o := new(strings.Builder); RunSpec([]string{"publish", "x", "--title", "T", "--body-file", f}, o, o) != 1 || !strings.Contains(o.String(), []string{"no review evidence", "stale"}[i]) {
			t.Fatal(i, o)
		}
		_, _ = review.Load(os.Getenv("CLAUDE_PROJECT_DIR")).Begin("x", "", false)
		_, _ = review.Load(os.Getenv("CLAUDE_PROJECT_DIR")).Record("x", "PASS", "fresh", f)
	}
}

func TestCaseClash(t *testing.T) {
	ex := []string{"spec/LOGIN-v2", "spec/other", "spec/other--c1"}
	for _, c := range []struct{ b, want string }{
		{"spec/LOGIN-V2", "spec/LOGIN-v2"}, // the macOS collision of the LOGIN-V2 session
		{"spec/LOGIN-v2", ""},              // the same spelling is the same branch, not a clash
		{"spec/new", ""},
	} {
		if got := CaseClash(ex, c.b); got != c.want {
			t.Errorf("CaseClash(%q) = %q, want %q", c.b, got, c.want)
		}
	}
}

// The Bitbucket credentials of `spec publish` come from sdkit.local.env (the LOGIN-V2 session had to `source` it by hand),
// never from the shared sdkit.env; the process environment still wins.
func TestPublishCredentialsFromLocalEnv(t *testing.T) {
	root := t.TempDir()
	kit := filepath.Join(root, ".sdkit")
	_ = os.MkdirAll(kit, 0o755)
	_ = os.WriteFile(filepath.Join(kit, "sdkit.env"), []byte("BITBUCKET_TOKEN=committed-secret\nBITBUCKET_EMAIL=shared@x.y\n"), 0o644)
	_ = os.WriteFile(filepath.Join(kit, "sdkit.local.env"), []byte("BITBUCKET_TOKEN=local-token-123\nBITBUCKET_EMAIL=me@x.y\n"), 0o644)
	t.Setenv("BITBUCKET_TOKEN", "")
	t.Setenv("BITBUCKET_EMAIL", "")
	e := envAt(root, io.Discard, io.Discard)
	if e.get("BITBUCKET_TOKEN") != "local-token-123" || e.get("BITBUCKET_EMAIL") != "me@x.y" {
		t.Fatalf("got %q %q", e.get("BITBUCKET_TOKEN"), e.get("BITBUCKET_EMAIL"))
	}
	_ = os.Remove(filepath.Join(kit, "sdkit.local.env"))
	if e = envAt(root, io.Discard, io.Discard); e.get("BITBUCKET_TOKEN") != "" {
		t.Fatalf("a token in the shared sdkit.env must not be used, got %q", e.get("BITBUCKET_TOKEN"))
	}
	t.Setenv("BITBUCKET_TOKEN", "from-env-xyz")
	if e.get("BITBUCKET_TOKEN") != "from-env-xyz" {
		t.Fatal("the process environment must win")
	}
}

func TestMaskGit(t *testing.T) {
	t.Setenv("BITBUCKET_TOKEN", "s3cr3t-token-value")
	e := envAt(t.TempDir(), io.Discard, io.Discard)
	// built in pieces so the tree scan does not mistake the fixture for a leaked URL credential
	got := e.maskGit("remote: denied https://" + "me:s3cr3t-token-value" + "@bitbucket.org/a/b.git and s3cr3t-token-value")
	if strings.Contains(got, "s3cr3t") || !strings.Contains(got, "denied") {
		t.Fatal(got)
	}
}

func TestNext(t *testing.T) {
	root := t.TempDir()
	w := func(p, c string) {
		_ = os.MkdirAll(filepath.Dir(filepath.Join(root, p)), 0o755)
		_ = os.WriteFile(filepath.Join(root, p), []byte(c), 0o644)
	}
	w(".sdkit/sdkit.env", "ANALYST_LANGUAGE=en\n")
	step := func() Step { return Next(root, "x") }
	if s := step(); !s.Human || !strings.Contains(s.Action, "no pre-spec") || s.State != StateNoInput {
		t.Fatalf("%+v", s)
	}
	w("prespec/x.md", "raw")
	if s := step(); !s.Human || !strings.Contains(s.Action, "ONE batch") || s.State != StateNew {
		t.Fatalf("questions are collected once, up front: %+v", s)
	}
	w(".sdkit/work/spec-draft/x/prd.md", "#### Scenario: AC-X-1\n#### Scenario: AC-X-1\n")
	if s := step(); s.Human || !strings.Contains(s.Action, "lint error") {
		t.Fatalf("mechanical errors are fixed before any reviewer runs: %+v", s)
	}
	w(".sdkit/work/spec-draft/x/prd.md", "#### Scenario: AC-X-1\n")
	if s := step(); s.Human || !strings.Contains(s.Action, "review round") || s.State != StateDraft {
		t.Fatalf("%+v", s)
	}
	// the output exists but has no business-requirements.md: it is written before the output is reviewed
	w("specs/x/proposal.md", "p")
	if s := step(); !strings.Contains(s.Action, "business-requirements.md") || s.State != StateOutput {
		t.Fatalf("the business requirements come before the output review: %+v", s)
	}
	w("specs/x/business-requirements.md", "<!-- sdkit: derived view -->\n")
	if s := step(); strings.Contains(s.Action, "business-requirements.md") {
		t.Fatalf("once written the review starts: %+v", s)
	}
	_ = os.RemoveAll(filepath.Join(root, "specs", "x"))
	// `sdkit spec next <id>` itself: the verb was once unregistered and its branch read the wrong argument list
	w("specs/n/proposal.md", "p")
	t.Chdir(root)
	var out, errw strings.Builder
	if rc := RunSpec([]string{"next", "n"}, &out, &errw); rc != 0 || !strings.Contains(out.String(), "next (agent): write specs/n/business-requirements.md") {
		t.Fatalf("spec next: rc=%d out=%q err=%q", rc, out.String(), errw.String())
	}
	_ = os.RemoveAll(filepath.Join(root, "specs", "n"))
	// a draft and a pre-spec of the same id are one entry; a README and a stray directory name are not specs
	w("prespec/README.md", "x")
	w("specs/y/proposal.md", "p")
	got := []string{}
	for _, e := range List(root) {
		got = append(got, e.ID+":"+e.State)
	}
	if strings.Join(got, " ") != "x:draft y:output" {
		t.Fatalf("list = %v", got)
	}
	// published specs are read from their record, not from review evidence this machine may not have; open work sorts first
	w("specs/done/spec.meta.json", `{"id":"done","status":"approved","history":[{"version":"1.0","sha":"a"}]}`)
	w("specs/wait/spec.meta.json", `{"id":"wait","status":"draft","history":[{"version":"0.1","sha":"b"}]}`)
	got = got[:0]
	for _, e := range List(root) {
		got = append(got, e.ID+":"+e.State)
	}
	if strings.Join(got, " ") != "x:draft y:output wait:awaiting done:approved" {
		t.Fatalf("list = %v", got)
	}
}
