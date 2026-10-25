package term

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Protects the size and binary limits at their edges: exactly 1 MB is shown, one byte more is not; only the first 8000
// bytes are scanned for a NUL, and a NUL there is a binary file.
func TestReadFileEdges(t *testing.T) {
	root, _ := project(t)
	write := func(name string, b []byte) {
		if err := os.WriteFile(filepath.Join(root, name), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("exact.txt", bytes.Repeat([]byte("x"), maxFile))
	if _, _, err := readFile(root, "exact.txt"); err != nil {
		t.Errorf("a file of exactly 1 MB should be shown: %v", err)
	}
	late := bytes.Repeat([]byte("y"), 9000)
	late[8500] = 0
	write("late-nul.txt", late)
	if _, _, err := readFile(root, "late-nul.txt"); err != nil {
		t.Errorf("only the first 8000 bytes are scanned for a NUL: %v", err)
	}
	early := bytes.Repeat([]byte("y"), 9000)
	early[7999] = 0
	write("early-nul.txt", early)
	if _, _, err := readFile(root, "early-nul.txt"); err == nil || !strings.Contains(err.Error(), "binary") {
		t.Errorf("a NUL at byte 7999 should be binary: %v", err)
	}
	if _, _, err := readFile(filepath.Join(root, "nowhere"), "a.go"); err == nil || !strings.Contains(err.Error(), "not readable") {
		t.Errorf("a missing project folder should say so: %v", err)
	}
}

// Protects Visible at every edge: space and printable text stay, each control range is replaced by its own symbol.
func TestVisibleEdges(t *testing.T) {
	for in, want := range map[string]string{
		"a b":          "a b",          // 0x20 stays
		"\x7f":         "\u2421",       // DEL
		"\u0080":       "\uFFFD",       // first C1
		"\u009f":       "\uFFFD",       // last C1
		"\u00a0":       "\u00a0",       // no-break space is printable
		"\u00e9\u4e2d": "\u00e9\u4e2d", // text in other scripts is untouched
		"\x00\x1f":     "\u2400\u241f",
	} {
		if got := Visible(in); got != want {
			t.Errorf("Visible(%q) = %q, want %q", in, got, want)
		}
	}
}

// Protects the prompt's own output exactly: ls order and edge cases, cat usage, a missing trailing newline, several files
// with a refused one in the middle, CRLF files, and tkt (default binary, working folder, a missing binary, a failing one).
func TestPromptDetails(t *testing.T) {
	root, _ := project(t)
	w := func(name, s string) {
		if err := os.WriteFile(filepath.Join(root, name), []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	w("zz.zzz", "no newline at the end") // an unknown type stays plain
	w("crlf.zzz", "one\r\ntwo\r\n")
	w("plain.zzz", "line\n")
	if err := os.MkdirAll(filepath.Join(root, "order"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"b.txt", "a.txt", "c.txt"} {
		w(filepath.Join("order", n), "")
	}
	out := run(t, Config{Root: root}, "  ls order  \nls order/a.txt\nls .git\nls a b\nls -x\nls nope\ncat\ncat -n x\ncat zz.zzz\ncat plain.zzz\ncat .env plain.zzz\ncat crlf.zzz\n|cat\nls ~x\nexit\n")
	for _, want := range []string{
		"$ ",
		"-rw-r--r--", // the long form, with the mode first
		"  c.txt\n",
		"ls: the .git folder is never shown",
		"usage: ls [path]",
		"ls: no such file or directory",
		"usage: cat <file>...",
		"no newline at the end\n$ ", // a newline is added when missing, once
		"line\n$ ",                  // and not doubled when present
		"cat: .env files are never shown\nline\n",
		"one\ntwo\n", // CRLF shown as plain lines
		"not supported here (no shell): |",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	if a, b, c := strings.Index(out, "  a.txt\n"), strings.Index(out, "  b.txt\n"), strings.Index(out, "  c.txt\n"); !(a >= 0 && a < b && b < c) {
		t.Errorf("ls order should list a.txt, b.txt, c.txt:\n%s", out)
	}
	if strings.Contains(out, "\u240d") {
		t.Errorf("a CRLF file shows a symbol on every line:\n%s", out)
	}
}

func TestTktCommand(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script stand-in")
	}
	root, _ := project(t)
	bindir := t.TempDir()
	fake := filepath.Join(bindir, "tkt")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\npwd -P\necho \"args:$*\"\n[ \"$1\" = fail ] && exit 3\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Default binary: found on PATH, run in the project folder.
	t.Setenv("PATH", bindir+string(os.PathListSeparator)+os.Getenv("PATH"))
	rootReal, _ := filepath.EvalSymlinks(root)
	out := run(t, Config{Root: root}, "tkt ls --status=open\nexit\n")
	if !strings.Contains(out, rootReal) || !strings.Contains(out, "args:ls --status=open") {
		t.Errorf("tkt should run from the project folder with its arguments:\n%s", out)
	}
	// A bare "tkt" explains what is allowed.
	if out := run(t, Config{Root: root}, "tkt\nexit\n"); !strings.Contains(out, "usage: tkt <command>   read-only here: current, github-doctor, github-status, ls, show, why") {
		t.Errorf("bare tkt:\n%s", out)
	}
	// A tkt that exits non-zero adds nothing of its own; a missing one says so.
	if out := run(t, Config{Root: root, Tkt: fake}, "tkt ls\nexit\n"); strings.Contains(out, "tkt:") {
		t.Errorf("a normal exit should add no message:\n%s", out)
	}
	if out := run(t, Config{Root: root, Tkt: filepath.Join(bindir, "missing")}, "tkt ls\nexit\n"); !strings.Contains(out, "tkt: ") {
		t.Errorf("a missing tkt should say so:\n%s", out)
	}
}

// Protects the allowlist from testing itself: the list is written out here, not read back from the code.
func TestReadOnlyTktIsExactlyThis(t *testing.T) {
	want := "current github-doctor github-status ls show why"
	if got := strings.Join(ReadOnlyTkt(), " "); got != want {
		t.Errorf("read-only tkt = %q, want %q", got, want)
	}
}

// Protects su's defaults and its order of events: a missing limit means ten minutes, a bad warning means thirty seconds,
// the countdown message names the time, the shell has really returned before su_expired and the prompt message, and a
// Config with no event writer still works.
func TestSuDefaultsAndOrder(t *testing.T) {
	root, _ := project(t)
	f := newFakeSu()
	cfg := f.cfg(root)
	cfg.Limit, cfg.Warn = 0, 0
	shellDone := make(chan struct{})
	cfg.RunShell = func(ctx context.Context, root string) error {
		f.started <- struct{}{}
		<-ctx.Done()
		time.Sleep(60 * time.Millisecond)
		close(shellDone)
		return nil
	}
	out := &safeBuf{}
	pr, pw := newPipe()
	cfg.In, cfg.Out = pr, out
	done := make(chan int, 1)
	go func() { done <- Run(cfg) }()
	pw.WriteString("su\n")
	<-f.started
	waitFor(t, func() bool { f.mu.Lock(); defer f.mu.Unlock(); return len(f.chans) == 2 })
	if f.waits[0] != 9*time.Minute+30*time.Second || f.waits[1] != 10*time.Minute {
		t.Fatalf("defaults: timers %v, want 9m30s and 10m", f.waits)
	}
	if !strings.Contains(out.String(), "Full shell mode lasts 10m0s") {
		t.Errorf("the countdown message is missing:\n%s", out.String())
	}
	f.chans[1] <- time.Now()
	waitFor(t, func() bool { return strings.Contains(out.String(), "time is up") })
	select {
	case <-shellDone:
	default:
		t.Error("su reported the end before the shell had returned")
	}
	if strings.Contains(f.log(), "BADFIELDS") || !strings.HasSuffix(f.log(), "terminal.su_expired how=ended") {
		t.Errorf("events %q", f.log())
	}
	pw.WriteString("exit\n")
	<-done
	// A warning at or past the limit is replaced by the default; no event writer is fine.
	g := newFakeSu()
	close(g.stop)
	c2 := g.cfg(root)
	c2.Emit = nil
	c2.Limit, c2.Warn = time.Minute, time.Minute
	out2 := run(t, c2, "su\nexit\n")
	if g.waits[0] != 30*time.Second || !strings.Contains(out2, "Back in the restricted prompt.") {
		t.Errorf("a warning at the limit should become 30s; timers %v\n%s", g.waits, out2)
	}
}

// Protects the real clock path: with the default timer, a 300 ms limit ends the shell and says so.
func TestSuRealTimer(t *testing.T) {
	root, _ := project(t)
	f := newFakeSu()
	cfg := f.cfg(root)
	cfg.After = nil
	cfg.Limit, cfg.Warn = 300*time.Millisecond, 100*time.Millisecond
	out := run(t, cfg, "su\nexit\n")
	if !strings.Contains(out, "ends in") || !strings.Contains(out, "time is up") {
		t.Errorf("the real timers should warn and end:\n%s", out)
	}
	if !strings.HasSuffix(f.log(), "terminal.su_expired how=ended") {
		t.Errorf("events %q", f.log())
	}
}

// Protects the three tries: a failed OS prompt can be retried; the third failure in all, across every su, closes the
// terminal (exit status 1, logged as "locked"), and the commands after it never run; a pass starts the count again; a
// machine with no OS prompt never counts.
func TestSuThreeTriesThenTheTerminalCloses(t *testing.T) {
	root, _ := project(t)
	no := errors.New("Authentication failed")
	mk := func(auth ...error) (*fakeSu, Config, *safeBuf) {
		f := newFakeSu()
		close(f.stop)
		f.auth = auth
		return f, f.cfg(root), &safeBuf{}
	}
	runCode := func(cfg Config, out *safeBuf, input string) int {
		cfg.In, cfg.Out = strings.NewReader(input), out
		return Run(cfg)
	}
	// Two failures, then a pass: the shell starts.
	f, cfg, out := mk(no, no, nil)
	if code := runCode(cfg, out, "su\nsu\nsu\nexit\n"); code != 0 {
		t.Errorf("exit status %d", code)
	}
	if want := "terminal.su_prompted|terminal.su_denied reason=auth|terminal.su_prompted|terminal.su_denied reason=auth|terminal.su_prompted|terminal.su_granted minutes=5|terminal.su_expired how=exited"; f.log() != want {
		t.Errorf("events:\n got %s\nwant %s", f.log(), want)
	}
	if f.shells != 1 {
		t.Errorf("shells=%d\n%s", f.shells, out.String())
	}
	// Three failures close the terminal; nothing after them runs.
	f, cfg, out = mk(no, no, no)
	if code := runCode(cfg, out, "su\nsu\nsu\nls\nsu\n"); code != 1 {
		t.Errorf("a closed terminal should exit 1, got %d", code)
	}
	if want := "terminal.su_prompted|terminal.su_denied reason=auth|terminal.su_prompted|terminal.su_denied reason=auth|terminal.su_prompted|terminal.su_denied reason=locked"; f.log() != want {
		t.Errorf("events:\n got %s\nwant %s", f.log(), want)
	}
	if f.shells != 0 || strings.Contains(out.String(), "a.go") || !strings.Contains(out.String(), "Authentication failed 3 times: closing the terminal.") {
		t.Errorf("shells=%d\n%s", f.shells, out.String())
	}
	// A pass starts the count again: two failures, a pass, two failures do not close it.
	f, cfg, out = mk(no, no, nil, no, no)
	if code := runCode(cfg, out, "su\nsu\nsu\nsu\nsu\nexit\n"); code != 0 || f.shells != 1 {
		t.Errorf("a pass should reset the count: code=%d shells=%d\n%s", code, f.shells, out.String())
	}
	// No OS prompt on the machine never counts, however often it is tried.
	f, cfg, out = mk(ErrNoAuth, ErrNoAuth, ErrNoAuth, ErrNoAuth, ErrNoAuth)
	if code := runCode(cfg, out, "su\nsu\nsu\nsu\nsu\nls\n"); code != 0 || f.shells != 0 || !strings.Contains(out.String(), "a.go") {
		t.Errorf("an unavailable su must not close the terminal: code=%d shells=%d\n%s", code, f.shells, out.String())
	}
}

// A project inside a folder named like a secret (".envs") is still readable by absolute path: only names inside the
// project are refused.
func TestAbsolutePathUnderADotEnvParent(t *testing.T) {
	base := filepath.Join(t.TempDir(), ".envs", "proj")
	if err := os.MkdirAll(base, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(base, "a.zzz"), []byte("ok\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := readFile(base, filepath.Join(base, "a.zzz")); err != nil {
		t.Errorf("an absolute path under a .envs parent should be readable: %v", err)
	}
	if _, _, err := readFile(base, "a.zzz"); err != nil {
		t.Errorf("a relative path should be readable: %v", err)
	}
}

// Protects the terminal from ticket text: what tkt prints goes through the same filter as a file, line by line, so an
// escape sequence from an imported issue cannot move the cursor or draw a fake prompt, and a character split across two
// writes survives.
func TestTktOutputIsFiltered(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script stand-in")
	}
	root, _ := project(t)
	fake := filepath.Join(t.TempDir(), "tkt")
	script := "#!/bin/sh\nprintf 'title \\033]0;pwned\\007\\033[2Jfake$ \\n'\nprintf 'caf\\303'\nsleep 0.1\nprintf '\\251 tail\\n'\nprintf 'no newline at the end'\n"
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	out := run(t, Config{Root: root, Tkt: fake}, "tkt show t-ab12\nexit\n")
	rest := regexp.MustCompile("\\x1b\\[[0-9;]*m").ReplaceAllString(out, "") // the prompt's own bold title
	if strings.ContainsRune(rest, 0x1b) || strings.ContainsRune(rest, 0x07) {
		t.Errorf("a control character from tkt reached the terminal: %q", out)
	}
	for _, want := range []string{"title \u241b]0;pwned\u2407\u241b[2Jfake$ ", "caf\u00e9 tail", "no newline at the end"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%q", want, out)
		}
	}
}

// Protects ls's colours: folders bold blue, links cyan, executables green, plain files and anything unusual uncoloured.
func TestColorName(t *testing.T) {
	for _, c := range []struct {
		m    os.FileMode
		want string
	}{
		{os.ModeDir | 0o755, "\x1b[1;34mn\x1b[0m"},
		{os.ModeSymlink | 0o777, "\x1b[36mn\x1b[0m"},
		{0o755, "\x1b[32mn\x1b[0m"},
		{0o644, "n"},
		{os.ModeNamedPipe | 0o644, "n"},
	} {
		if got := colorName(c.m, "n"); got != c.want {
			t.Errorf("colorName(%v) = %q, want %q", c.m, got, c.want)
		}
	}
}
