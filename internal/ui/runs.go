package ui

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/wecii/sdkit/internal/state"
)

// Several specs advance at once: each run is a session in the tree of its own spec (see tree.go), one per spec, at most MaxRuns in all.

const defaultMaxRuns = 3

type runState struct {
	cancel context.CancelFunc
	action string
	root   string // the tree the run works in
}

func (s *Server) maxRuns() int {
	if s.cfg.MaxRuns > 0 {
		return s.cfg.MaxRuns
	}
	return defaultMaxRuns
}

// logFor is the event log of a spec's latest run; it exists before the run does, so a page can wait on it.
func (s *Server) logFor(id string) *Log {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.logs[id] == nil {
		s.logs[id] = NewLog()
	}
	return s.logs[id]
}

// events streams one spec's run log as server-sent events; ?from=<seq> resumes after a reconnect.
func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	from, _ := strconv.Atoi(r.URL.Query().Get("from"))
	past, live, cancel := s.logFor(r.URL.Query().Get("id")).Since(from)
	defer cancel()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	send := func(e Event) {
		b, _ := json.Marshal(e)
		fmt.Fprintf(w, "id: %d\ndata: %s\n\n", e.Seq, b)
		fl.Flush()
	}
	for _, e := range past {
		send(e)
	}
	last := from + len(past)
	for {
		select {
		case e := <-live:
			if e.Seq > last {
				last = e.Seq
				send(e)
			}
		case <-r.Context().Done():
			return
		}
	}
}

// runsList is what is going on now, for the badges: each running spec, its action and how many questions wait for the person.
func (s *Server) runsList(w http.ResponseWriter, r *http.Request) {
	asks, loose := map[string]int{}, 0
	for _, q := range s.broker.Pending() {
		if q.Spec == "" {
			loose++
		}
		asks[q.Spec]++
	}
	type item struct {
		ID     string `json:"id"`
		Action string `json:"action"`
		Asks   int    `json:"asks"`
	}
	out := struct {
		Runs  []item `json:"runs"`
		Max   int    `json:"max"`
		Loose int    `json:"loose"` // questions whose spec is not known: shown on every spec page
	}{Runs: []item{}, Max: s.maxRuns(), Loose: loose}
	s.mu.Lock()
	for id, rs := range s.runs {
		out.Runs = append(out.Runs, item{id, rs.action, asks[id]})
	}
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, out)
}

// touchesSpecFiles are the actions that write the spec's files, so they need the spec's own tree.
func touchesSpecFiles(action string) bool {
	return action == "generate-specs" || action == "update-specs" || action == "update-manual" || action == "merge-specs" ||
		action == "refine-specs" || action == "generate-design"
}

// run starts a session for {"action","id",...}: one per spec, in that spec's tree.
func (s *Server) run(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		id := r.URL.Query().Get("id")
		s.mu.Lock()
		st := struct {
			Running bool   `json:"running"`
			Action  string `json:"action"`
			ID      string `json:"id"`
		}{s.runs[id] != nil, s.last[id], id}
		s.mu.Unlock()
		writeJSON(w, http.StatusOK, st)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var in struct {
		Action string `json:"action"`
		ID     string `json:"id"`
		Parent string `json:"parent"`
		SHA    string `json:"sha"`
		Fresh  bool   `json:"fresh"` // start a new session even when an earlier one could be continued
	}
	if json.NewDecoder(io.LimitReader(r.Body, 1<<16)).Decode(&in) != nil {
		http.Error(w, `expected {"action":"generate-specs","id":"..."}`, http.StatusBadRequest)
		return
	}
	// the page names an action and an id; whether the pair is acceptable is settled before anything is made
	if _, err := Task(s.cfg.Dir, in.Action, in.ID, TaskInput{Parent: in.Parent, SHA: in.SHA}); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if in.Action == "generate-tasks" {
		// the page lists and checks these too, but a run is only started on what the server has verified itself
		if err := s.checkTaskInput(r.Context(), in.ID, in.Parent, in.SHA); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}
	// the slot is taken before the tree is made (that can take a few seconds), so two clicks cannot both get through
	s.mu.Lock()
	switch {
	case s.runs[in.ID] != nil:
		s.mu.Unlock()
		http.Error(w, "Bu spec için zaten bir çalışma sürüyor", http.StatusConflict)
		return
	case len(s.runs) >= s.maxRuns():
		s.mu.Unlock()
		http.Error(w, fmt.Sprintf("En fazla %d çalışma aynı anda yürüyebilir; birinin bitmesini bekleyin ya da birini durdurun", s.maxRuns()), http.StatusConflict)
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	rs := &runState{cancel: cancel, action: in.Action}
	s.runs[in.ID] = rs
	s.mu.Unlock()
	release := func() {
		s.mu.Lock()
		delete(s.runs, in.ID)
		s.mu.Unlock()
		cancel()
	}

	root := s.rootFor(in.ID)
	if touchesSpecFiles(in.Action) {
		var err error
		if root, _, err = Provision(s.cfg.Dir, in.ID); err != nil {
			release()
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
	if root == s.cfg.Dir { // the main tree has one branch checked out: only one spec can work in it
		s.mu.Lock()
		for other, o := range s.runs {
			if other != in.ID && o.root == s.cfg.Dir {
				s.mu.Unlock()
				release()
				http.Error(w, "Ana çalışma alanı şu an "+other+" ile meşgul. O spec bitince ya da durdurulunca bu spec devam edebilir", http.StatusConflict)
				return
			}
		}
		rs.root = root
		s.mu.Unlock()
	} else {
		s.mu.Lock()
		rs.root = root
		s.mu.Unlock()
	}

	ti := TaskInput{Parent: in.Parent, SHA: in.SHA}
	if b, ok := strings.CutPrefix(Branch(root), "spec/"+in.ID+"--"); ok {
		ti.Slug = b // the change this branch carries; what the page says about it is never read
	}
	task, err := Task(root, in.Action, in.ID, ti)
	if err != nil {
		release()
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	lg := NewLog()
	s.mu.Lock()
	s.logs[in.ID], s.last[in.ID] = lg, in.Action
	s.mu.Unlock()

	// the session reaches the ask bridge through these variables; `sdkit ui ask` reads them, and says which spec it asks for
	askEnv := []string{"SDKIT_UI_URL=http://" + s.addr, "SDKIT_UI_KEY=" + s.secret, "SDKIT_UI_SPEC=" + in.ID}
	if state.ValidSlug(in.ID) {
		// every token the session and its subagents spend is filed under the spec's id, so `sdkit report task <id>` is the spec's report
		askEnv = append(askEnv, "SDKIT_TASK="+in.ID)
	}
	// `sdkit ui ask` waits for a person inside the host's Bash tool, which ends a command after two minutes unless told otherwise; the
	// question would then vanish from the page while the agent carries on. Hours, not minutes.
	askEnv = append(askEnv, "BASH_DEFAULT_TIMEOUT_MS=7200000", "BASH_MAX_TIMEOUT_MS=14400000")
	prompt := task
	if s.cfg.Prompt != nil {
		prompt = s.cfg.Prompt(task, askEnv)
	}
	resume := ""
	if !in.Fresh {
		resume = ResumeFor(s.cfg.Dir, in.ID, root, s.cfg.SessionExists)[in.Action].Session
	}
	if resume != "" {
		prompt += "\n\nThis is the earlier session, resumed: carry on from where it stopped (check `sdkit spec next " + in.ID + "` first) and do not start the steps over. If your last message put a question to the person in plain text, ask it again now with sdkit ui ask: they only see the form."
	}
	spec := RunSpec{Resume: resume, Dir: root, Prompt: prompt, Env: append(append(append([]string{}, s.cfg.Env...), askEnv...), GitAuthEnv(s.cfg.Dir)...), Command: s.cfg.Command, Tools: s.cfg.Tools}
	// the run ledger is how a report finds its spec: the host's session id, written down with what the run was for and where
	var session string
	spec.OnSession = func(id string) {
		session = id
		RecordRun(s.cfg.Dir, RunRecord{Session: id, Spec: in.ID, Action: in.Action, Dir: root, Start: nowStamp()})
	}
	go func() {
		err := Run(ctx, spec, lg)
		if session != "" {
			out := "done"
			if ctx.Err() != nil {
				out = "stopped"
			} else if err != nil {
				out = "failed"
			}
			RecordRun(s.cfg.Dir, RunRecord{Session: session, Spec: in.ID, Action: in.Action, Dir: root, End: nowStamp(), Outcome: out})
		}
		release()
	}()
	w.WriteHeader(http.StatusAccepted)
}

// stop ends one spec's run ({"id"}) and its whole process tree; the others go on.
func (s *Server) stop(w http.ResponseWriter, r *http.Request) {
	var in struct{ ID string }
	json.NewDecoder(io.LimitReader(r.Body, 1<<12)).Decode(&in)
	s.mu.Lock()
	if rs := s.runs[in.ID]; rs != nil {
		rs.cancel()
	}
	s.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

// questions lists what waits for the person, of one spec (?id) or of all.
func (s *Server) questions(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	out := []Question{}
	for _, q := range s.broker.Pending() {
		if id == "" || q.Spec == id || q.Spec == "" {
			out = append(out, q)
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// ask is what `sdkit ui ask` calls from inside the session: it blocks until the person answers, then returns the answers.
func (s *Server) ask(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if r.Method != http.MethodPost || err != nil {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	spec := r.Header.Get("X-Sdkit-Spec")
	if !ValidID(spec) && !reKitID.MatchString(spec) {
		spec = ""
	}
	if spec == "" {
		// an older `sdkit` (or none of ours first on PATH) does not say which spec asks. With one run going it is that one; with
		// several the question is shown on every spec page rather than on none
		s.mu.Lock()
		if len(s.runs) == 1 {
			for id := range s.runs {
				spec = id
			}
		}
		s.mu.Unlock()
	}
	a, err := s.broker.Ask(r.Context(), body, spec)
	if err != nil {
		// the agent is told, and so is the person: a question that never reached the form must not look like one that was asked
		if r.Context().Err() == nil {
			s.logFor(spec).Add(Event{Kind: KindStatus, Name: "ask-refused", Text: clip(err.Error(), 300)})
		} else {
			s.logFor(spec).Add(Event{Kind: KindStatus, Name: "ask-expired", Text: "ajanın soruyu bekleyen komutu kapandı"})
		}
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(a)
}

// specCleanup removes a spec's worktree ({"id"}) once its work is done; git refuses when it holds unsaved work.
func (s *Server) specCleanup(w http.ResponseWriter, r *http.Request) {
	var in struct{ ID string }
	if r.Method != http.MethodPost || json.NewDecoder(io.LimitReader(r.Body, 1<<12)).Decode(&in) != nil || !(ValidID(in.ID) || reKitID.MatchString(in.ID)) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if s.specRunning(in.ID) {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "Bu spec için bir çalışma sürerken çalışma alanı silinemez"})
		return
	}
	if err := RemoveWorktree(s.cfg.Dir, in.ID); err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": err.Error()})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// info is the footer of the sidebar: whose panel this is and which repo and branch it is on.
func (s *Server) info(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"repo":   filepath.Base(s.cfg.Dir),
		"branch": Branch(s.cfg.Dir),
		"user":   ReadConnection(s.cfg.Dir).JiraUser,
	})
}

// TouchesSpecFiles reports whether the action writes the spec's files, so its run needs the spec's own tree.
func TouchesSpecFiles(action string) bool { return touchesSpecFiles(action) }
