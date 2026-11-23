package daemon

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"canon/internal/events"
)

// t-3e06 helpers: the activity log lines pre-gate-check.sh and sprint start write, for one ticket and project.
func logSprintEvent(t *testing.T, kind, project, ticket string) {
	t.Helper()
	if err := events.Emit(events.Home(), kind, "sprint", project, map[string]string{"ticket": ticket}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * time.Millisecond) // one line after another, in order
}

func todaysEvents(t *testing.T) string {
	t.Helper()
	b, _ := os.ReadFile(filepath.Join(os.Getenv("CANON_HOME"), "events", time.Now().UTC().Format("2006-01-02")+".jsonl"))
	return string(b)
}

func waitTyped(se *session, want string) string { return waitTypedFor(se, want, 3*time.Second) }

// typedAfter is what the session shows after a short wait, for a line that must NOT be typed.
func typedAfter(se *session) string { return waitTypedFor(se, "\x00never", 600*time.Millisecond) }

func waitTypedFor(se *session, want string, d time.Duration) string {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		se.mu.Lock()
		out := string(se.buf)
		se.mu.Unlock()
		if strings.Contains(out, want) {
			return out
		}
		time.Sleep(50 * time.Millisecond)
	}
	se.mu.Lock()
	defer se.mu.Unlock()
	return string(se.buf)
}

func atPrompt(s *server, se *session) {
	se.setStatus("running")
	se.setStatus("awaiting-input")
	s.switchStage(se)
}

// t-3e06 (user, 2026-11-22: the t-c3gi close ran on the Build model): once the close began (pre-gate-check's close.started after the
// ticket's newest sprint.started), a session on the Build model types `/model <close>` once and a line that continues the close at its
// next turn end, records build.switch stage=close with the model, and never implement.started; before close.started it types nothing.
// Protects every live Cockpit session at the close (the fake agent echoes what is typed).
func TestSwitchToCloseAtCloseStarted(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	restQuietWait(t, 200*time.Millisecond, 2*time.Second)
	s, se, _ := buildSwitchSession(t, "Tier: normal | Build model: sonnet | Close model: opus")
	logSprintEvent(t, "sprint.started", se.projectRoot, "t-ab12")
	atPrompt(s, se) // approved: plan -> build
	if out := waitTyped(se, "continue the build"); !strings.Contains(out, "continue the build") || se.stage != "build" {
		t.Fatalf("no build switch first (stage %q): %q", se.stage, out)
	}
	implements := strings.Count(todaysEvents(t), `"kind":"implement.started"`)
	// build, no close.started yet: nothing typed
	atPrompt(s, se)
	if out := typedAfter(se); strings.Contains(out, "/model opus") || se.stage != "build" {
		t.Fatalf("typed the Close model before close.started (stage %q): %q", se.stage, out)
	}
	logSprintEvent(t, "close.started", se.projectRoot, "t-ab12")
	// the close began but the agent still works: nothing typed
	se.setStatus("running")
	s.switchStage(se)
	if out := typedAfter(se); strings.Contains(out, "/model opus") {
		t.Fatalf("typed /model while the agent worked: %q", out)
	}
	atPrompt(s, se)
	out := waitTyped(se, "continue the close")
	if strings.Count(out, "/model opus") != 2 || !strings.Contains(out, "Close model on: continue the close (t-ab12) on opus.") { // echo + cat
		t.Fatalf("typed = %q, want one /model opus and the close's continue line", out)
	}
	if strings.Index(out, "/model opus") > strings.Index(out, "continue the close") {
		t.Errorf("the continue line came before /model: %q", out)
	}
	if se.stage != "close" || se.model != "opus" {
		t.Errorf("session after the close switch = stage %q model %q", se.stage, se.model)
	}
	// never twice
	atPrompt(s, se)
	if n := strings.Count(typedAfter(se), "/model opus"); n != 2 {
		t.Errorf("/model opus shows %d times, want 2 (typed once)", n)
	}
	ev := todaysEvents(t)
	if !hasEventLine(ev, `"kind":"build.switch"`, `"stage":"close"`, `"model":"opus"`, `"outcome":"started"`, `"line":"continue"`) {
		t.Errorf("no build.switch stage=close outcome=started model=opus: %s", ev)
	}
	if n := strings.Count(ev, `"kind":"implement.started"`); n != implements {
		t.Errorf("the close switch recorded implement.started (%d, was %d)", n, implements)
	}
}

// t-3e06: each case where the close switch must type nothing at a turn end on the Build model. Protects a live session from a /model
// it was never told about (the CLI prints the end-your-turn line only when it records the first close.started).
func TestCloseSwitchTypesNothing(t *testing.T) {
	cases := []struct {
		name, tier string
		events     []string // in order; "" = none
	}{
		{"no close.started", "Tier: normal | Build model: sonnet | Close model: opus", []string{"sprint.started"}},
		{"a close.started from an earlier sprint", "Tier: normal | Build model: sonnet | Close model: opus", []string{"sprint.started", "close.started", "sprint.started"}},
		{"another ticket's close.started", "Tier: normal | Build model: sonnet | Close model: opus", []string{"sprint.started", "other"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("CANON_HOME", t.TempDir())
			restQuietWait(t, 200*time.Millisecond, 2*time.Second)
			s, se, _ := buildSwitchSession(t, tc.tier)
			for _, k := range tc.events {
				if k == "other" {
					logSprintEvent(t, "close.started", se.projectRoot, "t-cd34")
					continue
				}
				logSprintEvent(t, k, se.projectRoot, "t-ab12")
			}
			atPrompt(s, se) // plan -> build
			waitTyped(se, "continue the build")
			atPrompt(s, se)
			if out := typedAfter(se); strings.Contains(out, "/model opus") || strings.Contains(out, "continue the close") || se.stage != "build" {
				t.Fatalf("typed for the close (stage %q): %q", se.stage, out)
			}
		})
	}
	// no Close pick anywhere (the ticket names none, Admin's close is empty): nothing typed, the stage still moves to close
	t.Run("no Close pick", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("CANON_HOME", home)
		restQuietWait(t, 200*time.Millisecond, 2*time.Second)
		if err := os.MkdirAll(filepath.Join(home, "cockpit"), 0o755); err != nil {
			t.Fatal(err)
		}
		reg := `{"defaults": {"plan": {}, "build": {}, "close": {}, "speccheck": {}, "reviewer": {}, "evaluator": {}, "light": {}}, "models": {"anthropic": [], "openai": []}}`
		if err := os.WriteFile(filepath.Join(home, "cockpit", "model-tiers.json"), []byte(reg), 0o644); err != nil {
			t.Fatal(err)
		}
		s, se, _ := buildSwitchSession(t, "Tier: normal | Build model: sonnet")
		logSprintEvent(t, "sprint.started", se.projectRoot, "t-ab12")
		atPrompt(s, se)
		waitTyped(se, "continue the build")
		logSprintEvent(t, "close.started", se.projectRoot, "t-ab12")
		atPrompt(s, se)
		if out := typedAfter(se); strings.Contains(out, "continue the close") || strings.Count(out, "/model") != 2 {
			t.Fatalf("typed for a close with no model: %q", out)
		}
		if se.stage != "close" {
			t.Errorf("stage = %q, want close (nothing to type, the stage still moves)", se.stage)
		}
	})
}

// t-3e06 (criterion 3b): a Close pick equal to the session's model types no /model, but the continue line still goes (pre-gate-check
// told the agent to end its turn), as the Build switch does. Protects the close from a session left waiting at its prompt.
func TestCloseSwitchSameModelTypesContinueOnly(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	restQuietWait(t, 200*time.Millisecond, 2*time.Second)
	s, se, _ := buildSwitchSession(t, "Tier: normal | Build model: sonnet | Close model: sonnet")
	logSprintEvent(t, "sprint.started", se.projectRoot, "t-ab12")
	atPrompt(s, se)
	waitTyped(se, "continue the build")
	logSprintEvent(t, "close.started", se.projectRoot, "t-ab12")
	atPrompt(s, se)
	out := waitTyped(se, "continue the close")
	if !strings.Contains(out, "Close model on: continue the close (t-ab12) on sonnet.") || strings.Count(out, "/model sonnet") != 2 {
		t.Fatalf("typed = %q, want the continue line and no second /model", out)
	}
	if se.stage != "close" {
		t.Errorf("stage = %q, want close", se.stage)
	}
}

// t-3e06 (criterion 4): a session started (Start / Continue) on a ticket whose close began starts on the Close model, stage close, and
// records build.switch stage=close line=spawn (the card's Close row), never implement.started; approved but not closing starts on Build.
// Protects a close resumed in a new session.
func TestSpawnOnCloseStartsOnCloseModel(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	bin, argvFile, _ := fakeSprint(t)
	root := t.TempDir()
	dir := filepath.Join(root, ".tickets", "t-ab12")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	plan := "# Plan\n\n## Sign-off\nTier: normal | Build model: sonnet | Close model: opus\n\n- [x] Plan approved\nApproved: sha256:abc 2026-11-14T00:00:00Z\n\n## Approach\n1. do it\n"
	if err := os.WriteFile(filepath.Join(dir, "plan.md"), []byte(plan), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newServer(config{token: bootTok, sprintBin: bin, projectRoot: root, stateDir: t.TempDir()})
	ts := httptest.NewServer(s.handler())
	t.Cleanup(ts.Close)
	t.Cleanup(func() { killAllSessions(s) })
	project := s.cfg.projectRoot
	logSprintEvent(t, "sprint.started", project, "t-ab12")
	if m, stage, _ := s.sessionModel(project, "t-ab12", "claude"); stage != "build" || m != "sonnet" {
		t.Fatalf("approved, not closing: %s on %q, want build on sonnet", stage, m)
	}
	logSprintEvent(t, "close.started", project, "t-ab12")
	resp := startSession(t, ts.URL, "t-ab12", bootTok)
	resp.Body.Close()
	waitFile(t, argvFile, 3*time.Second)
	var se *session
	s.mu.Lock()
	for _, x := range s.sessions {
		se = x
	}
	s.mu.Unlock()
	if se == nil || se.stage != "close" || se.model != "opus" {
		t.Fatalf("session = %+v, want stage close on opus", se)
	}
	ev := todaysEvents(t)
	if !hasEventLine(ev, `"kind":"build.switch"`, `"line":"spawn"`, `"stage":"close"`, `"model":"opus"`, `"outcome":"started"`) {
		t.Errorf("no build.switch stage=close line=spawn model=opus: %s", ev)
	}
	if strings.Contains(ev, `"kind":"implement.started"`) {
		t.Errorf("a spawn on Close recorded implement.started: %s", ev)
	}
}

// t-3e06: a ticket whose sprint runs in a bound worktree writes its close.started with the worktree as the project (pre-gate-check uses
// the ticket folder's grandparent): the main checkout's session counts it. Protects the close switch for worktree sprints.
func TestCloseBeganInBoundWorktree(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	root := t.TempDir()
	if r, err := filepath.EvalSymlinks(root); err == nil {
		root = r
	}
	wt := gitWorktreeFixture(t, root)
	if err := os.MkdirAll(filepath.Join(root, ".tickets", "t-ab12"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".tickets", "t-ab12", ".cockpit-cwd"), []byte(wt+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(wt, ".tickets", "t-ab12"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(wt, ".tickets", "t-ab12", "ticket.md"), []byte("---\nid: t-ab12\nstatus: in_progress\n---\n# t\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := newServer(config{token: bootTok, projectRoot: root, stateDir: t.TempDir()})
	if s.boundWorktreeIn(root, "t-ab12") == "" {
		t.Fatal("fixture: the ticket is not bound to the worktree")
	}
	logSprintEvent(t, "sprint.started", root, "t-ab12")
	if s.closeBeganIn(root, "t-ab12") {
		t.Fatal("close began with no close.started")
	}
	logSprintEvent(t, "close.started", filepath.Join(t.TempDir(), "elsewhere"), "t-ab12") // another project's ticket of the same id
	if s.closeBeganIn(root, "t-ab12") {
		t.Fatal("another project's close.started counted")
	}
	logSprintEvent(t, "close.started", wt, "t-ab12")
	if !s.closeBeganIn(root, "t-ab12") {
		t.Fatal("the worktree's close.started did not count")
	}
}

// hasEventLine: one line of the log holds every part (a field matched anywhere in the day's log proves nothing about one event).
func hasEventLine(log string, parts ...string) bool {
	for _, l := range strings.Split(log, "\n") {
		all := true
		for _, p := range parts {
			all = all && strings.Contains(l, p)
		}
		if all {
			return true
		}
	}
	return false
}
