package board

import (
	"encoding/json"
	"errors"
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
