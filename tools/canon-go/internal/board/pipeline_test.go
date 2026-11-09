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
		{"null body", `null`, "bad request body", 400},
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

// break-it (t-3a58): a request's keys are exact and unique, and nothing may trail the object.
func TestPipelineRequestKeysAreStrict(t *testing.T) {
	id, root := pipelineEnv(t)
	post(id, `{"op":"toggle","id":"break-it","on":false}`)
	before := treeDigest(t, root)
	for name, body := range map[string]string{
		"upper-case keys": `{"OP":"toggle","ID":"doc-audit","On":false}`,
		"mixed-case key":  `{"op":"toggle","Id":"doc-audit","on":false}`,
		"duplicate op":    `{"op":"toggle","op":"reset"}`,
		"duplicate id":    `{"op":"toggle","id":"doc-audit","id":"skill-eval","on":false}`,
		"trailing brace":  `{"op":"reset"}}`,
		"trailing text":   `{"op":"reset"} x`,
		"trailing array":  `{"op":"reset"}[]`,
		"null body":       `null`,
	} {
		code, m := post(id, body)
		if code != 400 || !strings.Contains(fmt.Sprint(m["error"]), "bad request body") {
			t.Errorf("%s: %d %v, want 400 bad request body", name, code, m)
		}
		if treeDigest(t, root) != before {
			t.Errorf("%s: the project changed", name)
		}
	}
	// whitespace around a good body is fine
	if code, _ := post(id, " \n{\"op\":\"reset\"}\r\n "); code != 200 {
		t.Errorf("a well-formed body with surrounding whitespace = %d, want 200", code)
	}
}

// break-it (t-3a58): a file over 64 KB is refused by the reader, and Reset still repairs it (it is a regular file the page may rewrite).
func TestPipelineOversizeFileIsRepairedByReset(t *testing.T) {
	id, root := pipelineEnv(t)
	os.MkdirAll(filepath.Join(root, "canon-config"), 0o755)
	big := "extends: canon-default\n" + strings.Repeat("# padding padding padding padding padding\n", 3000)
	os.WriteFile(filepath.Join(root, "canon-config", "pipeline.yaml"), []byte(big), 0o644)
	_, g := pipelineGetReq(id)
	if g["ok"] != false || g["can_reset"] != true || !strings.Contains(fmt.Sprint(g["error"]), "over 65536 bytes") {
		t.Fatalf("GET with an oversize file = %v", g)
	}
	if code, _ := post(id, `{"op":"toggle","id":"skill-eval","on":false}`); code != 400 {
		t.Fatalf("toggle on an oversize file = %d, want 400", code)
	}
	if got := pipelineFileText(root); got != big {
		t.Fatal("a refused toggle changed the oversize file")
	}
	if code, m := post(id, `{"op":"reset"}`); code != 200 || m["ok"] != true {
		t.Fatalf("Reset on an oversize file = %d %v", code, m)
	}
	if got := pipelineFileText(root); got != "extends: canon-default\n" {
		t.Fatalf("file after Reset = %q", got)
	}
}

// break-it (t-3a58): a registered path that is empty or relative is not a project root: nothing is written relative to the board's cwd.
func TestPipelineRefusesARegisteredPathThatIsNotAbsolute(t *testing.T) {
	_, _ = pipelineEnv(t)
	cwd := t.TempDir()
	t.Chdir(cwd)
	os.MkdirAll(filepath.Join(cwd, "rel", "canon-config"), 0o755)   // a write relative to the cwd would succeed, so only the refusal keeps the tree still
	reg, _ := json.Marshal([]registryProject{{ID: "emptyempty01", Path: "", Name: "n"}, {ID: "relativerel02", Path: "rel", Name: "n"}})
	os.WriteFile(registryFile(), reg, 0o644)
	before := treeDigest(t, cwd)
	for _, p := range []string{"emptyempty01", "relativerel02"} {
		if code, _ := post(p, `{"op":"toggle","id":"skill-eval","on":false}`); code != 400 {
			t.Errorf("POST for registered path of %s = %d, want 400", p, code)
		}
		req := httptest.NewRequest(http.MethodGet, "/api/pipeline?project="+p, nil)
		req.Header.Set("Origin", pipelineOrigin)
		w := httptest.NewRecorder()
		handleGet(w, req)
		if w.Code != 400 {
			t.Errorf("GET for registered path of %s = %d, want 400", p, w.Code)
		}
	}
	if treeDigest(t, cwd) != before {
		t.Fatal("a request wrote relative to the board's working directory")
	}
}

// ── mutation sweep survivors (t-3a58): the response's every field, the helpers, the boundaries and the messages ──

func TestPipelineReplyCarriesEveryField(t *testing.T) {
	id, root := pipelineEnv(t)
	tiers := filepath.Join(t.TempDir(), "model-tiers.json")
	os.WriteFile(tiers, []byte(`{"defaults":{"eval":{"anthropic":"claude-sonnet-5"}},"models":{"anthropic":[{"id":"other","name":"Other"},{"id":"claude-sonnet-5","name":"Claude Sonnet 5"}]}}`), 0o644)
	old := modelTiersPath
	modelTiersPath = tiers
	defer func() { modelTiersPath = old }()
	_, g := pipelineGetReq(id)
	nodes := g["nodes"].([]any)
	by := map[string]map[string]any{}
	for _, n := range nodes {
		m := n.(map[string]any)
		by[m["id"].(string)] = m
	}
	sk := by["skill-eval"]
	if sk["kind"] != "gate" || sk["order"] != float64(60) || sk["on"] != true || sk["locked"] != false || sk["when"] != "a skill or gate agent changed (tools/skill-eval-scope.sh)" || sk["prompt"] != "skills/skill-eval/SKILL.md" {
		t.Fatalf("skill-eval = %v", sk)
	}
	if _, has := sk["group"]; has {
		t.Errorf("a node outside the group carries a group: %v", sk)
	}
	if _, has := sk["reason"]; has {
		t.Errorf("an open node carries a reason (the placeholder dash leaked): %v", sk)
	}
	if mt := fmt.Sprint(by["mutation-test"]["when"]); !strings.Contains(mt, "needs python3") {
		t.Errorf("mutation-test says nothing about python3: %q", mt)
	}
	st := by["start"]
	if st["locked"] != true || st["reason"] != "Always runs: every sprint starts with a ticket and a plan." {
		t.Fatalf("start = %v", st)
	}
	if _, has := st["when"]; has {
		t.Errorf("a node with no condition carries a when: %v", st)
	}
	if by["doc-audit"]["group"] != "wrapup" {
		t.Errorf("doc-audit group = %v", by["doc-audit"]["group"])
	}
	// the Admin default model is shown on reviewer and eval only, with its registry name and source
	for _, nid := range []string{"reviewer", "eval"} {
		m, _ := by[nid]["model"].(map[string]any)
		if m == nil || m["id"] != "claude-sonnet-5" || m["name"] != "Claude Sonnet 5" || m["source"] != "Admin > Model tiers > Review & Eval default" {
			t.Errorf("%s model = %v", nid, by[nid]["model"])
		}
	}
	for _, nid := range []string{"break-it", "start", "code-reviewer", "security-review", "mutation-test"} {
		if _, has := by[nid]["model"]; has {
			t.Errorf("%s shows a model", nid)
		}
	}
	// no Admin default: no model at all
	os.WriteFile(tiers, []byte(`{"defaults":{"eval":{}},"models":{"anthropic":[]}}`), 0o644)
	_, g = pipelineGetReq(id)
	for _, n := range g["nodes"].([]any) {
		if _, has := n.(map[string]any)["model"]; has {
			t.Fatalf("a model without an Admin default: %v", n)
		}
	}
	// a default whose id is not in the registry shows the id as its name
	os.WriteFile(tiers, []byte(`{"defaults":{"eval":{"anthropic":"claude-x"}},"models":{"anthropic":[]}}`), 0o644)
	_, g = pipelineGetReq(id)
	for _, n := range g["nodes"].([]any) {
		m := n.(map[string]any)
		if m["id"] == "reviewer" && m["model"].(map[string]any)["name"] != "claude-x" {
			t.Fatalf("model name fallback = %v", m["model"])
		}
	}
	if g["file"] != "canon-config/pipeline.yaml" || g["exists"] != false || g["can_reset"] != false || g["text"] != "" {
		t.Fatalf("view fields = %v", g)
	}
	// a file in place: text (CR removed), can_reset, exists
	os.MkdirAll(filepath.Join(root, "canon-config"), 0o755)
	os.WriteFile(filepath.Join(root, "canon-config", "pipeline.yaml"), []byte("extends: canon-default\r\noff: [skill-eval]\r\n"), 0o644)
	_, g = pipelineGetReq(id)
	if g["exists"] != true || g["can_reset"] != true || g["text"] != "extends: canon-default\noff: [skill-eval]\n" || g["changed"] != true {
		t.Fatalf("view with a CRLF file = %v", g)
	}
	// a folder with no file: not a file, not a problem
	os.Remove(filepath.Join(root, "canon-config", "pipeline.yaml"))
	_, g = pipelineGetReq(id)
	if g["ok"] != true || g["exists"] != false || g["can_reset"] != false {
		t.Fatalf("view with an empty canon-config = %v", g)
	}
}

func TestPipelineViewFlagsAProblemFileAsExistingOrNot(t *testing.T) {
	id, root := pipelineEnv(t)
	outside := t.TempDir()
	os.Symlink(outside, filepath.Join(root, "canon-config"))
	if _, g := pipelineGetReq(id); g["exists"] != false || g["can_reset"] != false || g["ok"] != false {
		t.Fatalf("symlinked folder view = %v", g)
	}
	os.Remove(filepath.Join(root, "canon-config"))
	os.Mkdir(filepath.Join(root, "canon-config"), 0o755)
	os.Mkdir(filepath.Join(root, "canon-config", "pipeline.yaml"), 0o755)
	if _, g := pipelineGetReq(id); g["exists"] != false || g["can_reset"] != false || g["ok"] != false || !strings.Contains(fmt.Sprint(g["error"]), "not a plain file") {
		t.Fatalf("folder-as-file view = %v", g)
	}
}

func TestPipelineFileSizeBoundary(t *testing.T) {
	id, root := pipelineEnv(t)
	os.MkdirAll(filepath.Join(root, "canon-config"), 0o755)
	file := filepath.Join(root, "canon-config", "pipeline.yaml")
	head := "extends: canon-default\n"
	pad := func(n int) string { // short comment lines (the reader refuses a line over 400 characters), n bytes in all
		b := head
		for len(b) < n {
			b += "#" + strings.Repeat("x", 60) + "\n"
		}
		return b[:n-1] + "\n"
	}
	os.WriteFile(file, []byte(pad(pipelineFileMax)), 0o644) // exactly 64 KB: read and accepted
	if _, g := pipelineGetReq(id); g["ok"] != true || len(fmt.Sprint(g["text"])) != pipelineFileMax {
		t.Fatalf("a 64 KB file = ok %v, text %d bytes", g["ok"], len(fmt.Sprint(g["text"])))
	}
	os.WriteFile(file, []byte(pad(pipelineFileMax+1)), 0o644) // one byte over: the reader refuses it by name, text is not read
	if _, g := pipelineGetReq(id); g["ok"] != false || g["text"] != "" || !strings.Contains(fmt.Sprint(g["error"]), "over 65536 bytes") {
		t.Fatalf("a 64 KB + 1 file = %v", g)
	}
}

func TestPipelineMessagesAndFlagsOfRefusals(t *testing.T) {
	id, root := pipelineEnv(t)
	for _, body := range []string{`{"op":"toggle","id":"eval","on":false}`, `{"op":"delete"}`, `bad`} {
		if code, m := post(id, body); code != 400 || m["ok"] != false {
			t.Errorf("%s: %d ok=%v, want a 400 with ok:false", body, code, m["ok"])
		}
	}
	for _, c := range []struct{ origin, want string }{{"", "forbidden"}, {"http://evil.example", "forbidden"}} {
		req := httptest.NewRequest(http.MethodPost, "/api/pipeline?project="+id, strings.NewReader(`{"op":"reset"}`))
		req.Header.Set("Content-Type", "application/json")
		if c.origin != "" {
			req.Header.Set("Origin", c.origin)
		}
		w := httptest.NewRecorder()
		handlePost(w, req)
		if w.Code != 403 || !strings.Contains(w.Body.String(), c.want) {
			t.Errorf("origin %q = %d %q", c.origin, w.Code, w.Body.String())
		}
	}
	if code, m := pipelinePostReq(id, pipelineOrigin, "text/plain", `{"op":"reset"}`); code != 415 || !strings.Contains(fmt.Sprint(m["error"]), "expected application/json") || m["ok"] != false {
		t.Errorf("wrong content type = %d %v", code, m)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/pipeline?project=ffffffffffff", strings.NewReader(`{"op":"reset"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", pipelineOrigin)
	w := httptest.NewRecorder()
	handlePost(w, req)
	if w.Code != 400 || !strings.Contains(w.Body.String(), "unknown project") {
		t.Errorf("unknown project = %d %q", w.Code, w.Body.String())
	}
	// the permutation refusal names the group in order
	post(id, `{"op":"toggle","id":"break-it","on":false}`)
	if code, m := post(id, `{"op":"order","wrapup":["doc-audit","code-reviewer","reviewer"]}`); code != 400 || fmt.Sprint(m["error"]) != "wrapup must list exactly: code-simplifier, code-reviewer, doc-audit" {
		t.Errorf("permutation refusal = %d %v", code, m)
	}
	_ = root
}

func TestPipelineOrderKeepsTheOffList(t *testing.T) {
	id, root := pipelineEnv(t)
	post(id, `{"op":"toggle","id":"skill-eval","on":false}`)
	post(id, `{"op":"toggle","id":"mutation-test","on":false}`)
	if code, _ := post(id, `{"op":"order","wrapup":["doc-audit","code-reviewer","code-simplifier"]}`); code != 200 {
		t.Fatal("order refused")
	}
	if got := pipelineFileText(root); got != "extends: canon-default\noff: [skill-eval, mutation-test]\nwrapup-order: [doc-audit, code-reviewer, code-simplifier]\n" {
		t.Fatalf("an order change dropped or reordered the off list: %q", got)
	}
	// a toggle keeps the wrapup order
	post(id, `{"op":"toggle","id":"mutation-test","on":true}`)
	if got := pipelineFileText(root); got != "extends: canon-default\noff: [skill-eval]\nwrapup-order: [doc-audit, code-reviewer, code-simplifier]\n" {
		t.Fatalf("a toggle dropped the wrapup order: %q", got)
	}
}

func TestPipelineNoOpOnAnExistingFileWritesNothing(t *testing.T) {
	id, root := pipelineEnv(t)
	post(id, `{"op":"toggle","id":"skill-eval","on":false}`)
	before := treeDigest(t, root)
	code, m := post(id, `{"op":"toggle","id":"skill-eval","on":false}`)
	if code != 200 || m["created"] != false || m["ok"] != true {
		t.Fatalf("a repeated toggle = %d %v", code, m)
	}
	if treeDigest(t, root) != before {
		t.Fatal("a repeated toggle rewrote the file or left a temp file")
	}
}

func TestPipelineEventRecordsOldAndNew(t *testing.T) {
	id, _ := pipelineEnv(t)
	post(id, `{"op":"toggle","id":"skill-eval","on":false}`)
	post(id, `{"op":"toggle","id":"mutation-test","on":false}`)
	post(id, `{"op":"reset"}`)
	var all string
	files, _ := filepath.Glob(filepath.Join(os.Getenv("CANON_HOME"), "events", "*.jsonl"))
	for _, f := range files {
		b, _ := os.ReadFile(f)
		all += string(b)
	}
	for _, want := range []string{`"old":"off=-"`, `"new":"off=skill-eval"`, `"old":"off=skill-eval"`, `"new":"off=skill-eval,mutation-test"`, `"name":"pipeline.reset"`, `"new":"off=-"`} {
		if !strings.Contains(all, want) {
			t.Errorf("the activity log lacks %s in %q", want, all)
		}
	}
	// the summary stays within the event field's 64 characters
	if got := pipelineSummary([]string{"code-simplifier", "code-reviewer", "doc-audit", "skill-eval", "break-it", "reviewer", "mutation-test"}); len(got) != 60 || !strings.HasPrefix(got, "off=code-simplifier,code-reviewer,doc-audit,skill-eval,break") {
		t.Errorf("summary = %q (%d)", got, len(got))
	}
	if pipelineSummary(nil) != "off=-" || pipelineSummary([]string{"a"}) != "off=a" {
		t.Error("summary of none or one")
	}
}

func TestPipelineHelpers(t *testing.T) {
	for in, want := range map[string]string{"plain": "plain", "a\x1bb": "a?b", "é": "?", "tab\t": "tab?", "~ !": "~ !", "\x7f": "?"} {
		if got := pipelineClean(in); got != want {
			t.Errorf("pipelineClean(%q) = %q, want %q", in, got, want)
		}
	}
	if got := pipelineClean(strings.Repeat("a", 400)); len(got) != 400 {
		t.Errorf("400 characters came back as %d", len(got))
	}
	if got := pipelineClean(strings.Repeat("a", 401)); len(got) != 400 {
		t.Errorf("401 characters came back as %d", len(got))
	}
	if !pipelineSame([]string{"a", "b"}, []string{"a", "b"}) || pipelineSame([]string{"a"}, []string{"a", "b"}) || pipelineSame([]string{"a", "b"}, []string{"a", "c"}) || pipelineSame([]string{"b"}, nil) || !pipelineSame(nil, []string{}) {
		t.Error("pipelineSame")
	}
	good := []string{`{}`, `{"op":"reset"}`, ` {"op":"toggle","id":"x","on":true}`, `{"op":"order","wrapup":["a","b"]}`, "{\"op\":\"reset\"}\n"}
	bad := []string{``, `{`, `{"op"`, `{"op":}`, `{"op":"reset"`, `{1:2}`, `{"op":"reset","x":1}`, `{"op":"reset","op":"reset"}`, `{"OP":"reset"}`, `[]`, `null`, `5`, `"x"`, `{"op":"reset"}}`, `{"op":"reset"}{}`, `{"op":"reset"} 1`, `{"op":"reset",}`, `{"op":"reset" "id":"x"}`}
	for _, b := range good {
		if !pipelineKeysExact([]byte(b)) {
			t.Errorf("pipelineKeysExact(%q) = false", b)
		}
	}
	for _, b := range bad {
		if pipelineKeysExact([]byte(b)) {
			t.Errorf("pipelineKeysExact(%q) = true", b)
		}
	}
}

// the reader's output is read line by line: CRLF is trimmed, the placeholder dash is no value, a short or hostile line is an error with its message
func TestPipelineReaderOutputIsParsedStrictly(t *testing.T) {
	id, _ := pipelineEnv(t)
	stub := filepath.Join(t.TempDir(), "stub.sh")
	run := func(script string) map[string]any {
		os.WriteFile(stub, []byte("#!/usr/bin/env bash\n"+script), 0o755)
		t.Setenv("PIPELINE_BIN", stub)
		_, g := pipelineGetReq(id)
		return g
	}
	g := run("printf '10\\tstart\\tstep\\ton\\tlocked\\t-\\t-\\t-\\tr\\r\\n20\\tx\\tgate\\toff\\topen\\twrapup\\t-\\t-\\t-\\r\\n'\n")
	nodes, _ := g["nodes"].([]any)
	if len(nodes) != 2 {
		t.Fatalf("CRLF lines = %v", g)
	}
	n0 := nodes[0].(map[string]any)
	if n0["reason"] != "r" || n0["locked"] != true {
		t.Errorf("a CRLF line kept its carriage return: %v", n0)
	}
	for _, k := range []string{"when", "prompt"} {
		if _, has := n0[k]; has {
			t.Errorf("the placeholder dash leaked into %s: %v", k, n0)
		}
	}
	if g := run("echo one\n"); g["ok"] != false || g["error"] != "pipeline: the reader printed a line this page cannot read" {
		t.Errorf("short line = %v", g)
	}
	if g := run("printf '10\\tstart\\tstep\\ton\\tlocked\\t-\\t-\\t-\\tr\\textra\\n'\n"); g["ok"] != false || g["error"] != "pipeline: the reader printed a line this page cannot read" {
		t.Errorf("ten fields = %v", g)
	}
	if g := run("printf 'ten\\tstart\\tstep\\ton\\tlocked\\t-\\t-\\t-\\tr\\n'\n"); g["ok"] != false || g["error"] != "pipeline: the reader printed a line this page cannot read" {
		t.Errorf("a non-numeric order = %v", g)
	}
	if g := run("printf ''\n"); g["ok"] != false || g["error"] != "pipeline: the reader printed no nodes" {
		t.Errorf("no output = %v", g)
	}
	// 200 lines are fine, 201 are refused
	many := func(n int) string {
		return "for i in $(seq 1 " + fmt.Sprint(n) + "); do printf '%s\\tn%s\\tstep\\ton\\topen\\t-\\t-\\t-\\t-\\n' \"$i\" \"x$i\"; done\n"
	}
	if g := run(many(200)); g["ok"] != true {
		t.Errorf("200 lines = %v", g)
	}
	if g := run(many(201)); g["ok"] != false {
		t.Errorf("201 lines were accepted")
	}
	// a reader that fails with no message still says so; with a message, its first line is shown
	if g := run("exit 3\n"); g["ok"] != false || !strings.HasPrefix(fmt.Sprint(g["error"]), "pipeline: the reader failed: ") {
		t.Errorf("a silent failure = %v", g)
	}
	if g := run("echo 'pipeline: first line' >&2; echo second >&2; exit 2\n"); g["error"] != "pipeline: first line" {
		t.Errorf("a refusal = %v", g)
	}
	// the default failing: no list can be judged against it, and a change is not made
	if g := run("case \"$*\" in *--project*) printf '10\\tstart\\tstep\\ton\\tlocked\\t-\\t-\\t-\\tr\\n';; *) echo 'pipeline: default is missing' >&2; exit 2;; esac\n"); g["ok"] != false || g["error"] != "pipeline: default is missing" {
		t.Errorf("a failing default = %v", g)
	}
	code, m := post(id, `{"op":"toggle","id":"start","on":false}`)
	if code != 500 || m["error"] != "pipeline: default is missing" {
		t.Errorf("a change with a failing default = %d %v", code, m)
	}
}

func TestPipelineLeavesNoScratchFolderOrTempFile(t *testing.T) {
	id, root := pipelineEnv(t)
	scratch := t.TempDir()
	t.Setenv("TMPDIR", scratch)
	post(id, `{"op":"toggle","id":"skill-eval","on":false}`)
	post(id, `{"op":"toggle","id":"skill-eval","on":true}`)
	if left, _ := filepath.Glob(filepath.Join(scratch, "canon-pipeline-*")); len(left) != 0 {
		t.Errorf("the scratch project was left behind: %v", left)
	}
	entries, _ := os.ReadDir(filepath.Join(root, "canon-config"))
	if len(entries) != 1 {
		t.Errorf("canon-config holds %v", entries)
	}
}

func TestPipelineWriteIntoAReadOnlyFolderIsRefusedCleanly(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes anywhere")
	}
	id, root := pipelineEnv(t)
	os.MkdirAll(filepath.Join(root, "canon-config"), 0o755)
	os.WriteFile(filepath.Join(root, "canon-config", "pipeline.yaml"), []byte("extends: canon-default\n"), 0o644)
	os.Chmod(filepath.Join(root, "canon-config"), 0o555)
	defer os.Chmod(filepath.Join(root, "canon-config"), 0o755)
	code, m := post(id, `{"op":"toggle","id":"skill-eval","on":false}`)
	if code != 409 || !strings.Contains(fmt.Sprint(m["error"]), "could not be written") {
		t.Fatalf("a read-only folder = %d %v", code, m)
	}
	if got := pipelineFileText(root); got != "extends: canon-default\n" {
		t.Fatalf("the file changed: %q", got)
	}
	// a project whose root cannot hold canon-config at all: the folder is not made
	os.Chmod(filepath.Join(root, "canon-config"), 0o755)
	os.RemoveAll(filepath.Join(root, "canon-config"))
	os.Chmod(root, 0o555)
	defer os.Chmod(root, 0o755)
	if code, m := post(id, `{"op":"toggle","id":"skill-eval","on":false}`); code != 409 || !strings.Contains(fmt.Sprint(m["error"]), "could not be created") {
		t.Fatalf("a root that cannot hold canon-config = %d %v", code, m)
	}
}
