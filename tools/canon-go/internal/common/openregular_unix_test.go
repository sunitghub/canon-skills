//go:build !windows

package common

import (
	"errors"
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
