package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"time"

	"github.com/wecii/sdkit/internal/cli"
	"github.com/wecii/sdkit/internal/ext"
	"github.com/wecii/sdkit/internal/project"
	"github.com/wecii/sdkit/internal/ui"
)

// sdkit ext run <action> <id> [--fresh] [--note <text>] [--host <cmd>]   one agent run for an editor extension (docs/design-vscode.md)
// sdkit ext health [--host <cmd>]   the onboarding checklist as one JSON document
// sdkit ext specs                   every spec with its state, as JSON
// sdkit ext spec <id>               the page of one spec (state, actions, files and the folder they are in), as JSON
// sdkit ext spec branch|change <id>  move to the spec's own branch / open a change on an approved spec (the panel's rules, no git for the person)
// sdkit ext prespec <id> [--overwrite]   store the pre-spec text from stdin as a new pre-spec; {"exists":true} when it is there already
// sdkit ext sync                    fetch and fast-forward the base branch when that is safe; never discards or merges; JSON with a message for the person
// sdkit ext connection [save]       the saved Jira/Bitbucket settings; `save` reads them from stdin as JSON, stores them and checks them
//
//	writes one JSON line per event or question to stdout and reads answers and "stop" lines from stdin; no server, no page.
//	actions: generate-specs, update-specs, update-manual, merge-specs
func init() { cli.Register("ext", runExt) }

const extUsage = "usage: sdkit ext run <action> <id> [--fresh] [--note <text>] [--host <cmd>] | health [--host <cmd>] | specs | spec <id> | spec branch|change <id> | connection [save] | prespec <id> [--overwrite] | sync"

func runExt(args []string) int {
	if len(args) > 0 && args[0] != "run" {
		return runExtRead(args)
	}
	if len(args) < 3 || args[0] != "run" {
		fmt.Fprintln(os.Stderr, extUsage)
		return cli.ExitUsage
	}
	o := ext.Options{Action: args[1], ID: args[2], Rules: uiRules, Secret: ui.NewSecret(),
		Tools: []string{"Bash", "Read", "Write", "Edit", "Glob", "Grep", "Task", "Skill"}, SessionExists: claudeSessionExists}
	for i := 3; i < len(args); i++ {
		switch args[i] {
		case "--fresh":
			o.Fresh = true
		case "--note":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, extUsage)
				return cli.ExitUsage
			}
			i++
			o.Note = args[i]
		case "--host":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, extUsage)
				return cli.ExitUsage
			}
			i++
			o.Command = args[i]
		default:
			fmt.Fprintln(os.Stderr, extUsage)
			return cli.ExitUsage
		}
	}
	wd, _ := os.Getwd()
	root, err := project.Root(wd)
	if err != nil {
		root = wd
	}
	o.Root = root
	if exe, err := os.Executable(); err == nil {
		// the session calls `sdkit ...` by name and must get THIS binary
		dir, err := sdkitShim(exe)
		if err != nil {
			dir = filepath.Dir(exe)
		}
		o.Env = []string{"PATH=" + dir + string(os.PathListSeparator) + os.Getenv("PATH")}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := ext.Run(ctx, o, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "sdkit ext:", err)
		return cli.ExitFail
	}
	return cli.ExitOK
}

// runExtRead is the read verbs: one JSON document on stdout, the reason on stderr when it fails.
func runExtRead(args []string) int {
	wd, _ := os.Getwd()
	root, err := project.Root(wd)
	if err != nil {
		root = wd
	}
	switch {
	case args[0] == "health" && (len(args) == 1 || (len(args) == 3 && args[1] == "--host")):
		host := ""
		if len(args) == 3 {
			host = args[2]
		}
		err = ext.WriteHealth(context.Background(), os.Stdout, root, os.Getenv, host)
	case args[0] == "specs" && len(args) == 1:
		err = ext.WriteSpecs(os.Stdout, root)
	case args[0] == "spec" && len(args) == 3 && args[1] == "branch":
		err = ext.SpecBranch(os.Stdout, root, args[2])
	case args[0] == "spec" && len(args) == 3 && args[1] == "change":
		err = ext.SpecChange(os.Stdout, root, args[2], time.Now())
	case args[0] == "spec" && len(args) == 2:
		err = ext.WriteSpec(os.Stdout, root, args[1])
	case args[0] == "prespec" && (len(args) == 2 || (len(args) == 3 && args[2] == "--overwrite")):
		err = ext.WritePrespec(os.Stdout, os.Stdin, root, args[1], len(args) == 3)
	case args[0] == "sync" && len(args) == 1:
		err = ext.WriteSync(context.Background(), os.Stdout, root)
	case args[0] == "connection" && len(args) == 1:
		err = ext.WriteConnection(os.Stdout, root)
	case args[0] == "connection" && len(args) == 2 && args[1] == "save":
		err = ext.SaveConnection(context.Background(), os.Stdout, os.Stdin, root, "", nil)
	default:
		fmt.Fprintln(os.Stderr, extUsage)
		return cli.ExitUsage
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "sdkit ext:", err)
		return cli.ExitFail
	}
	return cli.ExitOK
}
