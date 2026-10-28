package board

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"canon/internal/events"
)

const logClick = "http://127.0.0.1:8423"

// logRig is a CANON_HOME with a few day files, and calls through the real handlers.
type logRig struct {
	t         *testing.T
	home, dir string
}

func newLogRig(t *testing.T, days map[string]string) *logRig {
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	t.Setenv("CANON_EVENTS_CLOCK", "") // the real clock: the rig's days are dated relative to it
	dir := filepath.Join(home, "events")
	os.MkdirAll(dir, 0o700)
	for name, body := range days {
		os.WriteFile(filepath.Join(dir, name), []byte(body), 0o600)
	}
	return &logRig{t, home, dir}
}

func (g *logRig) day(ago int) string {
	return time.Now().UTC().AddDate(0, 0, -ago).Format("2006-01-02")
}

func (g *logRig) get(path string) (int, map[string]any, []byte) {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	w := httptest.NewRecorder()
	handleGet(w, req)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out, w.Body.Bytes()
}

func (g *logRig) post(path, origin, body string) (int, map[string]any) {
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	w := httptest.NewRecorder()
	handlePost(w, req)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func (g *logRig) snapshot() map[string]string {
	out := map[string]string{}
	es, _ := os.ReadDir(g.home)
	for _, e := range es {
		if !e.IsDir() {
			b, _ := os.ReadFile(filepath.Join(g.home, e.Name()))
			out[e.Name()] = string(b)
		}
	}
	des, _ := os.ReadDir(g.dir)
	for _, e := range des {
		b, _ := os.ReadFile(filepath.Join(g.dir, e.Name()))
		out["events/"+e.Name()] = string(b)
	}
	return out
}

func sameFiles(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if w, ok := b[k]; !ok || w != v {
			return false
		}
	}
	return true
}

func lastEvent(t *testing.T, home, kind string) map[string]any {
	t.Helper()
	files, _ := filepath.Glob(filepath.Join(home, "events", "*.jsonl"))
	var found map[string]any
	for _, f := range files {
		if filepath.Base(f) == "seals.jsonl" {
			continue
		}
		b, _ := os.ReadFile(f)
		for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
			var m map[string]any
			if json.Unmarshal([]byte(l), &m) == nil && m["kind"] == kind {
				found = m
			}
		}
	}
	return found
}

// Protects Admin > Logging's state route: the saved settings with their defaults, where the log is (home abbreviated), how big it is, and a
// malformed settings file still answering 30.
func TestLoggingState(t *testing.T) {
	g := newLogRig(t, nil)
	os.WriteFile(filepath.Join(g.dir, g.day(0)+".jsonl"), []byte("{}\n"), 0o600)
	os.WriteFile(filepath.Join(g.dir, g.day(40)+".jsonl"), []byte("{}\n{}\n"), 0o600)
	os.WriteFile(filepath.Join(g.dir, g.day(50)+".jsonl.gz"), []byte("x"), 0o600)
	code, st, _ := g.get("/api/admin/logging")
	if opts, _ := st["retention_options"].([]any); st["ok"] != true || len(opts) != 3 || opts[0] != float64(30) || opts[1] != float64(90) || opts[2] != float64(365) || st["bytes"] != float64(3+6+1) {
		t.Errorf("ok, options and bytes: %v", st)
	}
	if code != 200 || st["retention_days"] != float64(30) || st["compress"] != true || st["retention_default"] != float64(30) || st["days"] != float64(3) || st["files"] != float64(3) {
		t.Fatalf("state = %d %v", code, st)
	}
	if st["oldest"] != g.day(50) || st["newest"] != g.day(0) || st["dir"] == "" || strings.Contains(st["dir"].(string), g.home) && !strings.HasPrefix(st["dir"].(string), g.home) {
		t.Errorf("oldest/newest/dir = %v %v %v", st["oldest"], st["newest"], st["dir"])
	}
	os.WriteFile(filepath.Join(g.home, "settings.json"), []byte("{not json"), 0o600)
	_, st, _ = g.get("/api/admin/logging")
	if st["retention_days"] != float64(30) || st["settings_error"] == nil {
		t.Errorf("a malformed settings file must still answer 30 and say so: %v", st)
	}
}

// Protects the write guard of every Logging write: no Origin and a foreign Origin are refused with nothing changed, and a read route
// needs no Origin.
func TestLoggingWritesNeedALoopbackOrigin(t *testing.T) {
	g := newLogRig(t, map[string]string{"2020-01-01.jsonl": "{}\n"})
	before := g.snapshot()
	for _, path := range []string{"/api/admin/logging", "/api/admin/logging/delete", "/api/admin/logging/reveal"} {
		for _, origin := range []string{"", "http://evil.example", "http://127.0.0.1.evil.example", "null"} {
			body := `{"retention_days":90,"confirm":"delete"}`
			if code, _ := g.post(path, origin, body); code != 403 {
				t.Errorf("POST %s with Origin %q answered %d", path, origin, code)
			}
		}
	}
	if !sameFiles(before, g.snapshot()) {
		t.Errorf("a refused write changed files")
	}
	revealed := ""
	old := revealFolder
	revealFolder = func(d string) error { revealed = d; return nil }
	defer func() { revealFolder = old }()
	if code, _ := g.post("/api/admin/logging/reveal", logClick, `{}`); code != 200 || revealed != g.dir {
		t.Errorf("reveal = %d %q (want %q)", code, revealed, g.dir)
	}
	if code, _, _ := g.get("/api/admin/logging/verify"); code != 200 {
		t.Errorf("verify read needs no Origin: %d", code)
	}
}

// Protects Keep for: a lower value that would remove days needs confirm_remove (409, nothing changed), the confirmed save writes the
// 0600 file and one setting.changed (actor user), no day file is removed inside the request, and a lower value that removes nothing
// saves without it. Bad values and unknown fields are refused.
func TestLoggingKeepFor(t *testing.T) {
	g := newLogRig(t, nil)
	os.WriteFile(filepath.Join(g.dir, g.day(0)+".jsonl"), []byte("{}\n"), 0o600)
	os.WriteFile(filepath.Join(g.dir, g.day(100)+".jsonl"), []byte("{}\n"), 0o600)
	setting := filepath.Join(g.home, "settings.json")
	if code, st := g.post("/api/admin/logging", logClick, `{"retention_days":365}`); code != 200 || st["retention_days"] != float64(365) {
		t.Fatalf("raise to 365: %d %v", code, st)
	}
	if runtime.GOOS != "windows" {
		if fi, _ := os.Stat(setting); fi.Mode().Perm() != 0o600 {
			t.Errorf("settings mode = %o", fi.Mode().Perm())
		}
	}
	ev := lastEvent(t, g.home, "setting.changed")
	d, _ := ev["data"].(map[string]any)
	if ev == nil || ev["actor"] != "user" || d["name"] != "log.retention_days" || d["old"] != "30" || d["new"] != "365" {
		t.Errorf("setting.changed = %v", ev)
	}
	before := g.snapshot()
	code, st := g.post("/api/admin/logging", logClick, `{"retention_days":30}`)
	if e, _ := st["error"].(string); st["ok"] != false || !strings.Contains(e, "confirm_remove") {
		t.Errorf("the 409 body must say ok false and name confirm_remove: %v", st)
	}
	if code != 409 || st["needs_confirm"] != true || st["would_remove_days"] != float64(1) || st["would_remove_files"] != float64(1) {
		t.Fatalf("lower without the flag: %d %v", code, st)
	}
	if !sameFiles(before, g.snapshot()) {
		t.Errorf("a refused lowering changed the setting or removed a file")
	}
	code, st = g.post("/api/admin/logging", logClick, `{"retention_days":30,"confirm_remove":true}`)
	if code != 200 || st["retention_days"] != float64(30) {
		t.Fatalf("lower with the flag: %d %v", code, st)
	}
	if _, err := os.Stat(filepath.Join(g.dir, g.day(100)+".jsonl")); err != nil {
		t.Errorf("a day file was removed inside the request")
	}
	if code, _ := g.post("/api/admin/logging", logClick, `{"retention_days":90}`); code != 200 { // raising never asks
		t.Errorf("raise to 90: %d", code)
	}
	os.Remove(filepath.Join(g.dir, g.day(100)+".jsonl"))
	if code, _ := g.post("/api/admin/logging", logClick, `{"retention_days":30}`); code != 200 { // nothing would go: no confirm needed
		t.Errorf("lower with nothing to remove: %d", code)
	}
	for _, body := range []string{`{"retention_days":7}`, `{"retention_days":"30"}`, `{"retention_days":30.5}`, `{"compress":"yes"}`, `{}`, `{"retention_days":90,"path":"/etc"}`, `{"retention_days":90,"compress":"yes"}`} {
		snap := g.snapshot()
		code, res := g.post("/api/admin/logging", logClick, body)
		if code != 400 || res == nil || res["ok"] != false || res["error"] == "" || res["error"] == nil || (strings.Contains(body, "path") && !strings.Contains(res["error"].(string), "unknown field path")) {
			t.Errorf("%s answered %d %v (one JSON error body expected)", body, code, res)
		}
		if !sameFiles(snap, g.snapshot()) {
			t.Errorf("%s changed a file although it was refused", body)
		}
	}
	// the same value again with days that would go is not a lowering: no confirm
	os.WriteFile(filepath.Join(g.dir, g.day(100)+".jsonl"), []byte("{}\n"), 0o600)
	if code, _ := g.post("/api/admin/logging", logClick, `{"retention_days":30}`); code != 200 {
		t.Errorf("saving the current value answered %d", code)
	}
	if code, res := g.post("/api/admin/logging", logClick, `{"retention_days":30,"compress":"x"}`); code != 400 || res["ok"] != false {
		t.Errorf("mixed bad body: %d %v", code, res)
	}
	os.WriteFile(setting, []byte("{not json"), 0o600)
	badBefore := g.snapshot()
	if code, res := g.post("/api/admin/logging", logClick, `{"retention_days":90}`); code != 400 || res == nil || res["ok"] != false || !strings.Contains(res["error"].(string), "settings.json") || !sameFiles(badBefore, g.snapshot()) {
		t.Errorf("a malformed settings file must be refused and left alone: %d %v", code, res)
	}
}

// Protects the compress switch: it saves log.compress, records one setting.changed, and off makes maintenance leave sealed old days plain.
func TestLoggingCompressSwitch(t *testing.T) {
	g := newLogRig(t, nil)
	old := g.day(20)
	os.WriteFile(filepath.Join(g.dir, old+".jsonl"), []byte("{}\n"), 0o600)
	if code, st := g.post("/api/admin/logging", logClick, `{"compress":false}`); code != 200 || st["compress"] != false {
		t.Fatalf("turn off: %d %v", code, st)
	}
	ev := lastEvent(t, g.home, "setting.changed")
	if d, _ := ev["data"].(map[string]any); ev == nil || d["name"] != "log.compress" || d["old"] != "true" || d["new"] != "false" {
		t.Errorf("setting.changed = %v", ev)
	}
	if err := events.Maintain(g.home, time.Now().UTC(), "board"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(g.dir, old+".jsonl")); err != nil {
		t.Errorf("a day was gzipped with compress off")
	}
	g.post("/api/admin/logging", logClick, `{"compress":true}`)
	events.Maintain(g.home, time.Now().UTC(), "board")
	if _, err := os.Stat(filepath.Join(g.dir, old+".jsonl.gz")); err != nil {
		t.Errorf("a day was not gzipped with compress on")
	}
}

// Protects Verify on the page: a sealed log is intact with its summary, a changed day is named in a broken summary, and the output holds
// only days and fixed words.
func TestLoggingVerify(t *testing.T) {
	g := newLogRig(t, map[string]string{"2020-01-01.jsonl": "{}\n", "2020-01-02.jsonl": "{}\n"})
	events.Seal(g.home, time.Now().UTC())
	_, v, _ := g.get("/api/admin/logging/verify")
	if v["intact"] != true || v["summary"] != "2 days sealed, all intact" {
		t.Fatalf("intact log: %v", v)
	}
	os.WriteFile(filepath.Join(g.dir, "2020-01-02.jsonl"), []byte("{\"x\":1}\n"), 0o600)
	_, v, _ = g.get("/api/admin/logging/verify")
	if v["intact"] != false || v["summary"] != "Broken: 2020-01-02 broken" {
		t.Errorf("tampered log: %v", v)
	}
	rows, _ := v["results"].([]any)
	if len(rows) == 0 {
		t.Errorf("no results")
	}
	rows0, _ := v["results"].([]any)
	if r1, _ := rows0[1].(map[string]any); r1["day"] != "2020-01-02" || r1["why"] != "does not match its seal" || r1["result"] != "broken" {
		t.Errorf("a broken row carries its reason: %v", rows0)
	}
	empty := newLogRig(t, nil)
	if _, v, _ := empty.get("/api/admin/logging/verify"); v["summary"] != "No activity log yet" {
		t.Errorf("empty log: %v", v)
	}
	only := newLogRig(t, map[string]string{"2020-01-01.jsonl": "{}\n"})
	if _, v, _ := only.get("/api/admin/logging/verify"); v["summary"] != "1 day not sealed yet" || v["intact"] != true {
		t.Errorf("only an unsealed day: %v", v)
	}
	many := newLogRig(t, nil)
	for i := 0; i < 2105; i++ {
		os.WriteFile(filepath.Join(many.dir, time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC).AddDate(0, 0, i).Format("2006-01-02")+".jsonl"), []byte("{}\n"), 0o600)
	}
	os.WriteFile(filepath.Join(many.dir, "2006-06-06.jsonl"), []byte("{}\n"), 0o600) // sorts after the 2000 rows kept
	events.Seal(many.home, time.Now().UTC())
	os.Remove(filepath.Join(many.dir, "2006-06-06.jsonl"))
	if _, v, _ := many.get("/api/admin/logging/verify"); len(v["results"].([]any)) != 2000 || v["intact"] != false || !strings.HasPrefix(v["summary"].(string), "Broken: ") {
		t.Errorf("results are capped at 2000 and a broken day past the cap still shows in the summary: %d %v", len(v["results"].([]any)), v["summary"])
	}
}

// Protects Export: every day in order, a gzipped day gunzipped, a link and seals.jsonl left out, headers that make it a download, and a
// log over the cap refused cleanly before any byte.
func TestLoggingExport(t *testing.T) {
	g := newLogRig(t, map[string]string{"2020-01-02.jsonl": "{\"b\":1}\n", "2020-01-04.jsonl": "{\"d\":1}"})
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write([]byte("{\"a\":1}\n"))
	zw.Close()
	os.WriteFile(filepath.Join(g.dir, "2020-01-01.jsonl.gz"), gz.Bytes(), 0o600)
	os.WriteFile(filepath.Join(g.dir, "seals.jsonl"), []byte("SEALS\n"), 0o600)
	if runtime.GOOS != "windows" {
		secret := filepath.Join(t.TempDir(), "secret")
		os.WriteFile(secret, []byte("SECRET\n"), 0o600)
		os.Symlink(secret, filepath.Join(g.dir, "2020-01-03.jsonl"))
	}
	req := httptest.NewRequest(http.MethodGet, "/api/admin/logging/export", nil)
	w := httptest.NewRecorder()
	handleGet(w, req)
	if w.Code != 200 || w.Header().Get("Content-Type") != "application/x-ndjson" || !strings.Contains(w.Header().Get("Content-Disposition"), `attachment; filename="canon-activity-log.jsonl"`) {
		t.Fatalf("export = %d %v", w.Code, w.Header())
	}
	if got := w.Body.String(); got != "{\"a\":1}\n{\"b\":1}\n{\"d\":1}\n" {
		t.Errorf("export body = %q", got)
	}
	if strings.Contains(w.Body.String(), "SECRET") || strings.Contains(w.Body.String(), "SEALS") {
		t.Errorf("export leaked a link target or the seal file")
	}
}

// Protects Delete: it needs the confirm word and a loopback Origin; it removes day files (plain and gz), the seal file and emit-errors.log
// by exact name, keeps look-alikes and a link's target, and leaves a fresh log that starts with log.deleted.
func TestLoggingDelete(t *testing.T) {
	g := newLogRig(t, map[string]string{
		"2020-01-01.jsonl": "{}\n", "2020-01-02.jsonl.gz": "x", "seals.jsonl": "{}\n", "emit-errors.log": "e\n",
		"notes.txt": "keep", "2020-01-01.jsonl.bak": "keep", "seals.jsonl.bak": "keep", "emit-errors.log.1": "keep", "2020-13-45.jsonl": "keep", "x2020-01-01.jsonl": "keep",
	})
	var outside string
	if runtime.GOOS != "windows" {
		outside = filepath.Join(t.TempDir(), "target")
		os.WriteFile(outside, []byte("keep"), 0o600)
		os.Symlink(outside, filepath.Join(g.dir, "2020-01-03.jsonl"))
	}
	before := g.snapshot()
	for _, body := range []string{`{}`, `{"confirm":"yes"}`, `{"confirm":true}`, `{"confirm":"Delete"}`} {
		code, res := g.post("/api/admin/logging/delete", logClick, body)
		if e, _ := res["error"].(string); code != 400 || res["ok"] != false || !strings.Contains(e, `"confirm":"delete"`) {
			t.Errorf("%s answered %d %v", body, code, res)
		}
	}
	if !sameFiles(before, g.snapshot()) {
		t.Fatalf("a refused delete changed files")
	}
	code, res := g.post("/api/admin/logging/delete", logClick, `{"confirm":"delete"}`)
	wantRemoved := 4
	if runtime.GOOS != "windows" {
		wantRemoved = 5 // the link itself is removed too
	}
	if code != 200 || res["ok"] != true || res["removed"] != float64(wantRemoved) {
		t.Fatalf("delete = %d %v", code, res)
	}
	for _, kept := range []string{"notes.txt", "seals.jsonl.bak", "emit-errors.log.1", "2020-01-01.jsonl.bak", "2020-13-45.jsonl", "x2020-01-01.jsonl"} {
		if _, err := os.Stat(filepath.Join(g.dir, kept)); err != nil {
			t.Errorf("%s was removed", kept)
		}
	}
	for _, gone := range []string{"2020-01-01.jsonl", "2020-01-02.jsonl.gz", "seals.jsonl", "emit-errors.log"} {
		if _, err := os.Stat(filepath.Join(g.dir, gone)); err == nil {
			t.Errorf("%s remains", gone)
		}
	}
	if outside != "" {
		if b, _ := os.ReadFile(outside); string(b) != "keep" {
			t.Errorf("a link's target was touched")
		}
	}
	ev := lastEvent(t, g.home, "log.deleted")
	d, _ := ev["data"].(map[string]any)
	if ev == nil || ev["actor"] != "user" || d["from"] != "2020-01-01" || d["to"] != "2020-01-03" && d["to"] != "2020-01-02" || d["files"] != "5" && d["files"] != "4" {
		t.Errorf("log.deleted = %v", ev)
	}
	// the fresh log's first line is that record
	files, _ := filepath.Glob(filepath.Join(g.dir, "????-??-??.jsonl"))
	first := ""
	for _, f := range files {
		if filepath.Base(f) == time.Now().UTC().Format("2006-01-02")+".jsonl" {
			b, _ := os.ReadFile(f)
			first = strings.SplitN(string(b), "\n", 2)[0]
		}
	}
	if !strings.Contains(first, `"kind":"log.deleted"`) {
		t.Errorf("the fresh log starts with %q", first)
	}
	// a delete with nothing to delete says ok and writes nothing
	g2 := newLogRig(t, nil)
	if code, res := g2.post("/api/admin/logging/delete", logClick, `{"confirm":"delete"}`); code != 200 || res["removed"] != float64(0) {
		t.Errorf("empty delete = %d %v", code, res)
	}
	if lastEvent(t, g2.home, "log.deleted") != nil {
		t.Errorf("an empty delete wrote a log.deleted event")
	}
}

// Protects Factory's "Last synced" wording: the intake answer carries how far back the log reaches, and last_synced when the log has one.
func TestIntakeCarriesKeepDaysAndLastSynced(t *testing.T) {
	g := newLogRig(t, nil)
	root := t.TempDir()
	res := map[string]any{"ok": true}
	addIntakeLog(res, root)
	if res["keep_days"] != 30 || res["last_synced"] != nil {
		t.Errorf("empty log: %v", res)
	}
	os.WriteFile(filepath.Join(g.home, "settings.json"), []byte(`{"log":{"retention_days":90}}`), 0o600)
	if err := events.Emit(g.home, "github.synced", "tkt", resolvedOrAbs(root), map[string]string{"count": "4"}); err != nil {
		t.Fatal(err)
	}
	res = map[string]any{"ok": true}
	addIntakeLog(res, root)
	ls, _ := res["last_synced"].(map[string]any)
	if res["keep_days"] != 90 || ls["count"] != "4" {
		t.Errorf("with a sync: %v", res)
	}
}

// Protects the folder name the page shows: inside the home folder it is abbreviated with ~ and the OS separator, outside it is the full path.
func TestLoggingDisplayDir(t *testing.T) {
	uh := t.TempDir()
	t.Setenv("HOME", uh)
	t.Setenv("USERPROFILE", uh)
	sep := string(filepath.Separator)
	if got := displayDir(filepath.Join(uh, ".canon")); got != "~"+sep+".canon"+sep+"events" {
		t.Errorf("inside home: %q", got)
	}
	other := t.TempDir()
	if got := displayDir(other); got != filepath.Join(other, "events") {
		t.Errorf("outside home: %q", got)
	}
	if got := displayDir(uh); got != "~"+sep+"events" {
		t.Errorf("home itself: %q", got)
	}
}

// Protects the page when the log folder cannot be read (a linked events folder): an error answer with ok false, not a half state.
func TestLoggingStateWhenTheFolderIsALink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	g := newLogRig(t, nil)
	os.Remove(g.dir)
	os.Symlink(t.TempDir(), g.dir)
	code, st, _ := g.get("/api/admin/logging")
	if code != 500 || st["ok"] != false || st["error"] != "the activity log folder cannot be read" {
		t.Errorf("state = %d %v", code, st)
	}
}

// Protects Show in folder: a missing folder is a 404 that opens nothing, a failing opener is a 500, and the folder opened is the events folder.
func TestLoggingReveal(t *testing.T) {
	g := newLogRig(t, nil)
	calls := 0
	old := revealFolder
	revealFolder = func(string) error { calls++; return nil }
	defer func() { revealFolder = old }()
	os.Remove(g.dir)
	if code, res := g.post("/api/admin/logging/reveal", logClick, `{}`); code != 404 || res["ok"] != false || calls != 0 || !strings.Contains(res["error"].(string), "no activity log folder") {
		t.Errorf("no folder: %d %v calls=%d", code, res, calls)
	}
	os.MkdirAll(g.dir, 0o700)
	revealFolder = func(string) error { return os.ErrPermission }
	if code, res := g.post("/api/admin/logging/reveal", logClick, `{}`); code != 500 || res["ok"] != false || !strings.Contains(res["error"].(string), "could not open") {
		t.Errorf("a failing opener: %d %v", code, res)
	}
	revealFolder = func(d string) error { calls++; return nil }
	if code, res := g.post("/api/admin/logging/reveal", logClick, `{}`); code != 200 || res["ok"] != true || calls != 1 {
		t.Errorf("reveal: %d %v calls=%d", code, res, calls)
	}
}

// Protects Verify's page answer: ok, the four counts, one row per non-empty day with its fields, and the unsealed note in the summary.
func TestLoggingVerifyShape(t *testing.T) {
	g := newLogRig(t, map[string]string{"2020-01-01.jsonl": "{}\n"})
	events.Seal(g.home, time.Now().UTC())
	os.WriteFile(filepath.Join(g.dir, "2020-01-02.jsonl"), []byte("{}\n"), 0o600) // closed, after the seal: not sealed yet
	_, v, _ := g.get("/api/admin/logging/verify")
	counts, _ := v["counts"].(map[string]any)
	rows, _ := v["results"].([]any)
	first, _ := rows[0].(map[string]any)
	if v["ok"] != true || v["intact"] != true || counts["intact"] != float64(1) || counts["unsealed"] != float64(1) || counts["broken"] != float64(0) || counts["missing"] != float64(0) {
		t.Fatalf("verify = %v", v)
	}
	if first["day"] != "2020-01-01" || first["result"] != "intact" || len(rows) != 2 {
		t.Errorf("rows = %v", rows)
	}
	if v["summary"] != "1 day sealed, all intact; 1 not sealed yet" {
		t.Errorf("summary = %v", v["summary"])
	}
	os.Remove(filepath.Join(g.dir, "2020-01-01.jsonl"))
	_, v, _ = g.get("/api/admin/logging/verify")
	if v["summary"] != "Broken: 2020-01-01 missing" || v["intact"] != false {
		t.Errorf("missing day: %v", v)
	}
}

// Protects Delete while canon is sealing, and a delete that cannot finish: a busy lock is a 409 that removes nothing, a folder that
// cannot be written is a 500 with the real reason that does not claim success.
func TestLoggingDeleteBusyAndPartial(t *testing.T) {
	g := newLogRig(t, map[string]string{"2020-01-01.jsonl": "{}\n"})
	os.WriteFile(filepath.Join(g.dir, ".maintain.lock"), nil, 0o600)
	if code, res := g.post("/api/admin/logging/delete", logClick, `{"confirm":"delete"}`); code != 409 || res["ok"] != false || !strings.Contains(res["error"].(string), "try again") {
		t.Errorf("busy: %d %v", code, res)
	}
	if _, err := os.Stat(filepath.Join(g.dir, "2020-01-01.jsonl")); err != nil {
		t.Errorf("a busy delete removed a file")
	}
	os.Remove(filepath.Join(g.dir, ".maintain.lock"))
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		return
	}
	os.Chmod(g.dir, 0o500) // the folder cannot be written: nothing can be removed
	defer os.Chmod(g.dir, 0o700)
	code, res := g.post("/api/admin/logging/delete", logClick, `{"confirm":"delete"}`)
	if e, _ := res["error"].(string); code != 500 || res["ok"] != false || !strings.Contains(e, "permission denied") || res["removed"] != float64(0) {
		t.Errorf("a folder that cannot be written: %d %v", code, res)
	}
	if _, err := os.Stat(filepath.Join(g.dir, "2020-01-01.jsonl")); err != nil {
		t.Errorf("a file went")
	}
}

// Protects Export's download headers and its refusal of a log it cannot read.
func TestLoggingExportHeadersAndRefusal(t *testing.T) {
	g := newLogRig(t, map[string]string{"2020-01-01.jsonl": "{}\n"})
	req := httptest.NewRequest(http.MethodGet, "/api/admin/logging/export", nil)
	w := httptest.NewRecorder()
	handleGet(w, req)
	if w.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("export must be nosniff: %v", w.Header())
	}
	if runtime.GOOS != "windows" {
		os.Remove(g.dir + "/2020-01-01.jsonl")
		os.WriteFile(g.dir+"/2020-01-01.jsonl.gz", []byte("not gzip"), 0o600)
		w = httptest.NewRecorder()
		handleGet(w, httptest.NewRequest(http.MethodGet, "/api/admin/logging/export", nil))
		var res map[string]any
		json.Unmarshal(w.Body.Bytes(), &res)
		if w.Code != 500 || res["ok"] != false || res["error"] == nil || w.Header().Get("Content-Disposition") != "" {
			t.Errorf("an unreadable day: %d %v %v", w.Code, res, w.Header())
		}
	}
}
