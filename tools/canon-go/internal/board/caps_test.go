package board

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// The units on hand-counted inputs (t-19bb). Protects `canon-go caps`, which the checklist and release-zip gates read their caps
// through.
func TestCapUnits(t *testing.T) {
	if n := capWords([]byte("one two\tthree\nfour\r\nfive  \v six\f")); n != 6 {
		t.Fatalf("words = %d, want 6", n)
	}
	if n := capWords([]byte("a b c")); n != 2 { // NBSP is not ASCII whitespace: "a b" is one word, as wc -w in the C locale
		t.Fatalf("words with NBSP = %d, want 2", n)
	}
	if n := capWords(nil); n != 0 {
		t.Fatalf("words of empty = %d", n)
	}
	for in, want := range map[string]int64{"": 0, "a": 1, "a\n": 1, "a\nb": 2, "a\nb\n": 2, "\n\n": 2, "a\r\nb\r\n": 2} {
		if n := capLines([]byte(in)); n != want {
			t.Fatalf("lines(%q) = %d, want %d", in, n, want)
		}
	}
	doc := "x\n<!-- canon:t:BEGIN -->\n1\n\n3\n<!-- canon:t:END -->\ny\n"
	if n, err := capBlockLines([]byte(doc), "canon:t"); err != nil || n != 3 {
		t.Fatalf("block-lines = %d, %v; want 3 (an empty line counts)", n, err)
	}
	if n, err := capBlockLines([]byte(strings.ReplaceAll(doc, "\n", "\r\n")), "canon:t"); err != nil || n != 3 {
		t.Fatalf("block-lines with CRLF = %d, %v; want 3", n, err)
	}
	if _, err := capBlockLines([]byte("<!-- canon:t:BEGIN -->\n1\n"), "canon:t"); err == nil {
		t.Fatal("an unclosed block must be an error, not a count")
	}
}

func writeCapTable(t *testing.T, dir string) string {
	t.Helper()
	tab := filepath.Join(dir, "caps.tsv")
	body := "# test table\n\nlist\tlist.md\t5\twords\t-\nzip\t-\t2\tkb\t-\nzipfiles\t-\t3\tfiles\t-\nblock\tB.md\t2\tblock-lines\tcanon:b\n"
	if err := os.WriteFile(tab, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return tab
}

func runCaps(t *testing.T, args ...string) (string, int) {
	t.Helper()
	var out, errb bytes.Buffer
	code := capsCLI(args, &out, &errb)
	return out.String() + errb.String(), code
}

func TestCapsCLI(t *testing.T) {
	d := t.TempDir()
	tab := writeCapTable(t, d)
	list := filepath.Join(d, "list.md")
	os.WriteFile(list, []byte("one two three four five"), 0o644)
	if out, code := runCaps(t, "--table", tab, "list", list); code != 0 || out != "list: 5 of 5 words, 0 left\n" {
		t.Fatalf("at the cap: %q %d", out, code)
	}
	os.WriteFile(list, []byte("one two three four five six"), 0o644)
	if out, code := runCaps(t, "--table", tab, "list", list); code != 1 || out != "list: 6 of 5 words, over by 1\n" {
		t.Fatalf("one over: %q %d", out, code)
	}
	if out, code := runCaps(t, "--json", "--table", tab, "list", list); code != 1 ||
		out != `{"name":"list","used":6,"limit":5,"unit":"words","left":-1,"over":true}`+"\n" {
		t.Fatalf("json: %q %d", out, code)
	}
	// the tree units: bytes rounded up, folders and symlinks cost nothing, odd names count
	tree := filepath.Join(d, "tree")
	os.MkdirAll(filepath.Join(tree, "sub dir", "empty"), 0o755)
	os.WriteFile(filepath.Join(tree, "a"), bytes.Repeat([]byte("x"), 1024), 0o644)
	os.WriteFile(filepath.Join(tree, "sub dir", ".dot"), []byte("y"), 0o644)
	name := "new\nline"
	if runtime.GOOS == "windows" {
		name = "-dash"
	}
	os.WriteFile(filepath.Join(tree, name), []byte("z"), 0o644)
	os.Symlink(filepath.Join(tree, "a"), filepath.Join(tree, "link"))
	if out, code := runCaps(t, "--table", tab, "zip", tree); code != 0 || out != "zip: 2 of 2 KB, 0 left\n" { // 1026 bytes -> 2 KB
		t.Fatalf("tree kb: %q %d", out, code)
	}
	if out, code := runCaps(t, "--table", tab, "zipfiles", tree); code != 0 || out != "zipfiles: 3 of 3 files, 0 left\n" {
		t.Fatalf("tree files: %q %d", out, code)
	}
	os.WriteFile(filepath.Join(tree, "a"), bytes.Repeat([]byte("x"), 2048), 0o644)
	if out, code := runCaps(t, "--table", tab, "zip", tree); code != 1 || out != "zip: 3 of 2 KB, over by 1\n" {
		t.Fatalf("tree over: %q %d", out, code)
	}
	// a block
	b := filepath.Join(d, "B.md")
	os.WriteFile(b, []byte("<!-- canon:b:BEGIN -->\n1\n2\n3\n<!-- canon:b:END -->\n"), 0o644)
	if out, code := runCaps(t, "--table", tab, "block", b); code != 1 || out != "block: 3 of 2 lines, over by 1\n" {
		t.Fatalf("block: %q %d", out, code)
	}
	// not capped, not present, the caller's path missing, a bad table, a usage error
	if out, code := runCaps(t, "--table", tab, "nothing.md"); code != 0 || out != "nothing.md: not capped\n" {
		t.Fatalf("not capped: %q %d", out, code)
	}
	if out, code := runCaps(t, "--table", tab, "list", filepath.Join(d, "gone.md")); code != 0 || !strings.Contains(out, "list: not present") {
		t.Fatalf("not present: %q %d", out, code)
	}
	if out, code := runCaps(t, "--table", tab, "zip"); code != 2 || !strings.Contains(out, "needs a path") {
		t.Fatalf("zip with no path: %q %d", out, code)
	}
	bad := filepath.Join(d, "bad.tsv")
	os.WriteFile(bad, []byte("x\ty\t0\twords\t-\n"), 0o644)
	if out, code := runCaps(t, "--table", bad, "x", list); code != 2 || !strings.Contains(out, "not a positive whole number") {
		t.Fatalf("bad limit: %q %d", out, code)
	}
	os.WriteFile(bad, []byte("x\ty\t5\tbytes\t-\n"), 0o644)
	if out, code := runCaps(t, "--table", bad, "x", list); code != 2 || !strings.Contains(out, "unknown unit") {
		t.Fatalf("bad unit: %q %d", out, code)
	}
	if _, code := runCaps(t, "--table", tab); code != 2 {
		t.Fatal("no name must be a usage error")
	}
	if _, code := runCaps(t, "--bogus", "list"); code != 2 {
		t.Fatal("an unknown option must be a usage error")
	}
	if runtime.GOOS != "windows" && os.Geteuid() != 0 { // a file it cannot read is an error, never a smaller number (root reads anything)
		os.Chmod(list, 0)
		defer os.Chmod(list, 0o644)
		if out, code := runCaps(t, "--table", tab, "list", list); code != 2 || !strings.Contains(out, "caps: list:") {
			t.Fatalf("unreadable: %q %d", out, code)
		}
	}
}

// --list, a row found by its path, the error branches (t-19bb sweep survivors).
func TestCapsListPathAndErrors(t *testing.T) {
	d := t.TempDir()
	tab := writeCapTable(t, d)
	os.WriteFile(filepath.Join(d, "list.md"), []byte("a b c d e f"), 0o644)
	wd, _ := os.Getwd()
	defer os.Chdir(wd)
	os.Mkdir(filepath.Join(d, ".git"), 0o755) // the project root for row paths
	os.Chdir(d)
	out, code := runCaps(t, "--list", "--table", tab)
	want := "list: 6 of 5 words, over by 1\nzip: 2 KB (the caller gives the path)\nzipfiles: 3 files (the caller gives the path)\nblock: not present (B.md)\n"
	if code != 0 || out != want {
		t.Fatalf("--list = %q %d, want %q", out, code, want)
	}
	os.WriteFile(filepath.Join(d, "B.md"), []byte("no block here\n"), 0o644)
	if out, _ := runCaps(t, "--list", "--table", tab); !strings.Contains(out, "block: cannot be measured: no <!-- canon:b:BEGIN -->") {
		t.Fatalf("--list with a broken block: %q", out)
	}
	if out, code := runCaps(t, "--list", "--table", tab, "list"); code != 2 || !strings.Contains(out, "usage") {
		t.Fatalf("--list with a name: %q %d", out, code)
	}
	// a row found by its path, relative or absolute; the name alone reads the table's path
	for _, arg := range []string{"list.md", "./list.md", filepath.Join(d, "list.md")} {
		if out, code := runCaps(t, "--table", tab, arg); code != 1 || out != "list: 6 of 5 words, over by 1\n" {
			t.Fatalf("by path %q: %q %d", arg, out, code)
		}
	}
	if out, code := runCaps(t, "--table", tab, "list"); code != 1 || out != "list: 6 of 5 words, over by 1\n" {
		t.Fatalf("by name: %q %d", out, code)
	}
	// errors exit 2: a folder for a file unit, a missing --table value, an unknown option, an unreadable folder in a tree
	if out, code := runCaps(t, "--table", tab, "list", d); code != 2 || !strings.Contains(out, "is a folder") {
		t.Fatalf("folder for words: %q %d", out, code)
	}
	if _, code := runCaps(t, "list", "--table"); code != 2 {
		t.Fatal("--table with no value must be a usage error")
	}
	if out, code := runCaps(t, "--table", tab, "--nope", "list"); code != 2 || !strings.Contains(out, "unknown option --nope") {
		t.Fatalf("unknown option: %q %d", out, code)
	}
	if runtime.GOOS != "windows" && os.Geteuid() != 0 {
		tree := filepath.Join(d, "tree")
		os.MkdirAll(filepath.Join(tree, "locked"), 0o755)
		os.Chmod(filepath.Join(tree, "locked"), 0)
		defer os.Chmod(filepath.Join(tree, "locked"), 0o755)
		if out, code := runCaps(t, "--table", tab, "zip", tree); code != 2 || !strings.Contains(out, "caps: zip:") {
			t.Fatalf("unreadable folder: %q %d", out, code)
		}
	}
}
