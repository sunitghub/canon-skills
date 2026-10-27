package settings

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// t-dba0. Protects every consumer of project settings: precedence default < shared < local with the source of each value, and a
// key the file does not know is kept when the file is rewritten.
func TestPrecedenceAndSources(t *testing.T) {
	root := t.TempDir()
	s := ProjectSet(root)
	r, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if v := r.Values["terminal.paging"]; v.V != "auto" || v.Source != SourceDefault {
		t.Fatalf("default: %+v", v)
	}
	write(t, s.Shared, `{"terminal":{"paging":"off"},"future":{"x":1}}`)
	if v, _ := s.Load(); v.Values["terminal.paging"].V != "off" || v.Values["terminal.paging"].Source != SourceShared {
		t.Fatalf("shared: %+v", v.Values["terminal.paging"])
	}
	write(t, s.Local, `{"terminal":{"paging":40,"other":"kept"},"mine":true}`)
	if v, _ := s.Load(); v.Values["terminal.paging"].V != 40 || v.Values["terminal.paging"].Source != SourceLocal {
		t.Fatalf("local: %+v", v.Values["terminal.paging"])
	}
	// a write keeps every key it does not own, and leaves the shared file alone
	sharedBefore := read(t, s.Shared)
	if _, err := s.SetLocal("terminal.paging", "off"); err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(read(t, s.Local)), &doc); err != nil {
		t.Fatal(err)
	}
	term := doc["terminal"].(map[string]any)
	if term["paging"] != "off" || term["other"] != "kept" || doc["mine"] != true {
		t.Fatalf("a write lost keys: %v", doc)
	}
	if read(t, s.Shared) != sharedBefore {
		t.Fatal("a write touched the shared file")
	}
}

// Protects the closed schema: only the three kinds of value a key accepts get in, with a message naming the key and the range.
func TestPagingValues(t *testing.T) {
	s := ProjectSet(t.TempDir())
	for _, ok := range []any{"auto", "off", float64(5), float64(500), 40, json.Number("25")} {
		if _, err := s.SetLocal("terminal.paging", ok); err != nil {
			t.Errorf("%v refused: %v", ok, err)
		}
	}
	for _, bad := range []any{float64(0), float64(4), float64(501), float64(-1), "on", "", "40", 1.5, nil, map[string]any{"a": 1}, []any{1}, true} {
		_, err := s.SetLocal("terminal.paging", bad)
		if err == nil {
			t.Errorf("%#v was accepted", bad)
		} else if !strings.Contains(err.Error(), "terminal.paging") || !strings.Contains(err.Error(), "500") {
			t.Errorf("%#v: the message should name the key and the range: %v", bad, err)
		}
	}
	if _, err := s.SetLocal("terminal.nope", "auto"); err == nil {
		t.Error("an unknown key was accepted")
	}
	if _, err := s.SetLocal("../../etc/passwd", "auto"); err == nil {
		t.Error("a path-like key was accepted")
	}
}

// Protects the user's file: a malformed, oversized, too deep or symlinked file is reported BY NAME on a read and a write is refused
// leaving it byte-identical: never reset, never silently ignored.
func TestMalformedFilesAreReportedNotReset(t *testing.T) {
	s := ProjectSet(t.TempDir())
	cases := map[string]string{
		"not json":        `{"terminal": `,
		"not an object":   `[1,2]`,
		"too large":       `{"pad":"` + strings.Repeat("x", MaxFileBytes) + `"}`,
		"too deep":        `{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"i":1}}}}}}}}}`,
		"a string number": `"hello"`,
	}
	for name, body := range cases {
		for _, which := range []string{"local", "shared"} {
			path := s.Local
			if which == "shared" {
				path = s.Shared
			}
			write(t, path, body)
			_, err := s.Load()
			var fe *FileError
			if !errors.As(err, &fe) || !strings.HasPrefix(fe.File, ".canon/settings") {
				t.Errorf("%s (%s): Load = %v, want a FileError naming the file", name, which, err)
			}
			if which == "local" {
				before := read(t, path)
				if _, err := s.SetLocal("terminal.paging", "off"); err == nil {
					t.Errorf("%s: a write over a malformed local file succeeded", name)
				}
				if read(t, path) != before {
					t.Errorf("%s: the malformed file was changed", name)
				}
			}
			os.Remove(path)
		}
	}
	// the message never carries an absolute path
	write(t, s.Local, `x`)
	if _, err := s.Load(); err == nil || strings.Contains(err.Error(), string(filepath.Separator)+"var") || filepath.IsAbs(strings.Fields(err.Error())[0]) {
		t.Errorf("the error leaks a path: %v", err)
	}
}

// Protects the user's other files: a symlinked .canon, settings file or exclude is refused, and nothing is written through it.
func TestSymlinksAreRefused(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	outside := t.TempDir()
	// .canon is a symlink to a folder outside the project
	root := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, ".canon")); err != nil {
		t.Fatal(err)
	}
	s := ProjectSet(root)
	if _, err := s.SetLocal("terminal.paging", "off"); err == nil {
		t.Error("a write through a symlinked .canon succeeded")
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Errorf("something was written outside the project: %v", entries)
	}
	// the file itself is a symlink to a precious file
	root2 := t.TempDir()
	precious := filepath.Join(outside, "precious")
	write(t, precious, `{"terminal":{"paging":"off"}}`) // valid settings: only the symlink check can refuse it
	s2 := ProjectSet(root2)
	if err := os.MkdirAll(filepath.Dir(s2.Local), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(precious, s2.Local); err != nil {
		t.Fatal(err)
	}
	if _, err := s2.SetLocal("terminal.paging", "off"); err == nil {
		t.Error("a write over a symlinked settings file succeeded")
	}
	if read(t, precious) != `{"terminal":{"paging":"off"}}` {
		t.Error("the symlink's target was changed")
	}
	if _, err := s2.Load(); err == nil {
		t.Error("a read of a symlinked settings file succeeded")
	}
}

// Protects the repo: only a key the schema marks Shareable can come from the shared (repo-controlled) file; an invalid value in
// either file is ignored with a warning, never fatal.
func TestSharedFileIsUntrusted(t *testing.T) {
	root := t.TempDir()
	s := Set{
		Schema: Schema{
			"ui.compact": {Validate: func(v any) (any, error) { return v, nil }, Shareable: true, Default: false},
			"run.command": {Validate: func(v any) (any, error) {
				if _, ok := v.(string); !ok {
					return nil, errors.New("must be text")
				}
				return v, nil
			}, Shareable: false, Default: ""},
		},
		Shared: filepath.Join(root, ".canon", "settings.json"),
		Local:  filepath.Join(root, ".canon", "settings.local.json"),
	}
	write(t, s.Shared, `{"ui":{"compact":true},"run":{"command":"rm -rf /"}}`)
	r, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if r.Values["run.command"].V != "" || r.Values["run.command"].Source != SourceDefault {
		t.Fatalf("a non-shareable key came from the shared file: %+v", r.Values["run.command"])
	}
	if r.Values["ui.compact"].V != true || r.Values["ui.compact"].Source != SourceShared {
		t.Fatalf("a shareable key did not: %+v", r.Values["ui.compact"])
	}
	if len(r.Warnings) != 1 || !strings.Contains(r.Warnings[0], "run.command") || !strings.Contains(r.Warnings[0], "shared") {
		t.Fatalf("warnings: %v", r.Warnings)
	}
	// the same key in the LOCAL file is honoured; an invalid value is ignored with a warning
	write(t, s.Local, `{"run":{"command":"make"}}`)
	if r, _ := s.Load(); r.Values["run.command"].V != "make" || r.Values["run.command"].Source != SourceLocal {
		t.Fatalf("local: %+v", r.Values["run.command"])
	}
	write(t, s.Local, `{"run":{"command":7}}`)
	r, _ = s.Load()
	if r.Values["run.command"].Source != SourceDefault || len(r.Warnings) < 2 {
		t.Fatalf("an invalid local value: %+v %v", r.Values["run.command"], r.Warnings)
	}
}

// Protects atomic, private writes: the file is 0600, no temp file is left, and the folder is created when missing.
func TestWriteIsAtomicAndPrivate(t *testing.T) {
	root := t.TempDir()
	s := ProjectSet(root)
	if _, err := s.SetLocal("terminal.paging", 30); err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" {
		if fi, _ := os.Stat(s.Local); fi.Mode().Perm() != 0o600 {
			t.Errorf("mode = %o, want 600", fi.Mode().Perm())
		}
	}
	entries, _ := os.ReadDir(filepath.Dir(s.Local))
	if len(entries) != 1 || entries[0].Name() != "settings.local.json" {
		t.Errorf("the folder holds %v, want only settings.local.json", entries)
	}
	// a second write replaces it whole
	if _, err := s.SetLocal("terminal.paging", "off"); err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(read(t, s.Local)), &doc); err != nil || doc["terminal"].(map[string]any)["paging"] != "off" {
		t.Fatalf("after the second write: %v %v", err, doc)
	}
}

// Protects `git status` and `canon update`: the local file is added to the repo's info/exclude ONCE, no tracked file changes, and a
// project without git needs nothing.
func TestIgnoreInGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
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
	s := ProjectSet(root)
	if _, err := s.SetLocal("terminal.paging", 20); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if err := IgnoreInGit(root, LocalRel); err != nil {
			t.Fatal(err)
		}
	}
	ex := read(t, filepath.Join(root, ".git", "info", "exclude"))
	if n := strings.Count(ex, LocalRel); n != 1 {
		t.Fatalf("exclude holds the line %d times:\n%s", n, ex)
	}
	if st := run("status", "--porcelain"); strings.TrimSpace(st) != "" {
		t.Fatalf("git status is not clean after a write:\n%s", st)
	}
	// no git at all: nothing happens and nothing fails
	if err := IgnoreInGit(t.TempDir(), LocalRel); err != nil {
		t.Errorf("a folder without git failed: %v", err)
	}
	// a symlinked exclude is refused
	if runtime.GOOS != "windows" {
		root2 := t.TempDir()
		cmd := exec.Command("git", "-C", root2, "init", "-q")
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v %s", err, out)
		}
		precious := filepath.Join(t.TempDir(), "precious")
		write(t, precious, "keep me")
		ex2 := filepath.Join(root2, ".git", "info", "exclude")
		os.Remove(ex2)
		if err := os.Symlink(precious, ex2); err != nil {
			t.Fatal(err)
		}
		if err := IgnoreInGit(root2, LocalRel); err == nil {
			t.Error("a symlinked exclude was edited")
		}
		if read(t, precious) != "keep me" {
			t.Error("the symlink's target was changed")
		}
	}
}

// Protects t-3137: the package works for an install-wide file, with one file and its own schema (no project folder, no git).
func TestInstallStyleSetWithOneFile(t *testing.T) {
	dir := t.TempDir()
	s := Set{
		Schema: Schema{"log.keep_days": {Validate: func(v any) (any, error) {
			f, ok := v.(float64)
			if !ok || (f != 30 && f != 90 && f != 365) {
				return nil, errors.New("must be 30, 90 or 365")
			}
			return int(f), nil
		}, Default: 30}},
		Local: filepath.Join(dir, "settings.json"),
	}
	if r, err := s.Load(); err != nil || r.Values["log.keep_days"].V != 30 || r.Values["log.keep_days"].Source != SourceDefault {
		t.Fatalf("default: %v %+v", err, r)
	}
	if _, err := s.SetLocal("log.keep_days", float64(90)); err != nil {
		t.Fatal(err)
	}
	if r, _ := s.Load(); r.Values["log.keep_days"].V != 90 {
		t.Fatalf("after set: %+v", r.Values["log.keep_days"])
	}
	if _, err := s.SetLocal("log.keep_days", float64(7)); err == nil {
		t.Error("a value outside the install schema was accepted")
	}
}

// t-dba0 (from the mutation sweep). Protects what a person reads when a file cannot be used: each failure says WHY, in its own words.
func TestFailureReasonsAreSaid(t *testing.T) {
	root := t.TempDir()
	s := ProjectSet(root)
	for want, body := range map[string]string{
		"is not valid JSON":    `{"terminal": `,
		"is not a JSON object": `[1]`,
		"larger than 64 KB":    `{"pad":"` + strings.Repeat("x", MaxFileBytes) + `"}`,
		"nested deeper than 8": `{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"i":1}}}}}}}}}`,
	} {
		write(t, s.Local, body)
		_, err := s.Load()
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("want a reason containing %q, got %v", want, err)
		}
	}
	if runtime.GOOS != "windows" {
		os.Remove(s.Local)
		target := filepath.Join(t.TempDir(), "t.json")
		write(t, target, `{}`)
		if err := os.Symlink(target, s.Local); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Load(); err == nil || !strings.Contains(err.Error(), "symlink") {
			t.Errorf("a symlink should say so: %v", err)
		}
		os.Remove(s.Local)
		if err := os.MkdirAll(s.Local, 0o755); err != nil { // a folder where the file should be
			t.Fatal(err)
		}
		if _, err := s.Load(); err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Errorf("a folder should say it is not a regular file: %v", err)
		}
	}
}

// Protects the caps at their edges: exactly 64 KB and exactly 8 levels are fine, one more is not.
func TestCapsAtTheirEdges(t *testing.T) {
	s := ProjectSet(t.TempDir())
	pad := func(n int) string { // a valid JSON object of exactly n bytes
		base := `{"p":""}`
		return `{"p":"` + strings.Repeat("x", n-len(base)) + `"}`
	}
	write(t, s.Local, pad(MaxFileBytes))
	if _, err := s.Load(); err != nil {
		t.Errorf("exactly %d bytes must load: %v", MaxFileBytes, err)
	}
	write(t, s.Local, pad(MaxFileBytes+1))
	if _, err := s.Load(); err == nil {
		t.Errorf("%d bytes must be refused", MaxFileBytes+1)
	}
	eight := `{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":1}}}}}}}}` // 8 levels of object
	write(t, s.Local, eight)
	if _, err := s.Load(); err != nil {
		t.Errorf("8 levels must load: %v", err)
	}
	write(t, s.Local, `{"a":`+eight+`}`)
	if _, err := s.Load(); err == nil {
		t.Error("9 levels must be refused")
	}
}

// Protects the names a reader (the board, a test, a plugin) compares against, and the range at both ends for every number type.
func TestSourceNamesAndRangeEdges(t *testing.T) {
	if SourceDefault != "default" || SourceShared != "shared" || SourceLocal != "local" {
		t.Errorf("source names changed: %q %q %q", SourceDefault, SourceShared, SourceLocal)
	}
	k := ProjectSet("").Schema["terminal.paging"]
	for _, ok := range []any{float64(5), float64(500), 5, 500, json.Number("5"), json.Number("500")} {
		if _, err := k.Validate(ok); err != nil {
			t.Errorf("%#v refused: %v", ok, err)
		}
	}
	for _, bad := range []any{float64(4), float64(501), 4, 501, json.Number("4"), json.Number("501"), json.Number("x"), json.Number("5.5")} {
		if _, err := k.Validate(bad); err == nil {
			t.Errorf("%#v accepted", bad)
		}
	}
}

// Protects the user's file when its shape is not what a write expects, and a set with no local file.
func TestWriteRefusals(t *testing.T) {
	s := ProjectSet(t.TempDir())
	write(t, s.Local, `{"terminal":"not an object"}`)
	before := read(t, s.Local)
	if _, err := s.SetLocal("terminal.paging", "off"); err == nil || !strings.Contains(err.Error(), "not an object") {
		t.Errorf("a non-object parent: %v", err)
	}
	if read(t, s.Local) != before {
		t.Error("the file was changed")
	}
	if _, err := (Set{Schema: s.Schema}).SetLocal("terminal.paging", "off"); err == nil || !strings.Contains(err.Error(), "no local settings file") {
		t.Errorf("a set with no local file: %v", err)
	}
	if runtime.GOOS != "windows" && os.Getuid() != 0 { // a folder that cannot be written to: nothing half-written is left
		root := t.TempDir()
		s2 := ProjectSet(root)
		if err := os.MkdirAll(filepath.Dir(s2.Local), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(filepath.Dir(s2.Local), 0o500); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(filepath.Dir(s2.Local), 0o755)
		if _, err := s2.SetLocal("terminal.paging", "off"); err == nil || !strings.Contains(err.Error(), "cannot write") {
			t.Errorf("a read-only folder: %v", err)
		}
		os.Chmod(filepath.Dir(s2.Local), 0o755)
		if entries, _ := os.ReadDir(filepath.Dir(s2.Local)); len(entries) != 0 {
			t.Errorf("a failed write left %v", entries)
		}
	}
}

// Protects the exclude file's own text: an existing file without a final newline gets the line on its own line, unrelated lines stay,
// and a symlinked exclude says so.
func TestIgnoreInGitKeepsTheExistingFile(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	root := t.TempDir()
	cmd := exec.Command("git", "-C", root, "init", "-q")
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	ex := filepath.Join(root, ".git", "info", "exclude")
	write(t, ex, "# mine\n*.log") // no final newline
	if err := IgnoreInGit(root, LocalRel); err != nil {
		t.Fatal(err)
	}
	if got := read(t, ex); got != "# mine\n*.log\n"+LocalRel+"\n" {
		t.Errorf("exclude = %q", got)
	}
	if err := IgnoreInGit(root, LocalRel); err != nil || read(t, ex) != "# mine\n*.log\n"+LocalRel+"\n" {
		t.Errorf("a second call changed the file: %v %q", err, read(t, ex))
	}
	if runtime.GOOS != "windows" {
		os.Remove(ex)
		target := filepath.Join(t.TempDir(), "x")
		write(t, target, "")
		if err := os.Symlink(target, ex); err != nil {
			t.Fatal(err)
		}
		if err := IgnoreInGit(root, LocalRel); err == nil || !strings.Contains(err.Error(), "symlink") {
			t.Errorf("a symlinked exclude: %v", err)
		}
	}
}

// t-dba0 (second sweep). Protects the edges of reading and writing: an empty or whitespace-only file is "no settings", an unreadable
// file or folder is said, a symlinked folder says so on a write, the file is written indented, and an empty exclude file gets the line
// with no blank line before it.
func TestReadAndWriteEdges(t *testing.T) {
	s := ProjectSet(t.TempDir())
	for _, body := range []string{"", "  \n\t\n"} {
		write(t, s.Local, body)
		if r, err := s.Load(); err != nil || r.Values["terminal.paging"].Source != SourceDefault {
			t.Errorf("%q: %v %+v", body, err, r)
		}
	}
	if _, err := s.SetLocal("terminal.paging", 30); err != nil {
		t.Fatal(err)
	}
	if got := read(t, s.Local); !strings.Contains(got, "\n  \"terminal\": {\n    \"paging\": 30\n  }\n}") {
		t.Errorf("the file is not written as indented JSON: %q", got)
	}
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		return
	}
	// unreadable file, and an unreadable folder: each says it cannot be read, naming the file
	if err := os.Chmod(s.Local, 0o000); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Load(); err == nil || !strings.Contains(err.Error(), "cannot be read") {
		t.Errorf("an unreadable file: %v", err)
	}
	os.Chmod(s.Local, 0o600)
	dir := filepath.Dir(s.Local)
	if err := os.Chmod(dir, 0o000); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o755)
	if _, err := s.Load(); err == nil || !strings.Contains(err.Error(), "cannot be read") {
		t.Errorf("an unreadable folder: %v", err)
	}
	os.Chmod(dir, 0o755)
	// a symlinked folder says so on a write
	root := t.TempDir()
	if err := os.Symlink(t.TempDir(), filepath.Join(root, ".canon")); err != nil {
		t.Fatal(err)
	}
	if _, err := ProjectSet(root).SetLocal("terminal.paging", "off"); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Errorf("a symlinked folder: %v", err)
	}
}

func TestIgnoreInGitOnAnEmptyExclude(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	root := t.TempDir()
	cmd := exec.Command("git", "-C", root, "init", "-q")
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	ex := filepath.Join(root, ".git", "info", "exclude")
	write(t, ex, "")
	if err := IgnoreInGit(root, LocalRel); err != nil {
		t.Fatal(err)
	}
	if got := read(t, ex); got != LocalRel+"\n" {
		t.Errorf("an empty exclude file became %q", got)
	}
	write(t, ex, "keep\n") // already ends with a newline: no blank line either
	if err := IgnoreInGit(root, LocalRel); err != nil || read(t, ex) != "keep\n"+LocalRel+"\n" {
		t.Errorf("%v %q", err, read(t, ex))
	}
}

// t-dba0 (reviewer round). Protects the user's file: a change that would leave it over 64 KB is refused before anything is written,
// keys this package does not own keep their digits and characters, trailing data is invalid JSON, arrays count as depth, and a missing
// project folder is not recreated by a write.
func TestReviewerFixes(t *testing.T) {
	s := ProjectSet(t.TempDir())
	big := `{"pad":"` + strings.Repeat("x", MaxFileBytes-20) + `"}`
	write(t, s.Local, big)
	before := read(t, s.Local)
	if _, err := s.SetLocal("terminal.paging", "off"); err == nil || !strings.Contains(err.Error(), "larger than 64 KB") {
		t.Errorf("a write past the cap: %v", err)
	}
	if read(t, s.Local) != before {
		t.Error("the file changed although the write was refused")
	}
	write(t, s.Local, `{"n":12345678901234567890,"f":1.0,"s":"a<b&c"}`)
	if _, err := s.SetLocal("terminal.paging", 30); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"12345678901234567890", "1.0", "a<b&c"} {
		if !strings.Contains(read(t, s.Local), want) {
			t.Errorf("%q was rewritten: %s", want, read(t, s.Local))
		}
	}
	write(t, s.Local, `{} {}`)
	if _, err := s.Load(); err == nil || !strings.Contains(err.Error(), "not valid JSON") {
		t.Errorf("trailing data: %v", err)
	}
	write(t, s.Local, `{"a":[[[[[[[[[1]]]]]]]]]}`)
	if _, err := s.Load(); err == nil || !strings.Contains(err.Error(), "deeper than 8") {
		t.Errorf("arrays must count as depth: %v", err)
	}
	gone := filepath.Join(t.TempDir(), "gone")
	if _, err := ProjectSet(gone).SetLocal("terminal.paging", "off"); err == nil {
		t.Error("a write for a missing project folder succeeded")
	}
	if _, err := os.Stat(gone); err == nil {
		t.Error("the missing project folder was recreated")
	}
}

// Protects `git status` for a project below the repository's top, and a project that is not in a repository at all.
func TestIgnoreInGitBelowTheTop(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	top := t.TempDir()
	git := func(dir string, args ...string) string {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
		return string(out)
	}
	git(top, "init", "-q")
	sub := filepath.Join(top, "sub")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(sub, LocalRel), `{}`)
	if err := IgnoreInGit(sub, LocalRel); err != nil {
		t.Fatal(err)
	}
	if st := git(top, "status", "--porcelain", "-uall"); strings.TrimSpace(st) != "" {
		t.Errorf("git status shows the file:\n%s", st)
	}
	if err := IgnoreInGit(t.TempDir(), LocalRel); err != nil { // not a repository: nothing is written anywhere
		t.Errorf("a non-repository: %v", err)
	}
}

// Protects the write cap at its exact edge: a result of exactly 64 KB is written, one byte more is refused.
func TestWriteCapEdge(t *testing.T) {
	s := ProjectSet(t.TempDir())
	pad := func(n int) { write(t, s.Local, `{"pad":"`+strings.Repeat("x", n)+`"}`) }
	const p0 = 1000
	pad(p0)
	if _, err := s.SetLocal("terminal.paging", "off"); err != nil {
		t.Fatal(err)
	}
	l0 := len(read(t, s.Local)) // what a write makes of a file with a pad of p0 bytes
	pad(p0 + MaxFileBytes - l0)
	if _, err := s.SetLocal("terminal.paging", "off"); err != nil {
		t.Fatalf("a result of exactly the cap: %v", err)
	}
	if n := len(read(t, s.Local)); n != MaxFileBytes {
		t.Fatalf("wrote %d bytes, want exactly %d", n, MaxFileBytes)
	}
	if got := read(t, s.Local); !strings.HasSuffix(got, "}\n") {
		t.Errorf("the file must end with one newline, not %q", got[len(got)-4:])
	}
	pad(p0 + MaxFileBytes - l0 + 1)
	if _, err := s.SetLocal("terminal.paging", "off"); err == nil {
		t.Error("a result one byte over the cap was written")
	}
}
