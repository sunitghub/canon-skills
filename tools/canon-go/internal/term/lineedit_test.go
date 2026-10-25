package term

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Protects Tab completion at the restricted prompt: commands, read-only tkt subcommands and project paths complete the
// way a shell does, and never reach .git, .env*, dotfiles nobody asked for, or anything outside the project.
func TestComplete(t *testing.T) {
	root, _ := project(t)
	c := Config{Root: root}
	for _, tc := range []struct {
		in, want string
		cands    string
	}{
		{"he", "help ", ""},
		{"cl", "cl", "clear  cls"},
		{"cat a.", "cat a.go ", ""},
		{"ls s", "ls sub/", ""},
		{"cat sub/b", "cat sub/b.md ", ""},
		{"tkt sh", "tkt show ", ""},
		{"tkt g", "tkt github-", "github-doctor  github-status"},
		{"cat .e", "cat .e", ""},         // .env* is never offered
		{"cat .g", "cat .g", ""},         // nor .git
		{"ls ../", "ls ../", ""},         // nor anything outside the project
		{"rm a", "rm a", ""},             // only ls and cat take paths
		{"cat link-o", "cat link-o", ""}, // a link out of the project is not offered
	} {
		got, cands := c.complete(tc.in)
		if got != tc.want || strings.Join(cands, "  ") != tc.cands {
			t.Errorf("complete(%q) = %q, %q; want %q, %q", tc.in, got, cands, tc.want, tc.cands)
		}
	}
	if got, _ := c.complete("cat "); got != "cat " {
		t.Errorf("an empty word with several files must not complete: %q", got)
	}
}

// Protects the key-by-key prompt line: Tab completes, Backspace and Ctrl-U edit, Ctrl-C drops the line, and the arrow
// keys walk the history, all without the terminal ever echoing for us.
func TestReadLineEditing(t *testing.T) {
	root, _ := project(t)
	read := func(in string, hist []string) (string, string) {
		var out bytes.Buffer
		c := Config{Root: root, Out: &out, RawMode: func() func() { return func() {} }}
		line, err := c.readLine(bufio.NewReader(strings.NewReader(in)), &hist)
		if err != nil {
			t.Fatalf("readLine(%q): %v", in, err)
		}
		return strings.TrimSpace(line), out.String()
	}
	for _, tc := range []struct{ in, want string }{
		{"cat a.\t\r", "cat a.go"},
		{"lz\x7fs\r", "ls"},
		{"cat zzz\x15ls\r", "ls"},
		{"cat zzz\x03", ""},
		{"\x1b[A\r", "ls sub"}, // Up brings the last command back
		{"\x1b[A\x1b[A\x1b[B\r", "ls sub"},
	} {
		if got, _ := read(tc.in, []string{"cat a.go", "ls sub"}); got != tc.want {
			t.Errorf("keys %q gave %q, want %q", tc.in, got, tc.want)
		}
	}
	if _, out := read("cl\t\r", nil); !strings.Contains(out, "clear  cls") {
		t.Errorf("an ambiguous Tab should list the matches:\n%q", out)
	}
}

// Protects the extra prompt words: a lone ? shows the list like help, clear or cls wipe the screen, and pwd names the project folder.
func TestHelpMarkAndClear(t *testing.T) {
	root, _ := project(t)
	out := run(t, Config{Root: root}, "?\nclear\ncls\npwd\n? x\nexit\n")
	if strings.Count(out, "Welcome to Canon Console") != 2 { // the opening welcome and the lone ?
		t.Errorf("want the welcome twice (open, ?):\n%s", out)
	}
	if strings.Count(out, "\x1b[2J") != 2 {
		t.Errorf("clear and cls should each wipe the screen:\n%q", out)
	}
	if !strings.Contains(out, root+"\n") {
		t.Errorf("pwd should print the project folder %q:\n%s", root, out)
	}
	if !strings.Contains(out, "not supported here (no shell): ?") {
		t.Errorf("a ? inside a longer line is still refused:\n%s", out)
	}
}

// Protects paging beyond cat: a long tkt listing and a long ls stop at "more" and q ends them, as a long file does.
func TestPagingCoversTktAndLs(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script stand-in")
	}
	root, _ := project(t)
	fake := filepath.Join(t.TempDir(), "tkt")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\ni=1\nwhile [ $i -le 40 ]; do echo \"t-$i row\"; i=$((i+1)); done\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := Config{Root: root, Tkt: fake, Rows: func() int { return 10 }}
	out := run(t, cfg, "tkt ls\nq\nexit\n")
	if !strings.Contains(out, "-- more:") || strings.Contains(out, "t-40 row") {
		t.Errorf("tkt ls should stop at the first page when q is typed:\n%s", out)
	}
	for i := 0; i < 12; i++ {
		os.WriteFile(filepath.Join(root, fmt.Sprintf("f%02d.txt", i)), nil, 0o644)
	}
	if out := run(t, cfg, "ls\nq\nexit\n"); !strings.Contains(out, "-- more:") {
		t.Errorf("a long ls should page:\n%s", out)
	}
}

// Protects the prompt line's edge cases: Ctrl-D leaves only on an empty line, Ctrl-W drops a word, history stops at both
// ends and keeps the half-typed line, escape sequences (Delete, SS3 arrows) are swallowed whole, non-ASCII text survives,
// the echo is exactly what a terminal needs, and a RawMode that cannot switch falls back to a plain line.
func TestReadLineEdges(t *testing.T) {
	root, _ := project(t)
	run1 := func(in string, hist []string, raw func() func()) (string, string, error) {
		var out bytes.Buffer
		c := Config{Root: root, Out: &out, RawMode: raw}
		line, err := c.readLine(bufio.NewReader(strings.NewReader(in)), &hist)
		return line, out.String(), err
	}
	ok := func() func() { return func() {} }
	if _, _, err := run1("\x04", nil, ok); err != io.EOF {
		t.Errorf("Ctrl-D on an empty line should end input, got %v", err)
	}
	if l, _, err := run1("ab\x04c\r", nil, ok); err != nil || l != "abc\n" {
		t.Errorf("Ctrl-D mid-line must be ignored: %q %v", l, err)
	}
	if l, _, _ := run1("cat abc\x17ls\r", nil, ok); l != "cat ls\n" {
		t.Errorf("Ctrl-W should drop the last word: %q", l)
	}
	h := []string{"one", "two"}
	for _, tc := range []struct{ in, want string }{
		{"\x1b[A\x1b[A\x1b[A\r", "one\n"},  // Up stops at the oldest
		{"\x1b[B\r", "\n"},                 // Down with nothing newer does nothing
		{"ab\x1b[A\x1b[B\r", "ab\n"},       // the half-typed line comes back
		{"a\x1b[3~b\r", "ab\n"},            // Delete key: the whole sequence is swallowed
		{"\x1bOAx\r", "two" + "x\n"},       // SS3 Up arrow
		{"\x1bqls\r", "ls\n"},              // a lone ESC eats just the next byte
		{"caf\xc3\xa9\r", "caf\xc3\xa9\n"}, // non-ASCII bytes pass through
		{"caf\xc3\xa9\x7f\r", "caf\n"},     // and Backspace removes the whole character
	} {
		if l, _, _ := run1(tc.in, h, ok); l != tc.want {
			t.Errorf("keys %q gave %q, want %q", tc.in, l, tc.want)
		}
	}
	if _, out, _ := run1("ls\r", nil, ok); out != "ls\r\n" {
		t.Errorf("echo of a typed line = %q", out)
	}
	if l, out, _ := run1("ab\x03", nil, ok); l != "\n" || out != "ab^C\r\n" {
		t.Errorf("Ctrl-C = %q, echo %q", l, out)
	}
	if _, out, _ := run1("lz\x7f\r", nil, ok); !strings.Contains(out, "\r\x1b[K$ l") {
		t.Errorf("Backspace should redraw the prompt and the line: %q", out)
	}
	if _, out, _ := run1("cl\t\r", nil, ok); !strings.Contains(out, "\r\nclear  cls\r\n\r\x1b[K$ cl") {
		t.Errorf("an ambiguous Tab lists the matches and redraws the line: %q", out)
	}
	if l, _, err := run1("ab", nil, ok); l != "ab" || err != io.EOF {
		t.Errorf("end of input mid-line should return the typed text and EOF: %q %v", l, err)
	}
	if l, out, err := run1("\x04ls\r", nil, ok); l != "" || err != io.EOF || out != "\r\n" {
		t.Errorf("Ctrl-D on an empty line must stop before reading on: %q %q %v", l, out, err)
	}
	if _, out, _ := run1("\x7f\r", nil, ok); out != "\r\n" {
		t.Errorf("Backspace on an empty line should redraw nothing: %q", out)
	}
	if _, out, _ := run1("ab\x15\r", nil, ok); out != "ab\r\x1b[K$ \r\n" {
		t.Errorf("Ctrl-U should redraw an empty line: %q", out)
	}
	if l, out, _ := run1("cat abc \x17x\r", nil, ok); l != "cat x\n" || !strings.Contains(out, "\r\x1b[K$ cat ") {
		t.Errorf("Ctrl-W after a trailing space should drop the word and redraw: %q %q", l, out)
	}
	if _, out, _ := run1("ca\t\r", nil, ok); !strings.Contains(out, "\r\x1b[K$ cat ") {
		t.Errorf("Tab should redraw the completed line: %q", out)
	}
	if _, out, _ := run1("\x1b[A\x1b[A\x1b[B\r", h, ok); !strings.Contains(out, "\r\x1b[K$ one") || !strings.Contains(out, "\r\x1b[K$ two") {
		t.Errorf("Up and Down should redraw the history line: %q", out)
	}
	if _, out, _ := run1("ab\x1b[A\x1b[B\r", h, ok); !strings.Contains(out, "\r\x1b[K$ ab") {
		t.Errorf("Down past the newest history line should redraw the half-typed line: %q", out)
	}
	if l, _, _ := run1("a\x01b\r", nil, ok); l != "ab\n" {
		t.Errorf("a control key that is not bound must not enter the line: %q", l)
	}
	if _, out, _ := run1("caf\xc3\xa9\r", nil, ok); out != "caf\xc3\xa9\r\n" {
		t.Errorf("non-ASCII text must be echoed byte for byte: %q", out)
	}
	if l, _, err := run1("ab\x1b[", nil, ok); l != "ab" || err != io.EOF {
		t.Errorf("a cut-off escape sequence must end at EOF, not hang: %q %v", l, err)
	}
	restored := 0
	run1("ls\r", nil, func() func() { return func() { restored++ } })
	if restored != 1 {
		t.Errorf("the terminal must be put back exactly once, got %d", restored)
	}
	if l, _, _ := run1("ls\n", nil, func() func() { return nil }); l != "ls\n" {
		t.Errorf("a RawMode that cannot switch should fall back to a plain line: %q", l)
	}
}

// Protects Tab's filters beyond the secrets: every command name completes, a dotfile is offered only when asked for,
// and a name that could not be typed at this prompt (a space, a shell character) is never offered.
func TestCompleteFilters(t *testing.T) {
	root, _ := project(t)
	for _, n := range []string{".dot", "a b.txt", "a$b.txt", "ab.txt"} {
		if err := os.WriteFile(filepath.Join(root, n), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	c := Config{Root: root}
	for _, tc := range []struct{ in, want string }{
		{"ca", "cat "}, {"ex", "exit "}, {"pw", "pwd "}, {"s", "su "}, {"t", "tkt "}, {"l", "ls "}, {"he", "help "},
		{"ls .d", "ls .dot "},
		{"ls ab", "ls ab.txt "}, // a b.txt and a$b.txt are not offered, so ab.txt is the only match
	} {
		if got, _ := c.complete(tc.in); got != tc.want {
			t.Errorf("complete(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
	if _, cands := c.complete("ls "); strings.Contains(strings.Join(cands, " "), ".dot") || strings.Contains(strings.Join(cands, "|"), "a b") || strings.Contains(strings.Join(cands, "|"), "a$b") {
		t.Errorf("an empty word offered dotfiles or untypeable names: %v", cands)
	}
	if got, _ := c.complete("ls " + filepath.Join(root, "su")); got != "ls "+filepath.Join(root, "sub")+"/" {
		t.Errorf("an absolute path inside the project should complete: %q", got)
	}
}
