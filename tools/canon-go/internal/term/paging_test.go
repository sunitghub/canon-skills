package term

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-dba0. Protects the Cockpit Terminal's pausing: auto pages at the screen's height, off never pauses, a number pauses every N
// lines; and the `paging` command changes it for THIS Terminal only (nothing is written anywhere).
func TestPageSizeFollowsPaging(t *testing.T) {
	rows := func() int { return 30 }
	for _, c := range []struct {
		paging string
		want   int
	}{{"", 29}, {"auto", 29}, {"off", 1<<31 - 1}, {"12", 12}, {"5", 5}, {"500", 500}, {"3", 29}, {"501", 29}, {"banana", 29}} {
		if got := (Config{Rows: rows, Paging: c.paging}).pageSize(); got != c.want {
			t.Errorf("paging %q: pageSize = %d, want %d", c.paging, got, c.want)
		}
	}
}

func TestPagingCommandIsSessionOnly(t *testing.T) {
	root, _ := project(t)
	var lines []string
	for i := 0; i < 60; i++ {
		lines = append(lines, fmt.Sprintf("line %02d", i))
	}
	if err := os.WriteFile(filepath.Join(root, "long.txt"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// off: the whole file at once, no "-- more" prompt; auto at 24 rows pauses
	out := run(t, Config{Root: root, Rows: func() int { return 24 }}, "paging\npaging off\ncat long.txt\npaging 10\npaging\npaging nope\npaging 4\npaging 1 2\nexit\n")
	for _, want := range []string{"paging: auto", "paging: off (this Terminal only)", "line 59", "paging: 10 (this Terminal only)", "paging: 10   (paging", `"nope" is not a setting here`, `"4" is not a setting here`, "usage: paging [auto|off|<lines>]"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "-- more") {
		t.Errorf("paging off still paused:\n%s", out)
	}
	out = run(t, Config{Root: root, Rows: func() int { return 24 }}, "cat long.txt\nq\nexit\n")
	if !strings.Contains(out, "-- more") {
		t.Errorf("auto at 24 rows did not pause a 60-line file:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(root, ".canon")); err == nil {
		t.Error("the paging command wrote a settings folder")
	}
	// a saved number pages that often
	out = run(t, Config{Root: root, Paging: "10", Rows: func() int { return 24 }}, "cat long.txt\nq\nexit\n")
	if !strings.Contains(out, "(50 lines left)") {
		t.Errorf("paging 10 should stop after 10 of 60 lines:\n%s", out)
	}
}

// Protects the start-up read: the Terminal takes terminal.paging from the project's files (local wins over shared), and a malformed
// file is said on the error stream and falls back to auto instead of stopping the Terminal.
func TestProjectPagingReadsTheFiles(t *testing.T) {
	root := t.TempDir()
	var errOut bytes.Buffer
	if got := projectPaging(root, &errOut); got != "auto" || errOut.Len() != 0 {
		t.Fatalf("no files: %q %q", got, errOut.String())
	}
	dir := filepath.Join(root, ".canon")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("settings.json", `{"terminal":{"paging":"off"}}`)
	if got := projectPaging(root, &errOut); got != "off" {
		t.Fatalf("shared: %q", got)
	}
	write("settings.local.json", `{"terminal":{"paging":40}}`)
	if got := projectPaging(root, &errOut); got != "40" {
		t.Fatalf("local over shared: %q", got)
	}
	write("settings.local.json", `{"terminal": `)
	errOut.Reset()
	if got := projectPaging(root, &errOut); got != "auto" || !strings.Contains(errOut.String(), ".canon/settings.local.json") {
		t.Fatalf("malformed: %q %q", got, errOut.String())
	}
}

// t-dba0 (from the mutation sweep). Protects the command's surface: `paging` is in the help and the not-allowed list, `on` means auto,
// a malformed use changes nothing, and `auto` resets.
func TestPagingCommandSurface(t *testing.T) {
	root, _ := project(t)
	out := run(t, Config{Root: root, Paging: "12"}, "help\nbogus\npaging 1 2\npaging\npaging on\npaging\npaging 30\npaging auto\npaging\nexit\n")
	for _, want := range []string{"show or set when output pauses", "allowed: help, ls, cat, pwd, paging, tkt, su, clear, exit", "usage: paging [auto|off|<lines>]", "paging: 12   (paging", "paging: auto (this Terminal only)", "paging: 30 (this Terminal only)"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q:\n%s", want, out)
		}
	}
	for _, never := range []string{`"1" is not a setting`, "<nil>"} { // a malformed use must not fall through to a change
		if strings.Contains(out, never) {
			t.Errorf("output must not contain %q:\n%s", never, out)
		}
	}
	if strings.Count(out, "paging: 12   (paging") != 1 {
		t.Errorf("a malformed `paging 1 2` must leave 12 in place, then `paging on` reset to auto:\n%s", out)
	}
	if strings.Count(out, "paging: auto   (paging") != 2 {
		t.Errorf("`paging` after `paging on` and after `paging auto` should both show auto:\n%s", out)
	}
}
