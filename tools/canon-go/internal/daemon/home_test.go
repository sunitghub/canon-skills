package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestMain pins CANON_HOME and HOME (t-8854): the daemon emits session events into $CANON_HOME/events, and a test must
// never write the developer's own log (t-f182: an unpinned run once left fixture events in ~/.canon/events). HOME too, so
// code that ignored CANON_HOME could not reach ~/.canon either. A test that needs its own still sets it with t.Setenv.
func TestMain(m *testing.M) {
	home, err := os.MkdirTemp("", "canon-home-")
	if err != nil {
		panic(err)
	}
	os.Setenv("CANON_HOME", home)
	os.Setenv("HOME", home)
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}

// waitEvent waits up to 3 s for an event of kind for session whose data holds every pair in want (t-8854: the daemon
// emits from its own goroutines), and fails the test if none arrives.
func waitEvent(t *testing.T, session, kind string, want map[string]string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		files, _ := filepath.Glob(filepath.Join(os.Getenv("CANON_HOME"), "events", "*.jsonl"))
		for _, f := range files {
			b, _ := os.ReadFile(f)
			for _, line := range strings.Split(string(b), "\n") {
				var e struct {
					Kind, Source, Project string
					Data                  map[string]string
				}
				if json.Unmarshal([]byte(line), &e) != nil || e.Kind != kind || e.Data["session"] != session || e.Source != "daemon" {
					continue
				}
				ok := e.Project != ""
				for k, v := range want {
					ok = ok && e.Data[k] == v
				}
				if ok {
					return
				}
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("no %s event for session %s with %v", kind, session, want)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
