// Package jira is the task contract (the fenced sdkit-task block) and the Jira
// REST client behind `sdkit jira`. The MCP path is the agent's, not this code's.
package jira

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/wecii/sdkit/internal/tasks"
	"regexp"
	"sort"
	"strings"
)

// Err carries the exit code: 3 egress/auth, 4 contract invalid, 5 not found or external failure, 2 usage.
type Err struct {
	Code int
	Msg  string
}

func (e *Err) Error() string { return e.Msg }

func fail(code int, f string, a ...any) *Err { return &Err{code, fmt.Sprintf(f, a...)} }

// Task is a task object as found in a description or given as JSON.
type Task map[string]any

// JSON renders v compact (indent "") or indented, without HTML escaping, like jq.
func JSON(v any, indent string) string {
	var b bytes.Buffer
	e := json.NewEncoder(&b)
	e.SetEscapeHTML(false)
	if indent != "" {
		e.SetIndent("", indent)
	}
	_ = e.Encode(v)
	return strings.TrimSuffix(b.String(), "\n")
}

var (
	reOpen  = regexp.MustCompile("^[ \t]*```[ \t]*sdkit-task[ \t]*$")
	reClose = regexp.MustCompile("^[ \t]*```[ \t]*$")
	reSHA   = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

// TaskFrom returns the task object in text: the JSON itself, or the fenced sdkit-task block.
// found is false when there is neither; obj is false when the block is not a JSON object.
func TaskFrom(in string) (t Task, found, obj bool) {
	if json.Unmarshal([]byte(in), &t) == nil && t != nil {
		return t, true, true
	}
	var blk []string
	in2, f := strings.Split(strings.ReplaceAll(in, "\r", ""), "\n"), false
	for _, l := range in2 {
		if !f && reOpen.MatchString(l) {
			f = true
		} else if f && reClose.MatchString(l) {
			break
		} else if f {
			blk = append(blk, l)
		}
	}
	if len(blk) == 0 {
		return nil, false, false
	}
	if json.Unmarshal([]byte(strings.Join(blk, "\n")), &t) != nil || t == nil {
		return nil, true, false
	}
	return t, true, true
}

func nes(v any) bool { s, ok := v.(string); return ok && strings.TrimSpace(s) != "" }

func sarr(v any) ([]string, bool) {
	a, ok := v.([]any)
	if !ok {
		return nil, false
	}
	out := make([]string, 0, len(a))
	for _, x := range a {
		if !nes(x) {
			return nil, false
		}
		out = append(out, x.(string))
	}
	return out, true
}

// Problems names the contract fields that are missing or malformed, comma separated.
func Problems(t Task) string {
	var p []string
	sp, ex := t["specId"], t["externalId"]
	if !(nes(sp) && nes(ex) && strings.HasPrefix(ex.(string), sp.(string)+":") && len(ex.(string)) > len(sp.(string))+1) {
		p = append(p, "externalId (<specId>:<taskKey>) / specId")
	}
	if _, num := t["specVersion"].(float64); !num && !nes(t["specVersion"]) {
		p = append(p, "specVersion")
	}
	if s, ok := t["specSha"].(string); !ok || !reSHA.MatchString(s) {
		p = append(p, "specSha (40 hex)")
	}
	if a, ok := sarr(t["acceptanceCriteria"]); !ok || len(a) == 0 {
		p = append(p, "acceptanceCriteria (non-empty array)")
	}
	if r := t["risk"]; r != "low" && r != "medium" && r != "high" {
		p = append(p, "risk (low|medium|high)")
	}
	if _, ok := sarr(t["dependencies"]); !ok {
		p = append(p, "dependencies (array)")
	}
	// scope is optional: the developer finds the files in the repo; when present it must be an array.
	if _, has := t["scope"]; has && t["scope"] != nil {
		if _, ok := sarr(t["scope"]); !ok {
			p = append(p, "scope (array)")
		}
	}
	if a, has := t["area"]; has && a != nil && !tasks.ValidRole(a) {
		p = append(p, "area (one of "+strings.Join(tasks.Roles, ", ")+")")
	}
	if g, has := t["group"]; has && g != nil {
		if _, ok := g.(bool); !ok {
			p = append(p, "group (boolean)")
		}
	}
	if !nes(t["parent"]) {
		p = append(p, "parent")
	}
	return strings.Join(p, ", ")
}

// Check returns the exit-4 error naming the failing fields, or nil.
func Check(t Task) error {
	if p := Problems(t); p != "" {
		return fail(4, "contract invalid, missing or malformed: %s", p)
	}
	return nil
}

// Validate is `validate-task`: the task of a description or JSON, checked.
func Validate(in string) (Task, error) {
	t, found, obj := TaskFrom(in)
	if !found {
		return nil, fail(4, "no sdkit-task block and not JSON")
	}
	if !obj {
		return nil, fail(4, "sdkit-task block is not a JSON object")
	}
	return t, Check(t)
}

func descText(iss map[string]any) string {
	f, _ := iss["fields"].(map[string]any)
	switch d := f["description"].(type) {
	case string:
		return d
	case map[string]any:
		var out []string
		var walk func(v any)
		walk = func(v any) {
			switch x := v.(type) {
			case map[string]any:
				if s, ok := x["text"].(string); ok {
					out = append(out, s)
				}
				ks := make([]string, 0, len(x))
				for k := range x {
					ks = append(ks, k)
				}
				sort.Strings(ks)
				for _, k := range ks {
					walk(x[k])
				}
			case []any:
				for _, e := range x {
					walk(e)
				}
			}
		}
		walk(d)
		return strings.Join(out, "\n")
	}
	return ""
}

func dig(m map[string]any, path ...string) any {
	var v any = m
	for _, k := range path {
		mm, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = mm[k]
	}
	return v
}

// Normalise turns an issue into the task plus key, status and statusCategory (exit 4 when the contract is not met).
func Normalise(iss map[string]any) (Task, error) {
	key, _ := iss["key"].(string)
	t, found, obj := TaskFrom(descText(iss))
	if !found {
		return nil, fail(4, "%s: no sdkit-task block in the description", key)
	}
	if !obj {
		return nil, fail(4, "%s: sdkit-task block is not a JSON object", key)
	}
	if p, ok := dig(iss, "fields", "parent", "key").(string); ok && p != "" {
		t["parent"] = p
	}
	if err := Check(t); err != nil {
		return nil, err
	}
	t["key"], t["status"], t["statusCategory"] = key, dig(iss, "fields", "status", "name"), dig(iss, "fields", "status", "statusCategory", "key")
	return t, nil
}

// Block is the task as written into a description.
func Block(t Task) any {
	m := map[string]any{}
	for _, k := range []string{"externalId", "specId", "specVersion", "specSha", "acceptanceCriteria", "risk", "dependencies", "scope", "area", "group", "parent"} {
		if (k == "scope" || k == "area" || k == "group") && t[k] == nil {
			continue
		}
		m[k] = t[k]
	}
	return m
}

// Desc is the description text of a task: note, blank line, the fenced block.
func Desc(t Task, note string) string {
	return note + "\n\n```sdkit-task\n" + JSON(Block(t), "  ") + "\n```\n"
}

// Label is the idempotency label of an external id.
func Label(ext string) string {
	return "sdkit-ext-" + strings.Map(func(r rune) rune {
		if r < 128 && (r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || strings.ContainsRune("_.:-", r)) {
			return r
		}
		return '_'
	}, ext)
}

// APIDesc is the description as a REST body value: plain text on API v2 (where "- " already makes a list), Atlassian Document Format
// on v3. In ADF a block of "- " lines becomes a bullet list and a short line ending in ":" a bold label, so the sections of a task
// description read as sections; the fenced sdkit-task block stays one code block, verbatim.
func APIDesc(text, version string) any {
	if version != "3" {
		return text
	}
	note, code, _ := strings.Cut(text, "```sdkit-")
	if code != "" {
		code = "```sdkit-" + code
	}
	para := func(l string, marks ...any) map[string]any {
		t := map[string]any{"type": "text", "text": l}
		if len(marks) > 0 {
			t["marks"] = marks
		}
		return map[string]any{"type": "paragraph", "content": []any{t}}
	}
	content := []any{}
	var items []any
	flush := func() {
		if len(items) > 0 {
			content = append(content, map[string]any{"type": "bulletList", "content": items})
			items = nil
		}
	}
	for _, l := range strings.Split(note, "\n") {
		switch {
		case strings.TrimSpace(l) == "":
			flush()
		case strings.HasPrefix(l, "- "):
			items = append(items, map[string]any{"type": "listItem", "content": []any{para(strings.TrimPrefix(l, "- "))}})
		case strings.HasSuffix(l, ":") && len([]rune(l)) <= 40 && !strings.HasPrefix(l, "Blocked"):
			flush()
			content = append(content, para(l, map[string]any{"type": "strong"}))
		default:
			flush()
			content = append(content, para(l))
		}
	}
	flush()
	if code != "" {
		content = append(content, map[string]any{"type": "codeBlock", "content": []any{map[string]any{"type": "text", "text": strings.TrimSuffix(code, "\n")}}})
	}
	return map[string]any{"version": 1, "type": "doc", "content": content}
}
