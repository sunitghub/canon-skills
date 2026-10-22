//go:build !windows

package common

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSecureStateDir(t *testing.T) {
	base := t.TempDir()

	missing := filepath.Join(base, "new", "canon-cockpit")
	if err := SecureStateDir(missing); err != nil {
		t.Fatalf("missing folder: %v", err)
	}
	if fi, _ := os.Stat(missing); fi.Mode().Perm() != 0o700 {
		t.Fatalf("created mode %04o, want 0700", fi.Mode().Perm())
	}

	open := filepath.Join(base, "open")
	os.Mkdir(open, 0o755)
	os.Chmod(open, 0o755)
	if err := SecureStateDir(open); err == nil || !strings.Contains(err.Error(), "must be 0700") {
		t.Fatalf("0755 folder must be refused, got %v", err)
	}
	if fi, _ := os.Stat(open); fi.Mode().Perm() != 0o755 {
		t.Fatal("SecureStateDir must never chmod an existing folder")
	}

	link := filepath.Join(base, "link")
	os.Symlink(missing, link)
	if err := SecureStateDir(link); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("symlinked folder must be refused, got %v", err)
	}

	file := filepath.Join(base, "file")
	os.WriteFile(file, nil, 0o600)
	if err := SecureStateDir(file); err == nil {
		t.Fatal("a file in place of the folder must be refused")
	}
}

func TestDefaultCockpitStateDirIsPerUser(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/4242")
	if got := DefaultCockpitStateDir(); got != "/run/user/4242/canon-cockpit" {
		t.Fatalf("DefaultCockpitStateDir = %q", got)
	}
	t.Setenv("XDG_RUNTIME_DIR", "")
	if got := DefaultCockpitStateDir(); strings.HasPrefix(got, os.TempDir()) {
		if _, err := os.UserCacheDir(); err == nil {
			t.Fatalf("with a user cache dir the default must not be under %s, got %q", os.TempDir(), got)
		}
	}
}
