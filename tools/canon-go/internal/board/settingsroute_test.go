package board

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-dba0. Protects /api/settings: GET returns the merged values with their sources; a write needs a loopback Origin, changes only
// the LOCAL file, records one setting.changed line (key, old, new, the project, actor user) and refuses an unknown project, key or
// value or a malformed file without writing anything.
func TestSettingsRoutes(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CANON_HOME", home)
	root := t.TempDir()
	old := projectRoot
	projectRoot = root
	defer func() { projectRoot = old }()
	shared := filepath.Join(root, ".canon", "settings.json")
	local := filepath.Join(root, ".canon", "settings.local.json")

	get := func(query string) (int, map[string]any) {
		req := httptest.NewRequest(http.MethodGet, "/api/settings"+query, nil)
		w := httptest.NewRecorder()
		handleGet(w, req)
		var out map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		return w.Code, out
	}
	post := func(query, origin, body string) (int, map[string]any) {
		req := httptest.NewRequest(http.MethodPost, "/api/settings"+query, strings.NewReader(body))
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
	val := func(m map[string]any) (any, any) {
		v, _ := m["values"].(map[string]any)["terminal.paging"].(map[string]any)
		return v["value"], v["source"]
	}
	const click = "http://127.0.0.1:8423"

	if c, m := get(""); c != 200 {
		t.Fatalf("GET = %d", c)
	} else if v, s := val(m); v != "auto" || s != "default" {
		t.Fatalf("default: %v %v", v, s)
	}
	if err := os.MkdirAll(filepath.Dir(shared), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(shared, []byte(`{"terminal":{"paging":"off"}}`), 0o644); err != nil {
		t.Fatal(err)
	}
	sharedBefore, _ := os.ReadFile(shared)
	if _, m := get(""); m == nil {
		t.Fatal("no body")
	} else if v, s := val(m); v != "off" || s != "shared" {
		t.Fatalf("shared: %v %v", v, s)
	}

	// refusals write nothing and log nothing
	for name, c := range map[string]struct {
		query, origin, body string
		want                int
	}{
		"no Origin":       {"", "", `{"key":"terminal.paging","value":"auto"}`, 403},
		"a foreign page":  {"", "http://evil.example", `{"key":"terminal.paging","value":"auto"}`, 403},
		"unknown project": {"?project=nope", click, `{"key":"terminal.paging","value":"auto"}`, 400},
		"unknown key":     {"", click, `{"key":"terminal.nope","value":"auto"}`, 400},
		"path-like key":   {"", click, `{"key":"../../x","value":"auto"}`, 400},
		"bad value":       {"", click, `{"key":"terminal.paging","value":"on"}`, 400},
		"too small":       {"", click, `{"key":"terminal.paging","value":3}`, 400},
	} {
		if code, _ := post(c.query, c.origin, c.body); code != c.want {
			t.Errorf("%s: %d, want %d", name, code, c.want)
		}
	}
	if _, err := os.Stat(local); err == nil {
		t.Fatal("a refused write created the local file")
	}
	if n := len(settingEvents(t, home)); n != 0 {
		t.Fatalf("refused writes logged %d line(s)", n)
	}

	// a good write
	code, m := post("", click, `{"key":"terminal.paging","value":30}`)
	if code != 200 {
		t.Fatalf("write = %d %v", code, m)
	}
	if v, s := val(m); v != float64(30) || s != "local" {
		t.Fatalf("answer: %v %v", v, s)
	}
	if after, _ := os.ReadFile(shared); string(after) != string(sharedBefore) {
		t.Fatal("the shared file changed")
	}
	got := settingEvents(t, home)
	if len(got) != 1 {
		t.Fatalf("a write logged %d line(s), want 1", len(got))
	}
	d := got[0]["data"].(map[string]any)
	if d["name"] != "terminal.paging" || d["old"] != "off" || d["new"] != "30" || got[0]["actor"] != "user" || got[0]["source"] != "board" || got[0]["project"] == "" {
		t.Fatalf("the line: %v", got[0])
	}
	if c, m := get(""); c != 200 {
		t.Fatalf("GET after = %d", c)
	} else if v, s := val(m); v != float64(30) || s != "local" {
		t.Fatalf("after: %v %v", v, s)
	}

	// a malformed local file: GET says so (422, naming it), a write is refused and leaves it byte-identical
	if err := os.WriteFile(local, []byte(`{"terminal": `), 0o600); err != nil {
		t.Fatal(err)
	}
	if c, m := get(""); c != 422 || !strings.Contains(m["error"].(string), ".canon/settings.local.json") {
		t.Fatalf("malformed GET: %d %v", c, m)
	}
	if c, _ := post("", click, `{"key":"terminal.paging","value":"auto"}`); c != 422 {
		t.Fatalf("malformed POST = %d", c)
	}
	if b, _ := os.ReadFile(local); string(b) != `{"terminal": ` {
		t.Fatalf("the malformed file was changed: %q", b)
	}
	if n := len(settingEvents(t, home)); n != 1 {
		t.Fatalf("a refused write logged: %d line(s) in total", n)
	}
}
