// Package gitx wraps the git calls the kit makes. All functions run git with a timeout.
package gitx

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/wecii/sdkit/internal/proc"
)

const timeout = 60 * time.Second

// Run runs `git -c core.quotePath=false args...` in dir and returns trimmed-right stdout.
// A non-zero exit is an error carrying stderr.
func Run(dir string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := proc.Run(ctx, dir, nil, "git", append([]string{"-c", "core.quotePath=false"}, args...)...)
	if err == nil && res.Code != 0 {
		err = &ExitError{Code: res.Code, Args: args, Stderr: strings.TrimSpace(res.Stderr)}
	}
	return strings.TrimRight(res.Stdout, "\r\n"), err
}

// ExitError is a git command that exited non-zero.
type ExitError struct {
	Code   int
	Args   []string
	Stderr string // what git said; may hold a remote URL with credentials, mask before showing
}

func (e *ExitError) Error() string {
	return "git " + strings.Join(e.Args, " ") + ": exit " + strconv.Itoa(e.Code)
}

func run(dir string, args ...string) (string, int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := proc.Run(ctx, dir, nil, "git", append([]string{"-c", "core.quotePath=false"}, args...)...)
	return strings.TrimRight(res.Stdout, "\r\n"), res.Code, err
}

// ok reports whether git exits 0.
func ok(dir string, args ...string) bool {
	_, code, err := run(dir, args...)
	return err == nil && code == 0
}

// Lines splits output into non-empty lines.
func Lines(s string) []string {
	var l []string
	for _, x := range strings.Split(s, "\n") {
		if x = strings.TrimSuffix(x, "\r"); x != "" {
			l = append(l, x)
		}
	}
	return l
}

// Top returns the repository top-level directory containing dir.
func Top(dir string) (string, error) { return Run(dir, "rev-parse", "--show-toplevel") }

// RevParse resolves rev to a commit id; "" when it does not exist.
func RevParse(dir, rev string) string {
	out, code, err := run(dir, "rev-parse", "--verify", "-q", rev+"^{commit}")
	if err != nil || code != 0 {
		return ""
	}
	return out
}

// MergeBase returns the merge base of a and b.
func MergeBase(dir, a, b string) (string, error) { return Run(dir, "merge-base", a, b) }

// Config returns a git config value, "" when unset.
func Config(dir, key string) string {
	out, code, err := run(dir, "config", key)
	if err != nil || code != 0 {
		return ""
	}
	return out
}

// IsIgnored reports whether path is ignored by git.
func IsIgnored(dir, path string) bool { return ok(dir, "check-ignore", "-q", "--", path) }

// Tracked reports whether path is tracked.
func Tracked(dir, path string) bool { return ok(dir, "ls-files", "--error-unmatch", "--", path) }

// ChangedFiles lists files changed since base (committed range base...HEAD is not used; this
// matches `git diff --name-only base`), plus untracked non-ignored files when untracked is true.
func ChangedFiles(dir, base string, untracked bool) ([]string, error) {
	out, err := Run(dir, "diff", "--name-only", base)
	if err != nil {
		return nil, err
	}
	files := Lines(out)
	if untracked {
		u, err := Run(dir, "ls-files", "-o", "--exclude-standard")
		if err != nil {
			return nil, err
		}
		files = append(files, Lines(u)...)
	}
	return files, nil
}

// RunInteractive runs git with the caller's stdin and without a timeout or a separate process
// group, so a credential or ssh prompt can reach the terminal (git asks on /dev/tty, which a
// background group may not read). Stdout and stderr are captured; a non-zero exit is an ExitError.
func RunInteractive(dir string, in io.Reader, args ...string) error {
	cmd := exec.Command("git", append([]string{"-c", "core.quotePath=false"}, args...)...)
	cmd.Dir, cmd.Stdin = dir, in
	var errb bytes.Buffer
	cmd.Stderr = &errb
	err := cmd.Run()
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return &ExitError{Code: ee.ExitCode(), Args: args, Stderr: strings.TrimSpace(errb.String())}
	}
	return err
}
