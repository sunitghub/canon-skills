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
