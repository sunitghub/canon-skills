//go:build !windows

package board

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Prod path: a cursor never makes the route open a file it should not (t-8d45): a FIFO named like a day file would hang any read of it, so a cursor for
// that day, and the snapshot beside it, must answer at once (a 400, and the snapshot as if the FIFO were not there).
func TestAPIv1EventsDoNotOpenAFifoNamedLikeADay(t *testing.T) {
	f := newEvFix(t)
	f.append("2026-11-10", f.line(1, f.proj))
	if err := syscall.Mkfifo(filepath.Join(f.home, "events", "2026-11-09.jsonl"), 0o600); err != nil {
		t.Skip("no FIFOs here")
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		resp := f.get("/api/v1/events/stream?cursor=2026-11-09:0", nil)
		body, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != 400 {
			t.Errorf("cursor into a FIFO day: %d %s", resp.StatusCode, body)
		}
		if w := v1Get(t, "GET", "/api/v1/events", ""); w.Code != 200 {
			t.Errorf("snapshot beside a FIFO: %d %s", w.Code, w.Body)
		}
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("the request hung: a FIFO was opened")
	}
}

// Prod path: a log that cannot be read is a 500 with a fixed message and one JSON document, never an empty answer (t-8d45): the snapshot, and a stream
// that has to find the end of the log.
func TestAPIv1EventsAnUnreadableLogIsAFixedFiveHundred(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads anything")
	}
	f := newEvFix(t)
	f.append("2026-11-10", f.line(1, f.proj))
	day := filepath.Join(f.home, "events", "2026-11-10.jsonl")
	if err := os.Chmod(day, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(day, 0o600) })
	snap := v1Get(t, "GET", "/api/v1/events", "")
	if snap.Code != 500 || oneJSON(t, snap.Body.Bytes())["error"] != "cannot read the event log" {
		t.Errorf("snapshot: %d %s", snap.Code, snap.Body)
	}
	resp := f.get("/api/v1/events/stream", nil)
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 500 || oneJSON(t, body)["error"] != "cannot read the event log" || strings.Contains(string(body), f.home) {
		t.Errorf("stream: %d %s", resp.StatusCode, body)
	}
}
