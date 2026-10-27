package board

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
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

// t-dba0 (from the mutation sweep). Protects the shape every client reads and the messages a person sees: ok true with a warnings
// list on success, ok false with the reason on a refusal, an unknown project said plainly, and the 403 naming what is missing.
func TestSettingsRouteAnswers(t *testing.T) {
	t.Setenv("CANON_HOME", t.TempDir())
	root := t.TempDir()
	old := projectRoot
	projectRoot = root
	defer func() { projectRoot = old }()
	do := func(method, query, origin, body string) (int, string, map[string]any) {
		req := httptest.NewRequest(method, "/api/settings"+query, strings.NewReader(body))
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		w := httptest.NewRecorder()
		if method == http.MethodGet {
			handleGet(w, req)
		} else {
			handlePost(w, req)
		}
		var m map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &m)
		return w.Code, w.Body.String(), m
	}
	if code, body, _ := do(http.MethodGet, "?project=nope", "", ""); code != 400 || !strings.Contains(body, "unknown project") {
		t.Errorf("GET unknown project: %d %q", code, body)
	}
	if code, body, _ := do(http.MethodPost, "", "", `{"key":"terminal.paging","value":"off"}`); code != 403 || !strings.Contains(body, "loopback Origin") {
		t.Errorf("POST without Origin: %d %q", code, body)
	}
	code, _, m := do(http.MethodGet, "", "", "")
	if code != 200 || m["ok"] != true {
		t.Fatalf("GET: %d %v", code, m)
	}
	if w, ok := m["warnings"].([]any); !ok || w == nil {
		t.Errorf("warnings must be a list, got %#v", m["warnings"])
	}
	code, _, m = do(http.MethodPost, "", "http://127.0.0.1:8423", `{"key":"terminal.paging","value":"on"}`)
	if code != 400 || m["ok"] != false || !strings.Contains(fmt.Sprint(m["error"]), "terminal.paging") {
		t.Errorf("a bad value: %d %v", code, m)
	}
}

// Protects `git status` through the real route: after a write in a repository the local file is excluded and nothing else changed.
func TestSettingsRouteKeepsTheFileOutOfGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	t.Setenv("CANON_HOME", t.TempDir())
	root := t.TempDir()
	run := func(args ...string) string {
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
		return string(out)
	}
	run("init", "-q")
	run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init")
	old := projectRoot
	projectRoot = root
	defer func() { projectRoot = old }()
	req := httptest.NewRequest(http.MethodPost, "/api/settings", strings.NewReader(`{"key":"terminal.paging","value":25}`))
	req.Header.Set("Origin", "http://127.0.0.1:8423")
	w := httptest.NewRecorder()
	handlePost(w, req)
	if w.Code != 200 {
		t.Fatalf("write = %d %s", w.Code, w.Body.String())
	}
	if _, err := os.Stat(filepath.Join(root, ".canon", "settings.local.json")); err != nil {
		t.Fatal(err)
	}
	if st := run("status", "--porcelain"); strings.TrimSpace(st) != "" {
		t.Fatalf("git status is not clean after a write:\n%s", st)
	}
}
