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
	want := "close.confirmed context.threshold gate.finished gate.rejected gate.started github.merged github.results_imported github.sent github.synced integrity.restored log.pruned plan.approved plan.written session.exited session.needs_you session.saved setting.changed sprint.completed sprint.started ticket.closed ticket.created ticket.status_changed wrapup.gate_finished wrapup.gate_started"
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

// Protects the v1 contract in docs/plugins.md: each kind takes exactly its documented fields, and every documented
// source is accepted (t-8854's kinds; a dropped or renamed field would break t-0b89/t-4c09 readers).
func TestKindFieldsAndSources(t *testing.T) {
	at := time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC)
	for kind, fields := range map[string][]string{
		"ticket.created":        {"ticket", "title", "type", "priority"},
		"ticket.status_changed": {"ticket", "from", "to"},
		"ticket.closed":         {"ticket"},
		"sprint.started":        {"ticket"},
		"sprint.completed":      {"ticket"},
		"gate.started":          {"ticket", "role", "attempt", "docs"},
		"gate.finished":         {"ticket", "role", "verdict", "model", "tokens", "minutes", "tier"},
		"gate.rejected":         {"ticket", "role", "reason"},
		"session.needs_you":     {"session", "ticket", "agent"},
		"session.exited":        {"session", "ticket", "agent", "reason", "models", "peak_context_pct", "tokens_new", "turns"},
		"session.saved":         {"session", "ticket", "agent", "by"},
		// t-4c09 audit kinds
		"plan.approved":           {"ticket", "tier"},
		"close.confirmed":         {"ticket", "tier"},
		"github.sent":             {"ticket", "issue"},
		"github.results_imported": {"ticket", "pr"},
		"github.merged":           {"ticket", "pr"},
		"github.synced":           {"count"},
		"setting.changed":         {"name", "old", "new"},
		"integrity.restored":      {"item", "count"},
		"context.threshold":       {"session", "ticket", "agent", "pct"},
		"log.pruned":              {"from", "to", "files", "last_seal"},
		// t-5ef8 sprint progress card
		"plan.written":         {"ticket", "tier"},
		"wrapup.gate_started":  {"ticket", "gate"},
		"wrapup.gate_finished": {"ticket", "gate", "result"},
	} {
		data := map[string]string{}
		for _, f := range fields {
			data[f] = "x"
		}
		if _, err := Line(kind, "tkt", "/p", data, at); err != nil {
			t.Errorf("%s with its documented fields: %v", kind, err)
		}
		if _, err := Line(kind, "tkt", "/p", map[string]string{"extra": "x"}, at); err == nil {
			t.Errorf("%s accepted an undocumented field", kind)
		}
	}
	for _, src := range []string{"tkt", "sprint", "board", "gate-snapshot", "subagent-log", "daemon"} {
		if _, err := Line("ticket.closed", src, "/p", nil, at); err != nil {
			t.Errorf("source %s refused: %v", src, err)
		}
	}
}

// Protects Factory > GitHub's "Last synced" (GET /api/github/intake, t-9641): Latest picks the newest valid matching line
// across day files and skips everything a writer other than Emit could leave there.
func TestLatestPicksNewestValidLine(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, "events")
	os.MkdirAll(dir, 0o700)
	ok := func(id, ts, project, count string) string {
		return `{"schema":1,"id":"` + id + `","ts":"` + ts + `","kind":"github.synced","source":"tkt","project":"` + project + `","data":{"count":"` + count + `"}}`
	}
	write := func(name string, lines ...string) {
		os.WriteFile(filepath.Join(dir, name), []byte(strings.Join(lines, "\n")+"\n"), 0o600)
	}
	write("2026-10-18.jsonl", ok("aaaaaaaaaaaaaaaa", "2026-10-18T09:00:00.000Z", "/p", "1"))
	write("2026-10-19.jsonl",
		ok("bbbbbbbbbbbbbbbb", "2026-10-19T09:00:00.000Z", "/p", "2"),
		ok("cccccccccccccccc", "2026-10-19T10:00:00.000Z", "/other", "9"), // another project
		`{"schema":1,"id":"dddddddddddddddd","ts":"2026-10-19T11:00:00.000Z","kind":"github.sent","source":"tkt","project":"/p","data":{"ticket":"t-a","issue":"1"}}`,
		`{"schema":2,"id":"eeeeeeeeeeeeeeee","ts":"2026-10-19T12:00:00.000Z","kind":"github.synced","source":"tkt","project":"/p","data":{"count":"7"}}`,
		`{"schema":1,"id":"ffffffffffffffff","ts":"2026-10-19T12:00:00.000Z","kind":"github.synced","source":"tkt","project":"/p","data":{"count":"7","title":"<script>"}}`,
		`{"schema":1,"id":"gggggggggggggggg","ts":"not a time","kind":"github.synced","source":"tkt","project":"/p","data":{"count":"7"}}`,
		`{"schema":1,"id":"hhhhhhhhhhhhhhhh","ts":"2026-10-19T12:00:00.000Z","kind":"github.synced","source":"cron","project":"/p","data":{"count":"7"}}`,
		`{"schema":1,"id":"iiiiiiiiiiiiiiii","ts":"2026-10-19T12:00:00.000Z","kind":"github.synced","source":"tkt","project":"/p","data":{"count":7}}`,
		`not json at all`,
		`{"schema":1,"id":"jjjjjjjjjjjjjjjj","ts":"2026-10-19T12:00:00.000Z","kind":"github.synced","source":"tkt","project":"/p","data":{"count":"`+strings.Repeat("9", 70000)+`"}}`,
	)
	// Newer, but not readable as a day file: a symlink and a name that is not a day.
	os.WriteFile(filepath.Join(home, "elsewhere.jsonl"), []byte(ok("kkkkkkkkkkkkkkkk", "2026-10-20T09:00:00.000Z", "/p", "5")+"\n"), 0o600)
	os.Symlink(filepath.Join(home, "elsewhere.jsonl"), filepath.Join(dir, "2026-10-20.jsonl"))
	write("2026-10-21.jsonl.gz", ok("llllllllllllllll", "2026-10-21T09:00:00.000Z", "/p", "6"))
	write("latest.jsonl", ok("mmmmmmmmmmmmmmmm", "2026-10-22T09:00:00.000Z", "/p", "8"))

	ev, found := Latest(home, "github.synced", "/p")
	if !found || ev.ID != "bbbbbbbbbbbbbbbb" || ev.Data["count"] != "2" || !ev.TS.Equal(time.Date(2026, 10, 19, 9, 0, 0, 0, time.UTC)) {
		t.Fatalf("Latest = %+v, %v; want the 10-19 09:00 line", ev, found)
	}
	if _, found := Latest(home, "github.synced", "/nowhere"); found {
		t.Error("found an event for a project with none")
	}
	if _, found := Latest(filepath.Join(home, "missing"), "github.synced", "/p"); found {
		t.Error("found an event in a missing home")
	}
}

// Protects the same route against a day file full of junk: no panic, no match, for a few hundred malformed lines.
func TestLatestSurvivesMalformedLines(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, "events")
	os.MkdirAll(dir, 0o700)
	shapes := []string{`null`, `[]`, `{}`, `{"schema":"1"}`, `{"schema":1,"data":[]}`, `{"schema":1,"data":{"count":null}}`,
		`{"schema":1,"data":{"count":{"x":1}}}`, `{"schema":NaN}`, "\x00\x01\xff\xfe", "{\"schema\":1\r\n", strings.Repeat("[", 5000),
		`{"schema":1,"id":"aaaaaaaaaaaaaaaa","ts":"2026-10-19T12:00:00Z","kind":"github.synced","source":"tkt","project":"/p","data":{"count":"1"},"data":"x"}`}
	var b strings.Builder
	for i := 0; i < 400; i++ {
		b.WriteString(shapes[i%len(shapes)])
		if i%7 == 0 {
			b.WriteString(strings.Repeat("x", i*300))
		}
		b.WriteString("\n")
	}
	os.WriteFile(filepath.Join(dir, "2026-10-19.jsonl"), []byte(b.String()), 0o600)
	if ev, found := Latest(home, "github.synced", "/p"); found {
		t.Fatalf("a malformed line matched: %+v", ev)
	}
}
