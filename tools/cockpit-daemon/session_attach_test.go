package main

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"
)

// TestSameTicketSecondStartAttaches (t-c6fa): a second /session/start for a
// ticket that already has a live session must attach to it -- same session
// and token, no second spawn -- rather than racing a second PTY against the
// first for the same underlying claude conversation.
func TestSameTicketSecondStartAttaches(t *testing.T) {
	bin, _, _ := fakeSprint(t) // ends in `cat`: stays live until killed
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: t.TempDir(), stateDir: t.TempDir()})
	seedTicketDir(t, s.cfg.projectRoot, "t-ab12")
	ts := newTestServerFrom(t, s)
	base := ts.URL

	resp1 := startSession(t, base, "t-ab12", bootTok)
	var out1 struct{ Session, Token string }
	if err := json.NewDecoder(resp1.Body).Decode(&out1); err != nil {
		t.Fatal(err)
	}
	resp1.Body.Close()
	if out1.Session == "" || out1.Token == "" {
		t.Fatalf("first start: missing session/token, got %+v", out1)
	}

	s.mu.Lock()
	countAfterFirst := len(s.sessions)
	s.mu.Unlock()
	if countAfterFirst != 1 {
		t.Fatalf("want 1 live session after first start, got %d", countAfterFirst)
	}

	// Second /session/start for the SAME ticket, first session still live.
	resp2 := startSession(t, base, "t-ab12", bootTok)
	var out2 struct{ Session, Token string }
	if err := json.NewDecoder(resp2.Body).Decode(&out2); err != nil {
		t.Fatal(err)
	}
	resp2.Body.Close()

	if out2.Session != out1.Session || out2.Token != out1.Token {
		t.Fatalf("second start: want attach to existing session %q/%q, got %q/%q",
			out1.Session, out1.Token, out2.Session, out2.Token)
	}

	s.mu.Lock()
	countAfterSecond := len(s.sessions)
	s.mu.Unlock()
	if countAfterSecond != 1 {
		t.Fatalf("want still 1 live session after attach (no second spawn), got %d", countAfterSecond)
	}
}

// TestSameTicketAfterExitSpawnsFresh (t-c6fa): once the live session for a
// ticket has exited, the next /session/start must spawn fresh, not attach to
// the dead one -- the normal, unchanged path.
func TestSameTicketAfterExitSpawnsFresh(t *testing.T) {
	bin := fakeSprintQuickExit(t)
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: t.TempDir(), stateDir: t.TempDir()})
	seedTicketDir(t, s.cfg.projectRoot, "t-ab12")
	ts := newTestServerFrom(t, s)
	base := ts.URL

	resp1 := startSession(t, base, "t-ab12", bootTok)
	var out1 struct{ Session, Token string }
	json.NewDecoder(resp1.Body).Decode(&out1)
	resp1.Body.Close()

	waitForSessionExited(t, base, out1.Session, out1.Token, 3*time.Second)

	resp2 := startSession(t, base, "t-ab12", bootTok)
	var out2 struct{ Session, Token string }
	json.NewDecoder(resp2.Body).Decode(&out2)
	resp2.Body.Close()

	if out2.Session == out1.Session {
		t.Fatalf("want a fresh session after the prior one exited, got the same id %q", out1.Session)
	}
}

// TestLiveSessionForTicketScopedByProject (t-c6fa, unit-level): the same
// ticket ID in two different projects must never attach to each other's
// session -- exercised directly against liveSessionForTicket rather than
// through two full daemon instances, since the function is pure map
// filtering and the interesting behavior is the scoping logic itself.
func TestLiveSessionForTicketScopedByProject(t *testing.T) {
	s := &server{sessions: map[string]*session{}}
	a := &session{sid: "sid-a", ticket: "t-ab12", projectRoot: "/proj/a"}
	b := &session{sid: "sid-b", ticket: "t-ab12", projectRoot: "/proj/b"}
	dead := &session{sid: "sid-dead", ticket: "t-ab12", projectRoot: "/proj/a", exited: true}
	s.sessions[a.sid] = a
	s.sessions[b.sid] = b
	s.sessions[dead.sid] = dead

	if got := s.liveSessionForTicket("/proj/a", "t-ab12"); got != a {
		t.Fatalf("project a: want session %q, got %+v", a.sid, got)
	}
	if got := s.liveSessionForTicket("/proj/b", "t-ab12"); got != b {
		t.Fatalf("project b: want session %q, got %+v", b.sid, got)
	}
	if got := s.liveSessionForTicket("/proj/c", "t-ab12"); got != nil {
		t.Fatalf("unrelated project: want nil, got %+v", got)
	}
	if got := s.liveSessionForTicket("/proj/a", "t-zzzz"); got != nil {
		t.Fatalf("unrelated ticket: want nil, got %+v", got)
	}

	// Only the exited entry left for /proj/a's t-ab12 -- confirm exited is
	// skipped by removing the live one and re-checking.
	s.mu.Lock()
	delete(s.sessions, a.sid)
	s.mu.Unlock()
	if got := s.liveSessionForTicket("/proj/a", "t-ab12"); got != nil {
		t.Fatalf("only an exited session remains: want nil, got %+v", got)
	}
}

// newTestServerFrom wires an already-configured *server the same way
// newTestServer does for its own internally-built one -- used here because
// these tests need cfg.projectRoot set to their own seeded ticket dir before
// the server exists, which newTestServer's fixed root doesn't allow.
func newTestServerFrom(t *testing.T, s *server) *httptest.Server {
	t.Helper()
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })
	return ts
}
