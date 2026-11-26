package preflight

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wecii/sdkit/internal/testutil"
)

func TestCheckSHA(t *testing.T) {
	good := strings.Repeat("a1", 20)
	for _, c := range []struct {
		sha     string
		bad     bool
		mention string
	}{{good, false, ""}, {good[1:], true, "39 karakter"}, {"xyz", true, "geçerli"}, {strings.ToUpper(good), true, "geçerli"}} {
		tr, _ := CheckSHA(c.sha)
		if (tr != "") != c.bad || !strings.Contains(tr, c.mention) {
			t.Errorf("%q: %q", c.sha, tr)
		}
	}
}

// The LOGIN-V2 session hit all of these one after another: no token seen, a case-only branch clash, a remote branch already merged.
func TestSpecPublishFindsEveryCauseAtOnce(t *testing.T) {
	repo := testutil.TempRepo(t)
	g := func(a ...string) {
		c := exec.Command("git", append([]string{"-C", repo, "-c", "user.name=t", "-c", "user.email=t@t"}, a...)...)
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s", a, out)
		}
	}
	_ = os.MkdirAll(filepath.Join(repo, ".sdkit"), 0o755)
	_ = os.WriteFile(filepath.Join(repo, ".sdkit", "sdkit.env"), []byte("ANALYST_LANGUAGE=en\n"), 0o644)
	_ = os.WriteFile(filepath.Join(repo, "f"), []byte("x"), 0o644)
	g("add", ".")
	g("commit", "-q", "-m", "i")
	g("remote", "add", "origin", "https://bitbucket.org/acme/specs.git")
	g("branch", "spec/Login-v2")
	run := func(env map[string]string) string {
		var sb strings.Builder
		for _, l := range SpecPublish(Opts{Root: repo, Offline: true, Getenv: func(k string) string { return env[k] }}, "Login-V2") {
			sb.WriteString(l.String() + "\n")
		}
		return sb.String()
	}
	out := run(nil)
	for _, want := range []string{"FAIL BITBUCKET_TOKEN not found", "FAIL spec/Login-V2 and the existing spec/Login-v2 differ only in letter case"} {
		if !strings.Contains(strings.Join(strings.Fields(out), " "), strings.Join(strings.Fields(want), " ")) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	_ = os.WriteFile(filepath.Join(repo, ".sdkit", "sdkit.local.env"), []byte("BITBUCKET_TOKEN=ATCTT-local\n"), 0o644)
	if out = run(nil); !strings.Contains(out, "BITBUCKET_TOKEN found (sdkit.local.env)") || strings.Contains(out, "not found") {
		t.Errorf("a token in sdkit.local.env must be seen:\n%s", out)
	}
}

// A first publish needs business-requirements.md; a spec published before it existed is not asked for it.
func TestSpecPublishNeedsBusinessRequirements(t *testing.T) {
	repo := testutil.TempRepo(t)
	_ = os.MkdirAll(filepath.Join(repo, ".sdkit"), 0o755)
	_ = os.WriteFile(filepath.Join(repo, ".sdkit", "sdkit.env"), []byte("ANALYST_LANGUAGE=en\n"), 0o644)
	dir := filepath.Join(repo, "specs", "x")
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "proposal.md"), []byte("p"), 0o644)
	run := func() string {
		var sb strings.Builder
		for _, l := range SpecPublish(Opts{Root: repo, Offline: true, Getenv: func(string) string { return "" }}, "x") {
			sb.WriteString(l.String() + "\n")
		}
		return sb.String()
	}
	if !strings.Contains(run(), "business-requirements.md does not exist") {
		t.Error("a spec never published needs the file")
	}
	_ = os.WriteFile(filepath.Join(dir, "spec.meta.json"), []byte(`{"history":[{"version":"0.1"}]}`), 0o644)
	if strings.Contains(run(), "business-requirements.md") {
		t.Error("a spec published before the file existed is not asked for it")
	}
}
