package common

import (
	"bufio"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestPathKeyCorpus protects every Go path comparison (the daemon's spawn-cwd check, worktree holds, machine events, the folder guard):
// PathKey gives canon_path_key's key for each row of tests/fixtures/path-keys.tsv, the one corpus tests/path-forms.sh also reads. The key
// is pure, so the same rows pass on every OS.
func TestPathKeyCorpus(t *testing.T) {
	f, err := os.Open(filepath.Join("..", "..", "..", "..", "tests", "fixtures", "path-keys.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	rows := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		c := strings.Split(line, "\t")
		if len(c) != 3 {
			t.Fatalf("corpus line %q: %d fields, want 3", line, len(c))
		}
		if got := PathKey(c[0]); got != c[1] {
			t.Errorf("PathKey(%q) = %q, want %q (%s)", c[0], got, c[1], c[2])
		}
		rows++
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if rows < 25 {
		t.Fatalf("only %d corpus rows ran", rows)
	}
	if got := PathKey("/a\n/b"); got != "/a%0A/b" {
		t.Errorf("a newline must be encoded as %%0A, got %q", got)
	}
	if PathKey("") != "" {
		t.Errorf("an empty path must have an empty key")
	}
}

func TestSamePath(t *testing.T) {
	d := t.TempDir()
	real, other := filepath.Join(d, "real"), filepath.Join(d, "other")
	for _, p := range []string{filepath.Join(real, "sub"), other} {
		if err := os.MkdirAll(p, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	link := filepath.Join(d, "link")
	symlinks := os.Symlink(real, link) == nil // Windows without Developer Mode cannot make one
	cases := []struct {
		name string
		a, b string
		want bool
	}{
		{"one folder", real, real, true},
		{"a trailing separator", real, real + string(filepath.Separator), true},
		{"two real folders", real, other, false},
		{"a missing folder in two spellings (key)", filepath.Join(d, "gone") + "//", filepath.Join(d, "gone"), true},
		{"a missing folder and a real one", filepath.Join(d, "gone"), real, false},
		{"drive spellings of a missing folder", `C:\Users\x\.canon`, "/c/Users/x/.canon", true},
		{"another missing folder", `C:\Users\x\.canon`, "/c/Users/y/.canon", false},
		{"two empty paths", "", "", false},
		{"an empty path", real, "", false},
	}
	if symlinks {
		cases = append(cases,
			struct {
				name string
				a, b string
				want bool
			}{"a folder and its symlink (identity)", real, link, true},
			struct {
				name string
				a, b string
				want bool
			}{"through a symlink", filepath.Join(real, "sub"), filepath.Join(link, "sub"), true})
	}
	for _, c := range cases {
		if got := SamePath(c.a, c.b); got != c.want {
			t.Errorf("%s: SamePath(%q, %q) = %v, want %v", c.name, c.a, c.b, got, c.want)
		}
	}
	// Identity decides when both exist: on POSIX a folder named `a\b` and the folder a/b have one key, but they are two folders.
	if runtime.GOOS != "windows" {
		ab, abs := filepath.Join(d, "a", "b"), filepath.Join(d, `a\b`)
		for _, p := range []string{ab, abs} {
			if err := os.MkdirAll(p, 0o755); err != nil {
				t.Fatal(err)
			}
		}
		if PathKey(ab) != PathKey(abs) {
			t.Fatalf("the fixture needs two folders with one key: %q vs %q", PathKey(ab), PathKey(abs))
		}
		if SamePath(ab, abs) {
			t.Errorf("SamePath(%q, %q): two existing folders with one key were the same folder", ab, abs)
		}
	}
}
