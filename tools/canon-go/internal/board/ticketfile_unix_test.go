//go:build !windows

package board

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// Protects the ticket loader against a FIFO named like a ticket file (t-ca73): os.ReadFile blocked on it forever, which hung
// /api/tickets and /api/v1/tickets. The loader must answer, with the other tickets, in well under the timeout.

func TestTicketFileFIFOsDoNotBlockTheLoader(t *testing.T) {
	for _, name := range []string{"ticket.md", "acceptance.md", "plan.md"} {
		root := setupTestProject(t)
		writeTicket(t, root, "t-good")
		dir := writeTicket(t, root, "t-fifo")
		fifo := filepath.Join(dir, name)
		if name == "ticket.md" {
			os.Remove(fifo)
		}
		if err := syscall.Mkfifo(fifo, 0o600); err != nil {
			t.Skip("no mkfifo:", err)
		}
		done := make(chan map[string]ticket, 1)
		go func() { done <- ticketIDs(root) }()
		select {
		case got := <-done:
			if got["t-good"] == nil {
				t.Errorf("%s: the other ticket vanished: %v", name, got)
			}
			if _, listed := got["t-fifo"]; listed != (name != "ticket.md") {
				t.Errorf("%s: t-fifo listed=%v", name, listed)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%s as a FIFO blocked the loader", name)
		}
	}
}

// t-2800: the board's theme list reads each file through the themes folder's os.Root. A theme swapped for a FIFO after
// its Lstat must not block (the nonblock open) and reads as "not a regular file"; a symlinked theme is never read.
func TestThemeReadThroughRootFIFOSwapAndSymlink(t *testing.T) {
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "a.json"), []byte(`{"name":"A","mode":"dark","colors":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	calls := 0
	var fifoErr error
	t.Cleanup(func() { afterPathCheck = nil })
	afterPathCheck = func() { // runs on themeRead's goroutine: no t.Skip/Fatal here
		calls++
		if calls == 2 { // after the Lstat, before the open
			os.Remove(filepath.Join(d, "a.json"))
			fifoErr = syscall.Mkfifo(filepath.Join(d, "a.json"), 0o600)
		}
	}
	done := make(chan string, 1)
	go func() { _, reason := themeRead(d, "a.json"); done <- reason }()
	select {
	case reason := <-done:
		if fifoErr != nil {
			t.Skip("no FIFOs here")
		}
		if reason != "not a regular file" {
			t.Fatalf("a theme swapped for a FIFO: reason %q, want \"not a regular file\"", reason)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("themeRead hung on a theme swapped for a FIFO")
	}
	afterPathCheck = nil
	if err := os.Symlink(filepath.Join(d, "a.json"), filepath.Join(d, "b.json")); err != nil {
		t.Fatal(err)
	}
	if _, reason := themeRead(d, "b.json"); reason != "symbolic links are not read" {
		t.Fatalf("a symlinked theme: reason %q", reason)
	}
	// and a plain valid theme is still read through the root (mutation sweep: a dropped open went unnoticed)
	writeFile(t, filepath.Join(d, "c.json"), fuzzTheme)
	if th, reason := themeRead(d, "c.json"); reason != "" || th.Name == "" {
		t.Fatalf("a valid theme: %+v, reason %q", th, reason)
	}
}
