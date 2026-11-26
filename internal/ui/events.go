// Package ui is the local panel behind `sdkit ui` (docs/design-ui.md): it drives one headless agent session per run, turns
// the session's output into events a browser can show, and relays the agent's questions to the person.
package ui

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
)

// Event kinds the browser knows.
const (
	KindStep    = "step"    // a skill step banner: Skill, Step, Total, Name, State
	KindText    = "text"    // what the agent says to the person
	KindTool    = "tool"    // what the agent is doing (shown under "details")
	KindOutput  = "output"  // what a tool printed back, clipped; only the extension's full conversation shows it
	KindThought = "thought" // the agent's own reasoning, clipped; same
	KindResult  = "result"  // the session ended: Text is the final message, Failed says how
	KindStatus  = "status"  // the panel's own notes (started, stopped, errors)
)

// Event is one line of a run, in the order it happened.
type Event struct {
	Seq    int    `json:"seq"`
	Kind   string `json:"kind"`
	Text   string `json:"text,omitempty"`
	Skill  string `json:"skill,omitempty"`
	Step   int    `json:"step,omitempty"`
	Total  int    `json:"total,omitempty"`
	Name   string `json:"name,omitempty"`
	State  string `json:"state,omitempty"`
	Failed bool   `json:"failed,omitempty"`
}

// banner is the line every skill prints per step: "[sdkit] generate-specs - Step 3/10: Draft - started".
// Models drop the name or the colon now and then ("Step 1/10 done"), so both are optional; the stepper must not lose a step over punctuation.
var banner = regexp.MustCompile(`\[sdkit\]\s+(\S+)\s+-\s+Step\s+(\d+)/(\d+):?\s*(?:(.+?)\s+-\s+)?(started|done)\b`)

// ParseLine turns one stream-json line of a Claude Code session into the events it carries. An unknown or malformed line
// gives none: the panel must never fail because the host added a field.
func ParseLine(line []byte) []Event {
	var m struct {
		Type    string `json:"type"`
		Subtype string `json:"subtype"`
		IsError bool   `json:"is_error"`
		Result  string `json:"result"`
		Message struct {
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(line, &m) != nil {
		return nil
	}
	switch m.Type {
	case "assistant":
		var blocks []struct {
			Type     string          `json:"type"`
			Text     string          `json:"text"`
			Name     string          `json:"name"`
			Input    json.RawMessage `json:"input"`
			Thinking string          `json:"thinking"`
		}
		if json.Unmarshal(m.Message.Content, &blocks) != nil {
			return nil
		}
		var out []Event
		for _, b := range blocks {
			switch b.Type {
			case "text":
				out = append(out, textEvents(b.Text)...)
			case "thinking":
				if t := strings.TrimSpace(b.Thinking); t != "" {
					out = append(out, Event{Kind: KindThought, Text: clip(t, maxDetail)})
				}
			case "tool_use":
				out = append(out, Event{Kind: KindTool, Name: b.Name, Text: toolSummary(b.Name, b.Input)})
			}
		}
		return out
	case "user":
		// a skill may print its banner with `echo`, so it arrives as the output of a tool, not as the agent's own text
		var blocks []struct {
			Type    string          `json:"type"`
			Content json.RawMessage `json:"content"`
		}
		if json.Unmarshal(m.Message.Content, &blocks) != nil {
			return nil
		}
		var out []Event
		for _, b := range blocks {
			if b.Type == "tool_result" {
				for _, e := range textEvents(resultText(b.Content)) {
					if e.Kind == KindStep {
						out = append(out, e)
					} else if e.Kind == KindText {
						out = append(out, Event{Kind: KindOutput, Text: clip(e.Text, maxDetail)})
					}
				}
			}
		}
		return out
	case "result":
		// the closing message was already shown as text; only a failure needs its own words
		failed := m.IsError || strings.HasPrefix(m.Subtype, "error")
		e := Event{Kind: KindResult, Failed: failed}
		if failed {
			e.Text = m.Result
		}
		return []Event{e}
	}
	return nil
}

// maxDetail bounds one output or thought event: one tool result can be a whole file, and the event log keeps every event.
const maxDetail = 4000

// resultText is the text of a tool result, which the host sends as a string or as a list of text blocks.
func resultText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []struct {
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &parts) != nil {
		return ""
	}
	var b strings.Builder
	for _, p := range parts {
		b.WriteString(p.Text + "\n")
	}
	return b.String()
}

// stepNames are the plain-words names of a skill's steps, in the person's language. The banners themselves stay English because
// other tools read them; a name the skill adds later falls back to the banner's own.
var stepNames = map[string][]string{
	"generate-specs": {"Girdiyi kontrol et", "Eksikleri sor", "Taslağı yaz", "Taslağı gözden geçir", "Bulguları çöz", "Spec'i oluştur", "İş gereksinimlerini yaz", "Çıktıyı gözden geçir ve yayınla", "Sonucu göster", "Tasarım (gerekirse)"},
}

// stepName returns the plain name of step n (1-based) of skill, or "" when there is none.
func stepName(skill string, n int) string {
	if names := stepNames[skill]; n >= 1 && n <= len(names) {
		return names[n-1]
	}
	return ""
}

// textEvents splits agent text into banner events and plain text: the banners drive the stepper, the rest is read by the person.
func textEvents(s string) []Event {
	var out []Event
	var rest []string
	for _, l := range strings.Split(s, "\n") {
		if m := banner.FindStringSubmatch(l); m != nil {
			step, _ := strconv.Atoi(m[2])
			total, _ := strconv.Atoi(m[3])
			name := m[4]
			if n := stepName(m[1], step); n != "" {
				name = n
			}
			out = append(out, Event{Kind: KindStep, Skill: m[1], Step: step, Total: total, Name: name, State: m[5]})
			continue
		}
		rest = append(rest, l)
	}
	if t := strings.TrimSpace(strings.Join(rest, "\n")); t != "" {
		out = append([]Event{{Kind: KindText, Text: t}}, out...)
	}
	return out
}

// toolSummary is the one-line form of a tool call: the command for Bash, the path for file tools.
func toolSummary(name string, input json.RawMessage) string {
	var in struct {
		Command     string `json:"command"`
		FilePath    string `json:"file_path"`
		Path        string `json:"path"`
		Pattern     string `json:"pattern"`
		Description string `json:"description"` // a subagent's task: what it is for
		Skill       string `json:"skill"`
	}
	json.Unmarshal(input, &in)
	// a subagent or a skill has no file or command; its description is what a person can follow
	for _, v := range []string{in.Description, in.Skill, in.Command, in.FilePath, in.Path, in.Pattern} {
		if v != "" {
			if len(v) > 200 {
				v = v[:200] + "..."
			}
			return v
		}
	}
	return ""
}
