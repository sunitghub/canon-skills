//go:build !windows

package common

import (
	"errors"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// t-adcb: a FIFO's own Lstat and fstat are the same file by identity, which is what Linux inode reuse hands a check that
// swaps a regular file for a FIFO. SameRegular must still refuse it. Protects the board's ticket loader (/api/tickets),
// the theme list, the daemon's Copilot status reader and event sealing.
// Falsifier: SameRegular without IsRegular() returns true here.
func TestSameRegularRefusesAFIFOWithTheSameIdentity(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a.json")
	if err := syscall.Mkfifo(p, 0o600); err != nil {
		t.Skip("no mkfifo:", err)
	}
	before, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(p, os.O_RDONLY|NonblockFlag, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, opened) {
		t.Fatal("fixture: a FIFO's Lstat and fstat should be the same file")
	}
	if SameRegular(before, opened) {
		t.Fatal("SameRegular accepted a FIFO with the same identity")
	}
}

// t-adcb: a regular file swapped for a FIFO after OpenRegular's Lstat is refused at once, not read and not waited on; an
// untouched regular file opens. Falsifier: the open without NonblockFlag blocks on the FIFO past the deadline.
func TestOpenRegularFIFOSwapAfterLstat(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "a.json")
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	f, fi, err := OpenRegular(p)
	if err != nil || fi.Size() != 1 {
		t.Fatalf("a regular file: %v %v", fi, err)
	}
	f.Close()
	var fifoErr error
	t.Cleanup(func() { afterLstat = nil })
	afterLstat = func() {
		os.Remove(p)
		fifoErr = syscall.Mkfifo(p, 0o600)
	}
	done := make(chan error, 1)
	go func() {
		f, _, err := OpenRegular(p)
		if f != nil {
			f.Close()
		}
		done <- err
	}()
	select {
	case err := <-done:
		if fifoErr != nil {
			t.Skip("no mkfifo:", fifoErr)
		}
		if !errors.Is(err, ErrNotRegular) { // the file opened is a FIFO on every OS, whatever its inode
			t.Fatalf("a file swapped for a FIFO: err %v, want ErrNotRegular", err)
		}
	case <-time.After(2 * time.Second):
		if w, err := os.OpenFile(p, os.O_WRONLY|syscall.O_NONBLOCK, 0); err == nil {
			w.Close() // release the blocked reader
		}
		t.Fatal("OpenRegular blocked on a file swapped for a FIFO")
	}
}

// t-adcb mutation sweep: OpenRegular's other refusals. A regular file swapped for another regular file is ErrChanged (the
// identity half of SameRegular); a socket is refused at the Lstat as ErrNotRegular (its open fails with an unrelated
// error); a missing path is the Lstat's own not-exist error. The texts are the ones seal's errors.Is callers share.
func TestOpenRegularOtherRefusals(t *testing.T) {
	if ErrNotRegular.Error() != "not a regular file" || ErrChanged.Error() != "changed while opening" {
		t.Fatalf("texts: %q %q", ErrNotRegular, ErrChanged)
	}
	d := t.TempDir()
	a, b := filepath.Join(d, "a"), filepath.Join(d, "b")
	for _, p := range []string{a, b} {
		if err := os.WriteFile(p, []byte(p), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	la, _ := os.Lstat(a)
	lb, _ := os.Lstat(b)
	if SameRegular(la, lb) {
		t.Fatal("SameRegular matched two different regular files")
	}
	t.Cleanup(func() { afterLstat = nil })
	afterLstat = func() { os.Rename(b, a) }
	if f, _, err := OpenRegular(a); !errors.Is(err, ErrChanged) {
		if f != nil {
			f.Close()
		}
		t.Fatalf("a regular file swapped for another: err %v, want ErrChanged", err)
	}
	afterLstat = nil
	if _, _, err := OpenRegular(filepath.Join(d, "missing")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a missing path: err %v, want not-exist", err)
	}
	sock := filepath.Join(d, "s")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Skip("no unix socket:", err)
	}
	defer l.Close()
	if _, _, err := OpenRegular(sock); !errors.Is(err, ErrNotRegular) {
		t.Fatalf("a socket: err %v, want ErrNotRegular", err)
	}
}
