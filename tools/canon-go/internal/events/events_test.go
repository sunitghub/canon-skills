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
	for _, keep := range []string{"2026-07-23.jsonl", "notes.txt", "emit-errors.log"} { // 89 days before 10-20: kept
		os.WriteFile(filepath.Join(dir, keep), []byte(""), 0o600)
	}
	os.WriteFile(filepath.Join(dir, "2026-07-21.jsonl"), []byte(""), 0o600) // 91 days: deleted
	for _, ts := range []string{"2026-10-19T23:59:59.900Z", "2026-10-20T00:00:00.100Z", "2026-10-20T00:00:01Z"} {
		t.Setenv("CANON_EVENTS_CLOCK", ts)
		if err := Emit(home, "ticket.closed", "tkt", "/p", map[string]string{"ticket": "t-" + ts[17:19]}); err != nil {
			t.Fatal(err)
		}
	}
	for name, want := range map[string]bool{"2026-07-21.jsonl": false, "2026-07-23.jsonl": true, "notes.txt": true, "2026-10-19.jsonl": true, "2026-10-20.jsonl": true} {
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
