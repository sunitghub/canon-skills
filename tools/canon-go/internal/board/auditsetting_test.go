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

// clickReq is a request as the Admin page sends it: a loopback Origin.
func clickReq() *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/admin/model-tiers", nil)
	r.Header.Set("Origin", "http://127.0.0.1:8423")
	return r
}

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
	auditTiers(clickReq(), "retire", func() map[string]any {
		return registryMove(func(map[string]any) error { return errors.New("no thanks") })
	})
	if n := len(settingEvents(t, dir)); n != 0 {
		t.Fatalf("a refused change logged %d event(s)", n)
	}
	// an invalid save: refused by validation, nothing logged
	if res := auditTiers(clickReq(), "save", func() map[string]any { return saveModelTiers(map[string]any{"models": "nope"}) }); res["ok"] == true {
		t.Fatal("an invalid payload was saved")
	}
	if n := len(settingEvents(t, dir)); n != 0 {
		t.Fatalf("an invalid save logged %d event(s)", n)
	}

	// a good retire: one line, the default before and after
	res := auditTiers(clickReq(), "retire", func() map[string]any {
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
	if res := auditTiers(clickReq(), "reset", func() map[string]any { return saveModelTiers(map[string]any{"reset": true}) }); res["ok"] != true {
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
	res := auditTiers(clickReq(), "retire", func() map[string]any {
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
	if d := last(); count() != 3 || d["name"] != "model-tiers.apply" { // a save of the registry as it is changed nothing (t-71c8): no new line
		t.Fatalf("save route: %d line(s), last %v", count(), d)
	}
	if c := post("/api/admin/model-tiers", `{"reset":true}`); c != http.StatusOK {
		t.Fatalf("reset = %d", c)
	}
	if d := last(); count() != 4 || d["name"] != "model-tiers.reset" {
		t.Fatalf("reset route: %d line(s), last %v", count(), d)
	}
	if c := post("/api/admin/model-tiers", `{"models":"nope"}`); c == http.StatusOK || count() != 4 {
		t.Fatalf("an invalid save: status %d, %d line(s)", c, count())
	}
	// no Origin (a script or an agent's shell): the write goes through as today, and the line claims no actor
	req := httptest.NewRequest(http.MethodPost, "/api/admin/model-tiers/apply", strings.NewReader(`{"add":[],"retire":[]}`))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handlePost(w, req)
	if w.Code != http.StatusOK || count() != 5 {
		t.Fatalf("an apply without an Origin: status %d, %d line(s)", w.Code, count())
	}
	if got := settingEvents(t, dir); got[4]["actor"] != nil {
		t.Fatalf("a request without an Origin was logged as %v", got[4]["actor"])
	}
	for i := 0; i < 4; i++ {
		if got := settingEvents(t, dir); got[i]["actor"] != "user" {
			t.Fatalf("line %d: a click should be logged as user, got %v", i, got[i]["actor"])
		}
	}
}

// t-71c8. Protects the Admin Model tiers page's Save and Reset buttons: one that leaves the Review & Eval default as it was (a save of the
// registry unchanged, a reset with no override) writes no setting.changed line, and one that changes it still writes exactly one.
func TestModelTiersSaveOrResetThatChangesNothingLogsNothing(t *testing.T) {
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
	save := func(doc map[string]any) {
		t.Helper()
		if res := auditTiers(clickReq(), "save", func() map[string]any { return saveModelTiers(doc) }); res["ok"] != true {
			t.Fatalf("save: %v", res)
		}
	}
	reset := func() {
		t.Helper()
		if res := auditTiers(clickReq(), "reset", func() map[string]any { return saveModelTiers(map[string]any{"reset": true}) }); res["ok"] != true {
			t.Fatalf("reset: %v", res)
		}
	}
	reset() // nothing overridden yet
	save(regDoc())
	if n := len(settingEvents(t, dir)); n != 0 {
		t.Fatalf("a reset and a save that changed nothing logged %d event(s)", n)
	}
	changed := regDoc()
	changed["defaults"].(map[string]any)["eval"].(map[string]any)["anthropic"] = "claude-sonnet-5-5"
	save(changed)
	got := settingEvents(t, dir)
	if len(got) != 1 || got[0]["data"].(map[string]any)["old"] != "claude-sonnet-5" || got[0]["data"].(map[string]any)["new"] != "claude-sonnet-5-5" {
		t.Fatalf("a save that changed the default should log one line: %v", got)
	}
	save(changed) // the same again: nothing changed
	if n := len(settingEvents(t, dir)); n != 1 {
		t.Fatalf("a repeat save logged: %d line(s)", n)
	}
	reset() // back to the seed's default: one line
	if n := len(settingEvents(t, dir)); n != 2 {
		t.Fatalf("a reset that changed the default should log one line: %d", n)
	}
}

// t-71c8 (user, 2026-10-29: log every changed value): a save that changes another tier's default writes one line named for that tier;
// a save that changes only a model card writes one line; nothing changed writes none. Prod path: POST /api/admin/model-tiers and the
// activity log Tower > Activity reads.
func TestModelTiersSaveLogsEveryChangedValue(t *testing.T) {
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
	save := func(doc map[string]any) {
		t.Helper()
		if res := auditTiers(clickReq(), "save", func() map[string]any { return saveModelTiers(doc) }); res["ok"] != true {
			t.Fatalf("save: %v", res)
		}
	}
	light := regDoc()
	light["defaults"].(map[string]any)["light"].(map[string]any)["anthropic"] = "claude-haiku-5-5"
	save(light)
	got := settingEvents(t, dir)
	if len(got) != 1 {
		t.Fatalf("a save that changed the light default should log one line, got %d: %v", len(got), got)
	}
	d := got[0]["data"].(map[string]any)
	if d["name"] != "model-tiers.save.light.anthropic" || d["old"] != "claude-haiku-4-5" || d["new"] != "claude-haiku-5-5" {
		t.Fatalf("wrong line for the light default: %v", d)
	}
	card := regDoc()
	card["defaults"].(map[string]any)["light"].(map[string]any)["anthropic"] = "claude-haiku-5-5"
	ms := card["models"].(map[string]any)["anthropic"].([]any)
	ms[0].(map[string]any)["name"] = "Claude Opus 5.5 (renamed)"
	save(card)
	got = settingEvents(t, dir)
	if len(got) != 2 {
		t.Fatalf("a save that changed only a model card should log one line, got %d", len(got)-1)
	}
	d = got[1]["data"].(map[string]any)
	if d["name"] != "model-tiers.save" || d["old"] != d["new"] {
		t.Fatalf("a card-only change should log model-tiers.save with the Review & Eval default as old and new: %v", d)
	}
	save(card)
	if n := len(settingEvents(t, dir)); n != 2 {
		t.Fatalf("the same save again changed nothing but logged %d more line(s)", n-2)
	}
}
