package board

// t-3a58: Factory > Pipeline, the board's GET and POST /api/pipeline. Prod path: the Cockpit's Factory page reads and writes a
// project's canon-config/pipeline.yaml through these routes, with the real tools/pipeline.sh as the one reader.

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const pipelineOrigin = "http://127.0.0.1:8423"

// pipelineEnv pins CANON_HOME and the reader (the repo's real tools/pipeline.sh) and registers one project; it returns its id and root.
func pipelineEnv(t *testing.T) (id, root string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("tools/pipeline.sh runs through Git Bash on Windows (pipeline.cmd); this suite stubs nothing there")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash is not installed")
	}
	sh, err := filepath.Abs("../../../pipeline.sh")
	if err != nil || !exists(sh) {
		t.Fatalf("tools/pipeline.sh not found at %s", sh)
	}
	home := t.TempDir()
	t.Setenv("CANON_HOME", filepath.Join(home, ".canon"))
	t.Setenv("PIPELINE_BIN", sh)
	root, err = filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(registryDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	id = "abc123def456"
	reg, _ := json.Marshal([]registryProject{{ID: id, Path: root, Name: "p"}})
	if err := os.WriteFile(registryFile(), reg, 0o644); err != nil {
		t.Fatal(err)
	}
	return id, root
}

func pipelineGetReq(project string) (int, map[string]any) {
	req := httptest.NewRequest(http.MethodGet, "/api/pipeline?project="+project, nil)
	req.Header.Set("Origin", pipelineOrigin)
	w := httptest.NewRecorder()
	handleGet(w, req)
	var m map[string]any
	json.Unmarshal(w.Body.Bytes(), &m)
	return w.Code, m
}

func pipelinePostReq(project, origin, ctype, body string, hdr ...string) (int, map[string]any) {
	req := httptest.NewRequest(http.MethodPost, "/api/pipeline?project="+project, strings.NewReader(body))
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	w := httptest.NewRecorder()
	handlePost(w, req)
	var m map[string]any
	json.Unmarshal(w.Body.Bytes(), &m)
	return w.Code, m
}

func post(project, body string) (int, map[string]any) {
	return pipelinePostReq(project, pipelineOrigin, "application/json", body)
}

func pipelineFileText(root string) string {
	b, err := os.ReadFile(filepath.Join(root, "canon-config", "pipeline.yaml"))
	if err != nil {
		return "<none>"
	}
	return string(b)
}

// treeDigest hashes every file and folder name under root, so "nothing was written" is one comparison.
func treeDigest(t *testing.T, root string) string {
	t.Helper()
	h := sha256.New()
	filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		fmt.Fprintf(h, "%s|%v|%d\n", rel, info.Mode(), info.Size())
		if info.Mode().IsRegular() {
			b, _ := os.ReadFile(p)
			h.Write(b)
		}
		return nil
	})
	return fmt.Sprintf("%x", h.Sum(nil))
}

func nodeIDs(m map[string]any) []string {
	var out []string
	l, _ := m["nodes"].([]any)
	for _, n := range l {
		out = append(out, n.(map[string]any)["id"].(string))
	}
	return out
}

func TestPipelineGetDefaultCreatesNothing(t *testing.T) {
	id, root := pipelineEnv(t)
	before := treeDigest(t, root)
	code, m := pipelineGetReq(id)
	if code != 200 || m["ok"] != true || m["exists"] != false || m["changed"] != false {
		t.Fatalf("GET with no file = %d %v", code, m)
	}
	ids := strings.Join(nodeIDs(m), " ")
	want := "start plan approve-plan build code-simplifier code-reviewer doc-audit skill-eval break-it reviewer security-review mutation-test eval close"
	if ids != want {
		t.Fatalf("nodes = %q, want %q", ids, want)
	}
	if treeDigest(t, root) != before {
		t.Fatal("a GET wrote into the project")
	}
}

func TestPipelineToggleFirstWriteThenNot(t *testing.T) {
	id, root := pipelineEnv(t)
	code, m := post(id, `{"op":"toggle","id":"mutation-test","on":false}`)
	if code != 200 || m["ok"] != true || m["created"] != true {
		t.Fatalf("first toggle = %d %v", code, m)
	}
	if got := pipelineFileText(root); got != "extends: canon-default\noff: [mutation-test]\n" {
		t.Fatalf("file = %q", got)
	}
	code, m = post(id, `{"op":"toggle","id":"break-it","on":false}`)
	if code != 200 || m["created"] != false {
		t.Fatalf("second toggle = %d %v (the OK dialog must open only for the creating change)", code, m)
	}
	if got := pipelineFileText(root); got != "extends: canon-default\noff: [break-it, mutation-test]\n" {
		t.Fatalf("file = %q", got)
	}
	if out, err := runPipeline("check", "--project", root); err != nil || !strings.Contains(out, "ok") {
		t.Fatalf("the reader refuses what the tab wrote: %q %v", out, err)
	}
	// switching both back on leaves the file as canon's default (it exists, so it is rewritten, not deleted)
	post(id, `{"op":"toggle","id":"break-it","on":true}`)
	post(id, `{"op":"toggle","id":"mutation-test","on":true}`)
	if got := pipelineFileText(root); got != "extends: canon-default\n" {
		t.Fatalf("file after both are back on = %q", got)
	}
	_, g := pipelineGetReq(id)
	if g["changed"] != false || g["exists"] != true || g["can_reset"] != true {
		t.Fatalf("view = %v", g)
	}
}

func TestPipelineToggleToSameStateWithNoFileCreatesNone(t *testing.T) {
	id, root := pipelineEnv(t)
	before := treeDigest(t, root)
	if code, m := post(id, `{"op":"toggle","id":"mutation-test","on":true}`); code != 200 || m["created"] != false {
		t.Fatalf("a no-op toggle = %d %v", code, m)
	}
	if treeDigest(t, root) != before {
		t.Fatal("a toggle that changes nothing created a file")
	}
}

func TestPipelineOrder(t *testing.T) {
	id, root := pipelineEnv(t)
	code, m := post(id, `{"op":"order","wrapup":["doc-audit","code-reviewer","code-simplifier"]}`)
	if code != 200 || m["created"] != true {
		t.Fatalf("order = %d %v", code, m)
	}
	if got := pipelineFileText(root); got != "extends: canon-default\nwrapup-order: [doc-audit, code-reviewer, code-simplifier]\n" {
		t.Fatalf("file = %q", got)
	}
	_, g := pipelineGetReq(id)
	if g["changed"] != true || !strings.HasPrefix(strings.Join(nodeIDs(g), " "), "start plan approve-plan build doc-audit code-reviewer code-simplifier") {
		t.Fatalf("view after order = %v", g)
	}
	// putting the default order back: the file is rewritten without the wrapup-order line
	post(id, `{"op":"order","wrapup":["code-simplifier","code-reviewer","doc-audit"]}`)
	if got := pipelineFileText(root); got != "extends: canon-default\n" {
		t.Fatalf("file after the default order = %q", got)
	}
}

func TestPipelineReset(t *testing.T) {
	id, root := pipelineEnv(t)
	before := treeDigest(t, root)
	if code, m := post(id, `{"op":"reset"}`); code != 200 || m["created"] != false {
		t.Fatalf("reset with no file = %d %v", code, m)
	}
	if treeDigest(t, root) != before {
		t.Fatal("Reset with no file created something")
	}
	post(id, `{"op":"toggle","id":"skill-eval","on":false}`)
	post(id, `{"op":"order","wrapup":["doc-audit","code-reviewer","code-simplifier"]}`)
	if code, m := post(id, `{"op":"reset"}`); code != 200 || m["changed"] != false {
		t.Fatalf("reset = %d %v", code, m)
	}
	if got := pipelineFileText(root); got != "extends: canon-default\n" {
		t.Fatalf("file after Reset = %q", got)
	}
}

func TestPipelineRefusalsLeaveTheTreeAlone(t *testing.T) {
	id, root := pipelineEnv(t)
	post(id, `{"op":"toggle","id":"break-it","on":false}`)
	before := treeDigest(t, root)
	big := `{"op":"reset","id":"` + strings.Repeat("a", 17000) + `"}`
	cases := []struct {
		name, body, want string
		code             int
	}{
		{"locked node", `{"op":"toggle","id":"eval","on":false}`, "node 'eval' is locked", 400},
		{"locked security-review", `{"op":"toggle","id":"security-review","on":false}`, "node 'security-review' is locked", 400},
		{"unknown node", `{"op":"toggle","id":"repo-check","on":false}`, "unknown node 'repo-check'", 400},
		{"path in id", `{"op":"toggle","id":"../x","on":false}`, "bad node id", 400},
		{"command in id", `{"op":"toggle","id":"$(touch PWNED)","on":false}`, "bad node id", 400},
		{"escape in id", "{\"op\":\"toggle\",\"id\":\"\\u001b[31mx\",\"on\":false}", "bad node id", 400},
		{"empty id", `{"op":"toggle","id":"","on":false}`, "bad node id", 400},
		{"no on", `{"op":"toggle","id":"skill-eval"}`, "toggle needs on", 400},
		{"on is a string", `{"op":"toggle","id":"skill-eval","on":"false"}`, "bad request body", 400},
		{"fake op", `{"op":"delete"}`, "op must be", 400},
		{"empty op", `{}`, "op must be", 400},
		{"null body", `null`, "op must be", 400},
		{"array body", `[]`, "bad request body", 400},
		{"number body", `5`, "bad request body", 400},
		{"unknown field", `{"op":"reset","path":"/etc"}`, "bad request body", 400},
		{"trailing data", `{"op":"reset"}{"op":"reset"}`, "bad request body", 400},
		{"empty body", ``, "bad request body", 400},
		{"wrapup too short", `{"op":"order","wrapup":["doc-audit"]}`, "wrapup must list exactly: code-simplifier, code-reviewer, doc-audit", 400},
		{"wrapup outside the group", `{"op":"order","wrapup":["doc-audit","code-reviewer","reviewer"]}`, "wrapup must list exactly", 400},
		{"wrapup duplicate", `{"op":"order","wrapup":["doc-audit","doc-audit","code-reviewer"]}`, "wrapup must list exactly", 400},
		{"body over 16 KB", big, "over 16 KB", 413},
	}
	for _, c := range cases {
		code, m := post(id, c.body)
		msg, _ := m["error"].(string)
		if code != c.code || !strings.Contains(msg, c.want) {
			t.Errorf("%s: %d %q, want %d containing %q", c.name, code, msg, c.code, c.want)
		}
		if strings.ContainsAny(msg, "\x1b$(") && c.name != "unknown node" {
			t.Errorf("%s: the refusal echoes client text: %q", c.name, msg)
		}
		if treeDigest(t, root) != before {
			t.Errorf("%s: the project changed", c.name)
		}
	}
	// who may ask
	for _, c := range []struct {
		name, origin, ctype string
		hdr                 []string
		project             string
		code                int
	}{
		{"no Origin", "", "application/json", nil, id, 403},
		{"foreign Origin", "http://evil.example", "application/json", nil, id, 403},
		{"cross-site fetch", pipelineOrigin, "application/json", []string{"Sec-Fetch-Site", "cross-site"}, id, 403},
		{"not JSON", pipelineOrigin, "text/plain", nil, id, 415},
		{"no content type", pipelineOrigin, "", nil, id, 415},
		{"unknown project", pipelineOrigin, "application/json", nil, "ffffffffffff", 400},
	} {
		code, _ := pipelinePostReq(c.project, c.origin, c.ctype, `{"op":"reset"}`, c.hdr...)
		if code != c.code {
			t.Errorf("%s: %d, want %d", c.name, code, c.code)
		}
		if treeDigest(t, root) != before {
			t.Errorf("%s: the project changed", c.name)
		}
	}
	// a GET is cross-site refused too (it runs a tool)
	req := httptest.NewRequest(http.MethodGet, "/api/pipeline?project="+id, nil)
	req.Header.Set("Origin", "http://evil.example")
	w := httptest.NewRecorder()
	handleGet(w, req)
	if w.Code != 403 {
		t.Errorf("GET with a foreign Origin = %d, want 403", w.Code)
	}
}

func TestPipelineSymlinksAreNeverFollowed(t *testing.T) {
	id, root := pipelineEnv(t)
	outside := t.TempDir()
	// canon-config is a symlink to a folder elsewhere
	if err := os.Symlink(outside, filepath.Join(root, "canon-config")); err != nil {
		t.Skip("symlinks are not available: " + err.Error())
	}
	before := treeDigest(t, outside)
	for _, body := range []string{`{"op":"toggle","id":"skill-eval","on":false}`, `{"op":"order","wrapup":["doc-audit","code-reviewer","code-simplifier"]}`, `{"op":"reset"}`} {
		if code, m := post(id, body); code != 409 {
			t.Errorf("%s through a symlinked canon-config = %d %v, want 409", body, code, m)
		}
	}
	if treeDigest(t, outside) != before {
		t.Fatal("a write went through the symlinked folder")
	}
	if _, g := pipelineGetReq(id); g["ok"] != false || !strings.Contains(fmt.Sprint(g["error"]), "not a plain folder") {
		t.Fatalf("GET with a symlinked folder = %v", g)
	}
	os.Remove(filepath.Join(root, "canon-config"))
	// pipeline.yaml is a symlink to a file elsewhere
	os.MkdirAll(filepath.Join(root, "canon-config"), 0o755)
	victim := filepath.Join(outside, "victim.txt")
	os.WriteFile(victim, []byte("keep me\n"), 0o644)
	if err := os.Symlink(victim, filepath.Join(root, "canon-config", "pipeline.yaml")); err != nil {
		t.Skip("symlinks are not available")
	}
	for _, body := range []string{`{"op":"toggle","id":"skill-eval","on":false}`, `{"op":"reset"}`} {
		if code, _ := post(id, body); code != 409 {
			t.Errorf("%s through a symlinked file = %d, want 409", body, code)
		}
	}
	if b, _ := os.ReadFile(victim); string(b) != "keep me\n" {
		t.Fatalf("the symlink target was rewritten: %q", b)
	}
	// pipeline.yaml is a folder
	os.Remove(filepath.Join(root, "canon-config", "pipeline.yaml"))
	os.Mkdir(filepath.Join(root, "canon-config", "pipeline.yaml"), 0o755)
	if code, _ := post(id, `{"op":"reset"}`); code != 409 {
		t.Errorf("Reset on a folder named pipeline.yaml = %d, want 409", code)
	}
}

func TestPipelineMalformedFileIsOnlyRepairedByReset(t *testing.T) {
	id, root := pipelineEnv(t)
	os.MkdirAll(filepath.Join(root, "canon-config"), 0o755)
	bad := "extends: canon-default\nthis is not a pipeline\n"
	os.WriteFile(filepath.Join(root, "canon-config", "pipeline.yaml"), []byte(bad), 0o644)
	_, g := pipelineGetReq(id)
	if g["ok"] != false || !strings.Contains(fmt.Sprint(g["error"]), "unsupported line") || g["can_reset"] != true || g["nodes"] != nil {
		t.Fatalf("GET with a malformed file = %v", g)
	}
	if code, m := post(id, `{"op":"toggle","id":"skill-eval","on":false}`); code != 400 || !strings.Contains(fmt.Sprint(m["error"]), "unsupported line") {
		t.Fatalf("toggle on a malformed file = %d %v", code, m)
	}
	if got := pipelineFileText(root); got != bad {
		t.Fatalf("a refused toggle changed the file: %q", got)
	}
	if code, m := post(id, `{"op":"reset"}`); code != 200 || m["ok"] != true {
		t.Fatalf("Reset on a malformed file = %d %v", code, m)
	}
	if got := pipelineFileText(root); got != "extends: canon-default\n" {
		t.Fatalf("file after Reset = %q", got)
	}
}

func TestPipelineAFailedProofLeavesTheFileAndNoTempFile(t *testing.T) {
	id, root := pipelineEnv(t)
	post(id, `{"op":"toggle","id":"break-it","on":false}`)
	want := pipelineFileText(root)
	real := os.Getenv("PIPELINE_BIN")
	stub := filepath.Join(t.TempDir(), "pipeline-stub.sh")
	// refuses the scratch project the proof resolves, passes everything else to the real reader
	os.WriteFile(stub, []byte("#!/usr/bin/env bash\ncase \"$*\" in *canon-pipeline-*) echo 'pipeline: forced refusal' >&2; exit 2;; esac\nexec '"+real+"' \"$@\"\n"), 0o755)
	t.Setenv("PIPELINE_BIN", stub)
	code, m := post(id, `{"op":"toggle","id":"skill-eval","on":false}`)
	if code != 500 || !strings.Contains(fmt.Sprint(m["error"]), "nothing written") || !strings.Contains(fmt.Sprint(m["error"]), "forced refusal") {
		t.Fatalf("a refused proof = %d %v", code, m)
	}
	if got := pipelineFileText(root); got != want {
		t.Fatalf("the file changed after a failed proof: %q", got)
	}
	entries, _ := os.ReadDir(filepath.Join(root, "canon-config"))
	if len(entries) != 1 {
		t.Fatalf("a temp file was left behind: %v", entries)
	}
}

func TestPipelineRunsTheResolvedTool(t *testing.T) {
	id, _ := pipelineEnv(t)
	stub := filepath.Join(t.TempDir(), "stub.sh")
	os.WriteFile(stub, []byte("#!/usr/bin/env bash\nprintf '10\\tstart\\tstep\\ton\\tlocked\\t-\\t-\\t-\\tAlways\\n20\\tx-gate\\tgate\\toff\\topen\\twrapup\\tw\\tp.md\\t-\\n'\n"), 0o755)
	t.Setenv("PIPELINE_BIN", stub)
	_, g := pipelineGetReq(id)
	if strings.Join(nodeIDs(g), " ") != "start x-gate" {
		t.Fatalf("the board did not run the resolved tool: %v", g)
	}
	n := g["nodes"].([]any)[1].(map[string]any)
	if n["on"] != false || n["group"] != "wrapup" || n["when"] != "w" || n["prompt"] != "p.md" {
		t.Fatalf("node fields = %v", n)
	}
	// a tool that prints something this page cannot read is an error, never a half list
	os.WriteFile(stub, []byte("#!/usr/bin/env bash\necho 'one field'\n"), 0o755)
	if _, g := pipelineGetReq(id); g["ok"] != false || g["nodes"] != nil {
		t.Fatalf("an unreadable line = %v", g)
	}
	// a hostile id on a line is refused, not passed to the page
	os.WriteFile(stub, []byte("#!/usr/bin/env bash\nprintf '10\\tbad id\\tstep\\ton\\topen\\t-\\t-\\t-\\t-\\n'\n"), 0o755)
	if _, g := pipelineGetReq(id); g["ok"] != false {
		t.Fatalf("a hostile id was accepted: %v", g)
	}
}

func TestPipelineWindowsWrapperMatchesTkt(t *testing.T) {
	tkt, err1 := os.ReadFile("../../../tkt.cmd")
	pipe, err2 := os.ReadFile("../../../pipeline.cmd")
	if err1 != nil || err2 != nil {
		t.Fatalf("tools/tkt.cmd or tools/pipeline.cmd is missing: %v %v", err1, err2)
	}
	want := strings.Replace(string(tkt), `set "SCRIPT=%~dp0tkt"`, `set "SCRIPT=%~dp0pipeline.sh"`, 1)
	if string(pipe) != want {
		t.Fatalf("tools/pipeline.cmd differs from tools/tkt.cmd by more than the script name")
	}
}

func TestPipelineRouteDefaultsToNotFound(t *testing.T) {
	id, _ := pipelineEnv(t)
	for _, path := range []string{"/api/pipeline/other", "/api/pipelines", "/api/pipeline/"} {
		req := httptest.NewRequest(http.MethodGet, path+"?project="+id, nil)
		req.Header.Set("Origin", pipelineOrigin)
		w := httptest.NewRecorder()
		handleGet(w, req)
		if path == "/api/pipeline/" { // the trailing slash is trimmed like every route's
			if w.Code != 200 {
				t.Errorf("GET %s = %d, want 200", path, w.Code)
			}
			continue
		}
		if w.Code != http.StatusNotFound {
			t.Errorf("GET %s = %d, want 404", path, w.Code)
		}
	}
}

func TestPipelineWriteLogsOneSettingChanged(t *testing.T) {
	id, _ := pipelineEnv(t)
	post(id, `{"op":"toggle","id":"skill-eval","on":false}`)
	home := os.Getenv("CANON_HOME")
	files, _ := filepath.Glob(filepath.Join(home, "events", "*.jsonl"))
	var all string
	for _, f := range files {
		b, _ := os.ReadFile(f)
		all += string(b)
	}
	if !strings.Contains(all, `"kind":"setting.changed"`) || !strings.Contains(all, `"name":"pipeline.toggle"`) || !strings.Contains(all, `"new":"off=skill-eval"`) {
		t.Fatalf("no setting.changed line for the toggle in %q", all)
	}
	if strings.Count(all, `"name":"pipeline.toggle"`) != 1 {
		t.Fatalf("expected one line, got: %q", all)
	}
}
