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
	if _, hasAddr := out["addr"]; out["running"] != false || !hasAddr || !strings.Contains(msg, dir) || !strings.Contains(msg, "0700") {
		t.Fatalf("ensureCockpit = %v; want running=false and an error naming %s and 0700", out, dir)
	}
}

// A private (0700) state folder is read as before: the daemon pid and interrupted sessions come from it.
func TestStateFilesReadFromPrivateStateDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ck")
	os.Mkdir(dir, 0o700)
	os.WriteFile(filepath.Join(dir, "daemon.json"), []byte(`{"addr":"127.0.0.1:1","pid":"4242"}`), 0o600)
	os.WriteFile(filepath.Join(dir, "interrupted.json"), []byte(`[{"id":"t-abcd"}]`), 0o600)
	t.Setenv("COCKPIT_STATE_DIR", dir)
	if pid := readDaemonPID(); pid != 4242 {
		t.Fatalf("readDaemonPID = %d, want 4242", pid)
	}
	if es := readInterrupted(); len(es) != 1 || es[0]["id"] != "t-abcd" {
		t.Fatalf("readInterrupted = %v", es)
	}
	if addr, healthy := discoverCockpitAddr(); addr != "127.0.0.1:1" || healthy {
		// 127.0.0.1:1 never answers /healthz: the addr is read, and reported unhealthy.
		t.Fatalf("discoverCockpitAddr = %q, %v; want 127.0.0.1:1, false", addr, healthy)
	}
}
