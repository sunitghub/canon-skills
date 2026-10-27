package board

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// settingEvents returns every setting.changed line under $CANON_HOME/events as decoded JSON.
func settingEvents(t *testing.T, home string) []map[string]any {
	t.Helper()
	files, _ := filepath.Glob(filepath.Join(home, "events", "*.jsonl"))
	var out []map[string]any
	for _, f := range files {
		b, _ := os.ReadFile(f)
		for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
			if l == "" {
				continue
			}
			var m map[string]any
			if json.Unmarshal([]byte(l), &m) != nil {
				t.Fatalf("not JSON: %s", l)
			}
			if m["kind"] == "setting.changed" {
				out = append(out, m)
			}
		}
	}
	return out
}

// t-4c09. Protects the Admin Model tiers page's audit line: every successful write route leaves one setting.changed event with the
// Review & Eval default before and after and actor `user` (a person's click); a refused or invalid write leaves none; and no registry text
// (a source URL, a model description) ever reaches the log.
func TestModelTiersWritesLeaveOneAuditLine(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CANON_HOME", dir)
	seed := filepath.Join(dir, "seed.json")
	old := modelTiersPath
	modelTiersPath = seed
	defer func() { modelTiersPath = old }()
	doc := regDoc()
	doc["sources"] = []any{map[string]any{"url": "https://example.test/secret-registry.json", "kind": "docs", "provider": "openai"}}
	raw, _ := json.Marshal(doc)
	if err := os.WriteFile(seed, raw, 0o644); err != nil {
		t.Fatal(err)
	}

	// a refused change: nothing written, nothing logged
	auditTiers("retire", func() map[string]any {
		return registryMove(func(map[string]any) error { return errors.New("no thanks") })
	})
	if n := len(settingEvents(t, dir)); n != 0 {
		t.Fatalf("a refused change logged %d event(s)", n)
	}
	// an invalid save: refused by validation, nothing logged
	if res := auditTiers("save", func() map[string]any { return saveModelTiers(map[string]any{"models": "nope"}) }); res["ok"] == true {
		t.Fatal("an invalid payload was saved")
	}
	if n := len(settingEvents(t, dir)); n != 0 {
		t.Fatalf("an invalid save logged %d event(s)", n)
	}

	// a good retire: one line, the default before and after
	res := auditTiers("retire", func() map[string]any {
		return registryMove(func(d map[string]any) error { return retireModel(d, "claude-sonnet-5", "claude-sonnet-5-5") })
	})
	if res["ok"] != true {
		t.Fatalf("retire: %v", res)
	}
	got := settingEvents(t, dir)
	if len(got) != 1 {
		t.Fatalf("a good retire logged %d event(s), want 1", len(got))
	}
	e := got[0]
	data, _ := e["data"].(map[string]any)
	if e["source"] != "board" || e["actor"] != "user" || e["project"] != "" {
		t.Errorf("envelope: %v", e)
	}
	if data["name"] != "model-tiers.retire" || data["old"] != "claude-sonnet-5" || data["new"] != "claude-sonnet-5-5" || len(data) != 3 {
		t.Errorf("data: %v", data)
	}
	// a reset (the user's override deleted) is its own action
	if res := auditTiers("reset", func() map[string]any { return saveModelTiers(map[string]any{"reset": true}) }); res["ok"] != true {
		t.Fatalf("reset: %v", res)
	}
	got = settingEvents(t, dir)
	if len(got) != 2 || got[1]["data"].(map[string]any)["name"] != "model-tiers.reset" {
		t.Fatalf("a reset should add one model-tiers.reset line: %v", got)
	}
	files, _ := filepath.Glob(filepath.Join(dir, "events", "*.jsonl"))
	for _, f := range files {
		b, _ := os.ReadFile(f)
		if strings.Contains(string(b), "example.test") || strings.Contains(string(b), "secret-registry") {
			t.Fatalf("a registry source URL reached the audit log: %s", b)
		}
	}
}

// t-4c09. Observer-only: with the events folder unwritable, a Model tiers write still succeeds with the same answer and logs nothing.
func TestModelTiersWriteSucceedsWhenEventsCannotBeWritten(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CANON_HOME", dir)
	seed := filepath.Join(dir, "seed.json")
	old := modelTiersPath
	modelTiersPath = seed
	defer func() { modelTiersPath = old }()
	raw, _ := json.Marshal(regDoc())
	if err := os.WriteFile(seed, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "events"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(dir, "events"), 0o500); err != nil {
		t.Skip("cannot make the folder read-only here")
	}
	defer os.Chmod(filepath.Join(dir, "events"), 0o700)
	if f, err := os.OpenFile(filepath.Join(dir, "events", "probe"), os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		f.Close()
		t.Skip("the folder is still writable (running as root?)")
	}
	res := auditTiers("retire", func() map[string]any {
		return registryMove(func(d map[string]any) error { return retireModel(d, "claude-sonnet-5", "claude-sonnet-5-5") })
	})
	if res["ok"] != true {
		t.Fatalf("an unwritable events folder changed the write's answer: %v", res)
	}
	os.Chmod(filepath.Join(dir, "events"), 0o700)
	if n := len(settingEvents(t, dir)); n != 0 {
		t.Fatalf("%d event(s) were logged into a read-only folder", n)
	}
}

// t-4c09. Protects the Admin Model tiers routes themselves (the action name each one records and the payload each reads): a request to
// each write route leaves exactly one setting.changed line named for it, carrying the Review & Eval default before and after.
func TestModelTiersRoutesRecordTheirAction(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CANON_HOME", dir)
	seed := filepath.Join(dir, "seed.json")
	old := modelTiersPath
	modelTiersPath = seed
	defer func() { modelTiersPath = old }()
	raw, _ := json.Marshal(regDoc())
	if err := os.WriteFile(seed, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	post := func(path, body string) int {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", "http://127.0.0.1:8423")
		w := httptest.NewRecorder()
		handlePost(w, req)
		return w.Code
	}
	last := func() map[string]any {
		got := settingEvents(t, dir)
		if len(got) == 0 {
			return nil
		}
		return got[len(got)-1]["data"].(map[string]any)
	}
	count := func() int { return len(settingEvents(t, dir)) }

	if c := post("/api/admin/model-tiers/retire", `{"old":"claude-sonnet-5","new":"claude-sonnet-5-5"}`); c != http.StatusOK {
		t.Fatalf("retire = %d", c)
	}
	if d := last(); count() != 1 || d["name"] != "model-tiers.retire" || d["old"] != "claude-sonnet-5" || d["new"] != "claude-sonnet-5-5" {
		t.Fatalf("retire route: %d line(s), last %v", count(), d)
	}
	if c := post("/api/admin/model-tiers/remove", `{"id":"claude-haiku-5-5","move_to":"claude-haiku-4-5"}`); c != http.StatusOK {
		t.Fatalf("remove = %d", c)
	}
	if d := last(); count() != 2 || d["name"] != "model-tiers.remove" {
		t.Fatalf("remove route: %d line(s), last %v", count(), d)
	}
	if c := post("/api/admin/model-tiers/apply", `{"add":[],"retire":[{"old":"claude-opus-5-5","new":"claude-opus-5-5"}]}`); c == http.StatusOK {
		t.Fatalf("an apply that retires a model into itself must be refused, got %d", c)
	}
	if count() != 2 {
		t.Fatalf("a refused apply logged: %d line(s)", count())
	}
	if c := post("/api/admin/model-tiers/apply", `{"add":[],"retire":[]}`); c != http.StatusOK {
		t.Fatalf("an empty apply = %d", c)
	}
	if d := last(); count() != 3 || d["name"] != "model-tiers.apply" {
		t.Fatalf("apply route: %d line(s), last %v", count(), d)
	}
	cur, _ := json.Marshal(loadModelTiers())
	if c := post("/api/admin/model-tiers", string(cur)); c != http.StatusOK {
		t.Fatalf("save = %d", c)
	}
	if d := last(); count() != 4 || d["name"] != "model-tiers.save" {
		t.Fatalf("save route: %d line(s), last %v", count(), d)
	}
	if c := post("/api/admin/model-tiers", `{"reset":true}`); c != http.StatusOK {
		t.Fatalf("reset = %d", c)
	}
	if d := last(); count() != 5 || d["name"] != "model-tiers.reset" {
		t.Fatalf("reset route: %d line(s), last %v", count(), d)
	}
	if c := post("/api/admin/model-tiers", `{"models":"nope"}`); c == http.StatusOK || count() != 5 {
		t.Fatalf("an invalid save: status %d, %d line(s)", c, count())
	}
}
