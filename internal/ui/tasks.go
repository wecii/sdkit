package ui

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/wecii/sdkit/internal/project"
)

var (
	reParent = regexp.MustCompile(`^[A-Z][A-Z0-9_]{1,19}-[0-9]{1,9}$`)
	reSHA    = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

// ValidParent reports whether key looks like a Jira issue key; whether it exists is Jira's to say (CheckParent).
func ValidParent(key string) bool { return reParent.MatchString(key) }

// Parent is the answer to "does this Jira parent exist".
type Parent struct {
	OK      bool   `json:"ok"`
	Key     string `json:"key,omitempty"`
	Summary string `json:"summary,omitempty"`
	Type    string `json:"type,omitempty"`
	Status  string `json:"status,omitempty"`
	Message string `json:"message,omitempty"`
}

// CheckParent asks Jira for the issue, so a mistyped or unreachable parent is found before an agent run is spent on it.
// generate-tasks never creates a parent, so a key Jira does not know is a stop.
func CheckParent(ctx context.Context, c *http.Client, base, user, token, key string) Parent {
	if !ValidParent(key) {
		return Parent{Message: "Anahtar, TFF-123 gibi harfler, tire ve rakamdan oluşmalı"}
	}
	if base == "" || user == "" || token == "" {
		return Parent{Message: "Önce Configuration sayfasından Jira bilgilerini kaydedin"}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(base, "/")+"/rest/api/2/issue/"+url.PathEscape(key)+"?fields=summary,issuetype,status", nil)
	if err != nil {
		return Parent{Message: "Jira adresi geçersiz"}
	}
	req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(user+":"+token)))
	resp, err := c.Do(req)
	if err != nil {
		return Parent{Message: "Jira'ya ulaşılamadı; internet bağlantısını kontrol edin"}
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		var v struct {
			Fields struct {
				Summary   string `json:"summary"`
				IssueType struct {
					Name string `json:"name"`
				} `json:"issuetype"`
				Status struct {
					Name string `json:"name"`
				} `json:"status"`
			} `json:"fields"`
		}
		json.NewDecoder(resp.Body).Decode(&v)
		return Parent{OK: true, Key: key, Summary: clip(v.Fields.Summary, 200), Type: v.Fields.IssueType.Name, Status: v.Fields.Status.Name}
	case http.StatusUnauthorized, http.StatusForbidden:
		return Parent{Message: "Jira bu işe erişime izin vermedi; Configuration sayfasındaki bilgileri ve işin izinlerini kontrol edin"}
	case http.StatusNotFound:
		return Parent{Message: key + " Jira'da bulunamadı. Task'lar var olan bir işin altına açılır; anahtarı kontrol edin"}
	}
	return Parent{Message: fmt.Sprintf("Jira beklenmedik bir cevap verdi (HTTP %d)", resp.StatusCode)}
}

// TaskInput is what the page may say about a generate-tasks run: ids and a SHA, never wording.
type TaskInput struct {
	Parent string
	SHA    string
	Note   string // what the analyst wrote they want changed (update-specs, refine-specs); theirs, so the agent asks nothing more about it
	Slug   string // an open change on the current branch; filled by the server from git, never by the page
}

// generateTasksTask is the whole instruction of a tasks run. The files live in one directory so the panel can read the outcome
// back from them instead of from what the agent says.
func generateTasksTask(id string, in TaskInput, kit string) (string, error) {
	switch {
	case !ValidParent(in.Parent):
		return "", errors.New("geçersiz Jira anahtarı")
	case !reSHA.MatchString(in.SHA):
		return "", errors.New("geçersiz commit")
	}
	dir := filepath.ToSlash(filepath.Join(kit, "work", "tasks", id))
	return fmt.Sprintf("Use the generate-tasks skill for the spec id %q with Jira parent %s and SHA %s. Keep tasks.json, map.json, results.jsonl and report.md in %s (create it); `sdkit tasks report` writes report.md there. The plan gate is the person's: ask for it with `sdkit ui ask` and a \"plan\" object, and write no Jira task before they confirm.", id, in.Parent, in.SHA, dir), nil
}

// PlanTask is one row of the plan the person confirms: a group task, with the acceptance criteria it covers.
type PlanTask struct {
	Ref       string   `json:"ref"`
	Title     string   `json:"title"`
	Risk      string   `json:"risk,omitempty"`
	ACs       []string `json:"acs,omitempty"`
	DependsOn []string `json:"dependsOn,omitempty"`
	Roles     []string `json:"roles,omitempty"` // the role subtasks under it
}

// Plan is what the plan gate shows: the plan-check summary and the AC-to-task table. The agent fills it next to the question.
type Plan struct {
	Summary string     `json:"summary,omitempty"`
	Tasks   []PlanTask `json:"tasks"`
}

// normalizePlan bounds a plan the way a finding is bounded; a plan with no tasks is just the question.
func normalizePlan(p *Plan) *Plan {
	if p == nil {
		return nil
	}
	p.Summary = clip(p.Summary, 2000)
	if len(p.Tasks) > 60 {
		p.Tasks = p.Tasks[:60]
	}
	rows := p.Tasks[:0]
	for _, t := range p.Tasks {
		t.Ref, t.Title, t.Risk = clip(t.Ref, 40), clip(t.Title, 300), clip(t.Risk, 40)
		if t.Ref == "" && t.Title == "" {
			continue
		}
		t.ACs, t.DependsOn, t.Roles = clipList(t.ACs, 40, 30), clipList(t.DependsOn, 40, 20), clipList(t.Roles, 40, 12)
		rows = append(rows, t)
	}
	if len(rows) == 0 {
		return nil
	}
	p.Tasks = rows
	return p
}

func clipList(in []string, n, max int) []string {
	if len(in) > max {
		in = in[:max]
	}
	for i := range in {
		in[i] = clip(in[i], n)
	}
	return in
}

// Created is one Jira task of the finished run.
type Created struct {
	Key    string `json:"key"`
	URL    string `json:"url,omitempty"`
	Action string `json:"action"`
}

// TaskResult is the outcome of a tasks run, read from the files the run left (not from what the agent said): the Jira tasks and
// the report. Done is false when any of them is missing or the report says it is not a success.
type TaskResult struct {
	Tasks  []Created `json:"tasks"`
	Report string    `json:"report,omitempty"`
	Done   bool      `json:"done"`
}

// ReadTaskResult reads <project-dir>/work/tasks/<id>/results.jsonl and report.md. jiraBase turns keys into links.
func ReadTaskResult(root, id, jiraBase string) TaskResult {
	var r TaskResult
	if !ValidID(id) && !reKitID.MatchString(id) {
		return r
	}
	_, pj, _ := project.Load(root)
	dir := filepath.Join(pj.Dir(), "work", "tasks", id)
	if f, err := os.Open(filepath.Join(dir, "results.jsonl")); err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<16), 1<<20)
		for sc.Scan() {
			var c struct {
				Key    string `json:"key"`
				Action string `json:"action"`
			}
			if json.Unmarshal(sc.Bytes(), &c) != nil || !reParent.MatchString(c.Key) {
				continue
			}
			item := Created{Key: c.Key, Action: c.Action}
			if strings.HasPrefix(jiraBase, "http") {
				item.URL = strings.TrimRight(jiraBase, "/") + "/browse/" + c.Key
			}
			r.Tasks = append(r.Tasks, item)
		}
	}
	if b, err := os.ReadFile(filepath.Join(dir, "report.md")); err == nil {
		r.Report = clip(string(b), 20000)
		r.Done = len(r.Tasks) > 0 && !strings.Contains(r.Report, "NOT CREATED") && !strings.Contains(r.Report, "NOT a success")
	}
	if r.Tasks == nil {
		r.Tasks = []Created{}
	}
	return r
}
