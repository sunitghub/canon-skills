//go:build !windows

package daemon

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-68ae: the daemon refuses to start, before it listens or writes its token, when COCKPIT_STATE_DIR is open to
// other accounts, and says which folder.
func TestRunRefusesOpenStateDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ck")
	os.Mkdir(dir, 0o755)
	os.Chmod(dir, 0o755)
	t.Setenv("COCKPIT_STATE_DIR", dir)
	r, w, _ := os.Pipe()
	old := os.Stderr
	os.Stderr = w
	code := Run("test", "dev", []string{"-addr", "127.0.0.1:0"})
	os.Stderr = old
	w.Close()
	out, _ := io.ReadAll(r)
	if code != 1 || !strings.Contains(string(out), "cockpit-daemon: cockpit state folder "+dir) || !strings.Contains(string(out), "0700") {
		t.Fatalf("Run = %d, stderr %q; want 1 naming %s and 0700", code, out, dir)
	}
	if _, err := os.Stat(filepath.Join(dir, "daemon.json")); err == nil {
		t.Fatal("the daemon wrote daemon.json into an open state folder")
	}
}
