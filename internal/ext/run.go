// Package ext is the side of `sdkit ext` that an editor extension drives: no server and no page, only lines of JSON on the
// standard streams (docs/design-vscode.md). It reuses the panel's session driver, ask bridge and event log from internal/ui.
package ext

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/wecii/sdkit/internal/state"
	"github.com/wecii/sdkit/internal/ui"
)

// Options is what a run needs; cmd fills it, this package reads no environment.
type Options struct {
	Root, Action, ID string
	Note             string   // what the analyst wants changed, typed before an update; empty when they edited the files or have nothing to add
	Fresh            bool     // start a new host session even when an earlier one could be continued
	Rules            string   // put before the task: the person is not technical and has no terminal
	Env              []string // for the session (PATH with this binary first)
	Command          string   // host executable, `claude` by default
	Tools            []string
	SessionExists    func(id string) bool
	Secret           string // key of the ask bridge
}

// Out is one line written to the extension.
//
//	{"type":"event","event":{...}}                 a step, a text, a tool, a status (ui.Event)
//	{"type":"question","id":1,"questions":[...]}   the agent waits for the person; answer it with an "answer" line
//	{"type":"end","failed":false}                  the run is over; always the last line
type Out struct {
	Type      string          `json:"type"`
	Event     *ui.Event       `json:"event,omitempty"`
	ID        int             `json:"id,omitempty"`
	Spec      string          `json:"spec,omitempty"`
	Questions json.RawMessage `json:"questions,omitempty"`
	Failed    bool            `json:"failed,omitempty"`
	Error     string          `json:"error,omitempty"`
}

// In is one line read from the extension: {"type":"answer","id":1,"answers":{...}} or {"type":"stop"}. End of input also stops the run.
type In struct {
	Type    string          `json:"type"`
	ID      int             `json:"id"`
	Answers json.RawMessage `json:"answers"`
}

type writer struct {
	mu  sync.Mutex
	enc *json.Encoder
}

func (w *writer) put(o Out) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.enc.Encode(o)
}

// Run drives one run of action for the spec id until the session ends or the extension stops it.
func Run(ctx context.Context, o Options, in io.Reader, out io.Writer) error {
	w := &writer{enc: json.NewEncoder(out)}
	err := run(ctx, o, in, w)
	end := Out{Type: "end", Failed: err != nil}
	if err != nil {
		end.Error = err.Error()
	}
	w.put(end)
	return err
}

func run(ctx context.Context, o Options, in io.Reader, w *writer) error {
	if _, err := ui.Task(o.Root, o.Action, o.ID, ui.TaskInput{}); err != nil {
		return err
	}
	root := ui.RootFor(o.Root, o.ID)
	if ui.TouchesSpecFiles(o.Action) {
		var err error
		if root, _, err = ui.Provision(o.Root, o.ID); err != nil {
			return err
		}
	}
	ti := ui.TaskInput{Note: o.Note}
	if b, ok := strings.CutPrefix(ui.Branch(root), "spec/"+o.ID+"--"); ok {
		ti.Slug = b
	}
	task, err := ui.Task(root, o.Action, o.ID, ti)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	lg := ui.NewLog()
	broker := ui.NewBroker(func(q ui.Question) {
		w.put(Out{Type: "question", ID: q.ID, Spec: q.Spec, Questions: q.Questions})
	})

	// the bridge `sdkit ui ask` talks to from inside the session: this process, on loopback, with the run's own key
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/ask", func(rw http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("X-Sdkit-Key") != o.Secret {
			http.Error(rw, "forbidden", http.StatusForbidden)
			return
		}
		body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		a, err := broker.Ask(r.Context(), body, o.ID)
		if err != nil {
			if r.Context().Err() == nil {
				lg.Add(ui.Event{Kind: ui.KindStatus, Name: "ask-refused", Text: err.Error()})
			}
			http.Error(rw, err.Error(), http.StatusBadRequest)
			return
		}
		rw.Header().Set("Content-Type", "application/json")
		rw.Write(a)
	})
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	defer srv.Close()

	askEnv := []string{"SDKIT_UI_URL=http://" + ln.Addr().String(), "SDKIT_UI_KEY=" + o.Secret, "SDKIT_UI_SPEC=" + o.ID,
		// a question waits for a person inside the host's Bash tool, which ends a command after two minutes unless told otherwise
		"BASH_DEFAULT_TIMEOUT_MS=7200000", "BASH_MAX_TIMEOUT_MS=14400000"}
	if state.ValidSlug(o.ID) {
		askEnv = append(askEnv, "SDKIT_TASK="+o.ID) // every token of the session is filed under the spec
	}
	prompt := o.Rules + task
	resume := ""
	if !o.Fresh {
		resume = ui.ResumeFor(o.Root, o.ID, root, o.SessionExists)[o.Action].Session
	}
	if resume != "" {
		prompt += "\n\nThis is the earlier session, resumed: carry on from where it stopped (check `sdkit spec next " + o.ID + "` first) and do not start the steps over. If your last message put a question to the person in plain text, ask it again now with sdkit ui ask: they only see the form."
	}
	rs := ui.RunSpec{Resume: resume, Dir: root, Prompt: prompt, Command: o.Command, Tools: o.Tools,
		Env: append(append(append([]string{}, o.Env...), askEnv...), ui.GitAuthEnv(o.Root)...)}
	var session string
	rs.OnSession = func(id string) {
		session = id
		ui.RecordRun(o.Root, ui.RunRecord{Session: id, Spec: o.ID, Action: o.Action, Dir: root, Start: stamp()})
	}

	// the extension's answers and its stop
	go func() {
		sc := bufio.NewScanner(in)
		sc.Buffer(make([]byte, 1<<20), 4<<20)
		for sc.Scan() {
			var m In
			if json.Unmarshal(sc.Bytes(), &m) != nil {
				continue
			}
			switch m.Type {
			case "answer":
				if err := broker.Answer(m.ID, m.Answers); err != nil {
					lg.Add(ui.Event{Kind: ui.KindStatus, Name: "answer-refused", Text: err.Error()})
				}
			case "stop":
				cancel()
				return
			}
		}
		cancel() // the extension is gone: nobody can answer
	}()

	// events go out in order; the log drops for a slow reader, so a gap is filled from the log itself
	finished := make(chan struct{})
	forwarded := make(chan struct{})
	go func() {
		defer close(forwarded)
		last := 0
		emit := func(es []ui.Event) {
			for _, e := range es {
				if e.Seq > last {
					last = e.Seq
					e := e
					w.put(Out{Type: "event", Event: &e})
				}
			}
		}
		_, live, stop := lg.Since(0)
		defer stop()
		for {
			select {
			case e := <-live:
				if e.Seq != last+1 {
					past, _, c := lg.Since(last)
					c()
					emit(past)
				}
				emit([]ui.Event{e})
			case <-finished:
				past, _, c := lg.Since(last)
				c()
				emit(past)
				return
			}
		}
	}()

	runErr := ui.Run(ctx, rs, lg)
	close(finished)
	<-forwarded
	if session != "" {
		outcome := "done"
		if ctx.Err() != nil {
			outcome = "stopped"
		} else if runErr != nil {
			outcome = "failed"
		}
		ui.RecordRun(o.Root, ui.RunRecord{Session: session, Spec: o.ID, Action: o.Action, Dir: root, End: stamp(), Outcome: outcome})
	}
	if runErr != nil && ctx.Err() == nil {
		return fmt.Errorf("the host session failed: %w", runErr)
	}
	if ctx.Err() != nil && !errors.Is(ctx.Err(), context.Canceled) {
		return ctx.Err()
	}
	return nil
}

func stamp() string { return time.Now().UTC().Format("2006-01-02T15:04:05Z") }
