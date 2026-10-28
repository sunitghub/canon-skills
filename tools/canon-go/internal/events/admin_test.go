package events

import (
	"bytes"
	"compress/gzip"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Protects the Logging page's numbers: days count once even with a gz twin, a link is not a day, and no log yet is zero and not an error.
func TestStatAndWouldRemove(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-10-01.jsonl": "ab\n", "2026-10-02.jsonl": "abc\n", "2026-09-01.jsonl.gz": "xyz", "notes.txt": "no"})
	os.WriteFile(filepath.Join(dir, "2026-10-01.jsonl.gz"), []byte("gz"), 0o600) // a twin: the same day
	if runtime.GOOS != "windows" {
		os.Symlink(filepath.Join(t.TempDir(), "x"), filepath.Join(dir, "2026-10-03.jsonl"))
	}
	in, err := Stat(home)
	if err != nil || in.Days != 3 || in.Files != 4 || in.Bytes != 3+4+3+2 || in.Oldest != "2026-09-01" || in.Newest != "2026-10-02" {
		t.Errorf("Stat = %+v %v", in, err)
	}
	if in, err := Stat(t.TempDir()); err != nil || in != (Info{}) {
		t.Errorf("no log: %+v %v", in, err)
	}
	d, f := WouldRemove(home, 30, at("2026-10-31T12:00:00Z")) // cutoff 2026-10-01: 09-01 goes, 10-01 stays
	if d != 1 || f != 1 {
		t.Errorf("WouldRemove 30 = %d days %d files", d, f)
	}
	if d, f := WouldRemove(home, 365, at("2026-10-31T12:00:00Z")); d != 0 || f != 0 {
		t.Errorf("WouldRemove 365 = %d %d", d, f)
	}
	if d, f := WouldRemove(t.TempDir(), 30, at("2026-10-31T12:00:00Z")); d != 0 || f != 0 {
		t.Errorf("no log: %d %d", d, f)
	}
}

// Protects Export: day order, a gunzipped day, a final newline added where a day lacks one, nothing from a link or the seal file, the
// total cap refused before the first byte, and a day over its own cap named.
func TestExportOrderCapAndLinks(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-10-02.jsonl": "{\"b\":1}\n", "2026-10-03.jsonl": "{\"c\":1}", "seals.jsonl": "SEALS\n"})
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write([]byte("{\"a\":1}\n"))
	zw.Close()
	os.WriteFile(filepath.Join(dir, "2026-10-01.jsonl.gz"), gz.Bytes(), 0o600)
	if runtime.GOOS != "windows" {
		secret := filepath.Join(t.TempDir(), "secret")
		os.WriteFile(secret, []byte("SECRET\n"), 0o600)
		os.Symlink(secret, filepath.Join(dir, "2026-10-04.jsonl"))
	}
	var out bytes.Buffer
	if err := Export(&out, home); err != nil || out.String() != "{\"a\":1}\n{\"b\":1}\n{\"c\":1}\n" {
		t.Errorf("export = %q %v", out.String(), err)
	}
	old := exportMax
	exportMax = 20 // 8 + 8 + 9 bytes with the added newline
	defer func() { exportMax = old }()
	out.Reset()
	if err := Export(&out, home); err != ErrExportTooBig || out.Len() != 0 {
		t.Errorf("over the cap: %v, %d bytes written", err, out.Len())
	}
	exportMax = old
	oldDay := dayMaxBytes
	dayMaxBytes = 4
	defer func() { dayMaxBytes = oldDay }()
	out.Reset()
	if err := Export(&out, home); err == nil || !strings.Contains(err.Error(), "too large") || out.Len() != 0 {
		t.Errorf("a day over its cap: %v, %d bytes written", err, out.Len())
	}
	if err := Export(&out, t.TempDir()); err != nil {
		t.Errorf("no log: %v", err)
	}
}

// Protects Delete's reach: exact names only, a link is removed and its target kept, and a busy lock stops it.
func TestClearExactNamesAndLock(t *testing.T) {
	home, dir := logWith(t, map[string]string{
		"2026-10-01.jsonl": "x", "2026-10-02.jsonl.gz": "x", "seals.jsonl": "x", "emit-errors.log": "x", "2026-10-02.tmp.gz": "x",
		"keep.txt": "k", "2026-10-02.jsonl.old": "k", "2026-02-30.jsonl": "k", ".hidden": "k",
	})
	os.Mkdir(filepath.Join(dir, "2026-10-09.jsonl"), 0o700) // a folder named like a day is not a file
	os.WriteFile(filepath.Join(dir, lockName), nil, 0o600)
	if _, err := Clear(home); err != ErrBusy {
		t.Fatalf("a fresh lock: %v", err)
	}
	os.Remove(filepath.Join(dir, lockName))
	c, err := Clear(home)
	if err != nil || c.Files != 5 || c.From != "2026-10-01" || c.To != "2026-10-02" || len(c.Failed) != 0 {
		t.Fatalf("Clear = %+v %v", c, err)
	}
	left := []string{}
	es, _ := os.ReadDir(dir)
	for _, e := range es {
		left = append(left, e.Name())
	}
	if strings.Join(left, " ") != ".hidden 2026-02-30.jsonl 2026-10-02.jsonl.old 2026-10-09.jsonl keep.txt" {
		t.Errorf("left behind: %v", left)
	}
	if c, err := Clear(t.TempDir()); err != nil || c.Files != 0 {
		t.Errorf("no log: %+v %v", c, err)
	}
	if runtime.GOOS != "windows" {
		h2, d2 := logWith(t, nil)
		target := filepath.Join(t.TempDir(), "target")
		os.WriteFile(target, []byte("keep"), 0o600)
		os.Symlink(target, filepath.Join(d2, "2026-10-01.jsonl"))
		if c, err := Clear(h2); err != nil || c.Files != 1 {
			t.Errorf("a link: %+v %v", c, err)
		}
		if b, _ := os.ReadFile(target); string(b) != "keep" {
			t.Errorf("a link's target was removed")
		}
		h3 := t.TempDir()
		os.Symlink(t.TempDir(), filepath.Join(h3, "events"))
		if _, err := Clear(h3); err == nil {
			t.Errorf("a linked events folder must be refused")
		}
	}
}

// Protects Export's edges: a day with both a plain and a gz file is exported once (the plain), an empty day adds nothing, a total exactly at
// the cap is allowed, and a day exactly at its own cap is allowed.
func TestExportEdges(t *testing.T) {
	home, dir := logWith(t, map[string]string{"2026-10-01.jsonl": "{\"p\":1}\n", "2026-10-02.jsonl": "", "2026-13-45.jsonl": "{\"bad\":1}\n"})
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	zw.Write([]byte("{\"twin\":1}\n"))
	zw.Close()
	os.WriteFile(filepath.Join(dir, "2026-10-01.jsonl.gz"), gz.Bytes(), 0o600)
	var out bytes.Buffer
	if err := Export(&out, home); err != nil || out.String() != "{\"p\":1}\n" {
		t.Errorf("twin and empty day: %q %v", out.String(), err)
	}
	if in, _ := Stat(home); in.Days != 2 || in.Files != 3 {
		t.Errorf("an impossible date must not count: %+v", in)
	}
	oldMax, oldDay := exportMax, dayMaxBytes
	defer func() { exportMax, dayMaxBytes = oldMax, oldDay }()
	exportMax = 8 + 1 + 1 // the plain day (8 bytes) plus one per file counted, the empty day counting 1
	out.Reset()
	if err := Export(&out, home); err != nil {
		t.Errorf("a total exactly at the cap: %v", err)
	}
	exportMax--
	if err := Export(&out, home); err != ErrExportTooBig {
		t.Errorf("one byte over the cap: %v", err)
	}
	exportMax = oldMax
	dayMaxBytes = 8
	out.Reset()
	if err := Export(&out, home); err != nil {
		t.Errorf("a day exactly at its cap: %v", err)
	}
}

// Protects Delete in a folder that cannot be written: the real reason comes back (not "busy"), nothing is counted as removed, and the
// files are still there. A file held open on Windows lands in Failed instead; that needs a Windows machine to show.
func TestClearInAFolderThatCannotBeWritten(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs a folder the account cannot write")
	}
	home, dir := logWith(t, map[string]string{"2026-10-02.jsonl": "x", "2026-10-01.jsonl": "x"})
	os.Chmod(dir, 0o500)
	defer os.Chmod(dir, 0o700)
	c, err := Clear(home)
	if err == nil || errors.Is(err, ErrBusy) || !strings.Contains(err.Error(), "permission denied") || c.Files != 0 {
		t.Errorf("Clear = %+v %v", c, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "2026-10-01.jsonl")); err != nil {
		t.Errorf("a file went")
	}
}
