package term

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
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
		"a.txt  b.txt  c.txt\n", // sorted
		"a.txt\n",               // ls of a file prints its name
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
	if err := os.WriteFile(fake, []byte("#!/bin/sh\npwd\necho \"args:$*\"\n[ \"$1\" = fail ] && exit 3\nexit 0\n"), 0o755); err != nil {
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

// Protects su's defaults and its order of events: a missing limit means five minutes, a bad warning means thirty seconds,
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
	pw.WriteString("su\nKx7m2\n")
	<-f.started
	waitFor(t, func() bool { f.mu.Lock(); defer f.mu.Unlock(); return len(f.chans) == 2 })
	if f.waits[0] != 4*time.Minute+30*time.Second || f.waits[1] != 5*time.Minute {
		t.Fatalf("defaults: timers %v, want 4m30s and 5m", f.waits)
	}
	if !strings.Contains(out.String(), "Full shell mode lasts 5m0s") {
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
	out2 := run(t, c2, "su\nKx7m2\nexit\n")
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
	out := run(t, cfg, "su\nKx7m2\nexit\n")
	if !strings.Contains(out, "ends in") || !strings.Contains(out, "time is up") {
		t.Errorf("the real timers should warn and end:\n%s", out)
	}
	if !strings.HasSuffix(f.log(), "terminal.su_expired how=ended") {
		t.Errorf("events %q", f.log())
	}
}

// Protects the short word: three tries only. A typo can be retried on the same word; the third wrong answer in all, across
// every su, closes the terminal (exit status 1, logged as "locked"), and the commands after it never run; a right answer
// starts the count again; an empty answer or end of input never counts.
func TestSuThreeTriesThenTheTerminalCloses(t *testing.T) {
	root, _ := project(t)
	mk := func() (*fakeSu, Config, *safeBuf) {
		f := newFakeSu()
		close(f.stop)
		return f, f.cfg(root), &safeBuf{}
	}
	runCode := func(cfg Config, out *safeBuf, input string) int {
		cfg.In, cfg.Out = strings.NewReader(input), out
		return Run(cfg)
	}
	// A typo twice, then the word: the shell starts, and the prompt tells how many tries are left.
	f, cfg, out := mk()
	if code := runCode(cfg, out, "su\nBad11\nBad22\nKx7m2\nexit\n"); code != 0 {
		t.Errorf("exit status %d", code)
	}
	if want := "terminal.su_prompted|terminal.su_denied reason=wrong|terminal.su_denied reason=wrong|terminal.su_granted minutes=5|terminal.su_expired how=exited"; f.log() != want {
		t.Errorf("events:\n got %s\nwant %s", f.log(), want)
	}
	if f.shells != 1 || !strings.Contains(out.String(), "Wrong, 2 left.") || !strings.Contains(out.String(), "Wrong, 1 left.") {
		t.Errorf("shells=%d\n%s", f.shells, out.String())
	}
	// Three wrong answers in one su close the terminal; nothing after them runs.
	f, cfg, out = mk()
	if code := runCode(cfg, out, "su\nBad1\nBad2\nBad3\nls\nsu\nKx7m2\n"); code != 1 {
		t.Errorf("a closed terminal should exit 1, got %d", code)
	}
	if want := "terminal.su_prompted|terminal.su_denied reason=wrong|terminal.su_denied reason=wrong|terminal.su_denied reason=locked"; f.log() != want {
		t.Errorf("events:\n got %s\nwant %s", f.log(), want)
	}
	if f.shells != 0 || strings.Contains(out.String(), "a.go") || !strings.Contains(out.String(), "Wrong 3 times: closing the terminal.") {
		t.Errorf("shells=%d\n%s", f.shells, out.String())
	}
	// The count carries across su commands: one wrong answer, cancel, three times.
	f, cfg, out = mk()
	if code := runCode(cfg, out, "su\nBad1\n\nsu\nBad2\n\nsu\nBad3\nls\n"); code != 1 || f.shells != 0 || strings.Contains(out.String(), "a.go") {
		t.Errorf("three wrong answers over three su commands should close it: code=%d shells=%d\n%s", code, f.shells, out.String())
	}
	// A right answer starts the count again.
	f, cfg, out = mk()
	if code := runCode(cfg, out, "su\nBad1\nBad2\nKx7m2\nsu\nBad3\nBad4\nKx7m2\nexit\n"); code != 0 || f.shells != 2 {
		t.Errorf("a right answer should reset the count: code=%d shells=%d\n%s", code, f.shells, out.String())
	}
	// Empty answers and end of input never count.
	f, cfg, out = mk()
	if code := runCode(cfg, out, "su\n\nsu\n\nsu\n\nsu\n\nsu\nKx7m2\nexit\n"); code != 0 || f.shells != 1 {
		t.Errorf("empty answers must not close the terminal: code=%d shells=%d log=%s", code, f.shells, f.log())
	}
}
