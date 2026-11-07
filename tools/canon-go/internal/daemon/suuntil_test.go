package daemon

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"canon/internal/events"
)

// Protects /sessions' su_until (t-a4f8), the field the Agents list counts down from: a Terminal whose latest granted has no later
// expired and whose end is ahead gets it; an ended, crashed (past its limit) or non-Terminal session does not; two Terminals do not
// mix; and a later line in the log (su ended) is seen on the next call, not served from the cache.
func TestSessionsSuUntil(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	now := time.Now().UTC()
	emit := func(kind, sid, minutes string, at time.Time) {
		t.Helper()
		t.Setenv("CANON_EVENTS_CLOCK", at.Format(time.RFC3339Nano))
		d := map[string]string{"session": sid, "ticket": "s-ab12"}
		if kind == "terminal.su_granted" {
			d["minutes"] = minutes
		} else {
			d["how"] = "exited"
		}
		if err := events.Emit(home, kind, "daemon", "", d); err != nil {
			t.Fatal(err)
		}
	}
	emit("terminal.su_granted", "on", "10", now.Add(-2*time.Minute))    // 8 min left
	emit("terminal.su_granted", "ended", "10", now.Add(-5*time.Minute)) // granted, then expired
	emit("terminal.su_expired", "ended", "", now.Add(-4*time.Minute))
	emit("terminal.su_granted", "crashed", "10", now.Add(-20*time.Minute)) // no expired line, limit long past
	emit("terminal.su_granted", "again", "10", now.Add(-9*time.Minute))    // expired, then granted again
	emit("terminal.su_expired", "again", "", now.Add(-8*time.Minute))
	emit("terminal.su_granted", "again", "10", now.Add(-1*time.Minute))
	emit("terminal.su_granted", "future", "10", now.Add(48*time.Hour))  // a forged line stamped far ahead
	emit("terminal.su_granted", "agent", "10", now.Add(-1*time.Minute)) // a granted line for a session that is not a Terminal
	root := t.TempDir()
	s := newServer(config{token: bootTok, projectRoot: root, stateDir: t.TempDir()})
	for _, c := range []struct{ sid, agent string }{{"on", "term"}, {"ended", "term"}, {"crashed", "term"}, {"again", "term"}, {"agent", "claude"}, {"quiet", "term"}, {"future", "term"}} {
		s.sessions[c.sid] = &session{sid: c.sid, projectRoot: root, cwd: root, agent: c.agent, status: "running", started: now,
			subs: map[chan frame]struct{}{}, lastActivity: time.Now(), statusSince: time.Now()}
	}
	read := func() map[string]string {
		rec := httptest.NewRecorder()
		s.handleSessions(rec, httptest.NewRequest("GET", "/sessions", nil))
		var rows []struct {
			Session string `json:"session"`
			SuUntil string `json:"su_until"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &rows); err != nil {
			t.Fatalf("decode: %v", err)
		}
		m := map[string]string{}
		for _, r := range rows {
			m[r.Session] = r.SuUntil
		}
		return m
	}
	got := read()
	for sid, want := range map[string]time.Time{"on": now.Add(8 * time.Minute), "again": now.Add(9 * time.Minute)} {
		at, err := time.Parse(time.RFC3339, got[sid])
		if err != nil || at.Sub(want).Abs() > 2*time.Second {
			t.Errorf("%s: su_until %q, want about %s", sid, got[sid], want.Format(time.RFC3339))
		}
	}
	for _, sid := range []string{"ended", "crashed", "agent", "quiet", "future"} {
		if got[sid] != "" {
			t.Errorf("%s: su_until %q, want none", sid, got[sid])
		}
	}
	emit("terminal.su_expired", "on", "", now) // su ended: the log grew, so the next answer drops it
	if got := read(); got["on"] != "" || got["again"] == "" {
		t.Errorf("after su_expired for 'on': %v", got)
	}
}
