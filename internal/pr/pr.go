// Package pr opens, updates and closes pull requests: Bitbucket through its REST API,
// GitHub through gh, GitLab through glab. Credentials come from the environment and the
// origin URL only, never from sdkit.env.
package pr

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"regexp"
	"strings"

	"github.com/wecii/sdkit/internal/gitx"
	"github.com/wecii/sdkit/internal/proc"
)

// Error carries the exit code the command should end with.
type Error struct {
	Code int
	Msg  string
}

func (e *Error) Error() string { return e.Msg }

func fail(code int, f string, a ...any) error { return &Error{code, fmt.Sprintf(f, a...)} }

// Request is one invocation; Getenv and Setting resolve environment and sdkit.env values.
type Request struct {
	Dir, Host, Title, DescFile, Dest, CloseBranch string
	Mode                                          string // create (default), update, close
	Reuse                                         bool
	Getenv                                        func(string) string
	Out, Err                                      io.Writer
}

func (r *Request) env(k string) string {
	if r.Getenv != nil {
		return r.Getenv(k)
	}
	return os.Getenv(k)
}

// Detect names the host of an origin URL (PR_HOST=auto); ghHost and glHost are the self-hosted names.
func Detect(origin, ghHost, glHost string) (string, error) {
	has := func(s, h string) bool { return h != "" && (strings.Contains(s, h+":") || strings.Contains(s, h+"/")) }
	switch {
	case has(origin, "github.com"):
		return "github", nil
	case has(origin, "bitbucket.org"):
		return "bitbucket", nil
	case strings.Contains(origin, "gitlab."):
		return "gitlab", nil
	case has(origin, ghHost):
		return "github", nil
	case has(origin, glHost):
		return "gitlab", nil
	}
	return "", fail(2, "PR_HOST=auto: cannot tell the host from origin '%s'; set PR_HOST to bitbucket, github or gitlab", origin)
}

// ResolveHost applies PR_HOST (default bitbucket, auto detects).
func (r *Request) ResolveHost() (string, error) {
	h := r.Host
	if h == "" {
		h = "bitbucket"
	}
	if h == "auto" {
		o, _ := gitx.Run(r.Dir, "remote", "get-url", "origin")
		gl := r.env("GITLAB_HOST")
		if i := strings.Index(gl, "://"); i >= 0 {
			gl = gl[i+3:]
		}
		var err error
		if h, err = Detect(o, r.env("GH_HOST"), gl); err != nil {
			return "", err
		}
	}
	switch h {
	case "bitbucket", "github", "gitlab":
		return h, nil
	}
	return "", fail(2, "PR_HOST=%s is not supported (bitbucket, github, gitlab, auto). Open the PR by hand.", h)
}

var reCreds = regexp.MustCompile(`^https://([^@/]+:[^@/]+)@bitbucket\.org/`)

// reRepo takes https, scp-style ssh (git@bitbucket.org:ws/repo.git) and ssh:// origins; group 1 is workspace/repo.
var reRepo = regexp.MustCompile(`^(?:https://(?:[^@/]+@)?bitbucket\.org/|ssh://(?:[^@/]+@)?bitbucket\.org(?::\d+)?/|[^@/:]+@bitbucket\.org:/?)([^/]+/[^/]+?)(?:\.git)?/?$`)

// Run performs the request and returns the process exit code of the equivalent command.
func (r *Request) Run(ctx context.Context) error {
	host, err := r.ResolveHost()
	if err != nil {
		return err
	}
	desc, err := os.ReadFile(r.DescFile)
	if err != nil {
		return fail(2, "description file not readable: %s", r.DescFile)
	}
	source := r.CloseBranch
	if r.Mode != "close" {
		source, _ = gitx.Run(r.Dir, "rev-parse", "--abbrev-ref", "HEAD")
		if gitx.RevParse(r.Dir, "origin/"+source) == "" {
			return fail(1, "push %s first (git push -u origin %s)", source, source)
		}
	}
	if host == "bitbucket" {
		return r.bitbucket(ctx, source, string(desc))
	}
	return r.cli(ctx, host, source, string(desc))
}

func (r *Request) run(ctx context.Context, name string, args ...string) (proc.Result, error) {
	return proc.Run(ctx, r.Dir, nil, name, args...)
}

func (r *Request) cli(ctx context.Context, host, source, desc string) error {
	bin, doc := "gh", "https://cli.github.com), then gh auth login"
	if host == "gitlab" {
		bin, doc = "glab", "https://gitlab.com/gitlab-org/cli), then glab auth login"
	}
	if _, err := proc.LookPath(bin); err != nil {
		return fail(2, "PR_HOST=%s needs the %s CLI (%s", host, bin, doc)
	}
	// do runs one call; a non-zero exit is an error that carries the CLI's own code.
	do := func(args ...string) (string, error) {
		res, err := r.run(ctx, bin, args...)
		if err != nil {
			return "", fail(1, "%s: %v", bin, err)
		}
		if res.Code != 0 {
			fmt.Fprint(r.Err, res.Stderr)
			return res.Stdout, &Error{res.Code, ""}
		}
		return res.Stdout, nil
	}
	existing := func() string {
		if host == "github" {
			out, err := do("pr", "list", "--head", source, "--state", "open", "--json", "url")
			var v []struct{ URL string }
			if err != nil || json.Unmarshal([]byte(out), &v) != nil || len(v) == 0 {
				return ""
			}
			return v[0].URL
		}
		out, _ := do("mr", "list", "--source-branch", source, "--output", "json")
		var v []struct {
			WebURL string `json:"web_url"`
		}
		if json.Unmarshal([]byte(out), &v) != nil || len(v) == 0 {
			return ""
		}
		return v[0].WebURL
	}
	gh := host == "github"
	switch r.Mode {
	case "update":
		args := []string{"mr", "update", source, "--title", r.Title, "--description", desc}
		if gh {
			args = []string{"pr", "edit", source, "--title", r.Title, "--body-file", r.DescFile}
		}
		if _, err := do(args...); err != nil {
			return fail(1, "")
		}
		fmt.Fprintln(r.Out, existing())
		return nil
	case "close":
		a, b := []string{"mr", "note", source, "-m", desc}, []string{"mr", "close", source}
		if gh {
			a, b = []string{"pr", "comment", source, "--body-file", r.DescFile}, []string{"pr", "close", source}
		}
		if _, err := do(a...); err != nil {
			return fail(1, "")
		}
		if _, err := do(b...); err != nil {
			return fail(1, "")
		}
		fmt.Fprintln(r.Out, "closed "+source)
		return nil
	}
	if r.Reuse {
		if u := existing(); u != "" {
			fmt.Fprintln(r.Out, u)
			return nil
		}
	}
	args := []string{"mr", "create", "--source-branch", source, "--target-branch", r.Dest, "--title", r.Title, "--description", desc, "--yes"}
	if gh {
		args = []string{"pr", "create", "--base", r.Dest, "--head", source, "--title", r.Title, "--body-file", r.DescFile}
	}
	out, err := do(args...)
	fmt.Fprint(r.Out, out)
	return err
}

// Check is the preflight (open-pr --check): it lists everything missing and opens nothing.
// It returns the number of missing items; a non-nil error means the host could not be resolved.
func (r *Request) Check(ctx context.Context) (int, error) {
	host, err := r.ResolveHost()
	if err != nil {
		return 0, err
	}
	missing := 0
	need := func(s string) { fmt.Fprintln(r.Err, "  - "+s); missing++ }
	fmt.Fprintln(r.Err, "PR host: "+host)
	switch host {
	case "github", "gitlab":
		bin, inst, login := "gh", "https://cli.github.com", "gh auth login   (or export GH_TOKEN=...)"
		if host == "gitlab" {
			bin, inst, login = "glab", "https://gitlab.com/gitlab-org/cli", "glab auth login   (or export GITLAB_TOKEN=...)"
		}
		if _, err := proc.LookPath(bin); err != nil {
			need("install the " + bin + " CLI (" + inst + ")")
		} else if res, err := r.run(ctx, bin, "auth", "status"); err != nil || res.Code != 0 {
			need("run: " + login)
		}
	default:
		email := r.env("BITBUCKET_EMAIL")
		if email == "" {
			email = gitx.Config(r.Dir, "user.email")
		}
		tokURL, _ := gitx.Run(r.tokenRepo(), "remote", "get-url", "origin")
		tok := r.env("BITBUCKET_TOKEN")
		have := tok != ""
		if m := reCreds.FindStringSubmatch(tokURL); !have && m != nil {
			have, tok = true, m[1][strings.Index(m[1], ":")+1:]
		}
		bearer := strings.HasPrefix(r.env("BITBUCKET_TOKEN"), "ATCTT")
		if !bearer && email == "" {
			need("set the Bitbucket account email: export BITBUCKET_EMAIL=you@company.com  (or git config user.email)")
		}
		if !have {
			need("set a Bitbucket API token (repo + pull request write): export BITBUCKET_TOKEN=...   (create it in Bitbucket > Personal settings > API tokens)")
		}
		if have && (bearer || email != "") {
			origin, _ := gitx.Run(r.Dir, "remote", "get-url", "origin")
			slug := ""
			if m := reRepo.FindStringSubmatch(origin); m != nil {
				slug = m[1]
			}
			code := r.checkCredentials(ctx, slug, tok, email)
			switch code {
			case 200:
			case 401, 403:
				need(fmt.Sprintf("Bitbucket rejected the credentials (HTTP %d): ATCTT... access tokens are sent as Bearer; other tokens need BITBUCKET_EMAIL to be the Bitbucket account email, and the token must allow repository read + pull request write", code))
			case 0:
				fmt.Fprintln(r.Err, "  (warning: could not reach api.bitbucket.org, credentials not verified)")
			default:
				fmt.Fprintf(r.Err, "  (warning: Bitbucket answered HTTP %d on the credential check)\n", code)
			}
		}
	}
	return missing, nil
}

func (r *Request) tokenRepo() string {
	if t := r.env("PR_TOKEN_REPO"); t != "" {
		return t
	}
	return r.Dir
}

func queryEscape(s string) string { return strings.ReplaceAll(url.QueryEscape(s), "+", "%20") }
