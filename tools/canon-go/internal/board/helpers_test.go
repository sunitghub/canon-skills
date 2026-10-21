package board

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestMain pins CANON_HOME (t-f182): board code emits events into $CANON_HOME/events, and a test must never write the
// developer's own log (an unpinned run once left eleven fixture events in ~/.canon/events). A test that needs its own
// CANON_HOME or HOME still sets it with t.Setenv.
func TestMain(m *testing.M) {
	home, err := os.MkdirTemp("", "canon-home-")
	if err != nil {
		panic(err)
	}
	os.Setenv("CANON_HOME", home)
	os.Setenv("HOME", home) // and HOME: code that ignored CANON_HOME (a t-f182 sweep mutant did) would fall back to ~/.canon
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}

// Protects tools/sprint-headless and tools/sprint-headless-eval: they read this line with cut (t-b62a; the
// cases came from the retired tools/sprint-headless-json-go).
func TestFormatHeadlessResult(t *testing.T) {
	for _, tc := range []struct{ name, input, want string }{
		{"plain success", `{"is_error":false,"session_id":"abc-123","result":"hello"}`, "False\tabc-123\thello"},
		{"is_error missing reads True", `{"session_id":"abc-123","result":"hello"}`, "True\tabc-123\thello"},
		{"is_error null reads True", `{"is_error":null,"session_id":"s","result":"r"}`, "True\ts\tr"},
		{"session_id and result missing", `{"is_error":false}`, "False\tunknown\t"},
		{"quotes and backslashes", `{"is_error":true,"session_id":"s1","result":"line1\nline2 \"quoted\" back\\slash"}`, "True\ts1\tline1\x02line2 \"quoted\" back\\slash"},
		{"newlines as \\x02", `{"is_error":true,"session_id":"s1","result":"a\nb\nc"}`, "True\ts1\ta\x02b\x02c"},
		{"\\u escape decoded", `{"is_error":false,"session_id":"s1","result":"café"}`, "False\ts1\tcafé"},
		{"not JSON", `not json`, "PARSE_ERROR\t\t"},
		{"empty", ``, "PARSE_ERROR\t\t"},
		{"truncated", `{"is_error":false,"session_id":`, "PARSE_ERROR\t\t"},
		{"not an object", `[1,2]`, "PARSE_ERROR\t\t"},
	} {
		if got := formatHeadlessResult([]byte(tc.input)); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

// Protects sprint-headless-eval --allowed-tools-file.
func TestJSONStrings(t *testing.T) {
	dir := t.TempDir()
	for _, tc := range []struct {
		name, content, out, errText string
		code                        int
	}{
		{"list", `["Read", "Bash(git log:*)", "Grep"]`, "Read\nBash(git log:*)\nGrep\n", "", 0},
		{"empty list", `[]`, "", "", 0},
		{"bad JSON", `["Read",`, "", "invalid JSON in --allowed-tools-file", 2},
		{"object", `{"a":1}`, "", "must be a JSON array of strings", 2},
		{"non-string", `["Read", 3]`, "", "must be a JSON array of strings", 2},
		{"newline", `["Read", "a\nb"]`, "", "must not contain newlines", 2},
	} {
		f := filepath.Join(dir, tc.name+".json")
		os.WriteFile(f, []byte(tc.content), 0o644)
		var out, errb bytes.Buffer
		code := jsonStrings(f, &out, &errb)
		if code != tc.code || out.String() != tc.out || !strings.Contains(errb.String(), tc.errText) {
			t.Errorf("%s: code %d out %q err %q", tc.name, code, out.String(), errb.String())
		}
	}
}

// Protects `skills.sh add|remove sprint` (tools/skills/prompts.sh): the permission rules it writes into a
// user's .claude/settings.json, and that nothing else in that file changes (t-f01d).
func TestEditSettings(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	read := func(p string) string { b, _ := os.ReadFile(p); return string(b) }
	run := func(mode, p, key string, rules ...string) string {
		w, err := editSettings(mode, p, key, rules)
		if err != nil && w != "invalid" {
			t.Fatalf("%s %s: %v", mode, p, err)
		}
		return w
	}

	// add keeps key order, other keys' text (number literal, unicode, & in a rule) and the file's mode
	user := `{"model": "opus", "n": 1.50, "env": {"Z": "é & <x>"}, "permissions": {"ask": ["X"], "allow": ["Bash(a && b)"]}, "hooks": {}}`
	p := write("user.json", user)
	if w := run("add", p, "deny", "Bash(brew install:*)", "Bash(apt install:*)"); w != "ok" {
		t.Fatalf("add: %q", w)
	}
	want := `{
  "model": "opus",
  "n": 1.50,
  "env": {
    "Z": "é & <x>"
  },
  "permissions": {
    "ask": [
      "X"
    ],
    "allow": [
      "Bash(a && b)"
    ],
    "deny": [
      "Bash(brew install:*)",
      "Bash(apt install:*)"
    ]
  },
  "hooks": {}
}
`
	if got := read(p); got != want {
		t.Fatalf("add rewrote other keys:\n%s", got)
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o600 {
		t.Errorf("mode changed to %v", st.Mode().Perm())
	}
	if w := run("status", p, "deny", "Bash(brew install:*)", "Bash(apt install:*)"); w != "present" {
		t.Errorf("status after add: %q", w)
	}
	if w := run("status", p, "deny", "Bash(brew install:*)", "Bash(choco install:*)"); w != "absent" {
		t.Errorf("status with one missing: %q", w)
	}
	before := read(p)
	run("add", p, "deny", "Bash(brew install:*)")
	if read(p) != before {
		t.Error("adding a present rule changed the file")
	}

	// remove drops the rule, then an emptied list, then an emptied permissions; other keys stay
	p = write("rm.json", `{"a": 1, "permissions": {"allow": ["Bash(subagent-log.sh:*)", "Read"]}}`)
	run("remove", p, "allow", "Bash(subagent-log.sh:*)")
	if got := read(p); got != "{\n  \"a\": 1,\n  \"permissions\": {\n    \"allow\": [\n      \"Read\"\n    ]\n  }\n}\n" {
		t.Errorf("remove one: %s", got)
	}
	run("remove", p, "allow", "Read")
	if got := read(p); got != "{\n  \"a\": 1\n}\n" {
		t.Errorf("remove last: %s", got)
	}

	// a missing file: status absent, remove ok without creating it, add creates it
	missing := filepath.Join(dir, "missing.json")
	if run("status", missing, "allow", "R") != "absent" || run("remove", missing, "allow", "R") != "ok" {
		t.Error("missing file: wrong status/remove")
	}
	if _, err := os.Stat(missing); err == nil {
		t.Error("remove created a missing file")
	}
	if run("add", missing, "allow", "R") != "ok" || read(missing) != "{\n  \"permissions\": {\n    \"allow\": [\n      \"R\"\n    ]\n  }\n}\n" {
		t.Errorf("add to a missing file: %s", read(missing))
	}
	// no permissions key: status absent, remove ok and the file untouched
	p = write("noperm.json", `{"model":"x"}`)
	if run("status", p, "deny", "R") != "absent" || run("remove", p, "deny", "R") != "ok" || read(p) != `{"model":"x"}` {
		t.Error("no permissions: wrong result or file changed")
	}
	// a BOM (Windows PowerShell 5.1) is read and not written back
	p = write("bom.json", "\xef\xbb\xbf{\"permissions\":{\"allow\":[\"R\"]}}")
	if run("status", p, "allow", "R") != "present" {
		t.Error("BOM file: status")
	}
	run("add", p, "allow", "S")
	if strings.HasPrefix(read(p), "\xef\xbb\xbf") {
		t.Error("BOM written back")
	}

	// invalid shapes: reported, never written
	for name, content := range map[string]string{
		"notjson":   `{"permissions": `,
		"array":     `[1]`,
		"perms-str": `{"permissions": "x"}`,
		"list-obj":  `{"permissions": {"deny": {"a": 1}}}`,
		"list-null": `{"permissions": {"deny": null}}`,
		"trailing":  `{"a":1} {"b":2}`,
		"nan":       `{"a": NaN}`,
	} {
		p := write(name+".json", content)
		for _, mode := range []string{"status", "add", "remove"} {
			if w := run(mode, p, "deny", "R"); w != "invalid" {
				t.Errorf("%s %s: %q", name, mode, w)
			}
			if read(p) != content {
				t.Errorf("%s %s: file was written", name, mode)
			}
		}
	}

	// a symlinked settings file is refused, and neither the link nor its target changes
	target := write("target.json", `{"a":1}`)
	link := filepath.Join(dir, "link.json")
	if err := os.Symlink(target, link); err != nil {
		t.Skip("no symlinks here")
	}
	if w := run("add", link, "deny", "R"); w != "invalid" || read(target) != `{"a":1}` {
		t.Errorf("symlink: %q, target now %s", w, read(target))
	}
	if fi, _ := os.Lstat(link); fi.Mode()&os.ModeSymlink == 0 {
		t.Error("the link was replaced")
	}
	if leftovers, _ := filepath.Glob(filepath.Join(dir, ".*")); len(leftovers) > 0 {
		t.Errorf("temp files left: %v", leftovers)
	}
}

// The edge cases the t-b62a mutation sweep found untested: rule text kept literally, a list emptied beside another, the file's
// mode kept, and every error path reported without a write.
func TestEditSettingsEdges(t *testing.T) {
	dir := t.TempDir()
	read := func(p string) string { b, _ := os.ReadFile(p); return string(b) }

	// & < > in a rule are written as typed (json.Marshal would escape them as &…), and a 0640 file stays 0640
	p := filepath.Join(dir, "lit.json")
	os.WriteFile(p, []byte(`{}`), 0o640)
	if w, err := editSettings("add", p, "allow", []string{"Bash(a && b > c < d)"}); w != "ok" || err != nil {
		t.Fatalf("add: %q %v", w, err)
	}
	if !strings.Contains(read(p), `"Bash(a && b > c < d)"`) {
		t.Errorf("rule text escaped: %s", read(p))
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o640 {
		t.Errorf("mode 0640 became %v", st.Mode().Perm())
	}

	// removing the last allow rule keeps the deny list (and permissions)
	p = filepath.Join(dir, "both.json")
	os.WriteFile(p, []byte(`{"permissions": {"allow": ["R"], "deny": ["X"]}}`), 0o644)
	if w, _ := editSettings("remove", p, "allow", []string{"R"}); w != "ok" || read(p) != "{\n  \"permissions\": {\n    \"deny\": [\n      \"X\"\n    ]\n  }\n}\n" {
		t.Errorf("remove last allow beside deny: %q %s", w, read(p))
	}

	// errors: a bad list name; a directory, an unreadable file or a path under a file at the settings path; a read-only folder
	if w, err := editSettings("status", p, "ask", []string{"R"}); w != "" || err == nil {
		t.Errorf("bad list: %q %v", w, err)
	}
	sub := filepath.Join(dir, "adir")
	os.Mkdir(sub, 0o755)
	if w, _ := editSettings("add", sub, "deny", []string{"R"}); w != "invalid" {
		t.Errorf("a directory: %q", w)
	}
	if w, err := editSettings("add", filepath.Join(p, "x.json"), "deny", []string{"R"}); w != "" || err == nil {
		t.Errorf("a path under a regular file: %q %v", w, err)
	}
	if os.Geteuid() != 0 { // root reads and writes regardless of mode
		locked := filepath.Join(dir, "locked.json")
		os.WriteFile(locked, []byte(`{}`), 0o000)
		if w, err := editSettings("add", locked, "deny", []string{"R"}); w != "" || err == nil {
			t.Errorf("an unreadable file: %q %v", w, err)
		}
		ro := filepath.Join(dir, "ro")
		os.Mkdir(ro, 0o755)
		f := filepath.Join(ro, "settings.json")
		os.WriteFile(f, []byte(`{"a":1}`), 0o644)
		os.Chmod(ro, 0o555)
		defer os.Chmod(ro, 0o755)
		if w, err := editSettings("add", f, "deny", []string{"R"}); w != "" || err == nil || read(f) != `{"a":1}` {
			t.Errorf("a read-only folder: %q %v, file now %s", w, err, read(f))
		}
		if left, _ := os.ReadDir(ro); len(left) != 1 {
			t.Errorf("a failed write left files: %v", left)
		}
	}
}

// Protects the dispatch: a helper word never starts the board, and bad usage exits 2.
func TestRunHelperUsage(t *testing.T) {
	var out, errb bytes.Buffer
	if _, handled := runHelper([]string{"8423"}, nil, &out, &errb); handled {
		t.Error("a port number was taken as a helper")
	}
	for _, args := range [][]string{{"json-strings"}, {"settings", "add"}, {"skill-check"}} {
		if code, handled := runHelper(args, nil, &out, &errb); !handled || code != 2 {
			t.Errorf("%v: code %d handled %v", args, code, handled)
		}
	}
	if code, _ := runHelper([]string{"settings", "frob", "x.json", "deny", "R"}, nil, &out, &errb); code != 1 {
		t.Errorf("bad mode: code %d", code)
	}
}

// t-ff14: `sprint relay-report` relays a read-only gate's report from its harness transcript, byte for byte. Prod path: the
// close of a sprint whose gates ran on the Plan fallback.
func TestTranscriptReport(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, lines ...string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	run := func(path, prefix string) (string, int) {
		var out, errb bytes.Buffer
		code := transcriptReport(path, prefix, &out, &errb)
		return out.String(), code
	}
	long := strings.Repeat("x", 200000) // a transcript line can hold a whole tool result
	both := write("both.jsonl",
		`{"type":"user","message":{"content":"`+long+`"}}`,
		`not json`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"evaluator-run-id: 1-text\npass: from text"}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SubagentHandback","input":{"message":"Notes.\nevaluator-run-id: 2-handback\npass: from handback\n\n"}}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}`)
	if got, code := run(both, "evaluator-run-id:"); code != 0 || got != "evaluator-run-id: 2-handback\npass: from handback\n" {
		t.Fatalf("hand-back first, cut at the prefix, one trailing newline: %d %q", code, got)
	}
	textOnly := write("text.jsonl", `{"type":"assistant","message":{"content":[{"type":"text","text":"Intro\n# Review Notes\nYES"}]}}`)
	if got, code := run(textOnly, "# Review Notes"); code != 0 || got != "# Review Notes\nYES\n" {
		t.Fatalf("last text when there is no hand-back: %d %q", code, got)
	}
	// the prefix must start a line: mid-line text does not count, and no match prints nothing with exit 1
	mid := write("mid.jsonl", `{"type":"assistant","message":{"content":[{"type":"text","text":"see evaluator-run-id: 3"}]}}`)
	if got, code := run(mid, "evaluator-run-id:"); code != 1 || got != "" {
		t.Fatalf("a mid-line prefix relayed: %d %q", code, got)
	}
	if _, code := run(filepath.Join(dir, "missing.jsonl"), "x"); code != 1 {
		t.Fatalf("a missing transcript did not fail")
	}
}
