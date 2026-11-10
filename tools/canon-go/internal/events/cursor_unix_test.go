//go:build !windows

package events

import (
	"os"
	"path/filepath"
	"testing"
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
