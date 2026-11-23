package daemon

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// Lines in the shape Copilot 1.0.111 writes them (recorded from real events.jsonl files; content trimmed).
const (
	evUser      = `{"type":"user.message","data":{"content":"sprint approve t-ab12"}}`
	evStart     = `{"type":"assistant.turn_start","data":{"turnId":"0"}}`
	evMsgTools  = `{"type":"assistant.message","data":{"content":"","toolRequests":[{"name":"bash"}]}}`
	evMsgNone   = `{"type":"assistant.message","data":{"content":"Done.","toolRequests":[]}}`
	evMsgAbsent = `{"type":"assistant.message","data":{"content":"Done."}}`
	evEnd       = `{"type":"assistant.turn_end","data":{"turnId":"0"}}`
	evSubStart  = `{"type":"subagent.started","agentId":"a1","data":{}}`
	evSubDone   = `{"type":"subagent.completed","agentId":"a1","data":{}}`
	evSubFail   = `{"type":"subagent.failed","agentId":"a1","data":{}}`
	evSubTurn   = `{"type":"assistant.turn_start","agentId":"a1","data":{}}`
	evSubMsg    = `{"type":"assistant.message","agentId":"a1","data":{"toolRequests":[]}}`
	evSubEnd    = `{"type":"assistant.turn_end","agentId":"a1","data":{}}`
	evModel     = `{"type":"session.model_change","data":{"previousModel":"claude-sonnet-5.5","newModel":"claude-haiku-5.5"}}`
)

func appendLog(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, l := range lines {
		if _, err := f.WriteString(l); err != nil {
			t.Fatal(err)
		}
	}
}

func nl(lines ...string) []string {
	out := make([]string, len(lines))
	for i, l := range lines {
		out[i] = l + "\n"
	}
	return out
}

func readAll(t *testing.T, tr *copilotTurn, path string) []string {
	t.Helper()
	sts, err := tr.read(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return sts
}

// t-c723 (the Build switch every Copilot Cockpit session takes): which events.jsonl lines end a response. Protects the turn-end
// signal switchStage runs on for copilot.
func TestCopilotTurnStatuses(t *testing.T) {
	cases := []struct {
		name  string
		lines []string
		want  []string
	}{
		{"no-tools turn end ([])", nl(evUser, evStart, evMsgNone, evEnd), []string{"running", "awaiting-input"}},
		{"no-tools turn end (toolRequests absent)", nl(evStart, evMsgAbsent, evEnd), []string{"running", "awaiting-input"}},
		{"a turn that asked for tools", nl(evStart, evMsgTools, evEnd), []string{"running"}},
		{"tools, then a final no-tools turn", nl(evStart, evMsgTools, evEnd, evStart, evMsgNone, evEnd), []string{"running", "running", "awaiting-input"}},
		{"a subagent's own turn end", nl(evStart, evMsgTools, evSubStart, evSubTurn, evSubMsg, evSubEnd), []string{"running"}},
		{"main turn ends while a subagent runs", nl(evStart, evMsgNone, evSubStart, evEnd), []string{"running"}},
		{"the subagent finishes after", nl(evStart, evMsgNone, evSubStart, evEnd, evSubDone), []string{"running", "awaiting-input"}},
		{"a turn aborted after asking for tools", nl(evStart, evMsgTools, evEnd, evStart, evEnd), []string{"running", "running", "awaiting-input"}},
		{"a subagent that failed counts as finished", nl(evStart, evMsgNone, evSubStart, evEnd, evSubFail), []string{"running", "awaiting-input"}},
		{"a subagent finishing mid-turn ends nothing", nl(evStart, evMsgTools, evSubStart, evSubDone), []string{"running"}},
		{"a stray subagent.completed never goes below zero", nl(evSubDone, evStart, evMsgNone, evEnd), []string{"running", "awaiting-input"}},
		{"user.message and model_change change nothing", nl(evUser, evModel), nil},
		{"a malformed line is skipped", nl(evStart, `{"type":"assistant.message","data":{"toolRequests":[`, evMsgNone, evEnd), []string{"running", "awaiting-input"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "events.jsonl")
			appendLog(t, path, c.lines...)
			if got := readAll(t, &copilotTurn{}, path); !reflect.DeepEqual(got, c.want) {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

// t-c723: a line Copilot is still writing is left for the next read; a line over copilotLineMax is skipped whole, even when it
// spans reads, and the line after it still counts.
func TestCopilotTurnPartialAndLongLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	tr := &copilotTurn{}
	appendLog(t, path, evStart+"\n", evMsgNone+"\n", evEnd[:20])
	if got := readAll(t, tr, path); !reflect.DeepEqual(got, []string{"running"}) {
		t.Fatalf("partial line: got %q", got)
	}
	appendLog(t, path, evEnd[20:]+"\n")
	if got := readAll(t, tr, path); !reflect.DeepEqual(got, []string{"awaiting-input"}) {
		t.Fatalf("completed line: got %q", got)
	}

	old := copilotLineMax
	copilotLineMax = 200
	t.Cleanup(func() { copilotLineMax = old })
	long := `{"type":"assistant.turn_start","data":{"pad":"` + strings.Repeat("x", 150<<10) + `"}}`
	path2 := filepath.Join(t.TempDir(), "events.jsonl")
	tr2 := &copilotTurn{}
	appendLog(t, path2, long[:100<<10]) // an over-long line still being written
	if got := readAll(t, tr2, path2); got != nil {
		t.Fatalf("over-long partial line: got %q", got)
	}
	appendLog(t, path2, long[100<<10:]+"\n", evMsgNone+"\n", evEnd+"\n")
	if got := readAll(t, tr2, path2); !reflect.DeepEqual(got, []string{"awaiting-input"}) {
		t.Fatalf("after an over-long line: got %q, want only awaiting-input (the long turn_start skipped)", got)
	}
}

// t-c723: a log that is not a regular file is never read, and a resumed session starts at the size the log had at spawn.
func TestCopilotTurnRefusesLinksAndResumesAtOffset(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real.jsonl")
	appendLog(t, real, nl(evStart, evMsgNone, evEnd)...)
	link := filepath.Join(dir, "events.jsonl")
	if err := os.Symlink(real, link); err != nil {
		t.Skipf("no symlinks here: %v", err)
	}
	if sts, err := (&copilotTurn{}).read(link); err != errNotRegular || sts != nil {
		t.Fatalf("symlinked log: got %q, %v; want errNotRegular", sts, err)
	}
	if got := copilotLogSize(link); got != 0 {
		t.Fatalf("copilotLogSize of a link: %d", got)
	}

	tr := &copilotTurn{off: copilotLogSize(real)}
	if got := readAll(t, tr, real); got != nil {
		t.Fatalf("history before the resume was replayed: %q", got)
	}
	appendLog(t, real, nl(evStart, evMsgNone, evEnd)...)
	if got := readAll(t, tr, real); !reflect.DeepEqual(got, []string{"running", "awaiting-input"}) {
		t.Fatalf("after the resume: got %q", got)
	}
}

// t-c723 (security review): the session id comes from a file in the ticket's folder; only canon's UUID shape names a log path.
func TestCopilotEventsPathNeedsCanonsID(t *testing.T) {
	home := t.TempDir()
	if got := copilotEventsPath(home, "11111111-2222-4333-8444-555555555555"); got != filepath.Join(home, "session-state", "11111111-2222-4333-8444-555555555555", "events.jsonl") {
		t.Fatalf("a canon id: %q", got)
	}
	for _, sid := range []string{"", "../../etc", "../11111111-2222-4333-8444-555555555555", "11111111-2222-4333-8444-555555555555x", "11111111-2222-4333-8444-555555555555/../x", "ABCDEF01-2222-4333-8444-555555555555"} {
		if got := copilotEventsPath(home, sid); got != "" {
			t.Fatalf("%q named %q", sid, got)
		}
	}
}

// t-c723: a log replaced or cut shorter than what was read starts over from its first byte.
func TestCopilotTurnRestartsOnTruncatedLog(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	tr := &copilotTurn{}
	appendLog(t, path, nl(evUser, evStart, evMsgTools, evEnd, evStart, evMsgTools, evEnd)...)
	readAll(t, tr, path)
	if err := os.WriteFile(path, []byte(evStart+"\n"+evMsgNone+"\n"+evEnd+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := readAll(t, tr, path); !reflect.DeepEqual(got, []string{"running", "awaiting-input"}) {
		t.Fatalf("after the log was cut: got %q", got)
	}
}

// t-c723: the watcher ends with its session, so no poll outlives a Copilot session.
func TestCopilotWatcherEndsWithSession(t *testing.T) {
	copilotPollFast(t)
	se := &session{done: make(chan struct{})}
	close(se.done)
	ended := make(chan struct{})
	go func() { (&server{}).watchCopilotTurns(se, filepath.Join(t.TempDir(), "events.jsonl"), 0); close(ended) }()
	select {
	case <-ended:
	case <-time.After(2 * time.Second):
		t.Fatal("the watcher kept polling after its session ended")
	}
}

func copilotPollFast(t *testing.T) {
	old := copilotTurnPoll
	copilotTurnPoll = 20 * time.Millisecond
	t.Cleanup(func() { copilotTurnPoll = old })
}

func waitStatus(t *testing.T, se *session, want string, within time.Duration) {
	t.Helper()
	deadline := time.Now().Add(within)
	for time.Now().Before(deadline) {
		se.mu.Lock()
		st := se.status
		se.mu.Unlock()
		if st == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("status never became %q", want)
}

// t-c723: a resumed Copilot session's earlier turn ends (before the spawn) never start the switch; a new one after it does.
// Protects the at-spawn offset in spawn().
func TestCopilotResumeIgnoresOldTurnEnds(t *testing.T) {
	copilotPollFast(t)
	bin, argvFile, _ := fakeSprint(t)
	root, _ := boundTicketFixture(t, "open", "in_progress")
	home := t.TempDir()
	t.Setenv("COPILOT_HOME", home)
	t.Setenv("COCKPIT_COPILOT_BIN", bin)
	sid := "11111111-2222-4333-8444-555555555555"
	if err := os.WriteFile(filepath.Join(root, ".tickets", "t-ab12", ".cockpit-copilot-session-id"), []byte(sid+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	log := copilotEventsPath(home, sid)
	appendLog(t, log, nl(evUser, evStart, evMsgNone, evEnd)...)
	s := newServer(config{token: bootTok, projectRoot: root, stateDir: t.TempDir(), resumeGrace: 50 * time.Millisecond})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })
	startSessionWithAgentBody(t, ts.URL, "t-ab12", "copilot", bootTok)
	waitFile(t, argvFile, 3*time.Second)
	var se *session
	s.mu.Lock()
	for _, x := range s.sessions {
		se = x
	}
	s.mu.Unlock()
	if se.copilotLog != log {
		t.Fatalf("session reads %q, want %q", se.copilotLog, log)
	}
	time.Sleep(10 * copilotTurnPoll)
	se.mu.Lock()
	st := se.status
	se.mu.Unlock()
	if st != "running" {
		t.Fatalf("a turn end from before the resume set %q", st)
	}
	appendLog(t, log, nl(evStart, evMsgNone, evEnd)...)
	waitStatus(t, se, "awaiting-input", 3*time.Second)
}
