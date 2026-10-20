package events

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// Protects every emitter (tkt, sprint, the board): the v1 line shape and its limits.
func TestLineShapeAndLimits(t *testing.T) {
	at := time.Date(2026, 10, 20, 7, 8, 9, 123e6, time.UTC)
	b, err := Line("ticket.created", "tkt", "/p", map[string]string{"ticket": "t-abcd", "title": strings.Repeat("é", 300), "type": "task", "priority": "1"}, at)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 7 || got["schema"] != float64(1) || got["kind"] != "ticket.created" || got["source"] != "tkt" || got["project"] != "/p" || got["ts"] != "2026-10-20T07:08:09.123Z" {
		t.Fatalf("shape: %v", got)
	}
	if id, _ := got["id"].(string); len(id) != 16 {
		t.Errorf("id %q", id)
	}
	if title := got["data"].(map[string]any)["title"].(string); len([]rune(title)) != 200 {
		t.Errorf("title not cut to 200 runes: %d", len([]rune(title)))
	}
	for name, c := range map[string]struct {
		kind, source string
		data         map[string]string
	}{
		"unknown kind":   {"ticket.deleted", "tkt", nil},
		"unknown source": {"ticket.closed", "cron", map[string]string{"ticket": "t-a"}},
		"unknown field":  {"ticket.closed", "tkt", map[string]string{"ticket": "t-a", "body": "x"}},
	} {
		if _, err := Line(c.kind, c.source, "/p", c.data, at); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// a 60 KB value never lands whole
	b, _ = Line("ticket.created", "board", "/p", map[string]string{"ticket": "t-a", "title": strings.Repeat("x", 60000)}, at)
	if len(b) > 2048 {
		t.Errorf("60 KB title gave a %d-byte line", len(b))
	}
}

func readAll(t *testing.T, dir string) []map[string]any {
	t.Helper()
	files, _ := filepath.Glob(filepath.Join(dir, "*.jsonl"))
	var out []map[string]any
	for _, f := range files { // name order = day order
		fh, err := os.Open(f)
		if err != nil {
			t.Fatal(err)
		}
		sc := bufio.NewScanner(fh)
		sc.Buffer(make([]byte, 64*1024), 1<<20)
		for sc.Scan() {
			var m map[string]any
			if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
				t.Fatalf("%s: torn line %q", f, sc.Text())
			}
			out = append(out, m)
		}
		fh.Close()
	}
	return out
}

// Protects the dated files: events land in their UTC day, a reader in name-then-line order sees each once, and the
// first write of a day deletes files past retention (only day-shaped names).
func TestDayFilesAndRetention(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, "events")
	os.MkdirAll(dir, 0o700)
	// 2026-07-22 is exactly 90 days before 10-20: kept; look-alike names are never touched, however old they look
	for _, keep := range []string{"2026-07-22.jsonl", "2026-07-23.jsonl", "notes.txt", "emit-errors.log", "x2001-01-01.jsonl", "2001-01-01.jsonl.bak", "2001-13-45.jsonl"} {
		os.WriteFile(filepath.Join(dir, keep), []byte(""), 0o600)
	}
	os.WriteFile(filepath.Join(dir, "2026-07-21.jsonl"), []byte(""), 0o600) // 91 days: deleted
	for _, ts := range []string{"2026-10-19T23:59:59.900Z", "2026-10-20T00:00:00.100Z", "2026-10-20T00:00:01Z"} {
		t.Setenv("CANON_EVENTS_CLOCK", ts)
		if err := Emit(home, "ticket.closed", "tkt", "/p", map[string]string{"ticket": "t-" + ts[17:19]}); err != nil {
			t.Fatal(err)
		}
	}
	for name, want := range map[string]bool{"2026-07-21.jsonl": false, "2026-07-22.jsonl": true, "2026-07-23.jsonl": true, "notes.txt": true,
		"x2001-01-01.jsonl": true, "2001-01-01.jsonl.bak": true, "2001-13-45.jsonl": true, "2026-10-19.jsonl": true, "2026-10-20.jsonl": true} {
		if _, err := os.Stat(filepath.Join(dir, name)); (err == nil) != want {
			t.Errorf("%s present=%v, want %v", name, err == nil, want)
		}
	}
	all := readAll(t, dir)
	if len(all) != 3 || all[0]["ts"] != "2026-10-19T23:59:59.900Z" || all[2]["ts"] != "2026-10-20T00:00:01.000Z" {
		t.Errorf("events across midnight: %v", all)
	}
}

// Protects concurrent writers: whole lines, none lost.
func TestConcurrentEmit(t *testing.T) {
	home := t.TempDir()
	var wg sync.WaitGroup
	for w := 0; w < 16; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				Emit(home, "ticket.created", "board", strings.Repeat("/p", 400), map[string]string{"ticket": "t-x", "title": strings.Repeat("t", 200)})
			}
		}()
	}
	wg.Wait()
	if n := len(readAll(t, filepath.Join(home, "events"))); n != 3200 {
		t.Errorf("%d events, want 3200", n)
	}
}

// Protects observer-only: an unwritable folder fails quietly (an error to ignore), creates nothing, panics nothing.
func TestEmitFailsQuietly(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes anywhere")
	}
	home := t.TempDir()
	os.Chmod(home, 0o500)
	defer os.Chmod(home, 0o700)
	if err := Emit(home, "ticket.closed", "tkt", "/p", map[string]string{"ticket": "t-a"}); err == nil {
		t.Error("an unwritable home reported success")
	}
	if err := Emit("", "ticket.closed", "tkt", "/p", nil); err == nil {
		t.Error("no home reported success")
	}
}

// Protects where events go when CANON_HOME is unset, and that every documented kind is in the table (docs/plugins.md).
func TestHomeAndKinds(t *testing.T) {
	t.Setenv("CANON_HOME", "")
	t.Setenv("HOME", "/somewhere")
	if got := Home(); got != filepath.Join("/somewhere", ".canon") {
		t.Errorf("Home() = %q", got)
	}
	t.Setenv("CANON_HOME", "/pinned")
	if got := Home(); got != "/pinned" {
		t.Errorf("Home() with CANON_HOME = %q", got)
	}
	want := "gate.finished gate.rejected gate.started session.exited session.needs_you session.saved sprint.completed sprint.started ticket.closed ticket.created ticket.status_changed"
	if got := strings.Join(Kinds(), " "); got != want {
		t.Errorf("kinds %q, want %q", got, want)
	}
}

// Protects emit-errors.log from growing without bound when events keep failing.
func TestErrorsLogCap(t *testing.T) {
	home := t.TempDir()
	os.MkdirAll(filepath.Join(home, "events"), 0o700)
	log := filepath.Join(home, "events", "emit-errors.log")
	Emit(home, "ticket.nope", "tkt", "/p", nil)
	if b, _ := os.ReadFile(log); !strings.Contains(string(b), `unknown event kind "ticket.nope"`) {
		t.Fatalf("failure not noted: %q", b)
	}
	os.WriteFile(log, make([]byte, errorsLogMax+1), 0o600)
	Emit(home, "ticket.nope", "tkt", "/p", nil)
	if st, _ := os.Stat(log); st.Size() != errorsLogMax+1 {
		t.Errorf("a full log grew to %d", st.Size())
	}
}
