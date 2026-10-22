//go:build !windows

package board

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// t-68ae: the board never starts the daemon into, or reads daemon.json from, a state folder another account could
// write. A 0755 COCKPIT_STATE_DIR makes the cockpit status report the folder instead of launching.
func TestEnsureCockpitRefusesOpenStateDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ck")
	os.Mkdir(dir, 0o755)
	os.Chmod(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "daemon.json"), []byte(`{"addr":"127.0.0.1:1","pid":"1"}`), 0o644)
	t.Setenv("COCKPIT_STATE_DIR", dir)
	bin := filepath.Join(t.TempDir(), "cockpit-daemon")
	os.WriteFile(bin, []byte("#!/bin/sh\nexit 1\n"), 0o755)
	old := cockpitDaemonBin
	cockpitDaemonBin = bin
	defer func() { cockpitDaemonBin = old }()

	if pid := readDaemonPID(); pid != 0 {
		t.Fatalf("readDaemonPID read pid %d from an open state folder; want 0", pid)
	}
	out := ensureCockpit()
	msg, _ := out["error"].(string)
	if out["running"] != false || !strings.Contains(msg, dir) || !strings.Contains(msg, "0700") {
		t.Fatalf("ensureCockpit = %v; want running=false and an error naming %s and 0700", out, dir)
	}
}
