package term

import (
	"bufio"
	"bytes"
	"fmt"
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
