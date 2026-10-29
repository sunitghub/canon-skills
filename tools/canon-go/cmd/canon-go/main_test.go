package main

import (
	"io"
	"os"
	"strings"
	"testing"
)

// t-bdb0: the mode comes from the first argument only. Protects every start path of the one binary: the board's daemon
// launch (`canon-go daemon -addr ...`), the launcher's `canon-go board <port>`, the bare/port form older callers use, and
// the daemon's `daemon term` re-exec. The binary's own name (argv[0]) must never pick the mode, whatever it is called.
func TestModeByFirstArgumentOnly(t *testing.T) {
	old := os.Args
	t.Cleanup(func() { os.Args = old })
	for _, name := range []string{"/x/tools/canon-go-bin/canon-go", "/x/tools/cockpit-daemon/cockpit-daemon", "daemon", "canon-go-win.exe"} {
		os.Args = []string{name}
		cases := []struct {
			args []string
			mode string
			rest string
		}{
			{nil, "board", ""},
			{[]string{"8899"}, "board", "8899"},
			{[]string{"--version"}, "board", "--version"},
			{[]string{"headless-json"}, "board", "headless-json"},
			{[]string{"board", "8899"}, "board", "8899"},
			{[]string{"board", "--version"}, "board", "--version"},
			{[]string{"daemon", "-addr", "127.0.0.1:0"}, "daemon", "-addr 127.0.0.1:0"},
			{[]string{"daemon", "--version"}, "daemon", "--version"},
			{[]string{"daemon", "term", "--session", "s"}, "daemon", "term --session s"},
			{[]string{"8899", "daemon"}, "board", "8899 daemon"}, // only the FIRST word is a mode
		}
		for _, c := range cases {
			m, rest := mode(c.args)
			if m != c.mode || strings.Join(rest, " ") != c.rest {
				t.Errorf("argv[0]=%s mode(%q) = %s %q, want %s %q", name, c.args, m, rest, c.mode, c.rest)
			}
		}
	}
}

// t-bdb0: `canon-go --version`, `canon-go board --version` and `canon-go daemon --version` each print the build (the commit stamp
// in parentheses), and none starts a server. Protects tools/fetch-daemon.sh's is_current check (it reads `--version`) and the
// board's /api/version "daemon" row (`daemon --version`).
func TestEveryModePrintsTheBuild(t *testing.T) {
	oldCommit := commit
	commit = "c0ffee12"
	t.Cleanup(func() { commit = oldCommit })
	for _, args := range [][]string{{"--version"}, {"board", "--version"}, {"daemon", "--version"}} {
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		old := os.Stdout
		os.Stdout = w
		code := run(args)
		w.Close()
		os.Stdout = old
		b, _ := io.ReadAll(r)
		if code != 0 || !strings.Contains(string(b), "(c0ffee12)") {
			t.Errorf("canon-go %s: code=%d output=%q, want the build with (c0ffee12)", strings.Join(args, " "), code, b)
		}
	}
}
