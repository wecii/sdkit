package pr

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHostAndAuth(t *testing.T) {
	for o, w := range map[string]string{"git@github.com:a/b.git": "github", "https://u:p@bitbucket.org/a/b": "bitbucket", "https://gitlab.x.io/a/b": "gitlab", "ssh://h.corp:22/a": ""} {
		if g, _ := Detect(o, "", ""); g != w {
			t.Errorf("%s: %q", o, g)
		}
	}
	var got string
	s := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) { got = r.Header.Get("Authorization") }))
	defer s.Close()
	for tok, w := range map[string]string{"ATCTT1": "Bearer ATCTT1", "pw": "Basic YUBiLmM6cHc="} {
		(&Request{Getenv: func(string) string { return s.URL }}).checkCredentials(context.Background(), "a/b", tok, "a@b.c")
		b, _ := json.Marshal(CreateBody("T", "feat", "main", "D"))
		if got != w || string(b) != `{"close_source_branch":true,"description":"D","destination":{"branch":{"name":"main"}},"source":{"branch":{"name":"feat"}},"title":"T"}` {
			t.Errorf("%s %s", got, b)
		}
	}
}

func TestRepoSlug(t *testing.T) {
	for o, w := range map[string]string{
		"https://bitbucket.org/ws/repo.git":      "ws/repo",
		"https://u@bitbucket.org/ws/repo":        "ws/repo",
		"git@bitbucket.org:ws/repo.git":          "ws/repo",
		"ssh://git@bitbucket.org/ws/repo.git":    "ws/repo",
		"ssh://git@bitbucket.org:22/ws/repo.git": "ws/repo",
		"https://github.com/ws/repo.git":         "",
	} {
		g := ""
		if m := reRepo.FindStringSubmatch(o); m != nil {
			g = m[1]
		}
		if g != w {
			t.Errorf("%s: %q", o, g)
		}
	}
}
