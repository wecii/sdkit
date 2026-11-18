package testutil

import (
	"fmt"
	"regexp"
	"testing"
)

// The number moves with every release; the golden pins the shape of the output only.
var semver = regexp.MustCompile(`\d+\.\d+\.\d+\S*`)

func TestVersionGolden(t *testing.T) {
	out, code := RunKit(t, TempRepo(t), "", "version")
	Golden(t, "testutil/version", fmt.Sprintf("exit: %d\n%s", code, semver.ReplaceAllString(out, "<VERSION>")))
}
