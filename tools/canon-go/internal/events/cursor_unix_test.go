//go:build !windows

package events

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// Prod path: a day file that cannot be opened is an error from every reader, never a shorter log (t-8d45).
func TestAnUnreadableDayIsAnError(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads anything")
	}
	home, dir := logWith(t, map[string]string{"2026-11-10.jsonl": evLine(1, "/p")})
	path := filepath.Join(dir, "2026-11-10.jsonl")
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(path, 0o600) })
	if _, _, err := ReadSince(home, Cursor{"2026-11-10", 0}, 10); err == nil {
		t.Error("ReadSince")
	}
	if _, _, err := Newest(home, 10, func(Event) bool { return true }); err == nil {
		t.Error("Newest")
	}
	if _, err := End(home); err == nil {
		t.Error("End")
	}
}

// t-adcb: seal's openRegular goes through common.OpenRegular. A FIFO at a day log's path is errNotRegular (seal.go branches
// on it with errors.Is) and returns at once. Protects event sealing of the board's event log.
// Falsifier: errNotRegular no longer aliasing common.ErrNotRegular fails errors.Is.
func TestSealOpenRegularRefusesAFIFO(t *testing.T) {
	p := filepath.Join(t.TempDir(), "2026-11-27.jsonl")
	if err := syscall.Mkfifo(p, 0o600); err != nil {
		t.Skip("no mkfifo:", err)
	}
	done := make(chan error, 1)
	go func() {
		f, err := openRegular(p, dayMaxBytes)
		if f != nil {
			f.Close()
		}
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, errNotRegular) {
			t.Fatalf("a FIFO day log: err %v, want errNotRegular", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("openRegular blocked on a FIFO")
	}
}
