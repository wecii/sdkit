package main

import (
	"os"

	"github.com/wecii/sdkit/internal/spec"
)

// The mechanics of a published spec; spec.RunSpec also routes `change parse|...` and `apply renumber|delta` to the fact tools.
func init() {
	for _, v := range []string{"change", "apply", "check", "publish", "promote", "approved-sha", "init-meta", "hash", "status", "changed", "branch", "drift", "next"} {
		specCmds[v] = func(a []string) int { return spec.RunSpec(append([]string{v}, a...), os.Stdout, os.Stderr) }
	}
}
