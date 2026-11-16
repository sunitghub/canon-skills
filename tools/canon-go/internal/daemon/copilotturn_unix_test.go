//go:build !windows

package daemon

import (
	"path/filepath"
	"syscall"
	"testing"
)

// t-c723: a FIFO in the log's place is never opened (an open would block the watcher).
func TestCopilotTurnRefusesFIFO(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	if sts, err := (&copilotTurn{}).read(path); err != errNotRegular || sts != nil {
		t.Fatalf("FIFO log: got %q, %v; want errNotRegular", sts, err)
	}
}
